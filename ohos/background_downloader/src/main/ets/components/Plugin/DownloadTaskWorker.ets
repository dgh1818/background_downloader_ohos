import { common, sendableContextManager } from '@kit.AbilityKit'
import {
  BaseDirectory,
  ExceptionType,
  ResumeData,
  ResumeDataInterface,
  TaskException,
  TaskStatus,
  Task
} from '../../../../../../src/main/ets/components/plugin/Models';
import { TaskWorker, TaskWorkerKey } from '../../../../../../src/main/ets/components/plugin/TaskWorker'
import { http } from '@kit.NetworkKit';
import { baseDirPath, FileUtils, getContentLength, insufficientSpace, parseRange, suggestFilename } from '../../../../../../src/main/ets/components/plugin/Helper';
import { fileIo as fs, fileUri, picker } from '@kit.CoreFileKit';
import BDPlugin, {
  WorkerCommand,
  WorkerShareableData } from '../../../../../../src/main/ets/components/plugin/BDPlugin';
import { collections, ErrorEvent, MessageEvents, ThreadWorkerGlobalScope, uri, util, worker } from '@kit.ArkTS';
import { preferences } from '@kit.ArkData';
import { NotificationConfig } from '../../../../../../src/main/ets/components/plugin/Notifications';
import { BusinessError } from '@kit.BasicServicesKit';

let httpRequest:http.HttpRequest;

interface ReEnqueueMessage {
  command: "reEnqueue";
  taskJson: string;
  notificationConfigJsonString?: string;
  resumeData?: ResumeData;
  initialDelayMillis: number;
}

class DownloadTaskWorker extends TaskWorker {
  constructor(applicationContext: common.UIAbilityContext,
    workerParams: collections.Map<string, string | number | boolean | ResumeData | undefined>) {
    super(applicationContext, workerParams);
  }

  public static DownloadTaskWorkerTag = "DownloadTaskWorker";
  public eTagHeader?: string;
  public serverAcceptsRanges = false // if true, send resume data on fail
  public tempFilePath = ""
  public requiredStartByte = 0 // required start byte within the task range
  public taskRangeStartByte = 0 // Start of the Task's download range
  public eTag?: string
  // progress throttle
  private lastProgressPct = -1
  private lastProgressTime = 0
  private static readonly progressPctThreshold = 1 // percent
  private static readonly progressTimeMsThreshold = 500 // ms

  public async startDoTask() {
    console.error(DownloadTaskWorker.DownloadTaskWorkerTag, "startDoTask begin");
    const result = await this.doTask();
    console.error(DownloadTaskWorker.DownloadTaskWorkerTag, "startDoTask done with status", result);
    return result;
  }

  /**
   * Make the request to the [connection] and process the [Task]
   *
   * Returns the [TaskStatus]
   * */
  override async connectAndProcess(httpOptions: http.HttpRequestOptions,
    header: Record<string, string>): Promise<TaskStatus> {
    if (this.isResume) {
      let taskRangeHeader = this.task?.headers.get("Range") ?? ""

      let taskRange = parseRange(taskRangeHeader)
      this.taskRangeStartByte = taskRange[0];
      let resumeRange: Array<number | undefined> = [this.taskRangeStartByte + this.requiredStartByte, taskRange[1]];
      let newRangeString = `bytes=${resumeRange[0]}-${resumeRange[1] ?? ''}`;
      header["Range"] = newRangeString


    }
    let result = await super.connectAndProcess(httpOptions, header);
    if (result == TaskStatus.canceled) {
      this.deleteTempFile()
    }
    if (result == TaskStatus.failed) {
      this.prepResumeAfterFailure();
    }
    return result
  }

  /**
   * Deletes the temp file associated with this download
   */
  private deleteTempFile() {
    if (this.tempFilePath.length != 0) {
      try {
        fs.unlinkSync(this.tempFilePath);
      } catch (e) {
        console.info(DownloadTaskWorker.DownloadTaskWorkerTag + "Could not delete temp file at" + this.tempFilePath);
      }
      // remove cached temp path for this task
      if (this.task && TaskWorker.workerShareableData) {
        TaskWorker.workerShareableData.tempFilePathByTaskId.delete(this.task.taskId);
      }
    }
  }

