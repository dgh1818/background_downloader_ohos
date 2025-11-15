import { collections, MessageEvents, taskpool, ThreadWorkerGlobalScope, worker } from '@kit.ArkTS'
import {
  BaseDirectory,
  ExceptionType,
  Task,
  TaskException,
  TaskOptions,
  TaskOptionsJSON,
  TaskProgressUpdate,
  TaskStatus,
  TaskStatus_fun,
  Updates,
} from './Models'
import dataPreferences from '@ohos.data.preferences'
import { common } from '@kit.AbilityKit'
import BDPlugin from './BDPlugin'
import { WiFi } from './WIFI'
import { EnqueueItem, HoldingQueue } from './HoldingQueue'
import { NotificationConfig } from './Notifications'
import {BackgroundPost, QueueService} from './QueueService'
import { systemDateTime } from '@kit.BasicServicesKit'
import {TaskStatusUpdate,TaskStatusUpdatePara} from './Models'
import { workScheduler } from '@kit.BackgroundTasksKit'
import { Callbacks } from './Callbacks'



export enum TaskWorkerKey{
  keyNotificationConfig = "notificationConfig",
  keyResumeDataData = "tempFilename",
  keyStartByte = "startByte",
  keyETag = "eTag",
  keyTask = "Task"
}

export class TaskWorker {
  static readonly TAG = "TaskWorker"
  static readonly chunkGroup = "chunk"
  static readonly keyTask = "Task"
  static readonly keyNotificationConfig = "notificationConfig"
  static readonly keyResumeDataData = "tempFilename"
  static readonly keyStartByte = "startByte"
  static readonly keyETag = "eTag"
  static readonly bufferSize = 2 << 12;
  static readonly taskTimeoutMillis = 9 * 60 * 1000; // 9 minutes

  public static taskToJsonString(task: Task): string {
    return JSON.stringify(TaskWorker.toSerializableTask(task));
  }

  public static async postOnBackgroundChannel(
    method: string, task: Task, arg: ESObject, onFail?: () => Promise<void>
  ) {
    let bgPost = new BackgroundPost(task, method, arg, onFail)
    return QueueService.postOnBackgroundChannel(bgPost)
  }

