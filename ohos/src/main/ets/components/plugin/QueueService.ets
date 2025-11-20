import { ThreadWorkerGlobalScope } from '@kit.ArkTS'
import { Task } from './Models'
import { systemDateTime } from '@kit.BasicServicesKit'
import { createDeferred, Deferred } from './Callbacks';
import { MethodResult } from '@ohos/flutter_ohos';
import { TaskWorker } from './TaskWorker';
import BDPlugin from './BDPlugin';

const TAG = 'QueueService';

interface PendingBackgroundPost {
  post: BackgroundPost;
  completer: Deferred<void>;
}

interface PendingTaskIdCleanup {
  taskId: string;
  completer: Deferred<void>;
}


function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => globalThis.setTimeout(resolve, ms));
}

function booleanResultHandler(completer: Deferred<boolean>): MethodResult {
  return {
    success: (result?: Object) => {
      completer.resolve(result === true);
    },
    error: () => {
      completer.resolve(false);
    },
    notImplemented: () => {
      completer.resolve(false);
    },
  };
}

export class QueueService {

  static scope?:ThreadWorkerGlobalScope

  private static lastTaskIdAdditionTime: number = 0;
  private static readonly minTaskIdDeletionDelay: number = 2000; // ms

  private static taskIdDeletionQueue: PendingTaskIdCleanup[] = [];
  private static taskIdDeletionProcessing?: Promise<void>;

  private static backgroundPostQueue: PendingBackgroundPost[] = [];
  private static backgroundPostProcessing?: Promise<void>;

  /**
   * Post this [BackgroundPost] on the background channel
   */


  public static async postOnBackgroundChannel(bgPost: BackgroundPost) {
    const pending: PendingBackgroundPost = {
      post: bgPost,
      completer: createDeferred<void>(),
    };
    QueueService.backgroundPostQueue.push(pending);
    QueueService.ensureBackgroundPostProcessing();
    return pending.completer.promise;
  }

  /**
   * Remove this [taskId] from the BDPlugin maps after a brief delay.
   */
  public static cleanupTaskId(taskId: string): Promise<void> {
    QueueService.lastTaskIdAdditionTime = systemDateTime.getTime(false);
    const pending: PendingTaskIdCleanup = {
      taskId,
      completer: createDeferred<void>(),
    };
    QueueService.taskIdDeletionQueue.push(pending);
    QueueService.ensureTaskIdDeletionProcessing();
    return pending.completer.promise;
  }

  private static ensureBackgroundPostProcessing(): Promise<void> {
    if (!QueueService.backgroundPostProcessing) {
      QueueService.backgroundPostProcessing = QueueService.runLoop(
        () => QueueService.runBackgroundPostQueue()
      )
        .catch((error: Error) => {
          console.error(TAG, 'Failed to process background post queue', error);
        })
        .finally(() => {
          QueueService.backgroundPostProcessing = undefined;
          if (QueueService.backgroundPostQueue.length > 0) {
            QueueService.ensureBackgroundPostProcessing();
          }
        });
    }
    return QueueService.backgroundPostProcessing;
  }

  private static ensureTaskIdDeletionProcessing(): Promise<void> {
    if (!QueueService.taskIdDeletionProcessing) {
      QueueService.taskIdDeletionProcessing = QueueService.runLoop(
        () => QueueService.runTaskIdDeletionQueue()
      )
        .catch((error: Error) => {
          console.error(TAG, 'Failed to cleanup task id queue', error);
        })
        .finally(() => {
          QueueService.taskIdDeletionProcessing = undefined;
          if (QueueService.taskIdDeletionQueue.length > 0) {
            QueueService.ensureTaskIdDeletionProcessing();
          }
        });
    }
    return QueueService.taskIdDeletionProcessing;
  }

  private static runLoop(factory: () => Promise<void>): Promise<void> {
    return Promise.resolve().then(factory);
  }

  private static async runBackgroundPostQueue(): Promise<void> {
    while (true) {
      const pending = QueueService.backgroundPostQueue.shift();
      if (!pending) {
        break;
      }
      try {
        await QueueService.dispatchBackgroundPost(pending.post);
      } catch (error) {
        console.error(TAG, 'Error dispatching background post', error);
      } finally {
        pending.completer.resolve(undefined);
      }
    }
  }

  private static async runTaskIdDeletionQueue(): Promise<void> {
    while (true) {
      const pending = QueueService.taskIdDeletionQueue.shift();
      if (!pending) {
        break;
      }
      try {
        const now = systemDateTime.getTime(false);
        const elapsed = now - QueueService.lastTaskIdAdditionTime;
        if (elapsed < QueueService.minTaskIdDeletionDelay) {
          await sleep(QueueService.minTaskIdDeletionDelay - elapsed);
        }
        BDPlugin.flutterEngineByTaskId.delete(pending.taskId);
        BDPlugin.bgChannelByTaskId.delete(pending.taskId);
        BDPlugin.localResumeData.delete(pending.taskId);
        BDPlugin.notificationConfigJsonStrings.delete(pending.taskId);
      } catch (error) {
        console.error(TAG, 'Error cleaning up task id', error);
      } finally {
        pending.completer.resolve(undefined);
      }
    }
  }

  private static async dispatchBackgroundPost(bgPost: BackgroundPost): Promise<void> {
    const channel = BDPlugin.bgChannelByTaskId.get(bgPost.task.taskId)
      ?? BDPlugin.methodbackgroundChannel(undefined, bgPost.task.taskId)
      ?? BDPlugin.firstBackgroundChannel;
    if (!channel) {
      console.info(TaskWorker.TAG, `Could not post ${bgPost.method} to background channel`);
      if (bgPost.onFail) {
        await bgPost.onFail();
      }
      return;
    }

    const argList: Object[] = [TaskWorker.taskToJsonString(bgPost.task)];
    if (Array.isArray(bgPost.arg)) {
      argList.push(...bgPost.arg as Object[]);
    } else {
      argList.push(bgPost.arg);
    }

    const completer = createDeferred<boolean>();
    try {
      channel.invokeMethod(bgPost.method, argList, booleanResultHandler(completer));
    } catch (error) {
      console.warn(
        TaskWorker.TAG,
        `Exception trying to post ${bgPost.method} to background channel: ${error.message}`
      );
      completer.resolve(false);
    }

    const success = await completer.promise;
    if (bgPost.onFail && (BDPlugin.forceFailPostOnBackgroundChannel || !success)) {
      await bgPost.onFail();
    }
  }
}



/**
 * BackgroundPost to be sent via backgroundChannel to Flutter, used in [QueueService]
 */
export class BackgroundPost {
  readonly task: Task;
  readonly method: string;
  readonly arg: (string | number | Map<string, string> |boolean| undefined)[];
  readonly onFail?: () => Promise<void>;

  constructor(task: Task, method: string, arg: (string | number | Map<string, string> | boolean |undefined)[], onFail?: () => Promise<void>) {
    this.task = task;
    this.method = method;
    this.arg = arg;
    this.onFail = onFail;
  }
}
