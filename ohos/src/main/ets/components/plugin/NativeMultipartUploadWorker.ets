import { common, sendableContextManager } from '@kit.AbilityKit';
import { ErrorEvent, MessageEvents, ThreadWorkerGlobalScope, util, worker } from '@kit.ArkTS';
import { BusinessError, request } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { http } from '@kit.NetworkKit';
import { NativeMultipartUploadCommand } from './NativeMultipartUploadWorkerModels';
import { URLSessionManager } from './URLSessionManager';

const workerPort: ThreadWorkerGlobalScope = worker.workerPort;
const LARGE_FILE_THRESHOLD = 2 * 1024 * 1024 * 1024;

let currentRequest: http.HttpRequest | undefined;

interface PlainNativeMultipartRequestJson {
  method?: string;
  url?: string;
  headers?: Record<string, string>;
  fields?: Record<string, string>;
  fileFieldName?: string;
  filePath?: string;
  fileName?: string;
  contentType?: string;
  connectTimeoutMs?: number;
  readTimeoutMs?: number;
}

interface ProgressUpdateWorkerMessage {
  command: string;
  requestId: number;
  bytesSent: number;
  totalBytes: number;
}

interface MultipartSuccessWorkerMessage {
  command: string;
  requestId: number;
  statusCode: number;
  headers: Record<string, string>;
  body: string;
}

interface MultipartErrorWorkerMessage {
  command: string;
  requestId: number;
  code: string;
  name: string;
  message: string;
}

workerPort.onmessage = async (event: MessageEvents) => {
  const command = event.data as NativeMultipartUploadCommand;
  await runMultipartUpload(command);
};

workerPort.onmessageerror = () => {
  console.error('[NativeMultipartUploadWorker] workerPort onmessageerror');
};

workerPort.onerror = (error: ErrorEvent) => {
  try {
    const message = error.message ?? `${error}`;
    console.error(`[NativeMultipartUploadWorker] workerPort onerror: ${message}`);
    try {
      currentRequest?.destroy();
    } catch (destroyError) {
      console.error(`[NativeMultipartUploadWorker] workerPort onerror destroy failed: ${destroyError}`);
    }
    currentRequest = undefined;
  } catch (handlerError) {
    console.error(`[NativeMultipartUploadWorker] workerPort onerror handler failed: ${handlerError}`);
  }
};

async function runMultipartUpload(command: NativeMultipartUploadCommand): Promise<void> {
  const requestData = parseMultipartWorkerRequest(command);
  if (!requestData) {
    return;
  }

  const appContext = sendableContextManager.convertToApplicationContext(command.sendableAppContext);
  if (!appContext) {
    postError(command.requestId, 'INVALID_CONTEXT', 'invalid_context', 'Application context is required.');
    return;
  }

  const url = requestData.url;
  if (!url || url.length === 0) {
    postError(command.requestId, 'INVALID_URL', 'invalid_url', 'Request URL is required.');
    return;
  }

  const filePath = requestData.filePath;
  if (!filePath || filePath.length === 0) {
    postError(command.requestId, 'INVALID_FILE_PATH', 'invalid_file_path', 'File path is required.');
    return;
  }

  let stat: fs.Stat;
  try {
    stat = fs.statSync(filePath);
  } catch (error) {
    logWorkerError('statSync', command.requestId, error as Object);
    postError(command.requestId, 'FILE_NOT_FOUND', 'file_not_found', `File does not exist: ${filePath}`);
    return;
  }
  let isRegularFile = false;
  try {
    isRegularFile = stat.isFile();
  } catch (error) {
    const message = logWorkerError('stat.isFile', command.requestId, error as Object);
    postError(command.requestId, 'FILE_STAT_FAILED', 'file_stat_failed', message);
    return;
  }
  if (!isRegularFile) {
    postError(command.requestId, 'NOT_A_FILE', 'not_a_file', `Not a regular file: ${filePath}`);
    return;
  }
  if (stat.size >= LARGE_FILE_THRESHOLD) {
    await runLargeFileUpload(command, requestData, appContext, url, filePath);
    return;
  }

  await runNetworkKitMultipartUpload(command, requestData, appContext, url, filePath, stat);
}

