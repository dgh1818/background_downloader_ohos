import { common, sendableContextManager } from '@kit.AbilityKit';
import { collections, MessageEvents, ThreadWorkerGlobalScope, worker } from '@kit.ArkTS';
import { Task, TaskStatus } from './Models';
import { TaskWorker } from './TaskWorker';
import { notificationManager } from '@kit.NotificationKit';
import { NotificationConfig, NotificationType, TaskNotification, UpdateNotificationWorkerMessage } from './Notifications';
import BDPlugin from './BDPlugin';

/**
 * Worker that updates the notification for a task, given a
 * NotificationConfig and a TaskStatus.
 *
 * Used to update a task notification initiated from the Dart side, when
 * no actual TaskWorker is active for the task, e.g. when failing for the
 * last time on retry. We need a [TaskWorker] in order to call the
 * NotificationService to update the associated notification.
 *
 * Note this implementation is only valid for two situations:
 * - taskStatus is null -> deletes the notification
 * - taskStatus is TaskStatus.failed -> displays error notification if needed
 */
class UpdateNotificationWorker extends TaskWorker {
  static readonly keyTaskStatusOrdinal = "taskStatusOrdinal";

  static notificationTypeForTaskStatus(taskStatus: TaskStatus): NotificationType {
    switch (taskStatus) {
      case TaskStatus.enqueued:
      case TaskStatus.running:
        return NotificationType.running;
      case TaskStatus.complete:
        return NotificationType.complete;
      case TaskStatus.failed:
      case TaskStatus.notFound:
      case TaskStatus.waitingToRetry:
        return NotificationType.error;
      case TaskStatus.paused:
        return NotificationType.paused;
      case TaskStatus.canceled:
        return NotificationType.canceled;
      default:
        return NotificationType.running;
    }
  }

  static notificationTemplateForType(
    config: NotificationConfig,
    notificationType: NotificationType
  ): TaskNotification | undefined {
    switch (notificationType) {
      case NotificationType.running:
        return config.running;
      case NotificationType.complete:
        return config.complete;
      case NotificationType.error:
        return config.error;
      case NotificationType.paused:
        return config.paused;
      case NotificationType.canceled:
        return config.canceled;
      default:
        return undefined;
    }
  }

  static notificationIdForTask(taskId?: string): number {
    if (!taskId) {
      return 0;
    }
    let hashVal = 0;
    for (let i = 0; i < taskId.length; i++) {
      hashVal = ((hashVal << 5) - hashVal + taskId.charCodeAt(i)) | 0;
    }
    return Math.abs(hashVal);
  }

  static async cancelNotification(taskId?: string) {
    if (!taskId) {
      return;
    }
    const id = UpdateNotificationWorker.notificationIdForTask(taskId);
    try {
      notificationManager.cancel(id);
    } catch (_) {
    }
  }

  static async updateNotificationLocal(taskWorker: TaskWorker, taskStatus: TaskStatus): Promise<void> {
    const notificationConfig = taskWorker.notificationConfig;
    if (notificationConfig === undefined) {
      await UpdateNotificationWorker.cancelNotification(taskWorker.task?.taskId);
      return;
    }
    const notificationType = UpdateNotificationWorker.notificationTypeForTaskStatus(taskStatus);
    const template = UpdateNotificationWorker.notificationTemplateForType(notificationConfig, notificationType);
    if (template === undefined) {
      await UpdateNotificationWorker.cancelNotification(taskWorker.task?.taskId);
      return;
    }

    const title = template.title ?? "";
    const body = template.body ?? "";
    const fileName = taskWorker.task?.filename ?? "";
    const progress = taskWorker.notificationProgress;
    const id = UpdateNotificationWorker.notificationIdForTask(taskWorker.task?.taskId);

    const progressPct = progress >= 0 && progress <= 1 ? Math.round(progress * 100) : -1;
    console.error(BDPlugin.TAG, `UpdateNotificationWorker: progressPct=${progressPct}`);
    const request: notificationManager.NotificationRequest = {
      id: id,
      groupName: "immich",
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: {
          title: `${title}`,
          text: `${fileName}`,
          additionalText: progressPct >= 0 ? `${progressPct}%` : `${body}`
        }
      },
      template: {
        name: "downloadTemplate",
        data: {
          title: `${title}`,
          fileName: `${fileName}`,
          progressValue: progressPct >= 0 ? progressPct : 0
        }
      }
    };
    try {
      notificationManager.publish(request);
    } catch (e) {
      console.error('UpdateNotificationWorker', `Failed to publish notification for task ${taskWorker.task?.taskId}: ${e}`);
    }
  }

  constructor(applicationContext: common.UIAbilityContext, workerParams?: collections.Map<string, string | number>) {
    super(applicationContext, workerParams);
  }
}

const workerPort: ThreadWorkerGlobalScope = worker.workerPort;
workerPort.onmessage = async (event: MessageEvents) => {
  const message = event.data as UpdateNotificationWorkerMessage;
  console.error(BDPlugin.TAG, `UpdateNotificationWorker: received message with command=${message.command}`);
  if (message.command !== 'update') {
    return;
  }
  const messageId = message.messageId;
  let ackSent = false;
  const sendAck = () => {
    if (ackSent || messageId === undefined) {
      return;
    }
    ackSent = true;
    workerPort.postMessage({ messageId });
  };

  const sendableCtx = message.uiContext;
  const uiContext =
    sendableCtx !== undefined
      ? sendableContextManager.convertToUIAbilityContext(sendableCtx)
      : undefined;
  if (uiContext === undefined) {
    console.error(BDPlugin.TAG, 'UpdateNotificationWorker requires a UIAbilityContext to run');
    sendAck();
    return;
  }

  const workerInstance = new UpdateNotificationWorker(uiContext);
  const parsedTask = JSON.parse(message.taskJson) as Task;
  workerInstance.task = Task.fromPlain(parsedTask as Task);
  workerInstance.notificationConfigJsonString = message.notificationConfigJson;
  workerInstance.notificationConfig = message.notificationConfigJson !== undefined
    ? (JSON.parse(message.notificationConfigJson) as NotificationConfig)
    : undefined;
  if (message.progress !== undefined) {
    workerInstance.notificationProgress = message.progress;
  }

  if (workerInstance.task === undefined) {
    console.error(BDPlugin.TAG, 'UpdateNotificationWorker received an invalid task payload');
    sendAck();
    return;
  }

  if (message.taskStatusOrdinal === undefined) {
    await UpdateNotificationWorker.cancelNotification(workerInstance.task.taskId);
    sendAck();
    return;
  }
  try {
    const taskStatus = message.taskStatusOrdinal as TaskStatus;
    await UpdateNotificationWorker.updateNotificationLocal(workerInstance, taskStatus);
  } finally {
    sendAck();
  }
};
