import { EnqueueItem } from "./HoldingQueue";
import { common, sendableContextManager } from "@kit.AbilityKit";
import { TaskWorker } from "./TaskWorker";
import { worker } from "@kit.ArkTS";
//import { UpdateNotificationWorker } from "./UpdateNotificationWorker";
import { SendableTask, TaskStatus } from "./Models";

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
}

export class NotificationService {
  private static updateNotificationWorker?: worker.ThreadWorker;
  private static pendingMessages: UpdateNotificationWorkerMessage[] = [];
  private static processingPromise?: Promise<void>;

  static registerEnqueue(item: EnqueueItem, success: boolean): void {
    const notificationConfigJsonString = item.notificationConfigJsonString;
    if (notificationConfigJsonString === undefined) {
      return;
    }
    const notificationConfig = JSON.parse(notificationConfigJsonString) as NotificationConfig;
    const groupNotificationId = notificationConfig.groupNotificationId;
    if (groupNotificationId.length !== 0) {
      const serializedTask = new SendableTask(item.task);
      NotificationService.createUpdateNotificationWorker(
        item.context,
        JSON.stringify(serializedTask),
        notificationConfigJsonString,
        success ? TaskStatus.enqueued : TaskStatus.failed
      );
    }
  }

  static createUpdateNotificationWorker(
    context: common.UIAbilityContext,
    taskJson: string,
    notificationConfigJson?: string,
    taskStatusOrdinal?: number
  ): void {
    const message: UpdateNotificationWorkerMessage = {
      command: "update",
      taskJson,
    };
    if (notificationConfigJson !== undefined) {
      message.notificationConfigJson = notificationConfigJson;
    }
    if (taskStatusOrdinal !== undefined) {
      message.taskStatusOrdinal = taskStatusOrdinal;
    }
    if (context !== undefined) {
      message.uiContext = sendableContextManager.convertFromContext(context);
    }
    NotificationService.pendingMessages.push(message);
    NotificationService.processPendingMessages();
  }

  private static processPendingMessages(): void {
    if (NotificationService.processingPromise !== undefined) {
      return;
    }
    NotificationService.processingPromise = NotificationService.runMessageLoop();
  }

  private static async runMessageLoop(): Promise<void> {
    try {
      while (NotificationService.pendingMessages.length > 0) {
        const message = NotificationService.pendingMessages.shift();
        if (message === undefined) {
          continue;
        }
        const workerInstance = NotificationService.ensureWorker();
        workerInstance.postMessage(message);
      }
    } finally {
      NotificationService.processingPromise = undefined;
    }
  }

  private static ensureWorker(): worker.ThreadWorker {
    if (NotificationService.updateNotificationWorker === undefined) {
      NotificationService.updateNotificationWorker = new worker.ThreadWorker("./UpdateNotificationWorker");
    }
    return NotificationService.updateNotificationWorker;
  }

  static updateNotification(taskWorker: TaskWorker, taskStatus: TaskStatus): void {
    const notificationConfig = taskWorker.notificationConfig;
    if (notificationConfig === undefined) {
      return;
    }
    const notificationType = NotificationService.notificationTypeForTaskStatus(taskStatus);
    const groupNotificationId = notificationConfig.groupNotificationId;
    if (groupNotificationId.length !== 0) {
      // Group notifications are not yet implemented on ArkTS.
      return;
    }
    const template = NotificationService.notificationTemplateForType(notificationConfig, notificationType);
    if (template === undefined) {
      return;
    }
    console.info(
      'NotificationService',
      `updateNotification(taskId=${taskWorker.task?.taskId}, type=${NotificationType[notificationType]}, title=${template.title})`
    );
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
}