async function runNetworkKitMultipartUpload(
  command: NativeMultipartUploadCommand,
  requestData: PlainNativeMultipartRequestJson,
  appContext: common.Context,
  url: string,
  filePath: string,
  stat: fs.Stat,
): Promise<void> {
  const methodStr = (requestData.method && requestData.method.length > 0 ? requestData.method : 'POST').toUpperCase();
  const method = methodStr === 'PUT' ? http.RequestMethod.PUT : http.RequestMethod.POST;

  const headers = requestData.headers ?? emptyHeaderRecord();
  headers['Content-Type'] = 'multipart/form-data';

  const formParts: Array<http.MultiFormData> = [];
  const fields = requestData.fields ?? emptyHeaderRecord();
  Object.keys(fields).forEach((key) => {
    formParts.push({
      name: key,
      contentType: 'text/plain',
      data: `${fields[key]}`,
      remoteFileName: undefined,
    });
  });

  const fileFieldName = requestData.fileFieldName && requestData.fileFieldName.length > 0
    ? requestData.fileFieldName
    : 'file';
  const contentType = requestData.contentType && requestData.contentType.length > 0
    ? requestData.contentType
    : 'application/octet-stream';
  const fileName = requestData.fileName && requestData.fileName.length > 0
    ? requestData.fileName
    : 'upload';
  formParts.push({
    name: fileFieldName,
    contentType: contentType,
    filePath: filePath,
    remoteFileName: fileName,
  });

  const options: http.HttpRequestOptions = {
    method: method,
    header: headers,
    multiFormDataList: formParts,
  };
  if (requestData.connectTimeoutMs !== undefined && requestData.connectTimeoutMs > 0) {
    options.connectTimeout = requestData.connectTimeoutMs;
  }
  URLSessionManager.applyToOptions(appContext, options, url);

  const httpRequest = http.createHttp();
  currentRequest = httpRequest;
  httpRequest.on('dataSendProgress', (info: http.DataSendProgressInfo) => {
    const sent = info.sendSize ?? 0;
    const total = info.totalSize ?? stat.size;
    if (total <= 0) {
      return;
    }
    const progressMessage: ProgressUpdateWorkerMessage = {
      command: 'progressUpdate',
      requestId: command.requestId,
      bytesSent: sent,
      totalBytes: total,
    };
    safePostMessage(progressMessage as Object);
  });

  let responseStatusCode = -1;
  let responseHeaders: Record<string, string> = emptyHeaderRecord();
  const responseChunks: ArrayBuffer[] = [];

  httpRequest.on('headersReceive', (header: Object) => {
    responseHeaders = toHeaderRecord(header);
  });

  httpRequest.on('dataReceive', (data: ArrayBuffer) => {
    responseChunks.push(data);
  });

  try {
    const streamDone = new Promise<void>((resolve) => {
      httpRequest.on('dataEnd', () => {
        resolve();
      });
    });

    responseStatusCode = await httpRequest.requestInStream(url, options);
    await streamDone;

    URLSessionManager.updateFromResponse(appContext, url, responseHeaders as Object | undefined);

    let bodyStr = '';
    if (responseChunks.length > 0) {
      const decoder = new util.TextDecoder('utf-8');
      for (const chunk of responseChunks) {
        bodyStr += decoder.decodeWithStream(new Uint8Array(chunk), { stream: true });
      }
      bodyStr += decoder.decodeWithStream(new Uint8Array(0), { stream: false });
    }

    const successMessage: MultipartSuccessWorkerMessage = {
      command: 'success',
      requestId: command.requestId,
      statusCode: responseStatusCode,
      headers: responseHeaders,
      body: bodyStr,
    };
    safePostMessage(successMessage as Object);
  } catch (error) {
    const message = logWorkerError('sendMultipartRequest', command.requestId, error as Object);
    postError(command.requestId, 'HTTP_MULTIPART_FAILED', 'http_multipart_failed', message);
  } finally {
    try {
      httpRequest.off('headersReceive');
    } catch (_) {}
    try {
      httpRequest.off('dataReceive');
    } catch (_) {}
    try {
      httpRequest.off('dataEnd');
    } catch (_) {}
    try {
      httpRequest.off('dataSendProgress');
    } catch (_) {}
    try {
      httpRequest.destroy();
    } catch (_) {}
    currentRequest = undefined;
  }
}

