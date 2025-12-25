import { common, sendableContextManager } from '@kit.AbilityKit';
import { collections, ErrorEvent, MessageEvents, ThreadWorkerGlobalScope, util, worker } from '@kit.ArkTS';
import { http } from '@kit.NetworkKit';
import { preferences } from '@kit.ArkData';
import {
  ExceptionType,
  ResumeData,
  Task,
  TaskException,
  TaskStatus
} from '../../../../../../src/main/ets/components/plugin/Models';
import { TaskWorker, TaskWorkerKey } from '../../../../../../src/main/ets/components/plugin/TaskWorker';
import BDPlugin, { WorkerCommand, WorkerShareableData } from '../../../../../../src/main/ets/components/plugin/BDPlugin';
import { NotificationConfig } from '../../../../../../src/main/ets/components/plugin/Notifications';
import { fileIo as fs } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';

let currentRequest: http.HttpRequest | undefined;

/**
 * Placeholder UploadTaskWorker for HarmonyOS.
 *
 * Currently uploads are not implemented; this worker will immediately fail the task.
 * When implementing real upload, mirror the logic from Android's UploadTaskWorker:
 *  - build binary or multipart body from Task fields/fileField/mimeType
 *  - set httpOptions.method = POST/PUT, headers, content length or chunked
 *  - stream bytes via http.request/expectDataType if supported
 */
class UploadTaskWorker extends TaskWorker {
  public static UploadTaskWorkerTag = 'UploadTaskWorker';
  public tempFilePath: string = '';
  public requiredStartByte: number = 0;
  public eTag?: string;
  private expectedFileSize = -1;
  private lastProgressPct = -1;
  private lastProgressTime = 0;
  private static readonly progressPctThreshold = 1; // percent
  private static readonly progressTimeMsThreshold = 500; // ms
  private lastUploadResponse?: http.HttpResponse;

  constructor(
    applicationContext: common.UIAbilityContext,
    workerParams: collections.Map<string, string | number | boolean | ResumeData | undefined>
  ) {
    super(applicationContext, workerParams);
  }

  public async startDoTask(): Promise<TaskStatus> {
    console.error(UploadTaskWorker.UploadTaskWorkerTag, 'startDoTask begin');
    const result = await this.doTask();
    console.error(UploadTaskWorker.UploadTaskWorkerTag, 'startDoTask done with status', result);
    return result;
  }

  // Override process: immediately fail with not-implemented error
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  override async process(httpOptions: http.HttpRequestOptions, header: Record<string, string>): Promise<TaskStatus> {
    console.error(UploadTaskWorker.UploadTaskWorkerTag, 'enter upload process');
    if (!this.task) {
      console.error(UploadTaskWorker.UploadTaskWorkerTag, 'no task available');
      return TaskStatus.failed;
    }

    try {
      const uploadStatus = (this.task.post?.toLowerCase() === 'binary')
        ? await this.processBinaryUpload(httpOptions, header)
        : await this.processMultipartUpload(httpOptions, header);

      switch (uploadStatus as number) {
        case TaskStatus.canceled as number:
          console.error(UploadTaskWorker.UploadTaskWorkerTag, `Canceled taskId ${this.task.taskId}`);
          return TaskStatus.canceled;
        case TaskStatus.failed as number:
          return TaskStatus.failed;
        case TaskStatus.complete as number: {
          const resp = this.lastUploadResponse;
          if (!resp) {
            return TaskStatus.failed;
          }
          const respHeaderMap = new Map<string, string>();
          const headerObj: Record<string, string> | undefined = resp.header as Record<string, string>;
          if (headerObj) {
            Object.keys(headerObj).forEach((k) => {
              const v = headerObj[k];
              respHeaderMap.set(k.toLowerCase(), `${v}`);
            });
          }
          this.extractResponseHeaders(respHeaderMap);
          this.responseBody = resp.result as string;
          this.responseStatusCode = resp.responseCode;
          if (resp.responseCode >= 200 && resp.responseCode <= 206) {
            console.error(UploadTaskWorker.UploadTaskWorkerTag, `Successfully uploaded taskId ${this.task.taskId}`);
            workerPort.postMessage({
              command: 'progressUpdate',
              progress: 1.0,
              expectedFileSize: this.expectedFileSize,
              taskJson: TaskWorker.taskToJsonString(this.task),
              downloadSpeed: -1,
              timeRemaining: -1000,
            });
            return TaskStatus.complete;
          }
          console.error(
            UploadTaskWorker.UploadTaskWorkerTag,
            `Response code ${resp.responseCode} for taskId ${this.task.taskId}`
          );
          const errorContent = typeof resp.result === 'string' ? (resp.result as string) : undefined;
          this.taskException = new TaskException(
            ExceptionType.httpResponse,
            resp.responseCode,
            errorContent && errorContent.length > 0 ? errorContent : ''
          );
          return resp.responseCode === 404 ? TaskStatus.notFound : TaskStatus.failed;
        }
        default:
          return TaskStatus.failed;
      }
    } catch (e) {
      const error = e as BusinessError;
      const message = error?.message ?? `${e}`;
      this.taskException = new TaskException(ExceptionType.general, undefined, message);
      return TaskStatus.failed;
    }
  }

