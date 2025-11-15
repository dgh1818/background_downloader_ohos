import {
  FlutterPlugin,
  FlutterPluginBinding,
  MethodCall,
  MethodCallHandler,
  MethodChannel,

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
import { ArkTSUtils, ArrayList, collections, MessageEvents, taskpool, uri, url, worker } from "@kit.ArkTS";
import { fileUri } from '@kit.CoreFileKit';
import dataPreferences from '@ohos.data.preferences'
import { photoAccessHelper } from "@kit.MediaLibraryKit";
import { dataSharePredicates, preferences } from "@kit.ArkData";
import { workScheduler } from "@kit.BackgroundTasksKit";

import { EnqueueItem, HoldingQueue } from './HoldingQueue'
import { NotificationConfig } from './Notifications'
import { ISendable, ResumeData, Task, RequireWiFi, TaskStatus } from "./Models";
import { getTaskMap, TaskWorker, TaskWorkerKey } from "./TaskWorker";
import BDPlugin from "./BDPlugin";


@Concurrent
export async function methodEnqueueAll_task(
  taskListJsonString: string,
  notificationConfigListJsonString: string
): Promise<Array<boolean>> {

  try {
    const rawTasks = JSON.parse(taskListJsonString) as Array<Record<string, Object>>;
    const rawNotificationConfigs =
      JSON.parse(notificationConfigListJsonString) as Array<NotificationConfig | undefined>;
    const results: boolean[] = [];

    for (let i = 0; i < rawTasks.length; i++) {
      const task = TaskWorker.fromSerializableTask(rawTasks[i]);
      const notificationConfig = rawNotificationConfigs[i];
      const notificationConfigJsonString = notificationConfig ? JSON.stringify(notificationConfig) : undefined;
      let success = false;
      try {
        try {
          decodeURIComponent(task.url); // 解码
        } catch (e) {

          console.log(BDPlugin.TAG, 'Malformed or undecodable URL for taskId' + task.taskId);
          results.push(false);
          continue;
        }

        if (BDPlugin.holdingQueue == undefined) {
          // 直接入队
          success = await BDPlugin.doEnqueue(
            BDPlugin.uiContext!,
            task,
            notificationConfigJsonString
          )
        } else {
          console.log(BDPlugin.TAG, 'Enqueueing task with id ' + task.taskId + ' to the HoldingQueue');
          await BDPlugin.holdingQueue.add(
            new EnqueueItem(
              BDPlugin.uiContext!,
              task,
              notificationConfigJsonString
            )
          );
          let options: preferences.Options = { name: 'DEFAULT' };
          let pref_current = preferences.getPreferencesSync(BDPlugin.uiContext, options);
          await TaskWorker.processStatusUpdate(task, TaskStatus.enqueued, pref_current, BDPlugin.uiContext);
          success = true;

        }
      } catch (e) {
        console.error(BDPlugin.TAG + 'Error processing task' + task.taskId + ':' + e);

      }
      results.push(success);
    }
    return results;
  } catch (e) {
    console.error(BDPlugin.TAG, 'Error decoding JSON: ' + e);
    return [];
  }
}