async function runLargeFileUpload(
  command: NativeMultipartUploadCommand,
  requestData: PlainNativeMultipartRequestJson,
  appContext: common.Context,
  url: string,
  filePath: string,
): Promise<void> {
  const fileFieldName = requestData.fileFieldName && requestData.fileFieldName.length > 0
    ? requestData.fileFieldName
    : 'file';
  const contentType = requestData.contentType && requestData.contentType.length > 0
    ? requestData.contentType
    : 'application/octet-stream';
  const fileName = requestData.fileName && requestData.fileName.length > 0
    ? requestData.fileName
    : 'upload';
  const methodStr = (requestData.method && requestData.method.length > 0
    ? requestData.method
    : 'POST').toUpperCase();

  const files: Array<request.File> = [{
    filename: fileName,
    name: fileFieldName,
    uri: filePath,
    type: contentType,
  }];

  const data: Array<request.RequestData> = [];
  const fields = requestData.fields ?? emptyHeaderRecord();
  Object.keys(fields).forEach((key) => {
    data.push({ name: key, value: `${fields[key]}` });
  });

  const uploadHeaders: Record<string, string> = {};
  const requestHeaders = requestData.headers ?? emptyHeaderRecord();
  Object.keys(requestHeaders).forEach((key) => {
    if (key.toLowerCase() !== 'content-type') {
      uploadHeaders[key] = requestHeaders[key];
    }
  });
  const tempOptions: http.HttpRequestOptions = {
    method: http.RequestMethod.POST,
    header: uploadHeaders,
  };
  URLSessionManager.applyToOptions(appContext, tempOptions, url);

  const config: request.UploadConfig = {
    url: url,
    header: tempOptions.header as Record<string, string>,
    method: methodStr,
    files: files,
    data: data,
  };

  let uploadTask: request.UploadTask;
  try {
    uploadTask = await request.uploadFile(appContext, config);
  } catch (error) {
    logWorkerError('uploadFile', command.requestId, error as Object);
    postError(
      command.requestId,
      'UPLOAD_TASK_CREATE_FAILED',
      'upload_task_create_failed',
      `Failed to create upload task: ${(error as BusinessError)?.message ?? error}`,
    );
    return;
  }

  let responseHeaders: Record<string, string> = emptyHeaderRecord();

  uploadTask.on('progress', (uploadedSize: number, totalSize: number) => {
    if (totalSize <= 0) {
      return;
    }
    const progressMessage: ProgressUpdateWorkerMessage = {
      command: 'progressUpdate',
      requestId: command.requestId,
      bytesSent: uploadedSize,
      totalBytes: totalSize,
    };
    safePostMessage(progressMessage as Object);
  });

  uploadTask.on('headerReceive', (header: Object) => {
    responseHeaders = toHeaderRecord(header);
  });

  await new Promise<void>((resolve) => {
    uploadTask.on('complete', (taskStates: Array<request.TaskState>) => {
      const taskState = taskStates.length > 0 ? taskStates[0] : undefined;
      const statusCode = taskState?.responseCode ?? 200;
      const bodyStr = taskState?.message ?? '';

      URLSessionManager.updateFromResponse(appContext, url, responseHeaders as Object);

      const successMessage: MultipartSuccessWorkerMessage = {
        command: 'success',
        requestId: command.requestId,
        statusCode: statusCode,
        headers: responseHeaders,
        body: bodyStr,
      };
      safePostMessage(successMessage as Object);
      resolve();
    });

    uploadTask.on('fail', (taskStates: Array<request.TaskState>) => {
      const taskState = taskStates.length > 0 ? taskStates[0] : undefined;
      const statusCode = taskState?.responseCode ?? -1;
      const message = taskState?.message ?? 'Upload failed';

      console.error(
        `[NativeMultipartUploadWorker] sendMultipartRequest[${command.requestId}] uploadFile FAILED, status=${statusCode}, msg=${message}`,
      );
      postError(
        command.requestId,
        'HTTP_MULTIPART_FAILED',
        'http_multipart_failed',
        `Large file upload failed (status ${statusCode}): ${message}`,
      );
      resolve();
    });
  });

  try {
    uploadTask.off('progress');
  } catch (_) {}
  try {
    uploadTask.off('headerReceive');
  } catch (_) {}
  try {
    uploadTask.off('complete');
  } catch (_) {}
  try {
    uploadTask.off('fail');
  } catch (_) {}
  try {
    uploadTask.delete();
  } catch (_) {}
}

