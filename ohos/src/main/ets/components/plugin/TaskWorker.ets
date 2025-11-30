import { collections, ErrorEvent, MessageEvents, taskpool, ThreadWorkerGlobalScope, util, worker } from '@kit.ArkTS'
import { ExceptionType,
  ResumeData,
  Task, TaskException,
  TaskOptions,
  TaskProgressUpdate, TaskStatus, TaskStatus_fun,
  Task_interface } from './Models'
import dataPreferences from '@ohos.data.preferences'
import { common, sendableContextManager } from '@kit.AbilityKit'
import BDPlugin, { WorkerShareableData } from './BDPlugin'
import { WiFi } from './WIFI'
import { EnqueueItem, HoldingQueue } from './HoldingQueue'
import { NotificationConfig } from './Notifications'
import { BackgroundPost, QueueService } from './QueueService'
import { systemDateTime } from '@kit.BasicServicesKit'
import { TaskStatusUpdate, TaskStatusUpdatePara } from './Models'
import { workScheduler } from '@kit.BackgroundTasksKit'
import { Callbacks } from './Callbacks'
import { Auth} from './Auth'
import { http } from '@kit.NetworkKit'
import preferences from '@ohos.data.preferences'

interface PlainAuthJson {
  accessToken?: string;
  accessHeaders?: Record<string, string>;
  accessQueryParams?: Record<string, string>;
  accessTokenExpiryTime?: number;
  refreshToken?: string;
  refreshHeaders?: Record<string, string>;
  refreshQueryParams?: Record<string, string>;
  refreshUrl?: string;
  onAuthRawHandle?: number;
}

interface PlainTaskOptionsJson {
  beforeTaskStartRawHandle?: number;
  onTaskStartRawHandle?: number;
  onTaskFinishedRawHandle?: number;
  auth?: PlainAuthJson;
}

interface PlainTaskJson {
  taskId: string;
  url: string;
  filename: string;
  headers: Record<string, string>;
  baseDirectory: number;
  group: string;
  updates: number;
  taskType: string;
  urls: Array<string>;
  httpRequestMethod: string;
  chunks: number;
  post?: string;
  fileField: string;
  mimeType: string;
  fields: Record<string, string>;
  directory: string;
  requiresWiFi: boolean;
  retries: number;
  retriesRemaining: number;
  allowPause: boolean;
  priority: number;
  metaData: string;
  displayName: string;
  creationTime: number;
  options?: PlainTaskOptionsJson;
}


export enum TaskWorkerKey {
  keyNotificationConfig = "notificationConfig",
  keyResumeDataData = "tempFilename",
  keyStartByte = "startByte",
  keyETag = "eTag",
  keyTask = "Task"
}

export class TaskWorker {
  static readonly TAG:string = "TaskWorker"
  static readonly chunkGroup:string = "chunk"
  static readonly keyTask:string = "Task"
  static readonly keyNotificationConfig:string = "notificationConfig"
  static readonly keyResumeDataData:string = "tempFilename"
  static readonly keyStartByte:string = "startByte"
  static readonly keyETag:string = "eTag"
  static readonly bufferSize:number = 2 << 12;
  static readonly taskTimeoutMillis:number = 9 * 60 * 1000; // 9 minutes

