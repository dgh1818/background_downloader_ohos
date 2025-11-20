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
import { ArkTSUtils, ArrayList, collections, MessageEvents, taskpool, uri, url, worker } from "@kit.ArkTS";
import { fileUri } from '@kit.CoreFileKit';
import dataPreferences from '@ohos.data.preferences'
import { photoAccessHelper } from "@kit.MediaLibraryKit";
import { dataSharePredicates, preferences } from "@kit.ArkData";
import { workScheduler } from "@kit.BackgroundTasksKit";

import { EnqueueItem, HoldingQueue } from './HoldingQueue'
import { NotificationConfig } from './Notifications'
import { ResumeData, Task, RequireWiFi, TaskStatus } from "./Models";
import { getTaskMap, TaskWorker, TaskWorkerKey } from "./TaskWorker";
import BDPlugin from "./BDPlugin";


export async function methodEnqueueAll_task(
  taskListJsonString: string,
  notificationConfigListJsonString: string,

): Promise<Array<boolean> | undefined> {

  try {
    console.error(BDPlugin.TAG + "enter methodEnqueueAll_task");
    const rawTasks = JSON.parse(taskListJsonString) as Map<string, Task | undefined>;
    if (!rawTasks) {
      console.error("rawTasks is undefined")
    }
    const rawNotificationConfigs =
      JSON.parse(notificationConfigListJsonString) as Array<NotificationConfig | undefined>;
    if (!rawNotificationConfigs) {
      console.error("rawNotificationConfigs is undefined")
    }
    if (!BDPlugin.uiContext) {
      return undefined;
    }
    let uiContext = BDPlugin.uiContext;

    const results: boolean[] = [];

    let index = 0;
    const promises: Promise<boolean>[] = [];
    const entries = Array.from(rawTasks.entries());

    for (let i = 0; i < entries.length; i++) {
      const entry = entries[i]; // entry 是形如 [key, task] 的数组/元组
      //const key = entry[0] as string;  // 不用解构，直接下标取
      const task = entry[1] as Task;

      if (!task) {
        results.push(false);
        continue;
      }

      const notificationConfig = rawNotificationConfigs[i];
      if (!notificationConfig) {
        console.error("notificationConfig is undefined, taskId = " + task.taskId);
        // results.push(false);
        // continue;
      }

      const notificationConfigJsonString = notificationConfig
        ? JSON.stringify(notificationConfig)
        : undefined; // 对应 Kotlin 的 null
      console.error("notificationConfigJsonString finish = " + task.taskId);
      let success = false;

      try {
        if (BDPlugin.holdingQueue == undefined) {
          console.error("enter BDPlugin.holdingQueue == undefined " + task.taskId);
          success = await BDPlugin.doEnqueue(
            uiContext,
            task,
            notificationConfigJsonString,
            undefined,
            0,
          );
        } else {
          // 校验 URL
          try {
            console.error("enter BDPlugin.holdingQueue != undefined " + task.taskId);
            const validateUrl = decodeURIComponent(task.url);
            if (!validateUrl) {
              results.push(false);
              continue;
            }
          } catch (e) {
            console.log(BDPlugin.TAG, 'Malformed or undecodable URL for taskId ' + task.taskId);
            results.push(false);
            continue;
          }

          console.error(BDPlugin.TAG, 'Enqueueing task with id ' + task.taskId + ' to the HoldingQueue');

          await BDPlugin.holdingQueue.add(
            new EnqueueItem(
              uiContext,
              task,
              notificationConfigJsonString,
              undefined,
            ),
          );

          console.error(BDPlugin.TAG, 'holdingQueue.added ' + task.taskId);

          const options: preferences.Options = { name: 'DEFAULT' };
          const pref_current = preferences.getPreferencesSync(uiContext, options);
          TaskWorker.processStatusUpdate(task, TaskStatus.enqueued, pref_current, uiContext);

          success = true;
        }
      } catch (e) {
        console.error(BDPlugin.TAG + ' Error processing task ' + task.taskId + ': ' + e);
        success = false;
      }

      results.push(success);
    }

    return results;
  } catch (e) {
    return undefined;
  }
}
