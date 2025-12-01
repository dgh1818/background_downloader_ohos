import { EnqueueItem } from "./HoldingQueue";
import { common, sendableContextManager } from "@kit.AbilityKit";
import { TaskWorker } from "./TaskWorker";
import { ArkTSUtils, MessageEvents, worker } from "@kit.ArkTS";
//import { UpdateNotificationWorker } from "./UpdateNotificationWorker";
import { Task, TaskStatus } from "./Models";
import { notificationManager } from '@kit.NotificationKit';
import { hash } from '@kit.CoreFileKit';
import BDPlugin from "./BDPlugin";
import { BusinessError } from '@kit.BasicServicesKit';

/**
 * Notification configuration object
 *
 * [running] is the notification used while the task is in progress
 * [complete] is the notification used when the task completed
 * [error] is the notification used when something went wrong,
 * including pause, failed and notFound status
 */
@Sendable
export class TaskNotification {
  title: string;
  body: string;

  constructor(title: string, body: string) {
    this.title = title;
    this.body = body;
  }

  toString(): string {
    return `Notification(title='${this.title}', body='${this.body}')`;
  }
}


@Sendable
export class NotificationConfig {
  running?: TaskNotification;
  complete?: TaskNotification;
  error?: TaskNotification;
  paused?: TaskNotification;
  canceled?: TaskNotification;
  progressBar: boolean;
  tapOpensFile: boolean;
  groupNotificationId: string;

  constructor(
    running?: TaskNotification,
    complete?: TaskNotification,
    error?: TaskNotification,
    paused?: TaskNotification,
    canceled?: TaskNotification,
    progressBar: boolean = false,
    tapOpensFile: boolean = false,
    groupNotificationId: string = ""
  ) {
    this.running = running;
    this.complete = complete;
    this.error = error;
    this.paused = paused;
    this.canceled = canceled;
    this.progressBar = progressBar;
    this.tapOpensFile = tapOpensFile;
    this.groupNotificationId = groupNotificationId;
  }

  toString(): string {
    return `NotificationConfig(running=${this.running}, complete=${this.complete}, error=${this.error}, paused=${this.paused}, progressBar=${this.progressBar}, tapOpensFile=${this.tapOpensFile}, groupNotificationId=${this.groupNotificationId})`;
  }
}

export enum NotificationType {
  running,
  complete,
  error,
  paused,
  canceled,
}

export interface UpdateNotificationWorkerMessage {
  command: string;
  taskJson: string;
  notificationConfigJson?: string;
  taskStatusOrdinal?: number;
  uiContext?: sendableContextManager.SendableContext;
  progress?: number;
  messageId?: number;
}

interface NotificationAck {
  messageId?: number;
}

@Sendable
export class UpdateNotificationSendableMessage implements UpdateNotificationWorkerMessage {
  constructor(
    command: string,
    taskJson: string,
    notificationConfigJson?: string,
    taskStatusOrdinal?: number,
    uiContext?: sendableContextManager.SendableContext,
    progress?: number,
    messageId?: number
  ) {
    this.command = command;
    this.taskJson = taskJson;
    this.notificationConfigJson = notificationConfigJson;
    this.taskStatusOrdinal = taskStatusOrdinal;
    this.uiContext = uiContext;
    this.progress = progress;
    this.messageId = messageId;
  }

  public command: string;
  public taskJson: string;
  public notificationConfigJson?: string;
  public taskStatusOrdinal?: number;
  public uiContext?: sendableContextManager.SendableContext;
  public progress?: number;
  public messageId?: number;
}

export class NotificationService {
  private static lock: ArkTSUtils.locks.AsyncLock = new ArkTSUtils.locks.AsyncLock();

  static registerEnqueue(item: EnqueueItem, success: boolean): void {
    const notificationConfigJsonString = item.notificationConfigJsonString;
    if (notificationConfigJsonString === undefined) {
      return;
    }
    const notificationConfig = JSON.parse(notificationConfigJsonString) as NotificationConfig;
    const groupNotificationId = notificationConfig.groupNotificationId;
    if (groupNotificationId.length !== 0) {
      //const serializedTask = new SendableTask(item.task);
      NotificationService.createUpdateNotificationWorker(
        BDPlugin.uiContext!,
        TaskWorker.taskToJsonString(item.task),
        notificationConfigJsonString,
        success ? TaskStatus.enqueued : TaskStatus.failed
      );
    }
  }