  static workerShareableData? :WorkerShareableData;
  //
  public static taskToJsonString(task: Task): string {
    const headers: Record<string, string> = {};
    task.headers.forEach((value, key) => {
      if (value !== undefined && value !== null) {
        headers[key] = `${value}`;
      }
    });
    const fields: Record<string, string> = {};
    task.fields.forEach((value, key) => {
      if (value !== undefined && value !== null) {
        fields[key] = `${value}`;
      }
    });
    const mapToRecordFromMap = (map?: collections.Map<string, string>): Record<string, string> => {
      const result: Record<string, string> = {};
      map?.forEach((v, k) => {
        if (v !== undefined && v !== null) {
          result[k] = `${v}`;
        }
      });
      return result;
    };
    const urls: Array<string> = [];
    task.urls.forEach((value) => {
      if (value !== undefined && value !== null) {
        urls.push(`${value}`);
      }
    });

    const plain: PlainTaskJson = {
      taskId: task.taskId,
      url: task.url,
      filename: task.filename,
      headers,
      baseDirectory: task.baseDirectory,
      group: task.group,
      updates: task.updates,
      taskType: task.taskType,
      urls,
      httpRequestMethod: task.httpRequestMethod,
      chunks: task.chunks,
      post: task.post,
      fileField: task.fileField,
      mimeType: task.mimeType,
      fields,
      directory: task.directory,
      requiresWiFi: task.requiresWiFi,
      retries: task.retries,
      retriesRemaining: task.retriesRemaining,
      allowPause: task.allowPause,
      priority: task.priority,
      metaData: task.metaData,
      displayName: task.displayName,
      creationTime: task.creationTime,
      options: task.options
        ? {
          beforeTaskStartRawHandle: task.options.beforeTaskStartRawHandle,
          onTaskStartRawHandle: task.options.onTaskStartRawHandle,
          onTaskFinishedRawHandle: task.options.onTaskFinishedRawHandle,
          auth: task.options.auth
            ? {
              accessToken: task.options.auth.accessToken,
              accessHeaders: mapToRecordFromMap(task.options.auth.accessHeaders),
              accessQueryParams: mapToRecordFromMap(task.options.auth.accessQueryParams),
              accessTokenExpiryTime: task.options.auth.accessTokenExpiryTime,
              refreshToken: task.options.auth.refreshToken,
              refreshHeaders: mapToRecordFromMap(task.options.auth.refreshHeaders),
              refreshQueryParams: mapToRecordFromMap(task.options.auth.refreshQueryParams),
              refreshUrl: task.options.auth.refreshUrl,
              onAuthRawHandle: task.options.auth.onAuthRawHandle,
            }
            : undefined,
        }
        : undefined,
    };

    const json = JSON.stringify(plain);
    return json;
  }
  //
  public static async postOnBackgroundChannel(
    method: string, task: Task, arg: (string | number | Map<string, string> |boolean| undefined)[], onFail?: () => Promise<void>
  ): Promise<void> {
    let bgPost = new BackgroundPost(task, method, arg, onFail)
    return QueueService.postOnBackgroundChannel(bgPost)
  }
  //
  /**
   * Processes a progress update for the [task]
   *
   * Sends progress update via the background channel to Flutter, if requested
   */
  public static async processProgressUpdate(
    task: Task, progress: number, prefs: dataPreferences.Preferences, expectedFileSize: number = -1,
    downloadSpeed: number = -1.0, timeRemaining: number = -1000
  ): Promise<void> {
    if (task.providesProgressUpdates()) {
      await TaskWorker.postOnBackgroundChannel(
        "progressUpdate", task,
        [progress, expectedFileSize, downloadSpeed, timeRemaining],
        async () => {
          // unsuccessful post, so store in local prefs
          console.error(TaskWorker.TAG, "Could not post progress update -> storing locally")
          TaskWorker.storeLocally(
            BDPlugin.keyProgressUpdateMap,
            task.taskId,
            JSON.stringify(new TaskProgressUpdate(
              task,
              progress,
              expectedFileSize
            )),
            prefs
          )
        }
      )
    }
  }

  /**
   * Send 'canResume' message via the background channel to Flutter
   */
  public async processCanResume(task: Task, canResume: boolean) {
    TaskWorker.postOnBackgroundChannel("canResume", task, [canResume]);
  }

  /**
   * Process resume information
   *
   * Attempts to post this to the Dart side via background channel. If that is not
   * successful, stores the resume data in shared preferences, for later retrieval by
   * the Dart side.
   *
   * Also stores a copy in memory locally, to allow notifications to resume a task
   */
  public async processResumeData(resumeData: ResumeData, prefs: dataPreferences.Preferences) {
    await TaskWorker.workerShareableData!.withLock(() => {
      TaskWorker.workerShareableData!.localResumeData.set(resumeData.task.taskId,resumeData)
    })
    TaskWorker.postOnBackgroundChannel(
      "resumeData", resumeData.task, [
      resumeData.data,
      resumeData.requiredStartByte,
      resumeData.eTag
    ],
      async ()=>{
        // unsuccessful post, so store in local prefs
        console.error(BDPlugin.TAG+"Could not post resume data -> storing locally");
        TaskWorker.storeLocally(
          BDPlugin.keyResumeDataMap,
          resumeData.task.taskId,
          JSON.stringify(resumeData),
          prefs,
        )
      })
  }

