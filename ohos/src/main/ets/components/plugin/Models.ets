import { collections, lang, uri } from '@kit.ArkTS';
import { Auth, AuthInit, AuthJSON } from './Auth';

export { Auth, AuthInit, AuthJSON } from './Auth';

export type ISendable = lang.ISendable;

/**
 * Base directory in which files will be stored, based on their relative path.
 * Matches the Flutter/Kotlin enum ordering so persisted ordinals stay aligned.
 */
export enum BaseDirectory {
  applicationDocuments,
  temporary,
  applicationSupport,
  applicationLibrary,
  root,
}

/** Type of updates requested for a group of tasks. */
export enum Updates {
  none,
  status,
  progress,
  statusAndProgress,
}

export interface TaskOptionsInit {
  readonly beforeTaskStartRawHandle?: number;
  readonly onTaskStartRawHandle?: number;
  readonly onTaskFinishedRawHandle?: number;
  readonly auth?: Auth | AuthInit | AuthJSON | null;
}

export interface TaskOptionsJSON {
  readonly beforeTaskStartRawHandle: number | null;
  readonly onTaskStartRawHandle: number | null;
  readonly onTaskFinishedRawHandle: number | null;
  readonly auth: AuthJSON | null;
}

@Sendable
export class TaskOptions {
  constructor(
    private readonly beforeTaskStartRawHandle?: number,
    private readonly onTaskStartRawHandle?: number,
    private readonly onTaskFinishedRawHandle?: number,
    readonly auth?: Auth,
  ) {}

  static from(init?: TaskOptions | TaskOptionsInit | TaskOptionsJSON | null): TaskOptions | undefined {
    if (!init) {
      return undefined;
    }
    if (init instanceof TaskOptions) {
      return init;
    }
    const isJson = (candidate: TaskOptions | TaskOptionsInit | TaskOptionsJSON): candidate is TaskOptionsJSON => {
      return (candidate as TaskOptionsJSON).beforeTaskStartRawHandle !== undefined && !(candidate instanceof TaskOptions);
    };
    if (isJson(init)) {
      return new TaskOptions(
        init.beforeTaskStartRawHandle ?? undefined,
        init.onTaskStartRawHandle ?? undefined,
        init.onTaskFinishedRawHandle ?? undefined,
        Auth.from(init.auth) ?? undefined,
      );
    }
    return new TaskOptions(
      init.beforeTaskStartRawHandle,
      init.onTaskStartRawHandle,
      init.onTaskFinishedRawHandle,
      Auth.from(init.auth) ?? undefined,
    );
  }

  hasBeforeStartCallback(): boolean {
    return this.beforeTaskStartRawHandle !== undefined && this.beforeTaskStartRawHandle !== null;
  }

  hasOnStartCallback(): boolean {
    return this.onTaskStartRawHandle !== undefined && this.onTaskStartRawHandle !== null;
  }

  hasOnFinishCallback(): boolean {
    return this.onTaskFinishedRawHandle !== undefined && this.onTaskFinishedRawHandle !== null;
  }

  toJSON(): TaskOptionsJSON {
    return {
      beforeTaskStartRawHandle: this.beforeTaskStartRawHandle ?? null,
      onTaskStartRawHandle: this.onTaskStartRawHandle ?? null,
      onTaskFinishedRawHandle: this.onTaskFinishedRawHandle ?? null,
      auth: this.auth ? this.auth.toJSON() : null,
    };
  }
}

export interface TaskInit {
  readonly taskId?: string;
  readonly url?: string;
  readonly urls?: collections.Array<string>;
  readonly filename?: string;
  readonly headers?: collections.Map<string, string>;
  readonly httpRequestMethod?: string;
  readonly chunks?: number;
  readonly post?: string;
  readonly fileField?: string;
  readonly mimeType?: string;
  readonly fields?: collections.Map<string, string>;
  readonly directory?: string;
  readonly baseDirectory?: BaseDirectory | number;
  readonly group?: string;
  readonly updates?: Updates | number;
  readonly requiresWiFi?: boolean;
  readonly retries?: number;
  readonly retriesRemaining?: number;
  readonly allowPause?: boolean;
  readonly priority?: number;
  readonly metaData?: string;
  readonly displayName?: string;
  readonly creationTime?: number;
  readonly options?: TaskOptions | TaskOptionsInit | TaskOptionsJSON | null;
  readonly taskType?: string;
}

@Sendable
export class Task {
  readonly taskId: string;
  readonly url: string;
  readonly urls: collections.Array<string>;
  readonly filename: string;
  readonly headers: collections.Map<string, string>;
  readonly httpRequestMethod: string;
  readonly chunks: number;
  readonly post?: string;
  readonly fileField: string;
  readonly mimeType: string;
  readonly fields: collections.Map<string, string>;
  readonly directory: string;
  readonly baseDirectory: BaseDirectory;
  readonly group: string;
  readonly updates: Updates;
  readonly requiresWiFi: boolean;
  readonly retries: number;
  retriesRemaining: number;
  readonly allowPause: boolean;
  readonly priority: number;
  readonly metaData: string;
  readonly displayName: string;
  readonly creationTime: number;
  readonly options?: TaskOptions;
  readonly taskType: string;