function postError(requestId: number, code: string, name: string, message: string): void {
  const errorMessage: MultipartErrorWorkerMessage = {
    command: 'error',
    requestId: requestId,
    code: code,
    name: name,
    message: message,
  };
  safePostMessage(errorMessage as Object);
}

function logWorkerError(stage: string, requestId: number, error: Object): string {
  const businessError = error as BusinessError;
  const code = businessError?.code !== undefined ? `${businessError.code}` : 'unknown';
  const name = businessError?.name ?? 'unknown';
  const message = businessError?.message ?? `${error}`;
  console.error(`[NativeMultipartUploadWorker] ${stage}[${requestId}] failed, code=${code}, name=${name}, message=${message}`);
  return message;
}

function safePostMessage(payload: Object): boolean {
  try {
    workerPort.postMessage(payload);
    return true;
  } catch (error) {
    console.error(`[NativeMultipartUploadWorker] postMessage failed: ${error}`);
    return false;
  }
}

function emptyHeaderRecord(): Record<string, string> {
  const headers: Record<string, string> = {};
  return headers;
}

function parseMultipartWorkerRequest(command: NativeMultipartUploadCommand): PlainNativeMultipartRequestJson | undefined {
  try {
    return JSON.parse(command.requestJson) as PlainNativeMultipartRequestJson;
  } catch (error) {
    const message = logWorkerError('parseMultipartWorkerRequest', command.requestId, error as Object);
    postError(command.requestId, 'INVALID_REQUEST', 'invalid_request', message);
    return undefined;
  }
}

function toHeaderRecord(headers?: Object): Record<string, string> {
  const result: Record<string, string> = {};
  if (!headers || typeof headers !== 'object') {
    return result;
  }

  if (headers instanceof Map) {
    headers.forEach((value: Object, key: string) => {
      if (!key) {
        return;
      }
      const normalizedValue = toHeaderValue(value);
      if (normalizedValue !== undefined) {
        result[key] = normalizedValue;
      }
    });
    return result;
  }

  const record = headers as Record<string, Object>;
  Object.keys(record).forEach((key) => {
    const normalizedValue = toHeaderValue(record[key]);
    if (normalizedValue !== undefined) {
      result[key] = normalizedValue;
    }
  });
  return result;
}

function toHeaderValue(value?: Object): string | undefined {
  if (value === undefined || value === null) {
    return undefined;
  }

  if (value instanceof Array) {
    return value
      .filter((item: Object) => item !== undefined && item !== null)
      .map((item: Object) => `${item}`)
      .join(', ');
  }

  return `${value}`;
}
