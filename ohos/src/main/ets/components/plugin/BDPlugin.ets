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
import { ArkTSUtils, ArrayList, collections, List, MessageEvents, taskpool, uri, url, worker } from "@kit.ArkTS";
import { fileUri } from '@kit.CoreFileKit';
import dataPreferences from '@ohos.data.preferences'
import { photoAccessHelper } from "@kit.MediaLibraryKit";
import { dataSharePredicates, preferences } from "@kit.ArkData";
import { workScheduler } from "@kit.BackgroundTasksKit";

import { EnqueueItem, HoldingQueue } from './HoldingQueue'
import { NotificationConfig } from './Notifications'
import { ISendable, ResumeData, Task, RequireWiFi, TaskStatus } from "./Models";
import { getTaskMap, TaskWorker, TaskWorkerKey } from "./TaskWorker";

@Sendable
export class SendableObject {
  //constructor(sendableContext: sendableContextManager.SendableContext, contextName: string) {
  constructor(command: string, sendableContext: sendableContextManager.SendableContext, immediate?: boolean,
    requireWifi?: boolean, requireCharging?: boolean, triggerUpdateDelay?: number, triggerMaxDelay?: number) {

    this.command = command;
    this.sendableContext = sendableContext;
    this.immediate = immediate;
    this.requireWifi = requireWifi;
    this.requireCharging = requireCharging;
    this.triggerUpdateDelay = triggerUpdateDelay;
    this.triggerMaxDelay = triggerMaxDelay;

  }

  //args: Map<string, ESObject>;
  command: string = "";
  sendableContext: sendableContextManager.SendableContext;
  immediate?: boolean = false;
  requireWifi?: boolean = false;
  requireCharging?: boolean = false;
  triggerUpdateDelay?: number = 5000;
  triggerMaxDelay?: number = 50000;
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
  // global setting
  public static localResumeData = new Map<string, ResumeData>()
  // by taskId, for pause notifications
  public static cancelUpdateSentForTaskId = new Map<string, number>()
  // <taskId, timeMillis>
  public static pausedTaskIds = new Set<String>()
  // <taskId>, acts as flag
  public static canceledTaskIds = new Set<String>()
  // <taskId>, acts as flag
  //public static parallelDownloadTaskWorkers = new Map<string, ParallelDownloadTaskWorker>() //Was a HashMap
  public static tasksToReEnqueue = new Set<Task>()
  // for when WiFi requirement changes
  public static taskIdsRequiringWiFi = new Set<string>()
  // ensures correctness when enqueueing task
  public static notificationConfigJsonStrings = new Map<string, string>()
  // by taskId
  public static forceFailPostOnBackgroundChannel = false
  public static prefsLock = new ArkTSUtils.locks.AsyncLock()
  public static remainingBytesToDownload = new Map<string, number>()
  // <taskId, size>
  public static haveLoggedProxyMessage = false
  public static holdingQueue?: HoldingQueue