  private async processMultipartUpload(
    httpOptions: http.HttpRequestOptions,
    header: Record<string, string>
  ): Promise<TaskStatus> {
    if (!this.task) {
      return TaskStatus.failed;
    }
    const filePath = this.task.filePath(this.applicationContext!);
    let stat: fs.Stat;
    try {
      stat = fs.statSync(filePath);
    } catch (_e) {
      this.taskException = new TaskException(
        ExceptionType.fileSystem,
        undefined,
        `File to upload does not exist: ${filePath}`
      );
      return TaskStatus.failed;
    }
    if (!stat.isFile()) {
      this.taskException = new TaskException(
        ExceptionType.fileSystem,
        undefined,
        `File to upload is not a regular file: ${filePath}`
      );
      return TaskStatus.failed;
    }
    this.expectedFileSize = stat.size;
    console.error("httpRequestMethod=" + this.task.httpRequestMethod);
    const method =
      this.task.httpRequestMethod === 'PUT'
        ? http.RequestMethod.PUT
        : http.RequestMethod.POST;
    const headers: Record<string, string> = {};
    Object.keys(header).forEach((k) => {
      headers[k] = header[k];
    });
    headers['Content-Type'] = 'multipart/form-data';
    const formParts: Array<http.MultiFormData> = [];
    if (this.task.fields && this.task.fields.size > 0) {
      this.task.fields.forEach((value, key) => {
        formParts.push({
          name: key,
          contentType: 'text/plain',
          data: `${value}`,
          remoteFileName: undefined
        });
      });
    }
    const fileFieldName = this.task.fileField && this.task.fileField.length > 0 ? this.task.fileField : 'file';
    const contentType = (this.task.mimeType && this.task.mimeType.length) > 0
      ? this.task.mimeType
      : 'application/octet-stream';
    console.error(
      UploadTaskWorker.UploadTaskWorkerTag,
      `Uploading file field=${fileFieldName}, path=${filePath}, mimeType=${contentType}`
    );
    formParts.push({
      name: fileFieldName,
      contentType: contentType,
      filePath: filePath,
      remoteFileName: this.task.filename
    });

    const options: http.HttpRequestOptions = httpOptions;
    options.method = method;
    options.header = headers;
    options.multiFormDataList = formParts;
    options.expectDataType = http.HttpDataType.STRING;
    // Log all headers for debugging
    Object.keys(headers).forEach((k) => {
      console.error(UploadTaskWorker.UploadTaskWorkerTag, `multipart header ${k}: ${headers[k]}`);
    });

    const request = http.createHttp();
    currentRequest = request;
    workerPort.postMessage({
      command: 'progressUpdate',
      progress: 0.0,
      expectedFileSize: stat.size,
      taskJson: TaskWorker.taskToJsonString(this.task),
      downloadSpeed: -1,
      timeRemaining: -1000,
    });
    request.on('dataSendProgress', (info: http.DataSendProgressInfo) => {
      const sent = info.sendSize ?? 0;
      const total = info.totalSize ?? stat.size;
      if (total <= 0) {
        return;
      }
      const progressValue = Math.min(1.0, sent / total);
      const progressPct = Math.round(progressValue * 100);
      const now = Date.now();
      const pctDelta = this.lastProgressPct >= 0 ? Math.abs(progressPct - this.lastProgressPct) : 100;
      const timeDelta = now - this.lastProgressTime;
      if (pctDelta < UploadTaskWorker.progressPctThreshold &&
        timeDelta < UploadTaskWorker.progressTimeMsThreshold) {
        return;
      }
      this.lastProgressPct = progressPct;
      this.lastProgressTime = now;
      workerPort.postMessage({
        command: 'progressUpdate',
        progress: progressValue,
        expectedFileSize: total,
        taskJson: TaskWorker.taskToJsonString(this.task!),
        downloadSpeed: -1,
        timeRemaining: -1000,
      });
    });

    try {
      const resp: http.HttpResponse = await request.request(this.task.url, options);
      this.lastUploadResponse = resp;
      return TaskStatus.complete;
    } catch (err) {
      const message = (err as BusinessError)?.message ?? `${err}`;
      this.taskException = new TaskException(ExceptionType.general, undefined, message);
      return TaskStatus.failed;
    }
  }