  /**
   * Attempt to allow resume after failure by sending resume data
   * back to Dart
   *
   * If this is not possible, the temp file will be deleted
   */

  private async prepResumeAfterFailure() {
    if (this.serverAcceptsRanges && this.bytesTotal + this.startByte > (1 << 20)) {
      let init: ResumeDataInterface = {
        task: this.task!,
        data: this.tempFilePath,
        requiredStartByte: this.bytesTotal + this.startByte,
        eTag: this.eTagHeader,

      }
      // if failure can be resumed, post resume data
      super.processResumeData(new ResumeData(init), this.prefs!)
    } else {
      // if it cannot be resumed, delete the temp file
      this.deleteTempFile();
    }
  }

  private prepareResume(headers: Map<string, string>): boolean {
    if (this.tempFilePath.length == 0) {
      return false
    }
    let contentRange = headers.get("content-range")
    if (!contentRange) {
      console.info(DownloadTaskWorker.DownloadTaskWorkerTag + "Could not process partial response Content-Range")
      return false
    }
    const contentRangeRegEx = /(\d+)-(\d+)\/(\d+)/
    const matchResult = contentRangeRegEx.exec(contentRange)
    if (!matchResult) {
      this.taskException = new TaskException(ExceptionType.resume, undefined,
        `Could not process partial response Content-Range ${contentRange}`)
      return false
    }
    const start = Number.parseInt(matchResult[1])
    const tempFileLength = fs.statSync(this.tempFilePath).size
    this.startByte = start - this.taskRangeStartByte
    if (this.startByte > tempFileLength) {
      this.taskException = new TaskException(ExceptionType.resume, undefined,
        `Offered range not feasible: ${contentRange} with startByte ${this.startByte}`)
      return false
    }
    try {
      const file = fs.openSync(this.tempFilePath, fs.OpenMode.READ_WRITE)
      fs.truncateSync(file.fd, this.startByte)
      fs.closeSync(file)
    } catch (e) {
      let message = (e as BusinessError).message;
      this.taskException = new TaskException(ExceptionType.resume, undefined,
        "Could not truncate temp file")
      return false
    }
    return true
  }

  private destFilePath(headers: Map<string, string>): string {
    const destFilePath = this.task!.filePath(this.applicationContext!)
    const updatedTask = this.task!.withSuggestedFilenameFromResponseHeaders(
      this.applicationContext!,
      headers,
      true
    )
    this.task = updatedTask
    const lastSlashIndex = destFilePath.lastIndexOf('/')
    const dirName = lastSlashIndex >= 0 ? destFilePath.substring(0, lastSlashIndex) : ""
    return dirName.length == 0 ? this.task!.filename : `${dirName}/${this.task!.filename}`
  }