  static async doEnqueue(
    context: common.UIAbilityContext,
    task: Task,
    notificationConfigJsonString?: string,
    resumeData?: ResumeData,
    initialDelayMillis: number = 0,
    plugin?: BDPlugin
  ): Promise<boolean> {

    console.log(BDPlugin.TAG + 'Enqueuing task with id' + task.taskId);
    let bgChannel = BDPlugin.methodbackgroundChannel(plugin)
    if (bgChannel != undefined) {
      BDPlugin.bgChannelByTaskId.set(task.taskId, bgChannel);
    } else {
      console.warn(BDPlugin.TAG, "Could not find backgroundChannel for taskId" + task.taskId);
    }
    BDPlugin.holdingQueue?.hostByTaskId?.set(
      task.taskId,
      task.host()
    ) // store host if we have a HoldingQueue
    BDPlugin.canceledTaskIds.delete(task.taskId);
    BDPlugin.cancelUpdateSentForTaskId.delete(task.taskId) // reset flag
    let dataBuilder = new collections.Map<string, string | number>();


    if (notificationConfigJsonString != undefined) {
      BDPlugin.notificationConfigJsonStrings.set(task.taskId, notificationConfigJsonString);
    }
    let data = ArkTSUtils.ASON.stringify(dataBuilder) //To Do

    let taskRequiresWifi = BDPlugin.taskRequiresWifi(task)
    if (taskRequiresWifi) {
      BDPlugin.taskIdsRequiringWiFi.add(task.taskId)
    }

    // val constraints = Constraints.Builder().setRequiredNetworkType(
    // if (taskRequiresWifi) NetworkType.UNMETERED else NetworkType.CONNECTED
    // ).build()
    let network_condition: workScheduler.NetworkType;
    if (taskRequiresWifi) {
      network_condition = workScheduler.NetworkType.NETWORK_TYPE_WIFI
    } else {
      network_condition = workScheduler.NetworkType.NETWORK_TYPE_ANY
    }

    let WorkerName: string;

    switch (task.taskType) {
      case "ParallelDownloadTask":
        WorkerName = 'ParallelDownloadTaskWorker'
        break;
      case "DownloadTask":
        WorkerName = 'DownloadTaskWorker'
        break;
      case "UriDownloadTask":
        WorkerName = 'DownloadTaskWorker'
        break;
      case "UploadTask":
        WorkerName = 'UploadTaskWorker'
        break;
      case "UriUploadTask":
        WorkerName = 'UploadTaskWorker'
        break;
      case "MultiUploadTask":
        WorkerName = 'UploadTaskWorkerr'
        break;
      case "DataTask":
        WorkerName = 'DataTaskWorker'
        break;
      default:
        console.error(BDPlugin.TAG, 'Unknown taskType' + task.taskType);
        WorkerName = '';
        return false;
    }

    let requestBuilder: workScheduler.WorkInfo = {
      workId: parseInt(task.taskId),
      bundleName: 'background_downloader',
      abilityName: WorkerName,
      networkType: network_condition,
      parameters: {
        [TaskWorkerKey.keyTask]:ArkTSUtils.ASON.stringify(task),
        [TaskWorkerKey.keyNotificationConfig]:notificationConfigJsonString??'',
        [TaskWorkerKey.keyResumeDataData]:resumeData?resumeData.data:'',
        [TaskWorkerKey.keyStartByte]:resumeData?resumeData.requiredStartByte:-1,
        [TaskWorkerKey.keyETag]:resumeData?resumeData.eTag??'':'',
      }
    }

    // if (initialDelayMillis != 0) {
    //   requestBuilder.setInitialDelay(initialDelayMillis, TimeUnit.MILLISECONDS)
    // }
    // if (task.priority < 5 && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
    //   requestBuilder.setExpedited(policy = OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
    // }

    workScheduler.startWork(requestBuilder);

    try {
      // withContext(Dispatchers.IO) {
      //   operation.result.get()
      // }

      let options: preferences.Options = { name: 'DEFAULT' };
      let prefs = preferences.getPreferencesSync(BDPlugin.uiContext, options)
      // if (initialDelayMillis != 0) {
      //   delay(min(100L, initialDelayMillis))
      // }

      if (BDPlugin.holdingQueue?.enqueuedTaskIds?.includes(task.taskId) != true) {
        TaskWorker.processStatusUpdate(task, TaskStatus.enqueued, prefs, undefined,undefined,undefined,undefined,undefined,undefined,BDPlugin.uiContext)

      }
    } catch (e) {
      console.error(BDPlugin.TAG, 'Unable to start background request for taskId'+ task.taskId + 'in operation:');
      return false
    }

    BDPlugin.prefsLock.lockAsync(() => {
      let options: preferences.Options = { name: 'DEFAULT' };
      let prefs = preferences.getPreferencesSync(BDPlugin.uiContext, options)

      let tasksMap = getTaskMap(prefs)
      tasksMap.set(task.taskId,task);
      prefs.putSync(BDPlugin.keyTasksMap,JSON.stringify(tasksMap));
      prefs.flushSync();

    });

    return true;
  }

  public static uiContext?: common.UIAbilityContext;
  private sendableCtx?: sendableContextManager.SendableContext = undefined;
  private prefs?: dataPreferences.Preferences;
  private channel?: MethodChannel
  private backgroundChannel?: MethodChannel
  private applicationContext?: common.ApplicationContext;
  // scope?: CoroutineScope
  private binaryMessenger?: BinaryMessenger
  private activity?: Ability;

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    //context = ctx //move to onAttachedToAbility

    this.applicationContext = binding.getApplicationContext().getApplicationContext();
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
    let options: preferences.Options = { name: 'DEFAULT' };
    let prefs = preferences.getPreferencesSync(BDPlugin.uiContext, options);
    let allWorkInfos: workScheduler.WorkInfo[];