  private async processBinaryUpload(
    httpOptions: http.HttpRequestOptions,
    header: Record<string, string>
  ): Promise<TaskStatus> {
    if (!this.task) {
      return TaskStatus.failed;
    }
    const filePath = this.task.filePath(this.applicationContext!);
    let stat: fs.Stat;
    try {
      stat = fs.statSync(filePath);
    } catch (_e) {
      this.taskException = new TaskException(
        ExceptionType.fileSystem,
        undefined,
        `File to upload does not exist: ${filePath}`
      );
      return TaskStatus.failed;
    }
    if (!stat.isFile()) {
      this.taskException = new TaskException(
        ExceptionType.fileSystem,
        undefined,
        `File to upload is not a regular file: ${filePath}`
      );
      return TaskStatus.failed;
    }
    if (stat.size <= 0) {
      this.taskException = new TaskException(
        ExceptionType.fileSystem,
        undefined,
        `File ${filePath} has 0 length`
      );
      return TaskStatus.failed;
    }
    this.expectedFileSize = stat.size;

    let resolvedMimeType = (this.task.mimeType && this.task.mimeType.length > 0)
      ? this.task.mimeType
      : 'application/octet-stream';
    const headers: Record<string, string> = {};
    Object.keys(header).forEach((k) => {
      headers[k] = header[k];
    });
    headers['Content-Type'] = resolvedMimeType;
    const taskContentDisposition =
      this.task.headers.get('Content-Disposition') ?? this.task.headers.get('content-disposition');
    if (taskContentDisposition !== '') {
      headers['Content-Disposition'] = taskContentDisposition
        ?? (`attachment; filename="${this.task.filename}"`);
    }
    headers['Content-Length'] = `${stat.size}`;
    const method =
      this.task.httpRequestMethod === 'PUT'
        ? http.RequestMethod.PUT
        : http.RequestMethod.POST;

    let body: ArrayBuffer;
    try {
      const file = fs.openSync(filePath, fs.OpenMode.READ_ONLY);
      const buffer = new ArrayBuffer(stat.size);
      fs.readSync(file.fd, buffer);
      fs.closeSync(file);
      body = buffer;
    } catch (err) {
      const message = (err as BusinessError)?.message ?? `${err}`;
      this.taskException = new TaskException(ExceptionType.fileSystem, undefined, message);
      return TaskStatus.failed;
    }

    const options: http.HttpRequestOptions = httpOptions;
    options.method = method;
    options.header = headers;
    options.expectDataType = http.HttpDataType.STRING;
    options.extraData = body;
    // Log all headers for debugging
    Object.keys(headers).forEach((k) => {
      console.error(UploadTaskWorker.UploadTaskWorkerTag, `binary header ${k}: ${headers[k]}`);
    });
    const request = http.createHttp();
    currentRequest = request;
    workerPort.postMessage({
      command: 'progressUpdate',
      progress: 0.0,
      expectedFileSize: stat.size,
      taskJson: TaskWorker.taskToJsonString(this.task),
      downloadSpeed: -1,
      timeRemaining: -1000,
    });
    request.on('dataSendProgress', (info: http.DataSendProgressInfo) => {
      const sent = info.sendSize ?? 0;
      const total = info.totalSize ?? stat.size;
      if (total <= 0) {
        return;
      }
      const progressValue = Math.min(1.0, sent / total);
      const progressPct = Math.round(progressValue * 100);
      const now = Date.now();
      const pctDelta = this.lastProgressPct >= 0 ? Math.abs(progressPct - this.lastProgressPct) : 100;
      const timeDelta = now - this.lastProgressTime;
      if (pctDelta < UploadTaskWorker.progressPctThreshold &&
        timeDelta < UploadTaskWorker.progressTimeMsThreshold) {
        return;
      }
      this.lastProgressPct = progressPct;
      this.lastProgressTime = now;
      workerPort.postMessage({
        command: 'progressUpdate',
        progress: progressValue,
        expectedFileSize: total,
        taskJson: TaskWorker.taskToJsonString(this.task!),
        downloadSpeed: -1,
        timeRemaining: -1000,
      });
    });

    try {
      const resp: http.HttpResponse = await request.request(this.task.url, options);
      this.lastUploadResponse = resp;
      return TaskStatus.complete;
    } catch (err) {
      const message = (err as BusinessError)?.message ?? `${err}`;
      this.taskException = new TaskException(ExceptionType.general, undefined, message);
      return TaskStatus.failed;
    }
  }
}

