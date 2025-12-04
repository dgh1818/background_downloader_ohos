import {
  FlutterPlugin,
  FlutterPluginBinding,
  MethodCall,
  MethodCallHandler,
  MethodChannel,
  MethodResult,
  StandardMethodCodec,
  AbilityAware,
  AbilityPluginBinding,
  FlutterLoader,
  PluginRegistry,
  FlutterEngine,
  BinaryMessenger
} from "@ohos/flutter_ohos";
import {
  Ability,
  abilityAccessCtrl,
  common,
  ErrorCode,
  PermissionRequestResult,
  Permissions,
  sendableContextManager,
  StartOptions,
  UIAbility,
  Want,
  wantConstant
} from "@kit.AbilityKit";
import { hash } from '@kit.CoreFileKit';
import { BusinessError } from '@ohos.base';
import {
  ArkTSUtils,
  ArrayList,
  collections,
  ErrorEvent,
  List,
  MessageEvents,
  taskpool,
  uri,
  url,
  worker
} from "@kit.ArkTS";
import { fileUri, fileIo as fs } from '@kit.CoreFileKit';
import dataPreferences from '@ohos.data.preferences'
import { photoAccessHelper } from "@kit.MediaLibraryKit";
import { dataSharePredicates, preferences } from "@kit.ArkData";
import { workScheduler } from "@kit.BackgroundTasksKit";

import { EnqueueItem, HoldingQueue } from './HoldingQueue'
import { NotificationConfig, NotificationService } from './Notifications'
import { ResumeData, Task, RequireWiFi, TaskStatus, TaskException } from "./Models";
import { getTaskMap, TaskWorker, TaskWorkerKey } from "./TaskWorker";
import { methodEnqueueAll_task } from "./methodEnqueueAll_task";

@Sendable
export class WorkerShareableData {
  constructor(

    // requireWifi?: boolean | undefined,
    // triggerUpdateDelay?: number | undefined,
    // triggerMaxDelay?: number | undefined,
  ) {


    // this.requireWifi = requireWifi;
    // this.triggerUpdateDelay = triggerUpdateDelay;
    // this.triggerMaxDelay = triggerMaxDelay;
  }

  public haveLoggedProxyMessage: boolean = false;
  public remainingBytesToDownload: collections.Map<string, number> = new collections.Map<string, number>();
  public pausedTaskIds: collections.Set<string> = new collections.Set<string>();
  public tasksToReEnqueue: collections.Set<Task> = new collections.Set<Task>();
  public localResumeData: collections.Map<string, ResumeData> = new collections.Map<string, ResumeData>()
  public notificationConfigJsonStrings: collections.Map<string, string> = new collections.Map<string, string>();
  public canceledTaskIds: collections.Set<string> = new collections.Set<string>()
  public cancelUpdateSentForTaskId: collections.Map<string, number> = new collections.Map<string, number>();
  public tempFilePathByTaskId: collections.Map<string, string> = new collections.Map<string, string>();
  public lock: ArkTSUtils.locks.AsyncLock = new ArkTSUtils.locks.AsyncLock();

  public async withLock(action: () => void | Promise<void>): Promise<void> {
    await this.lock.lockAsync(action);
  }

  public command: string = "";
  // public requireWifi?: boolean = false;
  // public triggerUpdateDelay?: number = 5000;
  // public triggerMaxDelay?: number = 50000;
}

@Sendable
export class WorkerCommand {
  constructor(
    command: string,
    sendableUIContext: sendableContextManager.SendableContext,
    taskWorkerData: collections.Map<string, number | string | boolean | undefined | ResumeData>,
    workerShareableData: WorkerShareableData,
    // requireWifi?: boolean | undefined,
    // triggerUpdateDelay?: number | undefined,
    // triggerMaxDelay?: number | undefined,
  ) {
    this.command = command;
    this.sendableUIContext = sendableUIContext;
    this.taskWorkerData = taskWorkerData;
    this.workerShareableData = workerShareableData;

    // this.requireWifi = requireWifi;
    // this.triggerUpdateDelay = triggerUpdateDelay;
    // this.triggerMaxDelay = triggerMaxDelay;
  }

  public command: string;
  public sendableUIContext: sendableContextManager.SendableContext;
  public taskWorkerData: collections.Map<string, number | string | boolean | undefined | ResumeData>
  public workerShareableData: WorkerShareableData;
}