    workScheduler.obtainAllWorks().then((allWorkInfos: workScheduler.WorkInfo[]) => {
      if (allWorkInfos.length == 0) {
        BDPlugin.prefsLock.lockAsync(() => {
          prefs.deleteSync(BDPlugin.keyTasksMap);
          prefs.flushSync();
        })
      }
    });

    BDPlugin.requireWifi = prefs.getSync('keyRequireWiFi', 0) as RequireWiFi;
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
    //handleIntent(binding.activity.intent)
    BDPlugin.uiContext = binding.getAbility().context;
  }

  onDetachedFromAbility() {

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
    return plugin?.backgroundChannel;
  }

  static taskRequiresWifi(task: Task): Boolean {
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
    let notificationConfigListJsonString = args[1] as string
    try {
      let tasks = JSON.parse(taskListJsonString) as List<Task>;
      let notificationConfigs = JSON.parse(notificationConfigListJsonString) as List<NotificationConfig>;

      let results = new List<Boolean>()

      for (let index = 0; index < tasks.length; index++) {
        let task = tasks.get(index);
        const notificationConfig = notificationConfigs.length > index ? notificationConfigs.get(index) : undefined;
        const notificationConfigJsonString = notificationConfig ? JSON.stringify(notificationConfig) : undefined;
        let success = false;

        try {
          try {
            //new URL(task.url); // 检查 URL 是否有效
            decodeURIComponent(task.url); // 解码
          } catch (e) {
            console.log(`Malformed or undecodable URL for taskId ${task.taskId}`);
            results.add(false);
            continue;
          }

          if (BDPlugin.holdingQueue == undefined) {
            // 直接入队
            success = BDPlugin.doEnqueue(BDPlugin.uiContext!, task, notificationConfigJsonString, undefined, BDPlugin);
          } else {
            console.log(`Enqueueing task with id ${task.taskId} to the HoldingQueue`);
            BDPlugin.holdingQueue.add(new EnqueueItem(
              BDPlugin.uiContext,
              task,
              notificationConfigJsonString:
            notificationConfigJsonString,
            undefined,
            plugin:
            plugin
            )
            )
            ;
            processStatusUpdate(task, TaskStatus.enqueued, pref, BDPlugin.uiContext);
            success = true;
          }
          /*
                    try {
                                  try {
                                      URL(task.url)
                                      URLDecoder.decode(task.url, "UTF-8")
                                  } catch (_: MalformedURLException) {
                                      Log.i(TAG, "MalformedURLException for taskId ${task.taskId}")
                                      results.add(false)
                                      continue
                                  } catch (_: IllegalArgumentException) {
                                      Log.i(TAG, "Could not url-decode url for taskId ${task.taskId}")
                                      results.add(false)
                                      continue
                                  }
                                  // Enqueue or add to HoldingQueue
                                  success = if (holdingQueue == null) {
                                      doEnqueue(
                                          applicationContext,
                                          task,
                                          notificationConfigJsonString,
                                          resumeData = null,
                                          plugin = plugin
                                      )
                                  }
                    else
                    {
                      Log.i(TAG, "Enqueueing task with id ${task.taskId} to the HoldingQueue")
                      holdingQueue?.add(
                        EnqueueItem(
                          context = applicationContext,
                          task = task,
                          notificationConfigJsonString = notificationConfigJsonString,
                          resumeData = null,
                          plugin = plugin
                        )
                      )
                      processStatusUpdate(
                        task,
                        TaskStatus.enqueued,
                        PreferenceManager.getDefaultSharedPreferences(applicationContext),
                        context = applicationContext
                      )
                      true
                    }
                  } catch (e: Exception) {
                    Log.e(TAG, "Error processing task ${task.taskId}: ${e.message}")
                  }
                  results.add(success)
                }
                result.success(results)
              } catch (e: Exception) {
                Log.e(TAG, "Error decoding JSON: ${e.message}")
                result.success(emptyList<Boolean>()) // Return an empty list on error
              }
            }
            */

          /**
           * Starts a list of tasks, passed as a JSON string representing a list of [Task] objects.
           *
           * Returns a list of booleans indicating the success of each individual enqueue operation.
           */
          private
          methodEnqueueAll(call:
          MethodCall, result:
          MethodResult
          )
          {
            if (this.scope == undefined) {
              result.success(new Array<boolean>())
              return;
            }

            this.scope.execute()
            //         let plugin = this;
            //         scope!!.launch(Dispatchers.IO) {
            //             val args = call.arguments as List<*>
            //             val taskListJsonString = args[0] as String
            //             val notificationConfigListJsonString = args[1] as String
            //             try {
            //                 val tasks = Json.decodeFromString<List<Task>>(taskListJsonString)
            //                 val notificationConfigs =
            //                     Json.decodeFromString<List<NotificationConfig?>>(
            //                         notificationConfigListJsonString
            //                     )
            //                 val results = mutableListOf<Boolean>()
            //                 for ((index, task) in tasks.withIndex()) {
            //                     val notificationConfig = notificationConfigs.getOrNull(index)
            //                     val notificationConfigJsonString =
            //                         notificationConfig?.let { Json.encodeToString(it) }
            //   var success = false
            //   try {
            //   try {
            //   URL(task.url)
            //   URLDecoder.decode(task.url, "UTF-8")
            // } catch (_: MalformedURLException) {
            //   Log.i(TAG, "MalformedURLException for taskId ${task.taskId}")
            //   results.add(false)
            //   continue
            // } catch (_: IllegalArgumentException) {
            //   Log.i(TAG, "Could not url-decode url for taskId ${task.taskId}")
            //   results.add(false)
            //   continue
            // }
            // // Enqueue or add to HoldingQueue
            // success = if (holdingQueue == null) {
            //   doEnqueue(
            //     applicationContext,
            //     task,
            //     notificationConfigJsonString,
            //     resumeData = null,
            //     plugin = plugin
            //   )
            // } else {
            //   Log.i(TAG, "Enqueueing task with id ${task.taskId} to the HoldingQueue")
            //   holdingQueue?.add(
            //     EnqueueItem(
            //       context = applicationContext,
            //       task = task,
            //       notificationConfigJsonString = notificationConfigJsonString,
            //       resumeData = null,
            //       plugin = plugin
            //     )
            //   )
            //   processStatusUpdate(
            //     task,
            //     TaskStatus.enqueued,
            //     PreferenceManager.getDefaultSharedPreferences(applicationContext),
            //     context = applicationContext
            //   )
            //   true
            // }
            // } catch (e: Exception) {
            //   Log.e(TAG, "Error processing task ${task.taskId}: ${e.message}")
            // }
            // results.add(success)
            // }
            // result.success(results)
            // } catch (e: Exception) {
            //   Log.e(TAG, "Error decoding JSON: ${e.message}")
            //   result.success(emptyList<Boolean>()) // Return an empty list on error
            // }
            // }
          }
        }
      }
    }
  }

        class TaskScope {
          private tasks: Set<taskpool.Task>; // 保存 taskpool.Task 实例

          constructor() {
            this.tasks = new Set();
          }

          // 提交一个 taskpool 任务并返回一个 Promise
          // fn 必须是一个 @Concurrent 标注的函数引用（或已注册到 TaskPool 的 worker 函数）
          async launch(fn: Function, ...args: ESObject[]): Promise<ESObject> {
            // 构造 task（TaskPool API 可能略有差异，请按平台替换）
            const t = new taskpool.Task(fn, ...args);
            this.tasks.add(t);

            try {
              const res = await taskpool.execute(t);
              //const res = await t.execute();
              // 任务完成后从集合中移除引用
              this.tasks.delete(t);
              return res;
            } catch (err) {
              taskpool.cancel(t)
              this.tasks.delete(t);
            }
          }

          // 取消一个正在执行的任务（如果 TaskPool 支持 cancel）
          cancelTask(task: any): void {
            try {
              taskpool.cancel(task);
            } catch (e) {
              // ignore
            } finally {
              this.tasks.delete(task);
            }
          }

          // 取消 scope 内的所有任务（类似 CoroutineScope.cancel()）
          cancelAll(): void {
            const snapshot = Array.from(this.tasks);
            for (let i = 0; i < snapshot.length; i++) {
              const t = snapshot[i];
              try {
                taskpool.cancel(t);
              } catch (e) {
                // 可能任务已完成或 API 不支持跨线程取消，忽略错误
              }
            }
            this.tasks.clear();
          }

          // 是否还有未完成的任务
          isActive(): boolean {
            return this.tasks.size > 0;
          }
        }