type WorkerParamValue = string | number | boolean | sendableContextManager.SendableContext;

const workerPort: ThreadWorkerGlobalScope = worker.workerPort;

workerPort.onmessage = async (event: MessageEvents) => {
  let workercommand = event.data as WorkerCommand;

  let command = workercommand.command;
  console.error(UploadTaskWorker.UploadTaskWorkerTag, `UploadTaskWorker: received message with command=${command}`);
  let sendableUIContext = workercommand.sendableUIContext;
  let taskWorkerData = workercommand.taskWorkerData;
  let workerShareableData = workercommand.workerShareableData;
  if (!workerShareableData) {
    return;
  }
  TaskWorker.workerShareableData = workerShareableData;

  let uiContext = sendableContextManager.convertToUIAbilityContext(sendableUIContext);
  if (!uiContext) {
    console.error(UploadTaskWorker.UploadTaskWorkerTag, 'UploadTaskWorker requires a valid UI context');
    return;
  }
  switch (command) {
    case 'startWork': {
      let worker = new UploadTaskWorker(uiContext, taskWorkerData);
      let taskJson = taskWorkerData.get(TaskWorkerKey.keyTask) as string | undefined;
      if (!taskJson) {
        console.error(UploadTaskWorker.UploadTaskWorkerTag, 'UploadTaskWorker requires a task payload');
        return;
      }
      worker.task = Task.fromPlain(JSON.parse(taskJson) as Task);
      worker.notificationConfigJsonString = taskWorkerData.get(TaskWorkerKey.keyNotificationConfig) as string | undefined;
      worker.notificationConfig = worker.notificationConfigJsonString
        ? (JSON.parse(worker.notificationConfigJsonString) as NotificationConfig)
        : undefined;

      const resumeDataPath = taskWorkerData.get(TaskWorkerKey.keyResumeDataData) as string | undefined;
      const requiredStartByte = taskWorkerData.get(TaskWorkerKey.keyStartByte) as number | undefined;
      const resumeETag = taskWorkerData.get(TaskWorkerKey.keyETag) as string | undefined;
      if (resumeDataPath !== undefined && requiredStartByte !== undefined) {
        worker.isResume = true;
        worker.taskCanResume = true;
      }
      worker.tempFilePath = resumeDataPath ?? '';
      worker.requiredStartByte = requiredStartByte ?? 0;
      worker.eTag = resumeETag;
      const prefOptions: preferences.Options = { name: 'DEFAULT' };
      worker.prefs = preferences.getPreferencesSync(uiContext, prefOptions);

      workerPort.postMessage({
        command: 'statusUpdate',
        status: TaskStatus.running,
        taskJson: taskToJsonString(worker.task!),
      });

      let status = await worker.startDoTask();
      workerPort.postMessage({
        command: 'statusUpdate',
        status: status,
        taskJson: TaskWorker.taskToJsonString(worker.task!),
        exception: worker.taskException,
        responseBody: worker.responseBody,
        responseStatusCode: worker.responseStatusCode
      });
    }
      break;
    default:
      break;
  }
};

workerPort.onmessageerror = () => {
  console.error(UploadTaskWorker.UploadTaskWorkerTag, 'workerPort onmessageerror for UploadTaskWorker');
};

workerPort.onerror = (err: ErrorEvent) => {
  console.error(UploadTaskWorker.UploadTaskWorkerTag, 'workerPort onerror for UploadTaskWorker:', err.message);
  try {
    currentRequest?.destroy();
  } catch (_) {
  }
};