  /**
   * Determine if this task should run in the foreground
   *
   * Based on {@link canRunInForeground} and {@link contentLength} > {@link runInForegroundFileSize}
   */
  public determineRunInForeground(task: Task, contentLength: number): void {
    this.runInForeground =
      this.canRunInForeground && contentLength > (this.runInForegroundFileSize << 20)
    if (this.runInForeground) {
      console.info(`${TaskWorker.TAG} TaskId ${task.taskId} will run in foreground`)
    }
  }

  protected extractContentType(headers: Map<string, string>): void {
    let contentTypeValue = headers.get("content-type");

    if (!contentTypeValue) {
      const iter = headers.entries();
      let next = iter.next();
      while (!next.done) {
        const entry = next.value;
        const key = entry[0];
        const value = entry[1];
        if (key.toLowerCase() == "content-type") {
          contentTypeValue = value;
          break;
        }
        next = iter.next();
      }
    }

    if (contentTypeValue) {
      const regEx = /(.*);\s*charset\s*=(.*)/;
      const matchResult = regEx.exec(contentTypeValue);
      if (matchResult) {
        this.mimeType = matchResult[1];
        this.charSet = matchResult[2];
      } else {
        this.mimeType = contentTypeValue;
      }
    }
  }

  /**
   * Extract headers from response {@code headers} and store in {@link responseHeaders}
   *
   * The Dart convention concatenates multiple values under the same key using a comma and
   * a space, so mirror that behavior here.
   */
  protected extractResponseHeaders(headers: Map<string, string | string[]>): void {
    const loweredHeaders = new Map<string, string>();
    headers.forEach((value, key) => {
      const joinedValue = Array.isArray(value) ? value.join(', ') : value;
      loweredHeaders.set(key, joinedValue);
    });
    this.responseHeaders = loweredHeaders;
  }

  private static storeLocally(
    prefsKey: string,
    taskId: string,
    item: string,
    prefs: dataPreferences.Preferences
  ): void {    //ohos share
    BDPlugin.prefsLock.lockAsync(() => {
      const jsonString = prefs.getSync(prefsKey, "{}") as string;
      let mapByTaskId: Record<string, string> = {};
      try {
        mapByTaskId = JSON.parse(jsonString) as Record<string, string>;
      } catch (_) {
        mapByTaskId = {};
      }
      mapByTaskId[taskId] = item;
      prefs.putSync(prefsKey, JSON.stringify(mapByTaskId));
      prefs.flushSync();
    })
  }

