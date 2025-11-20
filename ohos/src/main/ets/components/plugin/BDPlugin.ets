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
import { ArkTSUtils, ArrayList, collections,
  ErrorEvent,
  List, MessageEvents, taskpool, uri, url, worker } from "@kit.ArkTS";
import { fileUri } from '@kit.CoreFileKit';
import dataPreferences from '@ohos.data.preferences'
import { photoAccessHelper } from "@kit.MediaLibraryKit";
import { dataSharePredicates, preferences } from "@kit.ArkData";
import { workScheduler } from "@kit.BackgroundTasksKit";

import { EnqueueItem, HoldingQueue } from './HoldingQueue'
import { NotificationConfig, NotificationService } from './Notifications'
import { ResumeData, Task, RequireWiFi, TaskStatus } from "./Models";
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

  public haveLoggedProxyMessage:boolean = false;
  public remainingBytesToDownload:collections.Map<string, number> = new collections.Map<string, number>();
  public pausedTaskIds:collections.Set<string> = new collections.Set<string>();
  public tasksToReEnqueue:collections.Set<Task> = new collections.Set<Task>();
  public localResumeData:collections.Map<string, ResumeData> = new collections.Map<string, ResumeData>()
  public notificationConfigJsonStrings:collections.Map<string, string> = new collections.Map<string, string>();
  public canceledTaskIds:collections.Set<string> = new collections.Set<string>()
  public cancelUpdateSentForTaskId:collections.Map<string, number> = new collections.Map<string, number>();

  public lock: ArkTSUtils.locks.AsyncLock = new ArkTSUtils.locks.AsyncLock();

  public async withLock(action: () => void | Promise<void>): Promise<void> {
    await this.lock.lockAsync(action);
  }

  public command: string = "";
  // public requireWifi?: boolean = false;
  // public triggerUpdateDelay?: number = 5000;
  // public triggerMaxDelay?: number = 50000;
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
  public static requireWifi = RequireWiFi.asSetByTask
  public static workerShareableData:WorkerShareableData = new WorkerShareableData();

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
    console.error(BDPlugin.TAG, `before if (notificationConfigJsonString !== undefined) {`);
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

    let workerName: string;
    console.error("before switch (task.taskType)"+task.taskType);
    switch (task.taskType) {
      case "ParallelDownloadTask":
        workerName = "ParallelDownloadTaskWorker";
        break;
      case "DownloadTask":
      case "UriDownloadTask":
        workerName = "DownloadTaskWorker";
        break;
      case "UploadTask":
      case "UriUploadTask":
        workerName = "UploadTaskWorker";
        break;
      case "MultiUploadTask":
        workerName = "UploadTaskWorker";
        break;
      case "DataTask":
        workerName = "DataTaskWorker";
        break;
      default:
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


    const downloadTaskWorker: worker.ThreadWorker = new worker.ThreadWorker('../../../../../background_downloader/src/main/ets/components/Plugin/DownloadTaskWorker.ets');

    downloadTaskWorker.onerror = (err: ErrorEvent) => {
      console.info("Worker出错了：" + err.message);
    }


      if(context == undefined) {
        console.error("BDPlugin.sendableUIContext is false")
      return false;
    }
    //let requireWifi = BDPlugin.requireWifi.valueOf() == 1 ? true:false;
    let requireWifi = false;

    let taskWorkerData = new collections.Map<string,number|string|boolean|undefined|ResumeData>();

    taskWorkerData.set(TaskWorkerKey.keyTask, TaskWorker.taskToJsonString(task));
    taskWorkerData.set(TaskWorkerKey.keyNotificationConfig,notificationConfigJsonString);
    taskWorkerData.set(TaskWorkerKey.keyResumeDataData,resumeData?.data);
    taskWorkerData.set(TaskWorkerKey.keyStartByte,resumeData?.requiredStartByte);
    taskWorkerData.set(TaskWorkerKey.keyETag,resumeData?.eTag);

    //let sendableObject:SendableObject = new SendableObject("startWork",sendableContext,taskWorkerData)

    downloadTaskWorker.postMessageWithSharedSendable(
      { command:"startWork",
        sendableContext:BDPlugin.sendableUIContext,
        taskWorkerData: taskWorkerData,
        workerShareableData:BDPlugin.workerShareableData,
        })

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
      const serializedTasks: Record<string, Object> = {};
      const iterator = tasksMap.entries();
      let entry = iterator.next();
      while (!entry.done) {
        const pair = entry.value;
        const storedTaskId = pair[0];
        const storedTask = pair[1];
        serializedTasks[storedTaskId] = storedTask;
        entry = iterator.next();
      }
      prefs.putSync(BDPlugin.keyTasksMap, JSON.stringify(serializedTasks));
      prefs.flushSync();
    });

    return true;
  }

  public static uiContext?: common.UIAbilityContext;
  public static sendableUIContext? : sendableContextManager.SendableContext;
  private prefs?: dataPreferences.Preferences;
  private channel?: MethodChannel
  private backgroundChannel?: MethodChannel
  //private applicationContext?: common.ApplicationContext;
  // scope?: CoroutineScope
  private binaryMessenger?: BinaryMessenger
  private activity?: Ability;

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    console.error("attach to engine");
    //context = ctx //move to onAttachedToAbility


    this.binaryMessenger = binding.getBinaryMessenger()
    this.backgroundChannel =
      new MethodChannel(binding.getBinaryMessenger(), "com.bbflight.background_downloader.background");
    if (BDPlugin.firstBackgroundChannel == undefined) {
      BDPlugin.firstBackgroundChannel = this.backgroundChannel;
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
      Array.from(BDPlugin.bgChannelByTaskId).filter(entry => entry[1] !== this.backgroundChannel)
    );

    if (BDPlugin.firstBackgroundChannel == this.backgroundChannel) {
      BDPlugin.firstBackgroundChannel = undefined;
    }

    this.backgroundChannel = undefined;
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
    BDPlugin.requireWifi = prefs.getSync('keyRequireWiFi', 0) as RequireWiFi;
    console.error("attach to engine successfully");

  }

  onDetachedFromAbility() {

  }

  private methodConfigForegroundFileSize(call: MethodCall, result: MethodResult) {
     let fileSize = call.args as number;
     this.updateSharedPreferences(BDPlugin.keyConfigForegroundFileSize,fileSize);
     if(fileSize==0) {
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
  if(value!=undefined) {
    prefs.putSync(key,value)
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

  private scope?: taskpool.SequenceRunner;

  static methodbackgroundChannel(
    plugin: BDPlugin | undefined = undefined,
    taskId: string = "bgd_non_existent_id"
  ): MethodChannel | undefined {
    return plugin?.backgroundChannel
      ?? BDPlugin.bgChannelByTaskId.get(taskId)
      ?? BDPlugin.firstBackgroundChannel;
  }

  static taskRequiresWifi(task: Task): boolean {
    return (BDPlugin.requireWifi == RequireWiFi.forAllTasks ||
      (BDPlugin.requireWifi == RequireWiFi.asSetByTask && task.requiresWiFi))
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


  private methodEnqueueAll(call: MethodCall, result: MethodResult) {
    let args: Array<ESObject> = call.args as Array<ESObject>;
    let taskListJsonString = args[0] as string;
    let notificationConfigListJsonString = args[1] as string;

    BDPlugin.latestPluginInstance = this;

    if(!BDPlugin.sendableUIContext) {
      console.error("sendableUIContext is error");
      return
    }
    const rawTasks = JSON.parse(taskListJsonString) as Map<string,Task>;
    rawTasks.forEach(async (value, key) => {
      const task = value;
      const bgChannel = BDPlugin.methodbackgroundChannel(this);
      if (bgChannel !== undefined) {
        BDPlugin.bgChannelByTaskId.set(task.taskId, bgChannel);
      } else {
        console.error(BDPlugin.TAG, `Could not find backgroundChannel for taskId ${task.taskId}`);
      }
    })

    methodEnqueueAll_task(taskListJsonString,notificationConfigListJsonString);

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