export default class BDPlugin implements FlutterPlugin, MethodCallHandler, AbilityAware {
  public static readonly TAG = "BackgroundDownloader"
  public static readonly keyTasksMap = "com.bbflight.background_downloader.taskMap.v2"
  public static readonly keyResumeDataMap = "com.bbflight.background_downloader.resumeDataMap.v2"
  public static readonly keyStatusUpdateMap = "com.bbflight.background_downloader.statusUpdateMap.v2"
  public static readonly keyProgressUpdateMap = "com.bbflight.background_downloader.progressUpdateMap.v2"
  public static readonly keyRequireWiFi =
    "com.bbflight.background_downloader.requireWifi"
  public static readonly keyCallbackDispatcherRawHandle =
    "com.bbflight.background_downloader.callbackDispatcherRawHandle"
  public static readonly keyConfigForegroundFileSize =
    "com.bbflight.background_downloader.config.foregroundFileSize"
  public static readonly keyConfigProxyAddress = "com.bbflight.background_downloader.config.proxyAddress"
  public static readonly keyConfigProxyPort = "com.bbflight.background_downloader.config.proxyPort"
  public static readonly keyConfigRequestTimeout =
    "com.bbflight.background_downloader.config.requestTimeout"
  public static readonly keyConfigCheckAvailableSpace =
    "com.bbflight.background_downloader.config.checkAvailableSpace"
  public static readonly keyConfigUseCacheDir = "com.bbflight.background_downloader.config.useCacheDir"
  public static readonly keyConfigUseExternalStorage =
    "com.bbflight.background_downloader.config.useExternalStorage"
  //@SuppressLint("StaticFieldLeak")
  public static notificationButtonText = new Map<string, string>()
  // for localization
  public static firstBackgroundChannel?: MethodChannel;
  public static bgChannelByTaskId = new Map<string, MethodChannel>()
  public static flutterEngineByTaskId = new Map<string, FlutterEngine>();
  // Avoid touching the enum at module eval time; initialize in onAttachedToAbility
  public static requireWifi: RequireWiFi = 0 as RequireWiFi;
  public static workerShareableData: WorkerShareableData = new WorkerShareableData();
  public static runningWorkers: Map<string, worker.ThreadWorker> = new Map<string, worker.ThreadWorker>();
  // <taskId, timeMillis>
  // <taskId>, acts as flag
  //public static parallelDownloadTaskWorkers = new Map<string, ParallelDownloadTaskWorker>() //Was a HashMap
  // for when WiFi requirement changes
  public static taskIdsRequiringWiFi = new Set<string>()
  // by taskId
  public static forceFailPostOnBackgroundChannel = false
  public static prefsLock = new ArkTSUtils.locks.AsyncLock()
  // <taskId, size>

  public static holdingQueue?: HoldingQueue
  public static latestPluginInstance?: BDPlugin;
  public workCommand?:WorkerCommand;