  private static filterHeaders(headers?: Map<string, string> | collections.Map<string, string>): Map<string, string> | undefined {
    if (!headers) {
      return undefined
    }
    const lowered = new Map<string, string>()
    if (headers instanceof Map) {
      headers.forEach((value, key) => {
        if (value !== undefined) {
          lowered.set(key.toLowerCase(), value)
        }
      })
      return lowered
    }

    if (headers instanceof collections.Map) {
      headers.forEach((value, key) => {
        if (value !== undefined) {
          lowered.set(key.toLowerCase(), value)
        }
      })
      return lowered
    }

    return undefined;
  }
  //   main thread
  public static async processStatusUpdate(
    task: Task,
    status: TaskStatus,
    prefs: dataPreferences.Preferences,
    context?: common.UIAbilityContext,
    taskException?: TaskException,
    responseBody?: string,
    responseHeaders?: Map<string, string>,
    responseStatusCode?: number,
    mimeType?: string,
    charSet?: string,
  ) {
    console.error("enter it");
    const resolvedContext: common.UIAbilityContext | undefined = context ?? BDPlugin.uiContext
    let removedFromReEnqueue = false;
    let shouldSignalEnd = false;
    let notificationConfigForReEnqueue: string | undefined;
    let resumeDataForReEnqueue: ResumeData | undefined;

    await BDPlugin.workerShareableData!.withLock(() => {
      removedFromReEnqueue = BDPlugin.workerShareableData!.tasksToReEnqueue.delete(task)
      if (removedFromReEnqueue) {
        notificationConfigForReEnqueue = BDPlugin.workerShareableData!.notificationConfigJsonStrings.get(task.taskId)
        resumeDataForReEnqueue = BDPlugin.workerShareableData!.localResumeData.get(task.taskId)
        shouldSignalEnd = BDPlugin.workerShareableData!.tasksToReEnqueue.size == 0
      }

    })

    if (removedFromReEnqueue) {
      if (status == TaskStatus.paused || status == TaskStatus.canceled || status == TaskStatus.failed) {
        if (resolvedContext !== undefined) {
          WiFi.reEnqueue(
            new EnqueueItem(
              resolvedContext,
              task,
              notificationConfigForReEnqueue,
              resumeDataForReEnqueue,
            )
          )
        }
        if (shouldSignalEnd) {
          WiFi.reEnqueue(undefined) // signal end of batch
        }
        return
      }

      if (shouldSignalEnd) {
        WiFi.reEnqueue(undefined) // signal end of batch
      }
    }


    console.error("leave it");

    // Normal status update

    // Check if the task was 'programmatically' canceled, in which case a TaskStatus.failed may be
    // incorrectly generated by the WorkManager, so we change it to 'canceled'
    let modifiedStatus: TaskStatus = status
    await BDPlugin.workerShareableData!.withLock(() => {
      modifiedStatus = BDPlugin.workerShareableData!.canceledTaskIds.has(task.taskId) ? TaskStatus.canceled : status
    })
    let retryNeeded = modifiedStatus as number == TaskStatus.failed && task.retriesRemaining > 0
    let canSendStatusUpdate = true

    console.error("modifiedStatus:" +modifiedStatus.valueOf());

    switch (modifiedStatus) {
      case TaskStatus.complete:
        TaskWorker.processProgressUpdate(task, 1.0, prefs);
        break;
      case TaskStatus.failed as number:
        if (!retryNeeded) {
          TaskWorker.processProgressUpdate(task, -1.0, prefs)
        }
        break;
      case TaskStatus.canceled:
        canSendStatusUpdate = await TaskWorker.canSendCancellation(task)
        if (canSendStatusUpdate) {
          await BDPlugin.workerShareableData!.withLock(() => {
            BDPlugin.workerShareableData!.cancelUpdateSentForTaskId.set(task.taskId, systemDateTime.getTime(false));
          })
          TaskWorker.processProgressUpdate(task, -2.0, prefs)
        }
        break;
      case TaskStatus.notFound:
        TaskWorker.processProgressUpdate(task, -3.0, prefs)
        break;
      case TaskStatus.paused as number:
        TaskWorker.processProgressUpdate(task, -5.0, prefs)
        break;
      default:
        break;
    }

    console.error("leave switch (modifiedStatus)");

    const isFinal = TaskStatus_fun.isFinalState(modifiedStatus)
    console.error("1");
    const includeStatusCode =
      modifiedStatus == TaskStatus.complete || modifiedStatus == TaskStatus.notFound
    console.error("2");
    const loweredHeaders = TaskWorker.filterHeaders(responseHeaders)
    console.error("3");
    const resolvedException =
      isFinal && modifiedStatus == TaskStatus.failed as number
        ? taskException ?? new TaskException(ExceptionType.general)
        : undefined
    console.error("4");

    let taskStatusUpdate = new TaskStatusUpdate({
      task: task,
      taskStatus: modifiedStatus,
      exception: resolvedException,
      responseBody: isFinal ? responseBody : undefined,
      responseHeaders: isFinal ? loweredHeaders : undefined,
      responseStatusCode: includeStatusCode ? responseStatusCode : undefined,
      mimeType: isFinal ? mimeType : undefined,
      charSet: isFinal ? charSet : undefined,
    })
    console.error("5");

    if (canSendStatusUpdate && (task.providesStatusUpdates() || retryNeeded)) {
      console.error("6");
      let arg = taskStatusUpdate.argList as  (string | number | Map<string, string> | undefined)[]
      await TaskWorker.postOnBackgroundChannel("statusUpdate", task, arg, async () => {
        // unsuccessful post, so store in local prefs
        console.error(TaskWorker.TAG, "Could not post status update -> storing locally")
        TaskWorker.storeLocally(
          BDPlugin.keyStatusUpdateMap,
          task.taskId,
          JSON.stringify(taskStatusUpdate),
          prefs
        )
      })
      console.error("7");
    }

    // if task is in final state, cancel the WorkManager job (if failed),
    // remove task from persistent storage, clean up references to taskId
    // and invoke the onTaskFinishedCallback if necessary
    if (isFinal) {
      if (modifiedStatus == TaskStatus.failed as number) {
        // Cancel the WorkManager job.
        // This is to avoid the WorkManager restarting a job that was
        // canceled because job constraints are violated (e.g. network unavailable)
        // We want to manage cancellation ourselves, so we cancel the job

        let workManager = await workScheduler.obtainAllWorks();

        for (let i = 0; i < workManager.length; i++) {
          if(!workManager) {
            continue;
          }
          if(!workManager[i].parameters) {
            continue
          }

          if(!workManager[i].parameters!['taskId']) {
            continue
          }

          if (workManager[i].parameters!['taskId'] == task.taskId) {
            try {
              workScheduler.stopWork(workManager[i], false);
            } catch (e) {
              console.error(
                BDPlugin.TAG,
                "Could not kill task wih id ${task.taskId} in operation: $operation"
              )
            }
          }
        }
      }
      BDPlugin.prefsLock.lockAsync<void>(async () => {
        let tasksMap = getTaskMap(prefs)
        console.error("getTaskMap success");
        tasksMap.delete(task.taskId)
        const serializedTasks: Record<string, Task> = {};
        tasksMap.forEach((value, key) => {
          serializedTasks[key] = value;
        });
        prefs.putSync(BDPlugin.keyTasksMap, JSON.stringify(serializedTasks));
        console.error("putSync success");
        prefs.flushSync();
        // 执行某些操作
      });

      console.error("cleanupTaskId");

      QueueService.cleanupTaskId(task.taskId)
      console.error("enter task.options?.hasOnFinishCallback()");
      console.error("task.options?.hasOnFinishCallback() == "+task.options?.hasOnFinishCallback());
      if (task.options?.hasOnFinishCallback() == true) {
        if (resolvedContext != undefined) {
          console.error("enter task.options?.hasOnFinishCallback() ")
          Callbacks.invokeOnTaskFinishedCallback(resolvedContext, taskStatusUpdate)
          console.error("leave task.options?.hasOnFinishCallback() ")
        }
      }
    }
  }

