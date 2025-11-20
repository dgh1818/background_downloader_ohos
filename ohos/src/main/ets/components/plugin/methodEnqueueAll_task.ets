import {
  FlutterPlugin,
  FlutterPluginBinding,
  MethodCall,
  MethodCallHandler,
  MethodChannel,
  MethodResult,

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
import { ResumeData, Task, RequireWiFi, TaskStatus} from "./Models";
import { getTaskMap, TaskWorker, TaskWorkerKey } from "./TaskWorker";
import BDPlugin from "./BDPlugin";


export async function methodEnqueueAll_task(
  taskListJsonString: string,
  notificationConfigListJsonString: string,

): Promise<Array<boolean>|undefined> {

  try {
    console.error(BDPlugin.TAG + "enter methodEnqueueAll_task");
    const rawTasks = JSON.parse(taskListJsonString) as Map<string,Task | undefined>;
    const rawNotificationConfigs =
      JSON.parse(notificationConfigListJsonString) as Array<NotificationConfig | undefined>;
    if(!BDPlugin.uiContext) {
      return undefined;
    }
    let uiContext = BDPlugin.uiContext;

    //const results: boolean[] = [];

    let index = 0;
    const promises: Promise<boolean>[] = [];
    rawTasks.forEach(async (value, key) => {
      const p = (async () => {
      const task = value;
      if(task == undefined) {
        return false;
      }
      const notificationConfig = rawNotificationConfigs[index];
      index++;
      const notificationConfigJsonString = notificationConfig ? JSON.stringify(notificationConfig) : undefined;
      try {

        if (BDPlugin.holdingQueue == undefined) {
          // 直接入队
          return await BDPlugin.doEnqueue(
            uiContext,
            task,
            notificationConfigJsonString,
            undefined,
            0,
          )
        } else {
          try {
            let validateUrl = decodeURIComponent(task.url); // 解码
            if(validateUrl == undefined) {
              return false;
            }
          } catch (e) {

            console.log(BDPlugin.TAG, 'Malformed or undecodable URL for taskId' + task.taskId);
            //results.push(false);
            return false;
          }
          console.log(BDPlugin.TAG, 'Enqueueing task with id ' + task.taskId + ' to the HoldingQueue');

          await BDPlugin.holdingQueue.add(
            new EnqueueItem(
              uiContext,
              task,
              notificationConfigJsonString,
              undefined,
            )
          );
          let options: preferences.Options = { name: 'DEFAULT' };
          let pref_current = preferences.getPreferencesSync(uiContext, options);
          TaskWorker.processStatusUpdate(task, TaskStatus.enqueued, pref_current, uiContext);
          return true;

        }
      } catch (e) {
        console.error(BDPlugin.TAG + 'Error processing task' + task.taskId + ':' + e);
        return false;
      }

      })();
      promises.push(p);
      //results.push(success);
    });
    const results = await Promise.all(promises); // 等所有 async 回调完成
    return results;
  } catch (e) {
    console.error(BDPlugin.TAG, 'Error decoding JSON: ' + e);
    return [];
  }
}