  static async doEnqueue(
    context: common.UIAbilityContext,
    task: Task,
    notificationConfigJsonString?: string,
    resumeData?: ResumeData,
    initialDelayMillis: number = 0,
    //plugin?: BDPlugin
  ): Promise<boolean> {

    if (BDPlugin.holdingQueue) {
      BDPlugin.holdingQueue.hostByTaskId.set(task.taskId, task.host() ?? "");
    }
    await BDPlugin.workerShareableData.withLock(() => {
      BDPlugin.workerShareableData.canceledTaskIds.delete(task.taskId);
      BDPlugin.workerShareableData.cancelUpdateSentForTaskId.delete(task.taskId);
    });
    console.error(BDPlugin.TAG, `Enqueuing task with id ${task.taskId}8`);

    const parameters: Record<string, string | number | boolean> = {};
    parameters[TaskWorkerKey.keyTask] = TaskWorker.taskToJsonString(task) as string;
    console.error(BDPlugin.TAG, `before if (notificationConfigJsonString !== undefined) {:`+notificationConfigJsonString !== undefined);
    if (notificationConfigJsonString !== undefined) {
      parameters[TaskWorkerKey.keyNotificationConfig] = notificationConfigJsonString;
      await BDPlugin.workerShareableData.withLock(() => {
        BDPlugin.workerShareableData.notificationConfigJsonStrings.set(task.taskId, notificationConfigJsonString);
      });
    }
    if (resumeData !== undefined) {
      parameters[TaskWorkerKey.keyResumeDataData] = resumeData.data;
      parameters[TaskWorkerKey.keyStartByte] = resumeData.requiredStartByte;
      if (resumeData.eTag !== undefined) {
        parameters[TaskWorkerKey.keyETag] = resumeData.eTag;
      }
    }

    const taskRequiresWifi = BDPlugin.taskRequiresWifi(task);
    if (taskRequiresWifi) {
      BDPlugin.taskIdsRequiringWiFi.add(task.taskId);
    }

    const networkCondition = taskRequiresWifi
      ? workScheduler.NetworkType.NETWORK_TYPE_WIFI
      : workScheduler.NetworkType.NETWORK_TYPE_ANY;

    const workerPath = BDPlugin.resolveWorkerPath(task.taskType);
    if (!workerPath) {
      console.error(BDPlugin.TAG, `Unknown taskType ${task.taskType}`);
      return false;
    }

    // const request: workScheduler.WorkInfo = {
    //   workId: parseInt(task.taskId),
    //   bundleName: "background_downloader",
    //   abilityName: workerName,
    //   networkType: networkCondition,
    //   parameters:parameters,
    // };

    const taskWorker: worker.ThreadWorker = new worker.ThreadWorker(workerPath);
    BDPlugin.runningWorkers.set(task.taskId, taskWorker);

    taskWorker.onerror = (err: ErrorEvent) => {
      console.info("Worker出错了：" + err.message);
    }

    const taskIdForWorker = task.taskId;
    taskWorker.onexit = (code: number) => {
      BDPlugin.runningWorkers.delete(taskIdForWorker);
      // Only clean temp file on abnormal exit; normal completion is cleaned in worker
      if (code != 0) {
        BDPlugin.cleanupTempFileForTask(taskIdForWorker);
      }
    };

    taskWorker.onmessage = async (event: MessageEvents) => {
      const data = event.data as Record<string, ESObject>;
      const command = data["command"] as string | undefined;
      if (!command) {
        return;
      }
      // Ensure static workerShareableData is available for TaskWorker.* helpers
      TaskWorker.workerShareableData = BDPlugin.workerShareableData;  //is it needed?? /To do
      try {
        const options: preferences.Options = { name: "DEFAULT" };
        const prefs = preferences.getPreferencesSync(BDPlugin.uiContext!, options);
        switch (command) {
          case "progressUpdate": {
            const taskJson = data["taskJson"] as string;
            const taskFromMsg = Task.fromPlain(JSON.parse(taskJson) as Task);
            const progress = data["progress"] as number;
            const expectedFileSize = (data["expectedFileSize"] as number) ?? -1;
            const downloadSpeed = (data["downloadSpeed"] as number) ?? -1.0;
            const timeRemaining = (data["timeRemaining"] as number) ?? -1000;
            await TaskWorker.processProgressUpdate(
              taskFromMsg,
              progress,
              prefs,
              expectedFileSize,
              downloadSpeed,
              timeRemaining
            );
            break;
          }
          case "statusUpdate": {
            const taskJson = data["taskJson"] as string;
            const taskFromMsg = Task.fromPlain(JSON.parse(taskJson) as Task);
            const status = data["status"] as TaskStatus;
            const exception = data["exception"] as TaskException | undefined;
            const responseBody = data["responseBody"] as string | undefined;
            const responseStatusCode = data["responseStatusCode"] as number | undefined;
            await TaskWorker.processStatusUpdate(
              taskFromMsg,
              status,
              prefs,
              BDPlugin.uiContext,
              exception,
              responseBody,
              undefined,
              responseStatusCode
            );
            break;
          }
          case "reEnqueue": {
            const taskJson = data["taskJson"] as string;
            if (!taskJson) {
              break;
            }
            const taskFromMsg = Task.fromPlain(JSON.parse(taskJson) as Task);
            const notificationConfigJsonString = data["notificationConfigJsonString"] as string | undefined;
            const resumeDataObj = data["resumeData"] as ResumeData | undefined;
            const initialDelayMillis = (data["initialDelayMillis"] as number) ?? 0;
            let resumeData: ResumeData | undefined = undefined;
            if (resumeDataObj !== undefined) {
              resumeData = new ResumeData({
                task: taskFromMsg,
                data: resumeDataObj.data,
                requiredStartByte: resumeDataObj.requiredStartByte,
                eTag: resumeDataObj.eTag
              });
            }
            if (BDPlugin.uiContext !== undefined) {
              await BDPlugin.doEnqueue(
                BDPlugin.uiContext,
                taskFromMsg,
                notificationConfigJsonString,
                resumeData,
                initialDelayMillis
              );
            }
            break;
          }
          default:
            console.error(BDPlugin.TAG, `Unknown worker command ${command}`);
            break;
        }
      } catch (e) {
        console.error(BDPlugin.TAG, `Error handling worker message ${command}: ${e}`);
      }
    };

    if (context == undefined) {
      console.error("BDPlugin.sendableUIContext is false")
      return false;
    }
    //let requireWifi = BDPlugin.requireWifi.valueOf() == 1 ? true:false;
    let requireWifi = false;

    let taskWorkerData = new collections.Map<string, number | string | boolean | undefined | ResumeData>();

    taskWorkerData.set(TaskWorkerKey.keyTask, TaskWorker.taskToJsonString(task));
    taskWorkerData.set(TaskWorkerKey.keyNotificationConfig, notificationConfigJsonString);
    taskWorkerData.set(TaskWorkerKey.keyResumeDataData, resumeData?.data);
    taskWorkerData.set(TaskWorkerKey.keyStartByte, resumeData?.requiredStartByte);
    taskWorkerData.set(TaskWorkerKey.keyETag, resumeData?.eTag);

    //let sendableObject:SendableObject = new SendableObject("startWork",sendableContext,taskWorkerData)
    let workCommand = new WorkerCommand("startWork",BDPlugin.sendableUIContext!,taskWorkerData,BDPlugin.workerShareableData)

    taskWorker.postMessageWithSharedSendable(workCommand);

    //downloadTaskWorker.postMessageWithSharedSendable(sendableObject);
    //.startWork(request);

    try {
      const options: preferences.Options = { name: "DEFAULT" };
      const prefs = preferences.getPreferencesSync(BDPlugin.uiContext, options);
      if (BDPlugin.holdingQueue?.enqueuedTaskIds?.includes(task.taskId) !== true) {
        await TaskWorker.processStatusUpdate(
          task,
          TaskStatus.enqueued,
          prefs,
          BDPlugin.uiContext,
          undefined,
          undefined,
          undefined,
          undefined,
          undefined,
          undefined
        );
      }
    } catch (error) {
      console.error(BDPlugin.TAG, `Unable to start background request for taskId ${task.taskId}`, error);
      return false;
    }

    NotificationService.registerEnqueue(
      new EnqueueItem(context, task, notificationConfigJsonString, resumeData),
      true
    );

    BDPlugin.prefsLock.lockAsync(() => {
      const options: preferences.Options = { name: "DEFAULT" };
      const prefs = preferences.getPreferencesSync(BDPlugin.uiContext, options);
      const tasksMap = getTaskMap(prefs);
      tasksMap.set(task.taskId, task);
      // Store as plain object for compatibility with existing reads
      const serializedTasks: Record<string, string> = {};
      tasksMap.forEach((value, key) => {
        serializedTasks[key] = TaskWorker.taskToJsonString(task);
      });
      prefs.putSync(BDPlugin.keyTasksMap, JSON.stringify(serializedTasks));
      prefs.flushSync();
    });

    return true;
  }