  /** Return true if we can send a cancellation for this task
   *
   * Cancellation can only be sent if it wasn't already sent by the [BDPlugin]
   *  in the cancelTasksWithId method.  Side effect is to clean out older cancellation entries
   * from the [BDPlugin.cancelUpdateSentForTaskId]
   */
  private static async canSendCancellation(task: Task): Promise<boolean> {
    let now = systemDateTime.getTime(false);
    const filteredEntries: Array<[string, number]> = []
    await TaskWorker.workerShareableData!.withLock(() => {
      TaskWorker.workerShareableData!.cancelUpdateSentForTaskId.forEach((ts: number, key: string) => {
        if (now - ts < 3000) {
          filteredEntries.push([key, ts])
        }
      })
      TaskWorker.workerShareableData!.cancelUpdateSentForTaskId = new collections.Map(filteredEntries)
    })
    return TaskWorker.workerShareableData!.cancelUpdateSentForTaskId.get(task.taskId) == undefined;
  }

  /**
   * Set up an OHOS HTTP request and delegate to {@link connectAndProcess}.
   *
   * Returns the {@link TaskStatus}.
   */
  protected async doTask(

  ): Promise<TaskStatus> {
    if (!this.task) {
      console.error(TaskWorker.TAG, 'doTask called without a task');
      return TaskStatus.failed;
    }

    let httpOptions: http.HttpRequestOptions = {};
    try {
      const prefOptions: preferences.Options = { name: "DEFAULT" };
      this.prefs = preferences.getPreferencesSync(this.applicationContext,prefOptions);
      let requestTimeoutSeconds = this.prefs.getSync(BDPlugin.keyConfigRequestTimeout, 60) as number;
      let proxyAddress:string = this.prefs.getSync(BDPlugin.keyConfigProxyAddress,"undefined") as string;
      let proxyPort = this.prefs.getSync(BDPlugin.keyConfigProxyPort, 0) as number;
      let useProxy = (proxyAddress != null && proxyPort != 0)? true:false;
      let proxy:http.HttpProxy = {
        host:proxyAddress,
        port: proxyPort,
        exclusionList:[]
      }
      let shouldLogProxyMessage = false;
      await TaskWorker.workerShareableData!.withLock(() => {
        if(!TaskWorker.workerShareableData!.haveLoggedProxyMessage) {
          TaskWorker.workerShareableData!.haveLoggedProxyMessage = true //共享
          shouldLogProxyMessage = true
        }
      })
      if (shouldLogProxyMessage) {
        if(useProxy) {
          console.error("Using proxy:" + proxyAddress + ":"+proxyPort+"for all tasks");
        } else {
          console.error(BDPlugin.TAG+"Not using proxy for any task")
        }
      }

      httpOptions = {
        method: this.task.httpRequestMethod as http.RequestMethod,
        //header: headerRecord,
        connectTimeout: requestTimeoutSeconds*1000,
        usingProxy:useProxy?proxy:false,
        extraData: this.task.post,
      };

      let header:Record<string,string> = {};
      this.task.headers.forEach((value, key) => {
        console.error(BDPlugin.TAG+"key:"+key+" value:"+value);
        if (!this.task!.isUploadTask() ||
          (!(key == "Range" || key == 'range') &&
            (!(key == "Content-Disposition" || key == "content-disposition")))) {
          header[key] = value;
          //console.error(BDPlugin.TAG+"key:"+key+" value:"+value);
        }
      });
      return this.connectAndProcess(httpOptions,header);

    } catch (err) {
      console.error(BDPlugin.TAG+"Error for taskId"+this.task.taskId + err as string)
      this.setTaskException(err)
    }

    return TaskStatus.failed;
  }

