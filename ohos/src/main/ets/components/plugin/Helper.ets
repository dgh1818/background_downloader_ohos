import { common } from "@kit.AbilityKit";
import { util } from "@kit.ArkTS";
import { fileIo as fs, fileUri, storageStatistics } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { BaseDirectory, Task } from "./Models";
import { TaskWorker } from "./TaskWorker";
import { preferences } from "@kit.ArkData";
import BDPlugin from "./BDPlugin";
/**
 * Parses the range in a Range header, and returns a Pair representing
 * the range. The format needs to be "bytes=10-20"
 *
 * A missing lower range is substituted with 0L, and a missing upper
 * range with null.  If the string cannot be parsed, returns (0L, null)
 */
export function parseRange(rangeStr: string): [number, number | undefined] {
  const regex = /bytes=(\d*)-(\d*)/;
  const match = regex.exec(rangeStr);
  if (!match) {
    return [0, undefined];
  }

  const start = Number.parseInt(match[1], 10);
  const end = Number.parseInt(match[2], 10);

  return [Number.isNaN(start) ? 0 : start, Number.isNaN(end) ? undefined : end];
}

/**
 * Suggests a filename based on response headers and a URL. If none can be derived, returns ""
 *
 * @param responseHeaders The response headers map.
 * @param url             The URL the file would be downloaded from.
 * @return A suggested filename, derived from the headers or the URL.
 */
export function suggestFilename(responseHeaders: Map<string, string>, url: string): string {
  try {
    const dispositionKeys = ["Content-Disposition", "content-disposition"]
    const disposition = dispositionKeys
      .map(key => responseHeaders.get(key))
      .find(value => value != undefined)
    if (disposition) {
      // Try filename*=UTF-8'language'"encodedFilename"
      const encodedFilenameRegEx = /filename\*=\s*([^']+)'([^']*)'"?([^"]+)"?/i
      let match = encodedFilenameRegEx.exec(disposition)
      if (match && match[1].length > 0 && match[3].length > 0) {
        try {
          const charset = match[1].toUpperCase()
          const rawFilename = match[3]
          const suggestedFilename = charset == "UTF-8" ? decodeURIComponent(rawFilename) : rawFilename
          return suggestedFilename
        } catch (_) {
          // ignore decoding errors and fall back to other strategies
        }
      }
      // Try filename="filename"
      const plainFilenameRegEx = /filename=\s*"?([^"]+)"?.*$/i
      match = plainFilenameRegEx.exec(disposition)
      if (match && match[1].length > 0) {
        return match[1]
      }
    }
  } catch (_) {
    // ignore header parsing errors
  }
  // Try filename derived from last path segment of the url
  try {
    const urlWithoutQuery = url.split("?")[0]
    const lastSlashIndex = urlWithoutQuery.lastIndexOf("/")
    if (lastSlashIndex != -1 && lastSlashIndex + 1 < urlWithoutQuery.length) {
      const lastSegment = urlWithoutQuery.substring(lastSlashIndex + 1)
      try {
        return decodeURIComponent(lastSegment)
      } catch (_) {
        return lastSegment
      }
    }
  } catch (_) {
    // ignore url parsing errors
  }
  return "" // Default fallback
}

export function getContentLength(responseHeaders: Map<string, string>, task: Task): number {
  let contentLength = Number.parseInt(responseHeaders.get("Content-Length")
    ?? responseHeaders.get("content-length") ?? "-1", 10)
  if (!Number.isNaN(contentLength) && contentLength != -1) {
    return contentLength
  }

  const taskRangeHeader = task.headers.get("Range") ?? task.headers.get("range") ?? ""
  const taskRange = parseRange(taskRangeHeader)
  if (taskRange[1] != undefined) {
    const rangeLength = taskRange[1] - taskRange[0] + 1
    console.info(TaskWorker.TAG,
      `TaskId ${task.taskId} contentLength set to ${rangeLength} based on Range header`)
    return rangeLength
  }

  let knownLength = Number.parseInt(task.headers.get("Known-Content-Length")
    ?? task.headers.get("known-content-length") ?? "-1", 10)
  knownLength = Number.isNaN(knownLength) ? -1 : knownLength
  if (knownLength != -1) {
    console.info(TaskWorker.TAG,
      `TaskId ${task.taskId} contentLength set to ${knownLength} based on Known-Content-Length header`)
  } else {
    console.info(TaskWorker.TAG,
      `TaskId ${task.taskId} contentLength undetermined`)
  }
  return knownLength
}

/**
 * Returns true if there is insufficient space to store a file of length [contentLength]
 *
 * Returns false if [contentLength] <= 0
 * Returns false if configCheckAvailableSpace has not been set, or if available
 * space is greater than that setting
 * Returns true otherwise
 */
