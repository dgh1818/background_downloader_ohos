import { common } from "@kit.AbilityKit";
import BDPlugin from "./BDPlugin";
import { ExceptionType, ResumeData, Task, TaskException, TaskStatus } from "./Models";
//import { TaskWorker } from "./TaskWorker";
import { preferences } from "@kit.ArkData";
import { ArkTSUtils, Queue } from "@kit.ArkTS";
import { NotificationService } from "./Notifications";

/**
 * Queue that holds [EnqueueItem] items before they are actually enqueued as a WorkManager job
 *
 * Configure [maxConcurrent], [maxConcurrentByHost] and [maxConcurrentByGroup] to limit which items
 * can be enqueued simultaneously.
 *
 * Call:
 * [add] to add an [EnqueueItem]
 * [taskFinished] for all tasks that finish, so we may start a new one
 * [cancelAllTasks] to empty the queue (sends status updates)
 * [cancelTasksWithIds] to remove specific tasks (sends status updates)
 * [allTasks] for a list of [Task] matching a group
 * [taskForId] to get the task for a specific taskId
 */
export class HoldingQueue {
  public maxConcurrent: number = 1 << 20;
  public maxConcurrentByHost: number = 1 << 20;
  public maxConcurrentByGroup: number = 1 << 20;
  public hostByTaskId: Map<string, string> = new Map<string, string>();
  public enqueuedTaskIds: string[] = [];
  private concurrent: number = 0;
  private concurrentByHost = new Map<string, number>();
  private concurrentByGroup = new Map<string, number>();
  private queue: EnqueueItem[] = [];
  // ArkTS 目前没有 Kotlin Channel 那样的“信号管道”，
  // 这里用一个 Promise 句柄来表示队列消费循环是否已经在运行。
  // 作用相当于 Android 版本里的 `processSignal` 协程或 iOS 里的 `processQueue` Task：
  // 只要已有循环在排队工作，就不再重复启动新的循环，避免并发修改状态。
  private processQueuePromise?: Promise<void>;
  private advanceTimerId?: number;
  private taskFinishedTail: Promise<void> = Promise.resolve();
  // private job?: Job
  // private scope = CoroutineScope(Dispatchers.Default)
  // private processSignal = Channel<Unit>(Channel.UNLIMITED)
  public stateMutex:ArkTSUtils.locks.AsyncLock = new ArkTSUtils.locks.AsyncLock();

  public static async taskFinished(task: Task): Promise<void> {
    const queue = BDPlugin.holdingQueue;
    if (!queue) {
      return;
    }

    try {
      await queue.taskFinished(task);
    } catch (error) {
      console.error(BDPlugin.TAG, "Failed to process finished task", error);
    }
  }

  /**
   * Add [EnqueueItem] [item] to the queue and advance the queue if possible
   */
  public async add(item: EnqueueItem) {
    await this.stateMutex.lockAsync<void>(async () => {
      this.queue.push(item);
      this.enqueuedTaskIds.push(item.task.taskId);
      this.sortQueue();
      NotificationService.registerEnqueue(
        item,
        true
      ); // for group notification count
    });
    this.advanceQueue();
  }

  private advanceQueue() {
    // Kick off or continue the single consumer loop, similar to Android's processSignal
    this.processQueue();

    // Keep a heartbeat so the queue doesn't dry up if no new tasks arrive
    this.clearAdvanceTimer();
    if (this.queue.length > 0) {
      this.advanceTimerId = globalThis.setTimeout(() => {
        this.advanceTimerId = undefined;
        this.processQueue();
        // Reschedule if there is still work waiting
        if (this.queue.length > 0) {
          this.advanceQueue();
        }
      }, 10000);
    }
  }

  /**
   * Advance the queue by signalling the queue processing coroutine
   *
   * Also restarts a timer that will advance the queue in 10 seconds, in case
   * it dries up
   */
  private advanceQueueInFuture() {
    this.processQueue();
    if (this.queue.length > 0) {
      this.advanceQueueInFuture();
    } else {
      this.clearAdvanceTimer();
    }
  }

  /**
   * Calls [advanceQueue] in 10 seconds, thus ensuring it never dries up
   *
   * If called again before the timer fires, cancels the original timer and
   * resets to 10 seconds
   */
  private clearAdvanceTimer() {
    if (this.advanceTimerId !== undefined) {
      globalThis.clearTimeout(this.advanceTimerId);
      this.advanceTimerId = undefined;
    }
  }

  /**
   * 启动（或复用）单例化的 processQueue 循环，保持与其他平台一致的命名。
   */
  private processQueue(): Promise<void> {
    if (!this.processQueuePromise) {
      this.processQueuePromise = this.runProcessQueue()
        .catch((error:Error) => {
          console.error(BDPlugin.TAG, "Error while processing holding queue", error);
        })
        .finally(() => {
          this.processQueuePromise = undefined;
          if (this.queue.length === 0) {
            this.clearAdvanceTimer();
          }
        });
    }
    return this.processQueuePromise;
  }

  private async runProcessQueue(): Promise<void> {
    while (true) {
      const item = await this.takeNextReadyItem();
      if (!item) {
        break;
      }
      try {
        await item.enqueue(0);
      } catch (error) {
        console.error(BDPlugin.TAG, "Failed to enqueue task", error);
        await this.handleTaskFinished(item.task);
      }
    }
  }

