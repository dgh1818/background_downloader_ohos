import { common, sendableContextManager } from '@kit.AbilityKit'
import {
  BaseDirectory,
  ExceptionType,
  ResumeData,
  ResumeDataInterface,
  SendableTask,
  TaskException,
  TaskStatus,
  Task
} from './Models';
import { TaskWorker, TaskWorkerKey } from './TaskWorker'
import { http } from '@kit.NetworkKit';
import { baseDirPath, FileUtils, getContentLength, insufficientSpace, parseRange, suggestFilename } from './Helper';
import { fileIo as fs } from '@kit.CoreFileKit';
import BDPlugin, { SendableObject } from './BDPlugin';
import { collections, ErrorEvent, MessageEvents, ThreadWorkerGlobalScope, uri, util, worker } from '@kit.ArkTS';
import { preferences } from '@kit.ArkData';
import { NotificationConfig } from './Notifications';

class DownloadTaskWorker extends TaskWorker {
  constructor(applicationContext: common.UIAbilityContext,
    workerParams: Map<string, string | number | boolean | ResumeData | undefined>) {
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
    return this.doTask(); // 在类内部，访问 protected 没问题
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
    let sendableTask = new SendableTask(this.task!)

    if (this.serverAcceptsRanges && this.bytesTotal + this.startByte > (1 << 20)) {
      let init: ResumeDataInterface = {
        task: sendableTask,
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
      this.setTaskException(e as string)
      return TaskStatus.failed
    }
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
      let outputStream: fs.File | undefined
      if (tempFile) {
        const openMode = this.isResume
          ? fs.OpenMode.READ_WRITE | fs.OpenMode.APPEND
          : fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE
        outputStream = fs.openSync(tempFile, openMode)
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
        transferResult = TaskStatus.complete
        if (outputStream) {
          fs.writeSync(outputStream.fd, bytes)
          fs.closeSync(outputStream)
        }
      } catch (e) {
        this.setTaskException(e as ESObject)
        transferResult = TaskStatus.failed
      }
      switch (transferResult as number) {
        case TaskStatus.complete:
          if (tempFile) {
            fs.copyFileSync(tempFile, destFilePath)
          }
          return TaskStatus.complete
        case TaskStatus.canceled as number:
          this.deleteTempFile()
          return TaskStatus.canceled
        case TaskStatus.paused as number:
          BDPlugin.pausedTaskIds.delete(this.task.taskId);
          if (this.taskCanResume) {
            this.processResumeData(new ResumeData({
              task: new SendableTask(this.task),
              data: this.tempFilePath,
              requiredStartByte: this.bytesTotal + this.startByte,
              eTag: this.eTagHeader
            }), this.prefs!)
            return TaskStatus.paused
          }

          if (BDPlugin.tasksToReEnqueue.has(this.task!) && this.serverAcceptsRanges) {

          }

          if (BDPlugin.tasksToReEnqueue.has(this.task) && this.serverAcceptsRanges) {
            BDPlugin.localResumeData.set(this.task.taskId, new ResumeData({
              task: new SendableTask(this.task),
              data: this.tempFilePath,
              requiredStartByte: this.bytesTotal + this.startByte,
              eTag: this.eTagHeader
            }))
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
                task: new SendableTask(this.task),
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
      return TaskStatus.failed
    }
  }
}

type WorkerParamValue = string | number | boolean | sendableContextManager.SendableContext


const workerPort: ThreadWorkerGlobalScope = worker.workerPort;
workerPort.onmessage = async (event: MessageEvents) => {
  console.error("enter on message");
  const data = event.data as SendableObject;
  if (data == undefined) {
    return;
  }
  let command = data.command;
  let sendableUIContext = data.sendableContext;
  let uiContext = sendableContextManager.convertToUIAbilityContext(sendableUIContext);
  if (!uiContext) {
    console.error(DownloadTaskWorker.DownloadTaskWorkerTag, 'DownloadTaskWorker requires a valid UI context')
    return;
  }
  console.error("enter on message:command is" + command);
  switch (command) {
    case "startWork": {
      let SendableTaskWorkerData = data.taskWorkerData;
      let TaskWorkerData = new Map<string, string | number | boolean | ResumeData | undefined>();
      SendableTaskWorkerData.forEach((value, key) => {
        TaskWorkerData.set(key, value);
      });

      let worker = new DownloadTaskWorker(uiContext, TaskWorkerData)
      let taskJson = TaskWorkerData.get(TaskWorkerKey.keyTask) as string | undefined
      if (!taskJson) {
        console.error(DownloadTaskWorker.DownloadTaskWorkerTag, 'DownloadTaskWorker requires a task payload')
        return
      }
      worker.task = Task.fromSendableTask(JSON.parse(taskJson) as SendableTask)
      worker.notificationConfigJsonString =
        TaskWorkerData.get(TaskWorkerKey.keyNotificationConfig) as string | undefined;
      worker.notificationConfig = worker.notificationConfigJsonString
        ? (JSON.parse(worker.notificationConfigJsonString) as NotificationConfig)
        : undefined
      const resumeDataPath = TaskWorkerData.get(TaskWorkerKey.keyResumeDataData) as string | undefined
      const requiredStartByte = TaskWorkerData.get(TaskWorkerKey.keyStartByte) as number | undefined
      const resumeETag = TaskWorkerData.get(TaskWorkerKey.keyETag) as string | undefined

      if (resumeDataPath !== undefined && requiredStartByte !== undefined) {
        worker.isResume = true
        worker.taskCanResume = true
      }
      worker.tempFilePath = resumeDataPath ?? "";
      worker.requiredStartByte = requiredStartByte ?? 0;
      worker.eTag = resumeETag
      const prefOptions: preferences.Options = { name: 'DEFAULT' }
      worker.prefs = preferences.getPreferencesSync(uiContext, prefOptions)
      await worker.startDoTask();
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