export function insufficientSpace(applicationContext: common.UIAbilityContext, contentLength: number): boolean {
  if (contentLength <= 0) {
    return false;
  }

  const prefOptions: preferences.Options = { name: "DEFAULT" };
  const prefs = preferences.getPreferencesSync(applicationContext, prefOptions);
  const checkValue = prefs.getSync(BDPlugin.keyConfigCheckAvailableSpace, 0) as number;
  if (checkValue <= 0) {
    return false;
  }

  let available = 0;
  try {
    available = storageStatistics.getFreeSizeSync();
  } catch (error) {
    console.warn(`${BDPlugin.TAG} Could not obtain storage statistics: ${JSON.stringify(error)}`);
    return false;
  }

  let remainingBytes = 0;

  TaskWorker.workerShareableData!.remainingBytesToDownload.forEach((value) => remainingBytes += value);
  return available - (remainingBytes + contentLength) < (checkValue << 20);
}

export function baseDirPath(context: common.UIAbilityContext, baseDirectory: BaseDirectory): string | undefined {
  const prefOptions: preferences.Options = { name: "DEFAULT" };
  const prefs = preferences.getPreferencesSync(context, prefOptions);
  const useExternalStorage = prefs.getSync(BDPlugin.keyConfigUseExternalStorage, -1) as number == 0;

  if (useExternalStorage) {
    console.error(`${BDPlugin.TAG}: External storage is requested but not available on this platform`);
    return undefined;
  }

  const filesDir = context.filesDir;
  const cacheDir = context.cacheDir;

  if (!filesDir || !cacheDir) {
    console.error(`${BDPlugin.TAG}: Could not resolve internal storage directories`);
    return undefined;
  }

  switch (baseDirectory) {
    case BaseDirectory.applicationDocuments:
      return filesDir;
    case BaseDirectory.temporary:
      return cacheDir;
    case BaseDirectory.applicationSupport:
      return filesDir;
    case BaseDirectory.applicationLibrary:
      return `${filesDir}/Library`;
    case BaseDirectory.root:
      return "";
    default:
      return filesDir;
  }
}

const TAG = "FileUtils";

export class FileUtils {
  static async getPathFromUri(context: common.UIAbilityContext | null, uri: string,
    defExtension?: string): Promise<string | undefined> {
    console.info(TAG, "getPathFromUri : " + uri);
    const uuid = util.generateRandomUUID();
    if (!context) {
      return undefined;
    }
    {
      if (!fs.accessSync(context.cacheDir + "/originalPhoto")) {
        fs.mkdirSync(context.cacheDir + "/originalPhoto");
      }
      const targetDirectoryPath = context.cacheDir + "/originalPhoto/" + uuid;
      try {
        fs.mkdirSync(targetDirectoryPath);
        let targetDir = fs.openSync(targetDirectoryPath);
        console.info(TAG, "mkdirSync success targetDirectoryPath:" + targetDirectoryPath + " fd: " + targetDir.fd);
        fs.closeSync(targetDir);
      } catch (err) {
        console.error(TAG, "mkdirSync failed err:" + err);
        return undefined;
      }

      const inputFilePath = uri.substring(uri.lastIndexOf("/") + 1);
      const inputFilePathSplits = inputFilePath.split(".");
      console.info(TAG, "getPathFromUri inputFilePath: " + inputFilePath);
      const outputFileName = inputFilePathSplits[0];
      let extension: string;
      if (inputFilePathSplits.length == 2) {
        extension = "." + inputFilePathSplits[1];
      } else {
        if (defExtension) {
          extension = defExtension;
        } else {
          extension = ".jpg";
        }
      }
      const outputFilePath = targetDirectoryPath + "/" + outputFileName + extension;

      try {
        let progressListener: fs.ProgressListener = (progress: fs.Progress) => {
          console.info(`progressSize: ${progress.processedSize}, totalSize: ${progress.totalSize}`);
        };
        let copyOption: fs.CopyOptions = {
          "progressListener": progressListener
        }
        let dstDirUriLocal: string = fileUri.getUriFromPath(outputFilePath);

        fs.copy(uri, dstDirUriLocal, copyOption, (err: BusinessError) => {
          if (err) {
            console.error(`Failed to copy. Code: ${err.code}, message: ${err.message}`);
            return;
          }
          console.info("Succeeded in copying.");


          return outputFilePath;
        })
      } catch (err) {
        console.error(TAG, "copyFile failed err:" + err);

        return undefined;
      } finally {
        //fs.closeSync(inputFile);
        //fs.closeSync(outputFile);
      }
      return outputFilePath;
    }
  }
}