  public static uiContext?: common.UIAbilityContext;
  public static sendableUIContext?: sendableContextManager.SendableContext;
  private prefs?: dataPreferences.Preferences;
  private channel?: MethodChannel
  static backgroundChannel?: MethodChannel
  //private applicationContext?: common.ApplicationContext;
  // scope?: CoroutineScope
  private binaryMessenger?: BinaryMessenger
  private activity?: Ability;

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    console.error("attach to engine");
    //context = ctx //move to onAttachedToAbility


    this.binaryMessenger = binding.getBinaryMessenger()
    BDPlugin.backgroundChannel =
      new MethodChannel(binding.getBinaryMessenger(), "com.bbflight.background_downloader.background");
    if (BDPlugin.firstBackgroundChannel == undefined) {
      BDPlugin.firstBackgroundChannel = BDPlugin.backgroundChannel;
    }
    this.channel = new MethodChannel(binding.getBinaryMessenger(), "com.bbflight.background_downloader")
    this.channel?.setMethodCallHandler(this)
    let uriUtilsChannel = new MethodChannel(
      binding.getBinaryMessenger(),
      "com.bbflight.background_downloader.uriutils"
    )

    // let allWorkInfos: workScheduler.WorkInfo[];
    //
    // workScheduler.obtainAllWorks().then((allWorkInfos: workScheduler.WorkInfo[]) => {
    //   if (allWorkInfos.length == 0) {
    //     BDPlugin.prefsLock.lockAsync(() => {
    //       prefs.deleteSync(BDPlugin.keyTasksMap);
    //       prefs.flushSync();
    //     })
    //   }
    // });
    //

  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    this.channel?.setMethodCallHandler(undefined);
    this.channel = undefined;