  private async takeNextReadyItem(): Promise<EnqueueItem | undefined> {
    return this.stateMutex.lockAsync<EnqueueItem | undefined>(async () => {
      if (this.concurrent >= this.maxConcurrent) {
        return undefined;
      }

      const mustWait: EnqueueItem[] = [];
      let candidate: EnqueueItem | undefined;

      while (this.queue.length > 0) {
        const next = this.queue.shift();
        if (!next) {
          break;
        }
        const host = next.task.host() ?? "";
        const group = next.task.group ?? "";
        const hostCount = this.concurrentByHost.get(host) ?? 0;
        const groupCount = this.concurrentByGroup.get(group) ?? 0;
        if (hostCount < this.maxConcurrentByHost && groupCount < this.maxConcurrentByGroup) {
          candidate = next;
          this.concurrent += 1;
          this.concurrentByHost.set(host, hostCount + 1);
          this.concurrentByGroup.set(group, groupCount + 1);
          this.hostByTaskId.set(next.task.taskId, host);
          break;
        }
        mustWait.push(next);
      }

      if (mustWait.length > 0) {
        this.queue.unshift(...mustWait);
        this.sortQueue();
      }

      return candidate;
    });
  }

  private sortQueue() {
    this.queue.sort((a, b) => a.compareTo(b));
  }

  private async handleTaskFinished(task: Task): Promise<void> {
    await this.stateMutex.lockAsync<void>(async () => {
      const host = this.hostByTaskId.get(task.taskId) ?? task.host() ?? "";
      this.hostByTaskId.delete(task.taskId);
      const enqueuedIndex = this.enqueuedTaskIds.indexOf(task.taskId);
      if (enqueuedIndex >= 0) {
        this.enqueuedTaskIds.splice(enqueuedIndex, 1);
      }
      const group = task.group ?? "";
      this.concurrent = Math.max(0, this.concurrent - 1);
      this.decrementCount(this.concurrentByHost, host);
      this.decrementCount(this.concurrentByGroup, group);
    });
    this.advanceQueue();
  }

  public taskFinished(task: Task): Promise<void> {
    const next = this.taskFinishedTail.then(() => this.handleTaskFinished(task));
    this.taskFinishedTail = next.then(
      () => undefined,
      (error: Error) => {
        console.error(BDPlugin.TAG, "Failed to process finished task", error);
      }
    );
    return next;
  }

  private decrementCount(map: Map<string, number>, key: string) {
    const current = map.get(key) ?? 0;
    if (current <= 1) {
      map.delete(key);
    } else {
      map.set(key, current - 1);
    }
  }
}

export function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/**
 * Holds data related to enqueueing a task
 *
 * Used in the context of changing the RequireWiFi setting (where tasks need to be re-enqueued)
 * and in the context of the [HoldingQueue]
 */
export class EnqueueItem {
  context: common.UIAbilityContext;
  task: Task;
  notificationConfigJsonString?: string;
  resumeData?: ResumeData;
  created: Date;

  constructor(
    context: common.UIAbilityContext,
    task: Task,
    notificationConfigJsonString?: string,
    resumeData?: ResumeData,
    created: Date = new Date()
  ) {
    this.context = context;
    this.task = task;
    this.notificationConfigJsonString = notificationConfigJsonString;
    this.resumeData = resumeData;
    this.created = created;
  }


  /**
   * Execute the re-enqueue after an appropriate delay
   * @param afterDelayMillis minimal延迟（ms）
   */
  public async enqueue(afterDelayMillis: number = 1000): Promise<void> {

    const timeSinceCreatedMillis = Date.now() - this.created.getTime();
    if (timeSinceCreatedMillis < afterDelayMillis) {
      await sleep(afterDelayMillis - timeSinceCreatedMillis);
    }

    // 假定 BDPlugin.doEnqueue 在 arkts 中也是个 async 函数并返回 boolean
    const success = await BDPlugin.doEnqueue(
      this.context,
      this.task,
      this.notificationConfigJsonString,
      this.resumeData,
      afterDelayMillis,
    );

    if (!success) {
      console.warn(BDPlugin.TAG,
        `Delayed or retried enqueue failed for taskId ${this.task.taskId}`
      );

      // 按原 Kotlin 逻辑调用 TaskWorker.processStatusUpdate
      // 这里假定 TaskWorker.processStatusUpdate 在 ArkTS 中也存在并接受类似参数

      let options: preferences.Options = { name: 'DEFAULT' };
      let defaultPref = preferences.getPreferencesSync(this.context, options);
      //(BDPlugin.uiContext!, options);

      // TaskWorker.processStatusUpdate(
      //   this.task,
      //   TaskStatus.failed, // 假定 TaskStatus 在 arkts 中有对应值
      //   defaultPref, // 占位
      //   this.context,
      //   new TaskException(ExceptionType.general, undefined, "Delayed or retried enqueue failed")
      // ); //需要改成后台

      // 如果有持有队列，通知其任务完成（占位调用）
      if (BDPlugin.holdingQueue) {
        HoldingQueue.taskFinished(this.task);

      }

      NotificationService.registerEnqueue(this, false);

    }
    await sleep(20);
  }

  /**
   * 比较函数：先按 priority，随后按 creationTime
   * 返回负数表示 this 优先级更高（排在前面）
   */
  compareTo(other: EnqueueItem): number {
    if (this.task.priority !== other.task.priority) {
      // 假设 priority 是数字，较小或较大取决于你的优先级定义
      return this.task.priority - other.task.priority;
    }
    return (this.task.creationTime ?? 0) - (other.task.creationTime ?? 0);
  }
}
