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
  private lastProgressPct = -1;
  private lastProgressTime = 0;
  private static readonly progressPctThreshold = 1; // percent
  private static readonly progressTimeMsThreshold = 500; // ms

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
    console.error(UploadTaskWorker.UploadTaskWorkerTag, "enter upload process");
    if (!this.task) {
      console.error(UploadTaskWorker.UploadTaskWorkerTag, "no task available");
      return TaskStatus.failed;
    }
    // Multipart upload implementation using filePath
    try {
      const filePath = this.task.filePath(this.applicationContext!);
      console.error("filePath=" + filePath);
      let stat: fs.Stat;
      try {
        stat = fs.statSync(filePath);
        console.error("fs.statSync success")
      } catch (_e) {
        console.error("fs.statSync error")
        this.taskException = new TaskException(
          ExceptionType.fileSystem,
          undefined,
          `File to upload does not exist: ${filePath}`
        );
        return TaskStatus.failed;
      }


      console.error(UploadTaskWorker.UploadTaskWorkerTag, `Uploading file at path: ${filePath}, size: ${stat.size} bytes`);
      if (!stat.isFile()) {
        console.error("!stat.isFile()");
        this.taskException = new TaskException(
          ExceptionType.fileSystem,
          undefined,
          `File to upload is not a regular file: ${filePath}`
        );
        return TaskStatus.failed;
      }

      // Build request options + multipart body
      const method =
        this.task.httpRequestMethod === 'PUT'
          ? http.RequestMethod.PUT
          : http.RequestMethod.POST;
      // keep incoming headers (e.g. auth token) consistent with download worker behavior
      const headers: Record<string, string> = {};
      Object.keys(header).forEach((key) => {
        headers[key] = header[key];
      });

      const formParts: Array<http.MultiFormData> = [];
      // add additional fields if present
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
      // file part
      const fileFieldName = this.task.fileField && this.task.fileField.length > 0 ? this.task.fileField : 'file';
      const contentType = this.task.mimeType && this.task.mimeType.length > 0
        ? this.task.mimeType
        : 'application/octet-stream';
      formParts.push({
        name: fileFieldName,
        contentType: contentType,
        filePath: filePath,
        remoteFileName: this.task.filename
      });

      const options: http.HttpRequestOptions = {
        method,
        header: headers,
        multiFormDataList: formParts,
        expectDataType: http.HttpDataType.STRING,
      };

      const request = http.createHttp();
      currentRequest = request;
      // progress: since we send in one buffer, just report start/end
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

      const resp: http.HttpResponse = await request.request(this.task.url, options);
      // Normalize headers to Map<string,string>
      const respHeaderMap = new Map<string, string>();
      const headerObj: Record<string, string> | undefined =
        resp.header as Record<string, string>
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
        workerPort.postMessage({
          command: 'progressUpdate',
          progress: 1.0,
          expectedFileSize: stat.size,
          taskJson: TaskWorker.taskToJsonString(this.task),
          downloadSpeed: -1,
          timeRemaining: -1000,
        });
        return TaskStatus.complete;
      }

      this.taskException = new TaskException(
        ExceptionType.httpResponse,
        resp.responseCode,
        this.responseBody ?? ''
      );
      return resp.responseCode === 404 ? TaskStatus.notFound : TaskStatus.failed;
    } catch (e) {
      let error = e as BusinessError;
      const message = error.message;
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