    BDPlugin.bgChannelByTaskId = new Map(
      Array.from(BDPlugin.bgChannelByTaskId).filter(entry => entry[1] !== BDPlugin.backgroundChannel)
    );

    if (BDPlugin.firstBackgroundChannel == BDPlugin.backgroundChannel) {
      BDPlugin.firstBackgroundChannel = undefined;
    }

    BDPlugin.backgroundChannel = undefined;
    this.binaryMessenger = undefined;
  }


  async onMethodCall(call: MethodCall, result: MethodResult): Promise<void> {

    console.error('BDPLUGIN' + call.method);
    switch (call.method) {
      case 'configForegroundFileSize':
        this.methodConfigForegroundFileSize(call, result);
        break;
      case 'configHoldingQueue':
        this.methodConfigHoldingQueue(call, result);
        break;
      case 'enqueueAll':
        this.methodEnqueueAll(call, result);
        break;
      case 'cancelTasksWithIds':
        this.methodCancelTasksWithIds(call, result);
        break;


      default:
        result.notImplemented();
        break;
    }
  }


  getUniqueClassName(): string {
    return "BDPlugin"
  }

  onAttachedToAbility(binding: AbilityPluginBinding) {
    console.error("enter onAttachedToAbility");
    //handleIntent(binding.activity.intent)
    BDPlugin.uiContext = binding.getAbility().context;
    BDPlugin.sendableUIContext = sendableContextManager.convertFromContext(BDPlugin.uiContext!);
    console.error("successful onAttachedToAbility");

    let options: preferences.Options = { name: 'DEFAULT' };
    let prefs = preferences.getPreferencesSync(BDPlugin.uiContext, options);
    BDPlugin.requireWifi = (prefs.getSync('keyRequireWiFi', 0) as RequireWiFi) ?? (0 as RequireWiFi);
    console.error("attach to engine successfully");

  }

  onDetachedFromAbility() {

  }

  private methodConfigForegroundFileSize(call: MethodCall, result: MethodResult) {
    let fileSize = call.args as number;
    this.updateSharedPreferences(BDPlugin.keyConfigForegroundFileSize, fileSize);
    if (fileSize == 0) {
      console.error("Enabled foreground mode for all tasks");
    } else if (fileSize == -1) {
      console.error("Disabled foreground mode for all tasks");
    } else {
      console.error("Set foreground file size threshold to" + fileSize + "MB");
    }

    result.success({});
  }

  /**
   * Helper function to update or delete the [value] in shared preferences under [key]
   *
   * If [value] is null, the [key] is deleted
   */
  private updateSharedPreferences(key: string, value?: number) {
    let options: preferences.Options = { name: 'DEFAULT' };
    let prefs = preferences.getPreferencesSync(BDPlugin.uiContext, options);
    if (value != undefined) {
      prefs.putSync(key, value)
    } else {
      prefs.deleteSync(key);
    }

    prefs.flushSync();
    console.info(BDPlugin.TAG, "Setting preference key" + key + ":" + value)
  }

  /**
   * Configure the holding queue
   */
  private methodConfigHoldingQueue(call: MethodCall, result: MethodResult) {
    let args: Array<ESObject> = call.args as Array<ESObject>
    if (args.length == 0) { // deactivate the holding queue
      BDPlugin.holdingQueue = undefined;
    } else {
      BDPlugin.holdingQueue = BDPlugin.holdingQueue ?? new HoldingQueue();
      BDPlugin.holdingQueue.maxConcurrent = args[0] as number;
      BDPlugin.holdingQueue.maxConcurrentByHost = args[1] as number;
      BDPlugin.holdingQueue.maxConcurrentByGroup = args[2] as number
    }
    result.success({});
  }

  /**
   * Cancel queued tasks with given ids (does not stop already running ones)
   */
  private async methodCancelTasksWithIds(call: MethodCall, result: MethodResult) {
    const taskIds = call.args as Array<string>;
    try {
      console.error(BDPlugin.TAG, `cancelTasksWithIds start: ${taskIds.join(",")}`);
      if (BDPlugin.holdingQueue) {
        await BDPlugin.holdingQueue.stateMutex.lockAsync(async () => {
          taskIds.forEach((id) => {
            const idx = BDPlugin.holdingQueue!.enqueuedTaskIds.indexOf(id);
            if (idx >= 0) {
              BDPlugin.holdingQueue!.enqueuedTaskIds.splice(idx, 1);
              console.error(BDPlugin.TAG, `Removed ${id} from holdingQueue`);
            }
          });
        });
      }
      // terminate running workers and delete temp files
      taskIds.forEach((id) => {
        const w = BDPlugin.runningWorkers.get(id);
        if (w) {
          console.error(BDPlugin.TAG, `Terminating worker for ${id}`);
          try {
            w.postMessage({ command: "cancelWork" });
            console.error(BDPlugin.TAG, `Sent cancelWork to worker for ${id}`);
          } catch (_) {}
          try {
            w.terminate();
            console.error(BDPlugin.TAG, `Terminated worker for ${id} successfully`);
          } catch (_) {}
          BDPlugin.runningWorkers.delete(id);
          console.error(BDPlugin.TAG, `Terminated worker for ${id}`);
        }
        console.error(BDPlugin.TAG, `Cleanup temp file for ${id}`);
        BDPlugin.cleanupTempFileForTask(id);
        console.error(BDPlugin.TAG, `Marked ${id} as canceled`);
      });
      // emit canceled status for matching tasks from persistent storage
      const options: preferences.Options = { name: 'DEFAULT' };
      const prefs = preferences.getPreferencesSync(BDPlugin.uiContext!, options);
      console.error(BDPlugin.TAG, `Obtained prefs for cancelTasksWithIds`);
      let tasksMap: Map<string, Task>;
      try {
        tasksMap = getTaskMap(prefs);
        console.error(BDPlugin.TAG, `Loaded tasks map with ${tasksMap.size} entries`);
      } catch (mapErr) {
        console.error(BDPlugin.TAG, `getTaskMap failed while canceling ${taskIds}: ${mapErr}`);
        result.success(false);
        return;
      }
      // Ensure TaskWorker has a shareable ref for cancellation updates
      TaskWorker.workerShareableData = BDPlugin.workerShareableData;
      for (const id of taskIds) {
        const task = tasksMap.get(id);
        if (task) {
          console.error(BDPlugin.TAG, `Posting canceled status for ${id}`);
          await TaskWorker.processStatusUpdate(
            task,
            TaskStatus.canceled,
            prefs,
            BDPlugin.uiContext,
            undefined,
            undefined,
            undefined,
            undefined
          );
        } else {
          console.error(BDPlugin.TAG, `No task found in prefs for ${id}, skipping status update`);
        }
      }
      console.error(BDPlugin.TAG, `cancelTasksWithIds completed ok`);
      result.success(true);
    } catch (e) {
      console.error(BDPlugin.TAG, `Failed to cancel tasks ${taskIds}: ${e}`);
      result.success(false);
    }
  }

  private scope?: taskpool.SequenceRunner;

  static methodbackgroundChannel(
    plugin: BDPlugin | undefined = undefined,
    taskId: string = "bgd_non_existent_id"
  ): MethodChannel | undefined {
    return BDPlugin.backgroundChannel
      ?? BDPlugin.bgChannelByTaskId.get(taskId)
      ?? BDPlugin.firstBackgroundChannel;
  }

  static taskRequiresWifi(task: Task): boolean {
    return (BDPlugin.requireWifi == RequireWiFi.forAllTasks ||
      (BDPlugin.requireWifi == RequireWiFi.asSetByTask && task.requiresWiFi))
  }

  private static resolveWorkerPath(taskType: string): string | undefined {
    switch (taskType) {
      case "ParallelDownloadTask":
        return "../../../../../background_downloader/src/main/ets/components/Plugin/ParallelDownloadTaskWorker.ets";
      case "DownloadTask":
      case "UriDownloadTask":
        return "../../../../../background_downloader/src/main/ets/components/Plugin/DownloadTaskWorker.ets";
      case "UploadTask":
      case "UriUploadTask":
      case "MultiUploadTask":
        return "../../../../../background_downloader/src/main/ets/components/Plugin/UploadTaskWorker.ets";
      case "DataTask":
        return "../../../../../background_downloader/src/main/ets/components/Plugin/DataTaskWorker.ets";
      default:
        return undefined;
    }
  }

  private static cleanupTempFileForTask(taskId: string) {
    const paths = BDPlugin.workerShareableData.tempFilePathByTaskId;
    const tempPath = paths.get(taskId);
    if (tempPath) {
      try {
        fs.unlinkSync(tempPath);
        console.info(BDPlugin.TAG, `Deleted temp file ${tempPath} for task ${taskId}`);
      } catch (_e) {
      }
      paths.delete(taskId);
    }
  }


  /**
   * Enqueue a WorkManager task based on the provided parameters
   */
  //   private doEnqueue(
  //   context: common.UIAbilityContext,
  //   task: Task,
  //   notificationConfigJsonString: String,
  //   resumeData: ResumeData?,
  //   initialDelayMillis: Long = 0,
  //   plugin: BDPlugin? = null
  //   ): Boolean {
  //   Log.i(TAG, "Enqueuing task with id ${task.taskId}")
  //   // store backgroundChannel to be used by this task
  //   val bgChannel = backgroundChannel(plugin)
  //   if (bgChannel != null) {
  //   bgChannelByTaskId[task.taskId] = bgChannel
  // } else {
  //   Log.w(TAG, "Could not find backgroundChannel for taskId ${task.taskId}")
  // }
  // holdingQueue?.hostByTaskId?.set(
  //   task.taskId,
  //   task.host()
  // ) // store host if we have a HoldingQueue
  // canceledTaskIds.remove(task.taskId) // reset flag
  // cancelUpdateSentForTaskId.remove(task.taskId) // reset flag
  // val dataBuilder = Data.Builder().putString(TaskWorker.keyTask, taskToJsonString(task))
  // if (notificationConfigJsonString != null) {
  //   dataBuilder.putString(
  //     TaskWorker.keyNotificationConfig,
  //     notificationConfigJsonString
  //   )
  //   notificationConfigJsonStrings[task.taskId] = notificationConfigJsonString
  // }
  // if (resumeData != null) {
  //   dataBuilder.putString(TaskWorker.keyResumeDataData, resumeData.data)
  //     .putLong(TaskWorker.keyStartByte, resumeData.requiredStartByte)
  //     .putString(TaskWorker.keyETag, resumeData.eTag)
  // }
  // val data = dataBuilder.build()
  // val taskRequiresWifi = taskRequiresWifi(task)
  // if (taskRequiresWifi) {
  //   taskIdsRequiringWiFi.add(task.taskId)
  // }
  // val constraints = Constraints.Builder().setRequiredNetworkType(
  //   if (taskRequiresWifi) NetworkType.UNMETERED else NetworkType.CONNECTED
  // ).build()
  // val requestBuilder = when (task.taskType) {
  //   "ParallelDownloadTask" -> OneTimeWorkRequestBuilder<ParallelDownloadTaskWorker>()
  //   "DownloadTask" -> OneTimeWorkRequestBuilder<DownloadTaskWorker>()
  //   "UriDownloadTask" -> OneTimeWorkRequestBuilder<DownloadTaskWorker>()
  //   "UploadTask" -> OneTimeWorkRequestBuilder<UploadTaskWorker>()
  //   "UriUploadTask" -> OneTimeWorkRequestBuilder<UploadTaskWorker>()
  //   "MultiUploadTask" -> OneTimeWorkRequestBuilder<UploadTaskWorker>()
  //   "DataTask" -> OneTimeWorkRequestBuilder<DataTaskWorker>()
  //   else -> {
  //     Log.w(TAG, "Unknown taskType: ${task.taskType}")
  //     return false
  //   }
  // }
  // requestBuilder.setInputData(data)
  //   .setConstraints(constraints).addTag(TAG).addTag("taskId=${task.taskId}")
  //   .addTag("group=${task.group}")
  // if (initialDelayMillis != 0L) {
  //   requestBuilder.setInitialDelay(initialDelayMillis, TimeUnit.MILLISECONDS)
  // }
  // if (task.priority < 5 && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
  //   requestBuilder.setExpedited(policy = OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
  // }
  // val workManager = WorkManager.getInstance(context)
  // val operation = workManager.enqueue(requestBuilder.build())
  // try {
  //   withContext(Dispatchers.IO) {
  //     operation.result.get()
  //   }
  //   val prefs = PreferenceManager.getDefaultSharedPreferences(context)
  //   if (initialDelayMillis != 0L) {
  //     delay(min(100L, initialDelayMillis))
  //   }
  //   if (holdingQueue?.enqueuedTaskIds?.contains(task.taskId) != true)
  //     processStatusUpdate(task, TaskStatus.enqueued, prefs, context = context)
  // } catch (_: Throwable) {
  //   Log.w(
  //     TAG,
  //     "Unable to start background request for taskId ${task.taskId} in operation: $operation"
  //   )
  //   return false
  // }
  // // Register the enqueue with the NotificationService
  // NotificationService.registerEnqueue(
  //   EnqueueItem(
  //     context = context,
  //     task = task,
  //     notificationConfigJsonString = notificationConfigJsonString
  //   ), success = true
  // )
  // // store Task in persistent storage, as Json representation keyed by taskId
  // prefsLock.write {
  //   val prefs = PreferenceManager.getDefaultSharedPreferences(context)
  //   val tasksMap = getTaskMap(prefs)
  //   tasksMap[task.taskId] = task
  //   prefs.edit {
  //     putString(keyTasksMap, Json.encodeToString(tasksMap))
  //   }
  // }
  // return true
  // }

  private async methodEnqueueAll(call: MethodCall, result: MethodResult) {
    let args: Array<ESObject> = call.args as Array<ESObject>;
    let taskListJsonString = args[0] as string;
    let notificationConfigListJsonString = args[1] as string;

    console.error(BDPlugin.TAG, "notificationConfigListJsonString is " + notificationConfigListJsonString);

    BDPlugin.latestPluginInstance = this;

    if (!BDPlugin.sendableUIContext) {
      console.error("sendableUIContext is error");
      return
    }
      try {
        const tasksPlain = JSON.parse(taskListJsonString) as Task[];
        const tasks = tasksPlain.map((t) => Task.fromPlain(t as Task));
        const notifConfigs = JSON.parse(notificationConfigListJsonString) as Array<NotificationConfig | undefined>;
        console.error(BDPlugin.TAG, `methodEnqueueAll: parsed ${tasks.length} tasks, ${notifConfigs?.length ?? 0} configs`);
        const bgChannel = BDPlugin.methodbackgroundChannel(this);
        if (bgChannel !== undefined) {
          tasks.forEach((task) => {
            BDPlugin.bgChannelByTaskId.set(task.taskId, bgChannel);
          });
        } else {
          tasks.forEach((task) => {
            console.error(BDPlugin.TAG, `Could not find backgroundChannel for taskId ${task.taskId}`);
          });
        }
        if (notifConfigs && notifConfigs.length !== tasks.length) {
          console.error(BDPlugin.TAG, `methodEnqueueAll: tasks and configs length mismatch (${tasks.length} vs ${notifConfigs.length})`);
        }
      } catch (e) {
        console.error(BDPlugin.TAG, `methodEnqueueAll: failed to parse tasks/configs: ${e}`);
      }

    let results = await methodEnqueueAll_task(taskListJsonString, notificationConfigListJsonString);
    result.success(results);

    // const task = new taskpool.Task(
    //   methodEnqueueAll_task,
    //   taskListJsonString,
    //   notificationConfigListJsonString,
    //   BDPlugin.holdingQueue,
    //   BDPlugin.sendableUIContext
    // );
    // taskpool.execute(task)
    //   .then((results: object) => {
    //     result.success(results as Array<boolean>);
    //     console.info('execute methodEnqueueAll success');
    //   })
    //   .catch((e: BusinessError) => {
    //     console.error(`execute methodEnqueueAll error: ${e.message}`);
    //     result.success([]);
    //   });
  }
}