  /**
   * Processes a progress update for the [task]
   *
   * Sends progress update via the background channel to Flutter, if requested
   */
  public static async processProgressUpdate(
    task: Task, progress: number, prefs: dataPreferences.Preferences, expectedFileSize: number = -1,
    downloadSpeed: number = -1.0, timeRemaining: number = -1000
  ) {
    if (task.providesProgressUpdates()) {
      await TaskWorker.postOnBackgroundChannel(
        "progressUpdate", task,
        [progress, expectedFileSize, downloadSpeed, timeRemaining],
        async () => {
          // unsuccessful post, so store in local prefs
          console.error(TaskWorker.TAG, "Could not post progress update -> storing locally")
          this.storeLocally(
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

  private static storeLocally(
    prefsKey: string,
    taskId: string,
    item: string,
    prefs: dataPreferences.Preferences
  ) {
    BDPlugin.prefsLock.lockAsync(() => {
      let jsonString = prefs.getSync(prefsKey, "{}") as string
      const mapByTaskId = jsonString ? JSON.parse(jsonString) as Record<string, string> : {}
      mapByTaskId[taskId] = item;
      prefs.putSync(prefsKey, JSON.stringify(mapByTaskId));
      prefs.flushSync();
    })
  }

  private static mapToRecord(map?: Map<string, string> | collections.Map<string, string>): Record<string, string> | undefined {
    if (!map) {
      return undefined
    }
    const record: Record<string, string> = {}
    const iterator = (map as unknown as { entries?: () => IterableIterator<[string, string]> }).entries
    if (typeof iterator === 'function') {
      for (const [key, value] of iterator.call(map)) {
        if (value !== undefined) {
          record[key] = value
        }
      }
    } else if (typeof (map as unknown as { forEach?: (callback: (value: string, key: string) => void) => void }).forEach === 'function') {
      (map as unknown as { forEach: (callback: (value: string, key: string) => void) => void }).forEach((value, key) => {
        if (value !== undefined) {
          record[key] = value
        }
      })
    }
    return record
  }

  private static arrayToList(array?: collections.Array<string>): string[] | undefined {
    if (!array) {
      return undefined
    }
    const result: string[] = []
    array.forEach((value: string) => {
      result.push(value)
    })
    return result
  }

  private static filterHeaders(headers?: Map<string, string> | collections.Map<string, string>): Map<string, string> | undefined {
    if (!headers) {
      return undefined
    }
    const lowered = new Map<string, string>()
    const iterator = (headers as unknown as { entries?: () => IterableIterator<[string, string]> }).entries
    if (typeof iterator === 'function') {
      for (const [key, value] of iterator.call(headers)) {
        if (value !== undefined) {
          lowered.set(key.toLowerCase(), value)
        }
      }
    } else if (typeof (headers as unknown as { forEach?: (callback: (value: string, key: string) => void) => void }).forEach === 'function') {
      (headers as unknown as { forEach: (callback: (value: string, key: string) => void) => void }).forEach((value, key) => {
        if (value !== undefined) {
          lowered.set(key.toLowerCase(), value)
        }
      })
    }
    return lowered
  }

  public static toSerializableTask(task: Task): Record<string, Object> {
    const headers = TaskWorker.mapToRecord(task.headers)
    const fields = TaskWorker.mapToRecord(task.fields)
    const urls = TaskWorker.arrayToList(task.urls)

    const base = {
      taskId: task.taskId,
      url: task.url,
      filename: task.filename,
      headers,
      httpRequestMethod: task.httpRequestMethod,
      chunks: task.chunks,
      fileField: task.fileField,
      mimeType: task.mimeType,
      fields,
      directory: task.directory,
      baseDirectory: task.baseDirectory as number,
      group: task.group,
      updates: task.updates as number,
      requiresWiFi: task.requiresWiFi,
      retries: task.retries,
      retriesRemaining: task.retriesRemaining,
      allowPause: task.allowPause,
      priority: task.priority,
      metaData: task.metaData,
      displayName: task.displayName,
      creationTime: task.creationTime,
      taskType: task.taskType,
      urls,
    }

    if (task.post !== undefined) {
      base.post = task.post
    }

    if (task.options !== undefined) {
      const serializedOptions = TaskWorker.serializeTaskOptions(task.options)
      if (serializedOptions) {
        base.options = serializedOptions
      }
    }

    return base
  }

  private static recordToCollectionsMap(record?: Record<string, string>): collections.Map<string, string> {
    const map = new collections.Map<string, string>()
    if (record) {
      for (const [key, value] of Object.entries(record)) {
        if (value !== undefined) {
          map.set(key, value)
        }
      }
    }
    return map
  }

  private static listToCollectionsArray(list?: string[]): collections.Array<string> {
    const array = new collections.Array<string>()
    if (list) {
      list.forEach((value) => {
        if (typeof (array as unknown as { push?: (item: string) => number }).push === 'function') {
          (array as unknown as { push: (item: string) => number }).push(value)
        } else if (typeof (array as unknown as { add?: (item: string) => void }).add === 'function') {
          (array as unknown as { add: (item: string) => void }).add(value)
        }
      })
    }
    return array
  }

  public static fromSerializableTask(data: Record<string, Object>): Task {
    const headers = TaskWorker.recordToCollectionsMap(data['headers'] as Record<string, string> | undefined)
    const fields = TaskWorker.recordToCollectionsMap(data['fields'] as Record<string, string> | undefined)
    const urls = TaskWorker.listToCollectionsArray(data['urls'] as string[] | undefined)

    return new Task({
      taskId: data['taskId'] as string | undefined,
      url: data['url'] as string | undefined,
      filename: data['filename'] as string | undefined,
      headers,
      httpRequestMethod: data['httpRequestMethod'] as string | undefined,
      chunks: data['chunks'] as number | undefined,
      post: data['post'] as string | undefined,
      fileField: data['fileField'] as string | undefined,
      mimeType: data['mimeType'] as string | undefined,
      fields,
      directory: data['directory'] as string | undefined,
      baseDirectory: TaskWorker.resolveBaseDirectory(data['baseDirectory'] as number | BaseDirectory | undefined),
      group: data['group'] as string | undefined,
      updates: TaskWorker.resolveUpdates(data['updates'] as number | Updates | undefined),
      requiresWiFi: data['requiresWiFi'] as boolean | undefined,
      retries: data['retries'] as number | undefined,
      retriesRemaining: data['retriesRemaining'] as number | undefined,
      allowPause: data['allowPause'] as boolean | undefined,
      priority: data['priority'] as number | undefined,
      metaData: data['metaData'] as string | undefined,
      displayName: data['displayName'] as string | undefined,
      creationTime: data['creationTime'] as number | undefined,
      options: TaskWorker.deserializeTaskOptions(data['options'] as Record<string, Object> | TaskOptions | undefined),
      taskType: data['taskType'] as string | undefined,
      urls,
    })
  }

  private static resolveBaseDirectory(value: number | BaseDirectory | undefined): BaseDirectory {
    if (typeof value === 'number' && BaseDirectory[value] !== undefined) {
      return value as BaseDirectory
    }
    if (value !== undefined) {
      return value as BaseDirectory
    }
    return BaseDirectory.applicationDocuments
  }

  private static resolveUpdates(value: number | Updates | undefined): Updates {
    if (typeof value === 'number' && Updates[value] !== undefined) {
      return value as Updates
    }
    if (value !== undefined) {
      return value as Updates
    }
    return Updates.status
  }

  private static serializeTaskOptions(options?: TaskOptions): TaskOptionsJSON | undefined {
    if (!options) {
      return undefined
    }
    return options.toJSON()
  }

  private static deserializeTaskOptions(
    raw?: Record<string, Object> | TaskOptions,
  ): TaskOptions | undefined {
    if (!raw) {
      return undefined
    }
    if (raw instanceof TaskOptions) {
      return raw
    }
    return TaskOptions.from(raw as TaskOptionsJSON)
  }

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

    if (BDPlugin.tasksToReEnqueue.delete(task)) {
      if (status == TaskStatus.paused || status == TaskStatus.canceled || status == TaskStatus.failed) {
        WiFi.reEnqueue(
          new EnqueueItem(
            context,
            task,
            BDPlugin.notificationConfigJsonStrings.get(task.taskId),
            BDPlugin.localResumeData.get(task.taskId)
          )
        )
        if (BDPlugin.tasksToReEnqueue.size == 0) {
          WiFi.reEnqueue(undefined) // signal end of batch
        }
        return
      }
      if (BDPlugin.tasksToReEnqueue.size == 0) {
        WiFi.reEnqueue(undefined)
      }
    }

    // Normal status update

    // Check if the task was 'programmatically' canceled, in which case a TaskStatus.failed may be
    // incorrectly generated by the WorkManager, so we change it to 'canceled'
    let modifiedStatus: TaskStatus =
      BDPlugin.canceledTaskIds.has(task.taskId) ? TaskStatus.canceled : status
    let retryNeeded = modifiedStatus as number == TaskStatus.failed && task.retriesRemaining > 0
    let canSendStatusUpdate = true

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
        canSendStatusUpdate = TaskWorker.canSendCancellation(task)
        if (canSendStatusUpdate) {
          BDPlugin.cancelUpdateSentForTaskId.set(task.taskId, systemDateTime.getTime(false));
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


    const isFinal = TaskStatus_fun.isFinalState(modifiedStatus)
    const includeStatusCode =
      modifiedStatus == TaskStatus.complete || modifiedStatus == TaskStatus.notFound
    const loweredHeaders = TaskWorker.filterHeaders(responseHeaders)
    const resolvedException =
      isFinal && modifiedStatus == TaskStatus.failed as number
        ? taskException ?? new TaskException(ExceptionType.general)
        : undefined

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

    if (canSendStatusUpdate && (task.providesStatusUpdates() || retryNeeded)) {
      let arg = taskStatusUpdate.argList
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
          if (workManager[i].parameters['taskId'] == task.taskId) {
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
        let tasksMap = await getTaskMap(prefs)
        tasksMap.delete(task.taskId)
        const serializedTasks: Record<string, Object> = {}
        for (const entry of tasksMap.entries()) {
          const id = entry[0]
          const storedTask = entry[1]
          serializedTasks[id] = TaskWorker.toSerializableTask(storedTask)
        }
        prefs.putSync(BDPlugin.keyTasksMap, JSON.stringify(serializedTasks));
        prefs.flushSync();
        // 执行某些操作
      });

      QueueService.cleanupTaskId(task.taskId)
      if (task.options?.hasOnFinishCallback() == true) {
        Callbacks.invokeOnTaskFinishedCallback(context, taskStatusUpdate)
      }
    }
  }

  /** Return true if we can send a cancellation for this task
   *
   * Cancellation can only be sent if it wasn't already sent by the [BDPlugin]
   *  in the cancelTasksWithId method.  Side effect is to clean out older cancellation entries
   * from the [BDPlugin.cancelUpdateSentForTaskId]
   */
  private static canSendCancellation(task: Task): boolean {
    let now = systemDateTime.getTime(false);
    BDPlugin.cancelUpdateSentForTaskId = new Map(
      Array.from(BDPlugin.cancelUpdateSentForTaskId.entries())
        .filter(([_, ts]) => now - ts < 3000)
    );
    return BDPlugin.cancelUpdateSentForTaskId.get(task.taskId) == undefined;
  }


  public task?: Task
  // properties related to pause/resume functionality and progress
  public startByte = 0 // actual starting position within the task range, used for resume
  public bytesTotal = 0 // total bytes read in this download session
  public taskCanResume = false // whether task is able to resume
  public sResume = false // whether task is a resume
  private bytesTotalAtLastProgressUpdate = 0
  private lastProgressUpdateTime = 0 // in millis
  private lastProgressUpdate = 0.0
  private nextProgressUpdateTime = 0
  public networkSpeed = -1.0 // in MB/s
  private isTimedOut = false
  // properties related to notifications
  public notificationConfigJsonString?: string
  public notificationConfig?: NotificationConfig
  public notificationId = 0
  public notificationProgress = 2.0 // indeterminate

  // additional parameters for final TaskStatusUpdate
  public taskException?: TaskException
  public responseBody?: string
  private responseHeaders?: Map<string, string>
  public responseStatusCode?: number
  private mimeType?: string // derived from Content-Type header
  private charSet?: string // derived from Content-Type header

  // related to foreground tasks
  private runInForegroundFileSize: number = -1
  public canRunInForeground = false
  public runInForeground = false
  private hasDeliveredResult = false

  get isActive(): boolean {
    return !this.hasDeliveredResult && !this.isStopped;
  }

  public prefs?: dataPreferences.Preferences
  // static keyNotificationConfig: string
  // static keyResumeDataData: string
  // static keyStartByte: string
  // static keyETag: string

  public applicationContext?: common.UIAbilityContext
  static taskException?: TaskException
  static keyTasksMap = "com.bbflight.background_downloader.taskMap.v2"

  //public workerParams?:Map<string,ESObject>

  constructor(applicationContext?: common.UIAbilityContext) {
    //constructor(applicationContext?:common.UIAbilityContext,workerParams?:Map<string,ESObject>) {
    this.applicationContext = applicationContext
    //this.workerParams = workerParams
  }
}










  /** Return the map of tasks stored in preferences */




export function getTaskMap(prefs: dataPreferences.Preferences): Map<string, Task> {
  const tasksMapJson = (prefs.getSync(BDPlugin.keyTasksMap, "{}") as string) ?? "{}"
  const parsed = JSON.parse(tasksMapJson) as Record<string, Object>
  const result = new Map<string, Task>()
  for (const [taskId, taskData] of Object.entries(parsed)) {
    result.set(taskId, TaskWorker.fromSerializableTask(taskData as Record<string, Object>))
  }
  return result
}

const workerPort: ThreadWorkerGlobalScope = worker.workerPort;



workerPort.onmessage = (e: MessageEvents) => {
  let obj: collections.Map<string, string> = e.data;
  console.info("sendable obj is: ");


}






