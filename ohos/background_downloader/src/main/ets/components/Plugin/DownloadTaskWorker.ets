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
      return TaskStatus.failed
    }
    const httpRequest = http.createHttp()
    let response: http.HttpResponse | undefined
    try {
      httpOptions.header = header;
      response = await httpRequest.request(this.task.url, httpOptions);
    } catch (e) {
      console.error(DownloadTaskWorker.DownloadTaskWorkerTag, "http request threw", e);
      this.setTaskException(e as string)
      return TaskStatus.failed
    }
    console.error(DownloadTaskWorker.DownloadTaskWorkerTag, "http response code", response.responseCode, "url", this.task.url);
    this.responseStatusCode = response.responseCode
    const headerMap = new Map<string, string>()
    Object.keys(response.header ?? {}).forEach(key => {
      const lowerKey = key.toLowerCase()
      const value = (response!.header as Record<string, string>)[key]
      headerMap.set(lowerKey, value)
    })
    if (response.responseCode >= 200 && response.responseCode <= 206) {
      const directoryUri = this.task.directory?.length ? new uri.URI(this.task.directory) : undefined
      const usesUri = directoryUri != undefined
      this.eTagHeader = headerMap.get("etag") ?? undefined
      const acceptRangesHeader = headerMap.get("accept-ranges")
      this.serverAcceptsRanges = acceptRangesHeader == "bytes" || response.responseCode == 206
      if (this.task.allowPause && !usesUri) {
        this.taskCanResume = this.serverAcceptsRanges
        super.processCanResume(this.task, this.taskCanResume)
      }
      this.isResume = this.isResume && response.responseCode == 206
      if (this.isResume) {
        this.taskRangeStartByte = parseRange(this.task.headers.get("Range") ?? "")[0]
        if (!this.prepareResume(headerMap)) {
          this.deleteTempFile()
          return TaskStatus.failed
        }
        if (this.eTagHeader != this.eTag || (this.eTag && this.eTag.startsWith("W/"))) {
          this.deleteTempFile()
          this.taskException = new TaskException(ExceptionType.resume, undefined,
            "Cannot resume: ETag is not identical, or is weak")
          return TaskStatus.failed
        }
      }

      if (this.applicationContext == undefined) {
        console.error(DownloadTaskWorker.DownloadTaskWorkerTag + this.applicationContext + DownloadTaskWorker.DownloadTaskWorkerTag + "is undefined")
        return TaskStatus.failed;
      }
      let destFilePath = this.task.filePath(this.applicationContext!);
      let destUriString = this.task.filename
      if (!this.task.hasFilename()) {
        if (usesUri) {
          destUriString = suggestFilename(headerMap, this.task.url)
          if (destUriString.length == 0) {
            destUriString = Math.floor(Math.random() * 1000000000).toString()
          }
          this.task = this.task.copyWith({ filename: destUriString })
        } else {
          destFilePath = this.destFilePath(headerMap)
        }
      }
      super.extractResponseHeaders(headerMap)
      super.extractContentType(headerMap)
      const contentLength = getContentLength(headerMap, this.task)
      let tempFile: string | undefined
      if (!usesUri) {
        const prefOptions: preferences.Options = { name: "DEFAULT" }
        const prefs = preferences.getPreferencesSync(this.applicationContext!, prefOptions)
        const applicationSupportPath = baseDirPath(this.applicationContext!, BaseDirectory.applicationSupport)
        const cachePath = baseDirPath(this.applicationContext!, BaseDirectory.temporary)
        if (!applicationSupportPath || !cachePath) {
          this.taskException = new TaskException(ExceptionType.fileSystem, undefined,
            "External storage is requested but not available")
          return TaskStatus.failed
        }
        const configUseCacheDir = prefs.getSync(BDPlugin.keyConfigUseCacheDir, -2) as number
        const tempDir =
          configUseCacheDir == 0 ? cachePath : (configUseCacheDir == -1 ? applicationSupportPath : cachePath)
        try {
          fs.accessSync(tempDir)
        } catch (_) {
          fs.mkdirSync(tempDir)
        }
        if (this.tempFilePath.length == 0) {
          this.tempFilePath = `${tempDir}/com.bbflight.background_downloader${Math.floor(Math.random() * 1000000000)}`
        }
        if (insufficientSpace(this.applicationContext!, contentLength)) {
          this.taskException = new TaskException(ExceptionType.fileSystem, undefined,
            "Insufficient space to store the file to be downloaded")
          return TaskStatus.failed
        }
        tempFile = this.tempFilePath
      }
      console.error(DownloadTaskWorker.DownloadTaskWorkerTag, "destFilePath", destFilePath, "tempFile", tempFile, "contentLength", contentLength);
      let outputStream: fs.File | undefined
      if (tempFile) {
        const openMode = this.isResume
          ? fs.OpenMode.READ_WRITE | fs.OpenMode.APPEND
          : fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE
        outputStream = fs.openSync(tempFile, openMode)
        console.error(DownloadTaskWorker.DownloadTaskWorkerTag, "opened tempFile", tempFile, "openMode", openMode)
      } else {
        console.error(DownloadTaskWorker.DownloadTaskWorkerTag, "no tempFile, usesUri flow");
      }
      //BDPlugin.remainingBytesToDownload.set(this.task.taskId, contentLength)
      super.determineRunInForeground(this.task, contentLength)
      let transferResult: TaskStatus = TaskStatus.failed
      try {
        const dataToWrite = typeof response.result === 'string'
          ? new util.TextEncoder().encodeInto(response.result as string)
          : (response.result as ArrayBuffer ?? new ArrayBuffer(0))
        const bytes = dataToWrite instanceof ArrayBuffer ? new Uint8Array(dataToWrite) : dataToWrite
        this.bytesTotal += bytes.byteLength
        console.error(DownloadTaskWorker.DownloadTaskWorkerTag, "about to write bytes", bytes.byteLength, "result type", typeof response.result);
        transferResult = TaskStatus.complete
        if (outputStream) {
          const buffer = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength)
          fs.writeSync(outputStream.fd, buffer)
          fs.closeSync(outputStream)

          console.error(DownloadTaskWorker.DownloadTaskWorkerTag, "writeSync ok, closed outputStream");
        }
      } catch (e) {
        this.setTaskException(e as ESObject)
        console.error(DownloadTaskWorker.DownloadTaskWorkerTag, "write failed", (e as Error).message ?? e);
        transferResult = TaskStatus.failed
      }
      switch (transferResult as number) {
        case TaskStatus.complete:
          if (tempFile) {
            fs.copyFileSync(tempFile, destFilePath)
            await this.saveFileToDownloads(tempFile,this.task.filename);
          }
          return TaskStatus.complete
        case TaskStatus.canceled as number:
          this.deleteTempFile()
          return TaskStatus.canceled
        case TaskStatus.paused as number:
          await TaskWorker.workerShareableData!.withLock(() => {
            TaskWorker.workerShareableData!.pausedTaskIds.delete(this.task!.taskId);  //share
          })
          if (this.taskCanResume) {
            this.processResumeData(new ResumeData({
              task: this.task,
              data: this.tempFilePath,
              requiredStartByte: this.bytesTotal + this.startByte,
              eTag: this.eTagHeader
            }), this.prefs!)
            return TaskStatus.paused
          }

          let shouldStoreResumeData = false;
          await TaskWorker.workerShareableData!.withLock(() => {
            shouldStoreResumeData = TaskWorker.workerShareableData!.tasksToReEnqueue.has(this.task!) && this.serverAcceptsRanges
          })

          if (shouldStoreResumeData) {
            const resumeData = new ResumeData({
              task: this.task,
              data: this.tempFilePath,
              requiredStartByte: this.bytesTotal + this.startByte,
              eTag: this.eTagHeader
            })
            await TaskWorker.workerShareableData!.withLock(() => {
              TaskWorker.workerShareableData!.localResumeData.set(this.task!.taskId, resumeData)
            })
            return TaskStatus.paused
          }
          this.deleteTempFile()
          this.taskException = new TaskException(ExceptionType.resume, undefined, "Task was paused but cannot resume")
          return TaskStatus.failed;
        case TaskStatus.enqueued as number:
          if (!this.task.allowPause) {
            this.taskException = new TaskException(ExceptionType.connection, undefined, "Task timed out")
            return TaskStatus.failed
          }
          if (this.taskCanResume) {
            let start = this.bytesTotal + this.startByte
            await BDPlugin.doEnqueue(
              this.applicationContext!,
              this.task,
              this.notificationConfigJsonString,
              new ResumeData({
                task: this.task,
                data: this.tempFilePath,
                requiredStartByte: start,
                eTag: this.eTag
              }),
              1000
            )
            return TaskStatus.paused
          }
          this.taskException = new TaskException(ExceptionType.connection, undefined, "Task timed out")
          this.deleteTempFile()
          return TaskStatus.failed;
        case TaskStatus.failed as number:
          await this.prepResumeAfterFailure();
        default:
          return TaskStatus.failed
      }
    } else {
      const errorContent = response.result as string
      this.taskException = new TaskException(ExceptionType.httpResponse, response.responseCode, errorContent)
      if (response.responseCode == 404) {
        this.responseBody = errorContent
        return TaskStatus.notFound
      }
      console.error(DownloadTaskWorker.DownloadTaskWorkerTag, "http non-2xx, code", response.responseCode, "body", errorContent);
      return TaskStatus.failed
    }
  }

  async saveFileToDownloads(source:string,filename:string) {
    const documentViewPicker = new picker.DocumentViewPicker(this.applicationContext!);
    // 创建保存选项并配置为下载模式（直接保存到下载目录，无需用户选择）
    const documentSaveOptions = new picker.DocumentSaveOptions();
    documentSaveOptions.pickerMode = picker.DocumentPickerMode.DOWNLOAD;
    let uri: string = '';

    await documentViewPicker.save(documentSaveOptions)
      .then(async (documentSaveResult: Array<string>) => {
        // 成功获取下载目录URI
        uri = documentSaveResult[0];
        console.info('获取下载目录成功，URI：' + uri);

        // 构建要创建的文件路径（在下载目录下）
        const testFilePath01 = new fileUri.FileUri(uri + '/' + filename).path; // 图片文件路径

        // 同步创建并打开文件（权限：创建+读写）
        const file01 = fs.openSync(testFilePath01, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE);

        // 同步关闭文件（释放资源）

        const stat = await fs.stat(source)
        const file = await fs.openSync(source,fs.OpenMode.READ_WRITE);
        const buf = new ArrayBuffer(stat.size);
        await fs.readSync(file.fd, buf);
        await fs.close(file);
        console.error("close source file success")

        fs.writeSync(file01.fd, buf);
        fs.closeSync(file01);
        //fs.copyFileSync(source, testFilePath01);
        // 显示保存成功提示
        //this.showDialog('文件保存成功');
      })
      .catch((err: BusinessError) => {
        // 操作失败：打印错误信息
        console.error(`下载目录文件保存失败，错误码：${err.code}，错误信息：${err.message}`);
      })
  }
}

type WorkerParamValue = string | number | boolean | sendableContextManager.SendableContext


const workerPort: ThreadWorkerGlobalScope = worker.workerPort;

workerPort.onmessage = async (event: MessageEvents) => {
  console.error("enter on message");
  let workercommand = event.data as WorkerCommand;

  let command = workercommand.command;
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
  console.error("enter on message:command is" + command);
  switch (command) {
    case "startWork": {
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
    default:
      break;
  }
}

workerPort.onmessageerror = () => {
  console.error(DownloadTaskWorker.DownloadTaskWorkerTag, 'workerPort onmessageerror for DownloadTaskWorker')
}

workerPort.onerror = (err: ErrorEvent) => {
  console.error(DownloadTaskWorker.DownloadTaskWorkerTag, 'workerPort onerror for DownloadTaskWorker:', err.message)
}