  static createUpdateNotificationWorker(
    context: common.UIAbilityContext,
    taskJson: string,
    notificationConfigJson?: string,
    taskStatusOrdinal?: number,
    progress?: number
  ): Promise<void> {
    return NotificationService.withLock(async () => {
      try {
        const parsedTask = Task.fromPlain(JSON.parse(taskJson) as Task);
        const workerInstance = new TaskWorker(context);
        workerInstance.task = parsedTask;
        workerInstance.notificationConfigJsonString = notificationConfigJson;
        workerInstance.notificationConfig = notificationConfigJson
          ? (JSON.parse(notificationConfigJson) as NotificationConfig)
          : undefined;
        if (progress !== undefined) {
          workerInstance.notificationProgress = progress;
        }
        if (taskStatusOrdinal === undefined) {
          await NotificationService.cancelNotification(workerInstance.task?.taskId);
          return;
        }
        const taskStatus = taskStatusOrdinal as TaskStatus;
        await NotificationService.updateNotification(workerInstance, taskStatus);
      } catch (e) {
        console.error(BDPlugin.TAG, `NotificationService.createUpdateNotificationWorker main-thread update failed: ${e}`);
      }
    });
  }

  private static async withLock<T>(fn: () => T | Promise<T>): Promise<T> {
    return NotificationService.lock.lockAsync(fn);
  }

  private static shouldThrottle(taskJson: string, progress?: number): boolean {
    return false;
  }

  static async updateNotification(taskWorker: TaskWorker, taskStatus: TaskStatus): Promise<void> {
    const notificationConfig = taskWorker.notificationConfig;
    if (notificationConfig === undefined) {
      return;
    }
    const notificationType = NotificationService.notificationTypeForTaskStatus(taskStatus);
    const groupNotificationId = notificationConfig.groupNotificationId;
    const template = NotificationService.notificationTemplateForType(notificationConfig, notificationType);
    if (template === undefined) {
      // if no template, cancel any existing notification for this task
      await NotificationService.cancelNotification(taskWorker.task?.taskId);
      return;
    }
    console.info(
      'NotificationService',
      `updateNotification(taskId=${taskWorker.task?.taskId}, type=${NotificationType[notificationType]}, title=${template.title})`
    );

    const title = template.title ?? "";
    const body = template.body ?? "";
    const fileName = taskWorker.task?.filename ?? "";
    const progress = taskWorker.notificationProgress;
    console.error('NotificationService', `updateNotification: progress=${progress}`);
    const id = await NotificationService.notificationIdForTask(taskWorker.task?.taskId);

    const progressPct = progress >= 0 && progress <= 1 ? Math.round(progress * 100) : -1;
    console.error('NotificationService', `updateNotification: progressPct=${progressPct}`);
    const request: notificationManager.NotificationRequest = {
      id: id,
      //groupName: groupNotificationId && groupNotificationId.length > 0 ? groupNotificationId : undefined,
      groupName:"immich",
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
      console.error('NotificationService', `Failed to publish notification for task ${taskWorker.task?.taskId}: ${e}`);
    }
  }

  private static notificationTypeForTaskStatus(taskStatus: TaskStatus): NotificationType {
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

  private static notificationTemplateForType(
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

  static async cancelNotification(taskId?: string) {
    if (!taskId) {
      return;
    }
    const id = await NotificationService.notificationIdForTask(taskId);
    try {
      notificationManager.cancel(id);
    } catch (_) {
    }
  }

  private static async notificationIdForTask(taskId?: string): Promise<number> {
    if (!taskId) {
      return 0;
    }
    // simple deterministic hash similar to Java String.hashCode
    let hashVal = 0;
    for (let i = 0; i < taskId.length; i++) {
      hashVal = ((hashVal << 5) - hashVal + taskId.charCodeAt(i)) | 0;
    }
    return Math.abs(hashVal);
  }
}