  override async process(httpOptions: http.HttpRequestOptions, header: Record<string, string>): Promise<TaskStatus> {
    if (!this.task) {
      return TaskStatus.failed;
    }
    if (!this.prefs && this.applicationContext) {
      const prefOptions: preferences.Options = { name: "DEFAULT" };
      this.prefs = preferences.getPreferencesSync(this.applicationContext, prefOptions);
    }

    httpRequest = http.createHttp();
    const task = this.task;

    return await new Promise<TaskStatus>(async (resolve) => {
      let headerMap = new Map<string, string>();
      let destFilePath = "";
      let tempFile: string | undefined;
      let outputStream: fs.File | undefined;
      let contentLength = -1;
      let usesUri = false;
      let prepared = false;
      let dataReceived = false;
      let responseCode = 0;

      const cleanup = (status: TaskStatus) => {
        try {
          if (outputStream) {
            fs.closeSync(outputStream);
          }
        } catch (_) {
        }
        resolve(status);
      };

      httpRequest.on("headersReceive", (headerObj: Object) => {
        console.error("header is"+ JSON.stringify(headerObj));
        try {
          const respHeader = headerObj as Record<string, string> | undefined;
          if (respHeader) {
            const headerKeys = Object.keys(respHeader);
            console.error(
              DownloadTaskWorker.DownloadTaskWorkerTag,
              "headersReceive, header keys:",
              headerKeys.join(",")
            );
            headerKeys.forEach((key) => {
              const lowerKey = key.toLowerCase();
              const value = respHeader[key];
              headerMap.set(lowerKey, value);
            });
          } else {
            console.error(DownloadTaskWorker.DownloadTaskWorkerTag, "headersReceive, no headers present");
          }

          // headersReceive parses headers only; status code handled after request returns
          console.error(
            DownloadTaskWorker.DownloadTaskWorkerTag,
            "status 2xx, url",
            task.url,
            "contentLength header",
            headerMap.get("content-length"),
            "usesUri",
            usesUri
          );

          const directoryUri = task.directory?.length ? new uri.URI(task.directory) : undefined;
          usesUri = directoryUri != undefined;
          this.eTagHeader = headerMap.get("etag") ?? undefined;
          const acceptRangesHeader = headerMap.get("accept-ranges");
          this.serverAcceptsRanges = acceptRangesHeader == "bytes";
          if (task.allowPause && !usesUri) {
            this.taskCanResume = this.serverAcceptsRanges;
            super.processCanResume(task, this.taskCanResume);
          }
          // headersReceive parses headers only; status code handled after request returns
          if (this.isResume) {
            this.taskRangeStartByte = parseRange(task.headers.get("Range") ?? "")[0];
            if (!this.prepareResume(headerMap)) {
              this.deleteTempFile();
              cleanup(TaskStatus.failed);
              return;
            }
            if (this.eTagHeader != this.eTag || (this.eTag && this.eTag.startsWith("W/"))) {
              this.deleteTempFile();
              this.taskException = new TaskException(
                ExceptionType.resume,
                undefined,
                "Cannot resume: ETag is not identical, or is weak"
              );
              cleanup(TaskStatus.failed);
              return;
            }
          }

          if (this.applicationContext == undefined) {
            console.error(
              DownloadTaskWorker.DownloadTaskWorkerTag + this.applicationContext + DownloadTaskWorker.DownloadTaskWorkerTag + "is undefined"
            );
            cleanup(TaskStatus.failed);
            return;
          }

          destFilePath = task.filePath(this.applicationContext);
          let destUriString = task.filename;
          if (!task.hasFilename()) {
            if (usesUri) {
              destUriString = suggestFilename(headerMap, task.url);
              if (destUriString.length == 0) {
                destUriString = Math.floor(Math.random() * 1000000000).toString();
              }
              this.task = task.copyWith({ filename: destUriString });
            } else {
              destFilePath = this.destFilePath(headerMap);
            }
          }
          super.extractResponseHeaders(headerMap);
          super.extractContentType(headerMap);
          contentLength = getContentLength(headerMap, task);
          console.error("contentLength is"+ contentLength);
          if (!usesUri) {
            const prefOptions: preferences.Options = { name: "DEFAULT" };
            const prefs = preferences.getPreferencesSync(this.applicationContext!, prefOptions);
            const applicationSupportPath = baseDirPath(this.applicationContext!, BaseDirectory.applicationSupport);
            const cachePath = baseDirPath(this.applicationContext!, BaseDirectory.temporary);
            if (!applicationSupportPath || !cachePath) {
              this.taskException = new TaskException(
                ExceptionType.fileSystem,
                undefined,
                "External storage is requested but not available"
              );
              cleanup(TaskStatus.failed);
              return;
            }
            const configUseCacheDir = prefs.getSync(BDPlugin.keyConfigUseCacheDir, -2) as number;
            const tempDir = configUseCacheDir == 0 ? cachePath : (configUseCacheDir == -1 ? applicationSupportPath : cachePath);
            try {
              fs.accessSync(tempDir);
            } catch (_) {
              fs.mkdirSync(tempDir);
            }
            if (this.tempFilePath.length == 0) {
              this.tempFilePath = `${tempDir}/com.bbflight.background_downloader${Math.floor(Math.random() * 1000000000)}`;
            }
            if (TaskWorker.workerShareableData) {
              TaskWorker.workerShareableData.tempFilePathByTaskId.set(task.taskId, this.tempFilePath);
            }
            if (insufficientSpace(this.applicationContext!, contentLength)) {
              this.taskException = new TaskException(
                ExceptionType.fileSystem,
                undefined,
                "Insufficient space to store the file to be downloaded"
              );
              cleanup(TaskStatus.failed);
              return;
            }
            tempFile = this.tempFilePath;
          }
          console.error(
            DownloadTaskWorker.DownloadTaskWorkerTag,
            "destFilePath",
            destFilePath,
            "tempFile",
            tempFile,
            "contentLength",
            contentLength
          );
          if (tempFile) {
            const openMode = this.isResume ? fs.OpenMode.READ_WRITE | fs.OpenMode.APPEND : fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE;
            outputStream = fs.openSync(tempFile, openMode);
            console.error(DownloadTaskWorker.DownloadTaskWorkerTag, "opened tempFile", tempFile, "openMode", openMode);
          } else {
            console.error(DownloadTaskWorker.DownloadTaskWorkerTag, "no tempFile, usesUri flow");
          }
          super.determineRunInForeground(task, contentLength);
          prepared = true;
        } catch (e) {
          let message = (e as BusinessError).message;
          this.setTaskException(message);
          cleanup(TaskStatus.failed);
        }
      });

      httpRequest.on("dataReceive", (chunk: ArrayBuffer) => {
        //console.error(DownloadTaskWorker.DownloadTaskWorkerTag, "dataReceive len", chunk.byteLength, "contentLength", contentLength);
        if (!prepared || !task) {
          return;
        }
        try {
          dataReceived = true;
          const bytes = new Uint8Array(chunk);
          this.bytesTotal += bytes.byteLength;
          if (outputStream) {
            const buffer = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
            fs.writeSync(outputStream.fd, buffer);
            //console.error(DownloadTaskWorker.DownloadTaskWorkerTag, "write chunk bytes", bytes.byteLength, "total", this.bytesTotal);
          }
        } catch (e) {
          let message = (e as BusinessError).message;
          this.setTaskException(message);
          cleanup(TaskStatus.failed);
        }
      });

      httpRequest.on("dataReceiveProgress", (info: http.DataReceiveProgressInfo) => {
        const received = info.receiveSize ?? 0;
        const total = info.totalSize ?? contentLength;
        this.bytesTotal = Math.max(this.bytesTotal, received);
        if (total > 0) {
          const progressValue = Math.min(1.0, Number((received / total).toFixed(6)));
          const progressPct = Math.round(progressValue * 100);
          const now = Date.now();
          const pctDelta = this.lastProgressPct >= 0 ? Math.abs(progressPct - this.lastProgressPct) : 100;
          const timeDelta = now - this.lastProgressTime;
          if (pctDelta < DownloadTaskWorker.progressPctThreshold && timeDelta < DownloadTaskWorker.progressTimeMsThreshold) {
            return;
          }
          this.lastProgressPct = progressPct;
          this.lastProgressTime = now;
          // Use a non-integer sentinel for downloadSpeed to keep type as double over the channel
          //const downloadSpeedValue = this.task?.providesProgressUpdates() ? -1.000001 : -1.000001;
          workerPort.postMessage({
            command: "progressUpdate",
            progress: received / total,
            expectedFileSize: total,
            taskJson: TaskWorker.taskToJsonString(task!),
            downloadSpeed: -1,
            timeRemaining: -1000
          });
        }
        // console.error(
        //   DownloadTaskWorker.DownloadTaskWorkerTag,
        //   "dataReceiveProgress receivedSize",
        //   received,
        //   "totalSize",
        //   total
        // );
      });

      httpRequest.on("dataEnd", async () => {
        if (!prepared) {
          cleanup(TaskStatus.failed);
          return;
        }
        try {
          if (outputStream) {
            fs.closeSync(outputStream);
            outputStream = undefined;
          }
          if (tempFile) {
            fs.copyFileSync(tempFile, destFilePath);
            console.error(DownloadTaskWorker.DownloadTaskWorkerTag, "copied tempFile to dest", tempFile, destFilePath);
            //await this.saveFileToDownloads(tempFile, this.task!.filename);
            this.deleteTempFile();
          }
          // push a final progress update to 100% when finished (even if length unknown)
          workerPort.postMessage({
            command: "progressUpdate",
            progress: 1.0,
            expectedFileSize: contentLength,
            taskJson: TaskWorker.taskToJsonString(task),
            downloadSpeed: -1.0,
            timeRemaining: -1000
          });
          cleanup(TaskStatus.complete);
        } catch (e) {
          let message = (e as BusinessError).message;
          this.setTaskException(message);
          cleanup(TaskStatus.failed);
        }
      });

      try {
        httpOptions.header = header;
        httpOptions.expectDataType = http.HttpDataType.ARRAY_BUFFER;
        // Use streaming request and rely on dataReceive/dataEnd callbacks to write incrementally
        responseCode = await httpRequest.requestInStream(this.task!.url, httpOptions);
        console.error(DownloadTaskWorker.DownloadTaskWorkerTag, "request finished (stream), responseCode", responseCode);

        // If headersReceive/dataEnd did not finish, fall back to response code
        if (prepared == false) {
          const code = responseCode || 0;
          if (code < 200 || code > 206) {
            this.taskException = new TaskException(ExceptionType.httpResponse, code, "");
            cleanup(code == 404 ? TaskStatus.notFound : TaskStatus.failed);
          } else {
            console.error(DownloadTaskWorker.DownloadTaskWorkerTag, "prepared false but code ok", code);
          }
        }
      } catch (e) {
        let message = (e as BusinessError).message;
        this.setTaskException(message);
        console.error(DownloadTaskWorker.DownloadTaskWorkerTag, "request threw", message);
        cleanup(TaskStatus.failed);
      }
    });
  }

