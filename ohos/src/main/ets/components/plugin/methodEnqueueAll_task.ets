import { NotificationConfig } from './Notifications';
import { ResumeData, Task, TaskStatus } from "./Models";
import { TaskWorker } from "./TaskWorker";
import BDPlugin from "./BDPlugin";
import { EnqueueItem } from './HoldingQueue';
import { preferences } from "@kit.ArkData";

export async function methodEnqueueAll_task(
  taskListJsonString: string,
  notificationConfigListJsonString: string,
): Promise<Array<boolean>> {
  console.error(BDPlugin.TAG + " enter methodEnqueueAll_task");

  let uiContext = BDPlugin.uiContext;
  const results: boolean[] = [];

  // parse tasks
  let tasksPlain: Task[] = [];
  try {
    tasksPlain = JSON.parse(taskListJsonString) as Task[];
  } catch (e) {
    console.error(BDPlugin.TAG + " failed to parse taskListJsonString: " + e);
    return results;
  }
  const entries = tasksPlain.entries();

  // parse notification configs
  let rawNotificationConfigs: Array<NotificationConfig | undefined> = [];
  try {
    rawNotificationConfigs = JSON.parse(notificationConfigListJsonString) as Array<NotificationConfig | undefined>;
  } catch (e) {
    console.error(BDPlugin.TAG + " failed to parse notificationConfigListJsonString: " + e);
  }

  // Ensure TaskWorker has access to shared data for status updates
  TaskWorker.workerShareableData = BDPlugin.workerShareableData;

  for (const entry of entries) {
    if (!uiContext) {
      results.push(false);
      continue;
    }

    const task = Task.fromPlain(entry[1] as Task);
    if (!task) {
      results.push(false);
      continue;
    }

    const notificationConfig = rawNotificationConfigs[entry[0]];
    const notificationConfigJsonString = notificationConfig
      ? JSON.stringify(notificationConfig)
      : undefined;

    let success = false;
    try {
      if (BDPlugin.holdingQueue == undefined) {
        success = await BDPlugin.doEnqueue(
          uiContext,
          task,
          notificationConfigJsonString,
          undefined,
          0,
        );
      } else {
        // Validate URL
        try {
          const validateUrl = decodeURIComponent(task.url);
          if (!validateUrl) {
            console.error(BDPlugin.TAG, 'Invalid URL for taskId ' + task.taskId);
            results.push(false);
            continue;
          }
        } catch (e) {
          console.log(BDPlugin.TAG, 'Malformed or undecodable URL for taskId ' + task.taskId);
          results.push(false);
          continue;
        }

        await BDPlugin.holdingQueue.add(
          new EnqueueItem(
            uiContext,
            task,
            notificationConfigJsonString,
            undefined,
          ),
        );

        const options: preferences.Options = { name: 'DEFAULT' };
        const pref_current = preferences.getPreferencesSync(uiContext, options);
        await TaskWorker.processStatusUpdate(task, TaskStatus.enqueued, pref_current, uiContext);
        success = true;
      }
    } catch (e) {
      console.error(BDPlugin.TAG + ' Error processing task ' + task.taskId + ': ' + e);
      success = false;
    }

    results.push(success);
  }

  return results;
}
