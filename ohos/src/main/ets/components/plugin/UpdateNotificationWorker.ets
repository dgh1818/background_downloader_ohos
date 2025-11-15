import { common, sendableContextManager } from '@kit.AbilityKit';
import { MessageEvents, ThreadWorkerGlobalScope, worker } from '@kit.ArkTS';
import { TaskStatus } from './Models';
import { TaskWorker } from './TaskWorker';
import { hash } from '@kit.CoreFileKit';
import { notificationManager } from '@kit.NotificationKit';
import { NotificationConfig, NotificationService, UpdateNotificationWorkerMessage } from './Notifications';
import BDPlugin from './BDPlugin';

/**
 * Worker that updates the notification for a task, given a
 * NotificationConfig and a TaskStatus.
 *
 * Used to update a task notification initiated from the Dart side, when
 * no actual TaskWorker is active for the task, e.g. when failing for the
 * last time on retry.  We need a [TaskWorker] in order to call the
 * [NotificationService] to update the associated notification.
 *
 * Note this implementation is only valid for two situations:
 * - taskStatus is null -> deletes the notification
 * - taskStatus is TaskStatus.failed -> displays error notification if needed
 */
export class UpdateNotificationWorker extends TaskWorker {
  // (applicationContext: common.UIAbilityContext, workerParams: WorkerParameters) :
  // TaskWorker(applicationContext, workerParams)
  // private applicationContext?:common.UIAbilityContext
  // private workerParams?:Map<string,ESObject>
  static readonly keyTaskStatusOrdinal = "taskStatusOrdinal"


  constructor(applicationContext: common.UIAbilityContext) {
    //constructor(applicationContext: common.UIAbilityContext,workerParams: Map<string,ESObject>) {
    super(applicationContext);

    this.applicationContext = applicationContext;

  }

  //@Concurrent
  // public updateNotification(task: Task, notificationType: NotificationType, notificationConfig?: NotificationConfig) {
  //

  //}


}

const workerPort: ThreadWorkerGlobalScope = worker.workerPort;

workerPort.onmessage = (event: MessageEvents) => {
  const message = event.data as UpdateNotificationWorkerMessage;
  if (message.command !== 'update') {
    return;
  }

  const sendableCtx = message.uiContext;
  const uiContext =
    sendableCtx !== undefined
      ? sendableContextManager.convertToUIAbilityContext(sendableCtx)
      : undefined;
  if (uiContext === undefined) {
    console.error(BDPlugin.TAG, 'UpdateNotificationWorker requires a UIAbilityContext to run');
    return;
  }

  const workerInstance = new UpdateNotificationWorker(uiContext);
  const parsedTask = JSON.parse(message.taskJson) as Record<string, Object>;
  workerInstance.task = TaskWorker.fromSerializableTask(parsedTask);
  workerInstance.notificationConfigJsonString = message.notificationConfigJson;
  workerInstance.notificationConfig = message.notificationConfigJson !== undefined
    ? (JSON.parse(message.notificationConfigJson) as NotificationConfig)
    : undefined;

  const task = workerInstance.task;
  if (task === undefined) {
    console.error(BDPlugin.TAG, 'UpdateNotificationWorker received an invalid task payload');
    return;
  }

  hash.hash(task.taskId, 'sha1').then((hashResult: string) => {
    workerInstance.notificationId = parseInt(hashResult, 16);
    if (message.taskStatusOrdinal === undefined) {
      notificationManager.cancel(workerInstance.notificationId);
      return;
    }
    const taskStatus = message.taskStatusOrdinal as TaskStatus;
    NotificationService.updateNotification(workerInstance, taskStatus);
  }).catch((error: Error) => {
    console.error(BDPlugin.TAG, 'Failed to update notification for task', error);
  });
};