  /**
   * Further configures the connection and makes the actual request by
   * calling {@link process}, while catching errors.
   *
   * Returns the {@link TaskStatus}.
   */
  protected async connectAndProcess(httpOptions: http.HttpRequestOptions,header:Record<string,string>): Promise<TaskStatus> {
    if (!this.task) {
      console.error(TaskWorker.TAG, 'connectAndProcessHttpRequest called without a task');
      return TaskStatus.failed;
    }

    const options: http.HttpRequestOptions = {}

    try {
      if ((this.task.isDownloadTask() || this.task.isDataTask()) && this.task.post != undefined) {
        const encoder = new util.TextEncoder();
        let result = encoder.encodeInto(this.task.post);


        httpOptions.extraData = result;
        httpOptions.method = http.RequestMethod.POST;


      }
      return this.process(httpOptions,header)
    } catch (e) {
      this.setTaskException(e);
      return TaskStatus.failed;
      // switch (e) {
      //   case FileSystemException:
      // }
    } finally {
      await TaskWorker.workerShareableData!.withLock(() => {
        TaskWorker.workerShareableData!.remainingBytesToDownload.delete(this.task!.taskId); //share
      })
    }

    return TaskStatus.failed;

  }

  /**
   * Process the {@link task} using the provided connection.
   *
   * Overridden by subclasses.
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  public async process(httpOptions: http.HttpRequestOptions,header:Record<string,string>): Promise<TaskStatus> {
    throw new Error('Not implemented');
  }

  /**
   * Set the {@link taskException} variable based on Exception {@code error}.
   */
  protected setTaskException(error: ESObject): void {
    const name = TaskWorker.errorName(error);
    let exceptionType = ExceptionType.general;

    if (name?.includes('FileSystem') || name?.includes('IO')) {
      exceptionType = ExceptionType.fileSystem;
    }
    if (name?.includes('Socket')) {
      exceptionType = ExceptionType.connection;
    }

    const description = error instanceof Error ? error.toString() : `${error}`;
    this.taskException = new TaskException(exceptionType, undefined, description);
  }