  constructor(init?: TaskInit) {
    const randomId = Math.abs(Math.floor(Math.random() * 0x7fffffff)).toString();
    this.taskId = init?.taskId ?? randomId;
    this.url = init?.url ?? '';
    this.urls = init?.urls ?? new collections.Array<string>();
    this.filename = init?.filename ?? '';
    this.headers = init?.headers ?? new collections.Map<string, string>();
    this.httpRequestMethod = init?.httpRequestMethod ?? 'GET';
    this.chunks = init?.chunks ?? 1;
    this.post = init?.post;
    this.fileField = init?.fileField ?? '';
    this.mimeType = init?.mimeType ?? '';
    this.fields = init?.fields ?? new collections.Map<string, string>();
    this.directory = init?.directory ?? '';
    const baseDirectoryValue = init?.baseDirectory;
    if (typeof baseDirectoryValue === 'number' && BaseDirectory[baseDirectoryValue] !== undefined) {
      this.baseDirectory = baseDirectoryValue as BaseDirectory;
    } else {
      this.baseDirectory = (baseDirectoryValue as BaseDirectory | undefined) ?? BaseDirectory.applicationDocuments;
    }
    this.group = init?.group ?? '';
    const updatesValue = init?.updates;
    if (typeof updatesValue === 'number' && Updates[updatesValue] !== undefined) {
      this.updates = updatesValue as Updates;
    } else {
      this.updates = (updatesValue as Updates | undefined) ?? Updates.status;
    }
    this.requiresWiFi = init?.requiresWiFi ?? false;
    this.retries = init?.retries ?? 0;
    this.retriesRemaining = init?.retriesRemaining ?? 0;
    this.allowPause = init?.allowPause ?? false;
    this.priority = init?.priority ?? 5;
    this.metaData = init?.metaData ?? '';
    this.displayName = init?.displayName ?? '';
    this.creationTime = init?.creationTime ?? Date.now();
    this.options = TaskOptions.from(init?.options);
    this.taskType = init?.taskType ?? '';
  }

  copyWith(params?: TaskInit): Task {
    return new Task({
      taskId: params?.taskId ?? this.taskId,
      url: params?.url ?? this.url,
      urls: params?.urls ?? this.urls,
      filename: params?.filename ?? this.filename,
      headers: params?.headers ?? this.headers,
      httpRequestMethod: params?.httpRequestMethod ?? this.httpRequestMethod,
      chunks: params?.chunks ?? this.chunks,
      post: params?.post ?? this.post,
      fileField: params?.fileField ?? this.fileField,
      mimeType: params?.mimeType ?? this.mimeType,
      fields: params?.fields ?? this.fields,
      directory: params?.directory ?? this.directory,
      baseDirectory: params?.baseDirectory ?? this.baseDirectory,
      group: params?.group ?? this.group,
      updates: params?.updates ?? this.updates,
      requiresWiFi: params?.requiresWiFi ?? this.requiresWiFi,
      retries: params?.retries ?? this.retries,
      retriesRemaining: params?.retriesRemaining ?? this.retriesRemaining,
      allowPause: params?.allowPause ?? this.allowPause,
      priority: params?.priority ?? this.priority,
      metaData: params?.metaData ?? this.metaData,
      displayName: params?.displayName ?? this.displayName,
      creationTime: params?.creationTime ?? this.creationTime,
      options: params?.options ?? this.options,
      taskType: params?.taskType ?? this.taskType,
    });
  }

  providesProgressUpdates(): boolean {
    return this.updates === Updates.progress || this.updates === Updates.statusAndProgress;
  }

  providesStatusUpdates(): boolean {
    return this.updates === Updates.status || this.updates === Updates.statusAndProgress;
  }

  isDownloadTask(): boolean {
    return this.taskType === 'DownloadTask' || this.taskType === 'UriDownloadTask' ||
      this.taskType === 'ParallelDownloadTask';
  }

  isUploadTask(): boolean {
    return this.taskType === 'UploadTask' || this.taskType === 'UriUploadTask' || this.taskType === 'MultiUploadTask';
  }

  isParallelDownloadTask(): boolean {
    return this.taskType === 'ParallelDownloadTask';
  }

  private isMultiUploadTask(): boolean {
    return this.taskType === 'MultiUploadTask';
  }

  isDataTask(): boolean {
    return this.taskType === 'DataTask';
  }

  host(): string {
    try {
      const parsed = new uri.URI(this.url);
      return parsed.host;
    } catch (error) {
      console.error('Model', 'Failed to parse host from url', error);
      return '';
    }
  }
}