  async saveFileToDownloads(source:string,filename:string) {
    const documentViewPicker = new picker.DocumentViewPicker(this.applicationContext!);
    const documentSaveOptions = new picker.DocumentSaveOptions();
    documentSaveOptions.pickerMode = picker.DocumentPickerMode.DOWNLOAD;
    let uri: string = "";
    await documentViewPicker.save(documentSaveOptions)
      .then(async (documentSaveResult: Array<string>) => {
        uri = documentSaveResult[0];
        console.info("Obtained download directory URI: " + uri);
        const destPath = new fileUri.FileUri(uri + "/" + filename).path;
        const file01 = fs.openSync(destPath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE);
        const stat = await fs.stat(source);
        const file = await fs.openSync(source, fs.OpenMode.READ_WRITE);
        const buf = new ArrayBuffer(stat.size);
        await fs.readSync(file.fd, buf);
        await fs.close(file);
        console.error("close source file success");
        fs.writeSync(file01.fd, buf);
        fs.closeSync(file01);
      })
      .catch((err: BusinessError) => {
        console.error(`Failed to save file to download directory, code: ${err.code}, message: ${err.message}`);
      });
  }
}

type WorkerParamValue = string | number | boolean | sendableContextManager.SendableContext


const workerPort: ThreadWorkerGlobalScope = worker.workerPort;
let currentTaskId:string