  private static extractOutputStream(connection: ESObject): ESObject | undefined {
    if (connection && typeof (connection as ESObject)['getOutputStream'] === 'function') {
      return (connection as ESObject)['getOutputStream']();
    }
    if (connection && (connection as ESObject)['outputStream'] !== undefined) {
      return (connection as ESObject)['outputStream'] as ESObject;
    }
    return undefined;
  }

  private static errorName(error: ESObject): string | undefined {
    if (!error) {
      return undefined;
    }
    if (error instanceof Error) {
      return error.name;
    }
    if (typeof (error as ESObject)['name'] === 'string') {
      return (error as ESObject)['name'] as string;
    }
    return undefined;
  }


  public task ?: Task;
  // properties related to pause/resume functionality and progress
  public startByte = 0 // actual starting position within the task range, used for resume
  public bytesTotal = 0 // total bytes read in this download session
  public taskCanResume = false // whether task is able to resume
  public isResume = false // whether task is a resume
  private bytesTotalAtLastProgressUpdate = 0
  private lastProgressUpdateTime = 0 // in millis
  private lastProgressUpdate = 0.0
  private nextProgressUpdateTime = 0
  public networkSpeed = -1.0 // in MB/s
  private isTimedOut = false
  // properties related to notifications
  public notificationConfigJsonString ?: string
  public notificationConfig ?: NotificationConfig
  public notificationId = 0
  public notificationProgress = 2.0 // indeterminate

  // additional parameters for final TaskStatusUpdate
  public taskException ?: TaskException
  public responseBody ?: string
  private responseHeaders ?: Map<string, string>
  public responseStatusCode ?: number
  private mimeType ?: string // derived from Content-Type header
  private charSet ?: string // derived from Content-Type header

  // related to foreground tasks
  private runInForegroundFileSize: number = -1
  public canRunInForeground = false
  public runInForeground = false
  private hasDeliveredResult = false

  get isActive():
    boolean {
    //return !this.hasDeliveredResult && !this.isStopped;
    return !this.hasDeliveredResult;
  }

  public prefs ?: dataPreferences.Preferences

  public applicationContext ?: common.UIAbilityContext
  static taskException ?: TaskException
  static keyTasksMap = "com.bbflight.background_downloader.taskMap.v2"

  public workerParams?:collections.Map<string, string | number|boolean | ResumeData | undefined>
  //
  constructor(applicationContext ?: common.UIAbilityContext,workerParams?:collections.Map<string, string | number | boolean | ResumeData | undefined>) {
    //constructor(applicationContext?:common.UIAbilityContext,workerParams?:Map<string,ESObject>) {
    this.applicationContext = applicationContext
    this.workerParams = workerParams
  }
  //
}


/** Return the map of tasks stored in preferences */
export function getTaskMap(prefs: dataPreferences.Preferences): Map<string, Task> {
  const tasksMapJson = (prefs.getSync(BDPlugin.keyTasksMap, "{}") as string) ?? "{}";
  let parsed: Record<string, Task> | undefined;
  try {
    parsed = JSON.parse(tasksMapJson) as Record<string, Task>;
  } catch (_) {
    parsed = {};
  }

  const result = new Map<string, Task>();
  if (!parsed) {
    return result;
  }

  const entries: Array<[string, Task]> = Object.entries(parsed);
  entries.forEach((entry) => {
    const taskId = entry[0];
    const taskData = entry[1];
    const task = Task.fromPlain(taskData as Task);
    result.set(taskId, task);
  });

  return result;
}
//
// const workerPort: ThreadWorkerGlobalScope = worker.workerPort;
//
//
// workerPort.onmessage = (e: MessageEvents) => {
//   console.info("sendable obj is: ");
//   //let obj: collections.Map<string, string> = e.data;
//
//
// }
//
// // 注册onmessageerror回调，当Worker对象接收到一条无法被序列化的消息时被调用，在Worker线程执行
// workerPort.onmessageerror = () => {
//   console.error('workerPort onmessageerror');
// }
//
// // 注册onerror回调，捕获Worker在执行过程中发生的异常，在Worker线程执行
// workerPort.onerror = (err: ErrorEvent) => {
//   console.error('workerPort onerror err is: ', err.message);
// }