export interface ResumeDataInterface {
  readonly task: Task;
  readonly data: string;
  readonly requiredStartByte: number;
  readonly eTag?: string;
}

@Sendable
export class ResumeData {
  readonly task: Task;
  readonly data: string;
  readonly requiredStartByte: number;
  readonly eTag?: string;

  constructor(init: ResumeDataInterface) {
    this.task = init.task;
    this.data = init.data;
    this.requiredStartByte = init.requiredStartByte;
    this.eTag = init.eTag;
  }

  copyWith(init: Partial<ResumeDataInterface>): ResumeData {
    return new ResumeData({
      task: init.task ?? this.task,
      data: init.data ?? this.data,
      requiredStartByte: init.requiredStartByte ?? this.requiredStartByte,
      eTag: init.eTag ?? this.eTag,
    });
  }
}

export enum RequireWiFi {
  asSetByTask,
  forAllTasks,
  forNoTasks,
}

export enum TaskStatus {
  enqueued,
  running,
  complete,
  notFound,
  failed,
  canceled,
  waitingToRetry,
  paused,
}

export class TaskStatus_fun {
  static readonly nonFinal = new Set<TaskStatus>([
    TaskStatus.enqueued,
    TaskStatus.running,
    TaskStatus.waitingToRetry,
    TaskStatus.paused,
  ]);

  public static isNotFinalState(status: TaskStatus | null | undefined): boolean {
    if (status === null || status === undefined) {
      return false;
    }
    return TaskStatus_fun.nonFinal.has(status);
  }

  public static isFinalState(status: TaskStatus | null | undefined): boolean {
    return !TaskStatus_fun.isNotFinalState(status);
  }

  public static ordinal(status: TaskStatus): number {
    return status as number;
  }
}

export interface TaskStatusUpdatePara {
  readonly task: Task;
  readonly taskStatus: TaskStatus;
  readonly exception?: TaskException;
  readonly responseBody?: string;
  readonly responseStatusCode?: number;
  readonly responseHeaders?: Map<string, string>;
  readonly mimeType?: string;
  readonly charSet?: string;
}

@Sendable
export class TaskStatusUpdate {
  readonly task: Task;
  readonly taskStatus: TaskStatus;
  readonly exception?: TaskException;
  readonly responseBody?: string;
  readonly responseStatusCode?: number;
  readonly responseHeaders?: Map<string, string>;
  readonly mimeType?: string;
  readonly charSet?: string;

  constructor(params: TaskStatusUpdatePara) {
    this.task = params.task;
    this.taskStatus = params.taskStatus;
    this.exception = params.exception;
    this.responseBody = params.responseBody;
    this.responseStatusCode = params.responseStatusCode;
    this.responseHeaders = params.responseHeaders;
    this.mimeType = params.mimeType;
    this.charSet = params.charSet;
  }

  get argList(): (number | string | Map<string, string> | null)[] {
    const ordinal = TaskStatus_fun.ordinal(this.taskStatus);

    if (this.taskStatus === TaskStatus.failed) {
      return [
        ordinal,
        this.exception?.type ?? null,
        this.exception?.description ?? null,
        this.exception?.httpResponseCode ?? null,
        this.responseBody ?? null,
      ];
    }

    const isFinal = TaskStatus_fun.isFinalState(this.taskStatus);
    const includeStatusCode =
      this.taskStatus === TaskStatus.complete || this.taskStatus === TaskStatus.notFound;

    return [
      ordinal,
      isFinal ? this.responseBody ?? null : null,
      isFinal ? this.responseHeaders ?? null : null,
      includeStatusCode ? this.responseStatusCode ?? null : null,
      isFinal ? this.mimeType ?? null : null,
      isFinal ? this.charSet ?? null : null,
    ];
  }

  toString(): string {
    return `TaskStatusUpdate(task=${JSON.stringify(this.task)}, taskStatus=${this.taskStatus}, exception=${JSON.stringify(
      this.exception,
    )}, responseBody=${this.responseBody}, responseStatusCode=${this.responseStatusCode}, responseHeaders=${JSON.stringify(
      this.responseHeaders,
    )}, mimeType=${this.mimeType}, charSet=${this.charSet})`;
  }
}

export enum ExceptionType {
  general = 'TaskException',
  fileSystem = 'TaskFileSystemException',
  url = 'TaskUrlException',
  connection = 'TaskConnectionException',
  resume = 'TaskResumeException',
  httpResponse = 'TaskHttpException',
}

@Sendable
export class TaskException {
  constructor(
    readonly type: ExceptionType = ExceptionType.general,
    readonly httpResponseCode: number = -1,
    readonly description: string = '',
  ) {}
}

@Sendable
export class TaskProgressUpdate {
  constructor(
    readonly task: Task,
    readonly progress: number,
    readonly expectedFileSize: number,
  ) {}
}