//
// class TaskScope {
//   private tasks: Set<taskpool.Task>; // 保存 taskpool.Task 实例
//
//   constructor() {
//     this.tasks = new Set();
//   }
//
//   // 提交一个 taskpool 任务并返回一个 Promise
//   // fn 必须是一个 @Concurrent 标注的函数引用（或已注册到 TaskPool 的 worker 函数）
//   async launch(fn: Function, ...args: ESObject[]): Promise<ESObject> {
//     // 构造 task（TaskPool API 可能略有差异，请按平台替换）
//     const t = new taskpool.Task(fn, ...args);
//     this.tasks.add(t);
//
//     try {
//       const res = await taskpool.execute(t);
//       //const res = await t.execute();
//       // 任务完成后从集合中移除引用
//       this.tasks.delete(t);
//       return res;
//     } catch (err) {
//       taskpool.cancel(t)
//       this.tasks.delete(t);
//     }
//   }
//
//   // 取消一个正在执行的任务（如果 TaskPool 支持 cancel）
//   cancelTask(task: any): void {
//     try {
//       taskpool.cancel(task);
//     } catch (e) {
//       // ignore
//     } finally {
//       this.tasks.delete(task);
//     }
//   }
//
//   // 取消 scope 内的所有任务（类似 CoroutineScope.cancel()）
//   cancelAll(): void {
//     const snapshot = Array.from(this.tasks);
//     for (let i = 0; i < snapshot.length; i++) {
//       const t = snapshot[i];
//       try {
//         taskpool.cancel(t);
//       } catch (e) {
//         // 可能任务已完成或 API 不支持跨线程取消，忽略错误
//       }
//     }
//     this.tasks.clear();
//   }
//
//   // 是否还有未完成的任务
//   isActive(): boolean {
//     return this.tasks.size > 0;
//   }
// }