function postReEnqueueMessage(
  task: Task,
  notificationConfigJsonString: string | undefined,
  tempFilePath: string,
  requiredStartByte: number,
  eTag?: string
) {
  const resumeData = new ResumeData({
    task,
    data: tempFilePath ?? "",
    requiredStartByte,
    eTag,
  });
  const message: ReEnqueueMessage = {
    command: "reEnqueue",
    taskJson: TaskWorker.taskToJsonString(task),
    notificationConfigJsonString,
    resumeData,
    initialDelayMillis: 1000,
  };
  workerPort.postMessageWithSharedSendable(message);
}

workerPort.onmessage = async (event: MessageEvents) => {
  console.error("enter on message");
  let workercommand = event.data as WorkerCommand;

  let command = workercommand.command;
  
  console.error("enter on message:command is" + command);
  switch (command) {
    case "startWork": {
      let sendableUIContext = workercommand.sendableUIContext;
      let taskWorkerData = workercommand.taskWorkerData;
      let workerShareableData = workercommand.workerShareableData;
      if(!workerShareableData) {
        return;
      }
      TaskWorker.workerShareableData = workerShareableData;

      let uiContext = sendableContextManager.convertToUIAbilityContext(sendableUIContext);
      if (!uiContext) {
        console.error(DownloadTaskWorker.DownloadTaskWorkerTag, 'DownloadTaskWorker requires a valid UI context')
        return;
      }
      // let TaskWorkerData = new collections.Map<string, string | number | boolean | ResumeData | undefined>();
      // taskWorkerData.forEach((value, key) => {
      //   TaskWorkerData.set(key, value);
      // });

      let worker = new DownloadTaskWorker(uiContext, taskWorkerData)
      console.error("startWork: worker instance created");
      let taskJson = taskWorkerData.get(TaskWorkerKey.keyTask) as string | undefined
      //worker.haveLoggedProxyMessage
      if (!taskJson) {
        console.error(DownloadTaskWorker.DownloadTaskWorkerTag, 'DownloadTaskWorker requires a task payload')
        return
      }
      worker.task = Task.fromPlain(JSON.parse(taskJson) as Task);
      currentTaskId = worker.task.taskId;
      console.error("startWork: task parsed:Json is "+taskJson);
      worker.notificationConfigJsonString =
        taskWorkerData.get(TaskWorkerKey.keyNotificationConfig) as string | undefined;
      worker.notificationConfig = worker.notificationConfigJsonString
        ? (JSON.parse(worker.notificationConfigJsonString) as NotificationConfig)
        : undefined
      console.error("startWork: notification config parsed");
      const resumeDataPath = taskWorkerData.get(TaskWorkerKey.keyResumeDataData) as string | undefined
      const requiredStartByte = taskWorkerData.get(TaskWorkerKey.keyStartByte) as number | undefined
      const resumeETag = taskWorkerData.get(TaskWorkerKey.keyETag) as string | undefined

      if (resumeDataPath !== undefined && requiredStartByte !== undefined) {
        worker.isResume = true
        worker.taskCanResume = true
      }
      worker.tempFilePath = resumeDataPath ?? "";
      worker.requiredStartByte = requiredStartByte ?? 0;
      worker.eTag = resumeETag
      const prefOptions: preferences.Options = { name: 'DEFAULT' }
      worker.prefs = preferences.getPreferencesSync(uiContext, prefOptions)
      workerPort.postMessage({
        command: "statusUpdate",
        status: TaskStatus.running,
        taskJson: taskToJsonString(worker.task!),
      });
      console.error("startWork: about to call startDoTask");
      let status = await worker.startDoTask();
      workerPort.postMessage({
        command: "statusUpdate",
        status: status,
        taskJson: TaskWorker.taskToJsonString(worker.task!),
        exception: worker.taskException,
        responseBody: worker.responseBody,
        responseStatusCode: worker.responseStatusCode,
      });
      console.error("startWork: startDoTask returned");
    }
      break;
    case "cancelWork": {
      console.error(DownloadTaskWorker.DownloadTaskWorkerTag, "received cancelWork, destroying httpRequest");
      try {
        httpRequest?.destroy();
      } catch (e) {
        let error = e as BusinessError;
        console.error(DownloadTaskWorker.DownloadTaskWorkerTag, "error destroying httpRequest on cancel", error.message);
      }
    }
      break;
    default:
      break;
  }
}

workerPort.onmessageerror = () => {
  console.error(DownloadTaskWorker.DownloadTaskWorkerTag, 'workerPort onmessageerror for DownloadTaskWorker')
}

workerPort.onerror = (err: ErrorEvent) => {
  console.error(DownloadTaskWorker.DownloadTaskWorkerTag, 'workerPort onexit', err.message);
  // on abnormal exit, try to clean temp file
  if (TaskWorker.workerShareableData) {
    // taskId may not be available here; best-effort cleanup by iterating known temp files
    const paths = TaskWorker.workerShareableData?.tempFilePathByTaskId;
    const tempPath = paths?.get(currentTaskId);
    if (tempPath) {
      try {
        fs.unlinkSync(tempPath);
        console.info(`${DownloadTaskWorker.DownloadTaskWorkerTag} deleted temp file ${tempPath} for task ${currentTaskId}`);
      } catch (e) {
      }
      paths?.delete(currentTaskId);
      httpRequest.destroy();
    }
  }
}
