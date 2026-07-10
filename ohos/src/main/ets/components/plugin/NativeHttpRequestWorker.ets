import { common, sendableContextManager } from '@kit.AbilityKit';
import { ErrorEvent, MessageEvents, ThreadWorkerGlobalScope, util, worker } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { http } from '@kit.NetworkKit';
import { NativeHttpRequestCommand } from './NativeHttpRequestWorkerModels';
import { URLSessionManager } from './URLSessionManager';

const workerPort: ThreadWorkerGlobalScope = worker.workerPort;
const STATUS_FIELD_NAMES = new Set<string>(['responseCode', 'statusCode', 'status', 'code']);

let currentRequest: http.HttpRequest | undefined;

interface PlainNativeHttpRequestJson {
  method?: string;
  url?: string;
  headers?: Record<string, string>;
  bodyBase64?: string;
  connectTimeoutMs?: number;
  readTimeoutMs?: number;
}

interface RequestSuccessWorkerMessage {
  command: string;
  requestId: number;
  statusCode: number;
  headers: Record<string, string>;
  body: Uint8Array;
}

interface RequestErrorWorkerMessage {
  command: string;
  requestId: number;
  code: string;
  name: string;
  message: string;
}

interface StreamHeadersWorkerMessage {
  command: string;
  requestId: number;
  statusCode: number;
  headers: Record<string, string>;
}

interface StreamDataWorkerMessage {
  command: string;
  requestId: number;
  chunk: Uint8Array;
}

interface StreamCompleteWorkerMessage {
  command: string;
  requestId: number;
  statusCode: number;
}

interface StreamErrorWorkerMessage {
  command: string;
  requestId: number;
  code: string;
  message: string;
}

interface StreamState {
  requestId: number;
  responseCode?: number;
  streamEnded: boolean;
  completed: boolean;
}

workerPort.onmessage = async (event: MessageEvents) => {
  const command = event.data as NativeHttpRequestCommand;
  if (command.command === 'stream') {
    await runStreamRequest(command);
    return;
  }
  await runSingleRequest(command);
};

workerPort.onmessageerror = () => {
  console.error('[NativeHttpRequestWorker] workerPort onmessageerror');
};

workerPort.onerror = (error: ErrorEvent) => {
  try {
    const message = error.message ?? `${error}`;
    console.error(`[NativeHttpRequestWorker] workerPort onerror: ${message}`);
    try {
      currentRequest?.destroy();
    } catch (destroyError) {
      console.error(`[NativeHttpRequestWorker] workerPort onerror destroy failed: ${destroyError}`);
    }
    currentRequest = undefined;
  } catch (handlerError) {
    console.error(`[NativeHttpRequestWorker] workerPort onerror handler failed: ${handlerError}`);
  }
};

async function runSingleRequest(command: NativeHttpRequestCommand): Promise<void> {
  const requestData = parseWorkerRequest(command);
  if (!requestData) {
    return;
  }

  const appContext = sendableContextManager.convertToApplicationContext(command.sendableAppContext);
  if (!appContext) {
    postRequestError(command.requestId, 'INVALID_CONTEXT', 'invalid_context', 'Application context is required.');
    return;
  }

  const url = requestData.url;
  if (!url || url.length === 0) {
    postRequestError(command.requestId, 'INVALID_URL', 'invalid_url', 'Request URL is required.');
    return;
  }

  const request = http.createHttp();
  currentRequest = request;
  let tlsDiagnostics = 'caPathConfigured=false,clientCertConfigured=false';
  try {
    const options = buildRequestOptions(requestData, false);
    console.info(`[NativeHttpRequestWorker] filesDir=${appContext.filesDir} url=${url}`);
    URLSessionManager.applyToOptions(appContext, options, url);
    tlsDiagnostics =
      `caPathConfigured=${options.caPath !== undefined},` +
      `clientCertConfigured=${options.clientCert !== undefined}`;

    const response = await request.request(url, options);
    URLSessionManager.updateFromResponse(appContext, url, response.header as Object | undefined);
    const responseHeaders = toHeaderRecord(response.header as Object | undefined);
    const buffer = response.result as ArrayBuffer | undefined;
    const bodyBytes = buffer ? new Uint8Array(buffer) : new Uint8Array(0);
    const successMessage: RequestSuccessWorkerMessage = {
      command: 'requestSuccess',
      requestId: command.requestId,
      statusCode: response.responseCode,
      headers: responseHeaders,
      body: bodyBytes,
    };
    safePostMessage(successMessage as Object);
  } catch (error) {
    const message = logWorkerError('sendRequest', command.requestId, error as Object, tlsDiagnostics);
    postRequestError(command.requestId, 'HTTP_REQUEST_FAILED', 'http_request_failed', message);
  } finally {
    try {
      request.destroy();
    } catch (_) {}
    currentRequest = undefined;
  }
}

async function runStreamRequest(command: NativeHttpRequestCommand): Promise<void> {
  const requestData = parseWorkerRequest(command);
  if (!requestData) {
    return;
  }

  const appContext = sendableContextManager.convertToApplicationContext(command.sendableAppContext);
  if (!appContext) {
    postStreamError(command.requestId, 'INVALID_CONTEXT', 'Application context is required.');
    return;
  }

  const url = requestData.url;
  if (!url || url.length === 0) {
    postStreamError(command.requestId, 'INVALID_URL', 'Request URL is required.');
    return;
  }

  const request = http.createHttp();
  currentRequest = request;
  const streamState: StreamState = {
    requestId: command.requestId,
    streamEnded: false,
    completed: false,
  };

  request.on('headersReceive', (headerObj: Object) => {
    URLSessionManager.updateFromResponse(appContext, url, headerObj);
    const headersMessage: StreamHeadersWorkerMessage = {
      command: 'streamHeaders',
      requestId: command.requestId,
      statusCode: extractStatusCode(headerObj) ?? -1,
      headers: toHeaderRecord(headerObj, STATUS_FIELD_NAMES),
    };
    safePostMessage(headersMessage as Object);
  });

  request.on('dataReceive', (chunk: ArrayBuffer) => {
    if (chunk.byteLength === 0) {
      return;
    }
    const dataMessage: StreamDataWorkerMessage = {
      command: 'streamData',
      requestId: command.requestId,
      chunk: new Uint8Array(chunk),
    };
    safePostMessage(dataMessage as Object);
  });

  request.on('dataEnd', () => {
    streamState.streamEnded = true;
    tryCompleteStream(streamState);
  });

  try {
    const options = buildRequestOptions(requestData, true);
    console.info(`[NativeHttpRequestWorker] stream filesDir=${appContext.filesDir} url=${url}`);
    URLSessionManager.applyToOptions(appContext, options, url);
    streamState.responseCode = await request.requestInStream(url, options);
    tryCompleteStream(streamState);
  } catch (error) {
    const message = logWorkerError('sendStreamRequest', command.requestId, error as Object);
    postStreamError(command.requestId, 'HTTP_STREAM_FAILED', message);
  } finally {
    cleanupRequest(request);
    currentRequest = undefined;
  }
}

function tryCompleteStream(streamState: StreamState): void {
  if (streamState.completed || !streamState.streamEnded || streamState.responseCode === undefined) {
    return;
  }
  streamState.completed = true;
  const completeMessage: StreamCompleteWorkerMessage = {
    command: 'streamComplete',
    requestId: streamState.requestId,
    statusCode: streamState.responseCode,
  };
  safePostMessage(completeMessage as Object);
}

function cleanupRequest(request: http.HttpRequest): void {
  try {
    request.off('headersReceive');
  } catch (_) {}
  try {
    request.off('dataReceive');
  } catch (_) {}
  try {
    request.off('dataEnd');
  } catch (_) {}
  try {
    request.destroy();
  } catch (_) {}
}

function buildRequestOptions(requestData: PlainNativeHttpRequestJson, isStreaming: boolean): http.HttpRequestOptions {
  const options: http.HttpRequestOptions = {
    method: toMethod(requestData.method),
    header: requestData.headers ?? emptyHeaderRecord(),
    expectDataType: http.HttpDataType.ARRAY_BUFFER,
  };

  if (!isStreaming) {
    options.maxLimit = 100 * 1024 * 1024;
  }
  if (requestData.connectTimeoutMs !== undefined && requestData.connectTimeoutMs > 0) {
    options.connectTimeout = requestData.connectTimeoutMs;
  }
  if (requestData.readTimeoutMs !== undefined && requestData.readTimeoutMs > 0) {
    options.readTimeout = requestData.readTimeoutMs;
  }
  if (requestData.bodyBase64 && requestData.bodyBase64.length > 0) {
    const bodyBytes = new util.Base64Helper().decodeSync(requestData.bodyBase64);
    options.extraData = bodyBytes.buffer.slice(bodyBytes.byteOffset, bodyBytes.byteOffset + bodyBytes.byteLength);
  }
  return options;
}

function toMethod(method?: string): http.RequestMethod {
  return ((method ?? 'GET').toUpperCase()) as http.RequestMethod;
}

function parseWorkerRequest(command: NativeHttpRequestCommand): PlainNativeHttpRequestJson | undefined {
  try {
    return JSON.parse(command.requestJson) as PlainNativeHttpRequestJson;
  } catch (error) {
    const message = logWorkerError('parseWorkerRequest', command.requestId, error as Object);
    postRequestError(command.requestId, 'INVALID_REQUEST', 'invalid_request', message);
    return undefined;
  }
}

function postRequestError(requestId: number, code: string, name: string, message: string): void {
  const errorMessage: RequestErrorWorkerMessage = {
    command: 'requestError',
    requestId: requestId,
    code: code,
    name: name,
    message: message,
  };
  safePostMessage(errorMessage as Object);
}

function postStreamError(requestId: number, code: string, message: string): void {
  const errorMessage: StreamErrorWorkerMessage = {
    command: 'streamError',
    requestId: requestId,
    code: code,
    message: message,
  };
  safePostMessage(errorMessage as Object);
}

function logWorkerError(stage: string, requestId: number, error: Object, diagnostics?: string): string {
  const businessError = error as BusinessError;
  const code = businessError?.code !== undefined ? `${businessError.code}` : 'unknown';
  const name = businessError?.name ?? 'unknown';
  const message = businessError?.message ?? `${error}`;
  const suffix = diagnostics && diagnostics.length > 0 ? `; ${diagnostics}` : '';
  const details = `${code}:${name}:${message}${suffix}`;
  console.error(`[NativeHttpRequestWorker] ${stage}[${requestId}] failed: ${details}`);
  return details;
}

function safePostMessage(payload: Object): boolean {
  try {
    workerPort.postMessage(payload);
    return true;
  } catch (error) {
    console.error(`[NativeHttpRequestWorker] postMessage failed: ${error}`);
    return false;
  }
}

function emptyHeaderRecord(): Record<string, string> {
  const headers: Record<string, string> = {};
  return headers;
}

function toHeaderRecord(headers?: Object, excludedKeys?: Set<string>): Record<string, string> {
  const result: Record<string, string> = {};
  if (!headers || typeof headers !== 'object') {
    return result;
  }

  if (headers instanceof Map) {
    headers.forEach((value: Object, key: string) => {
      if (!key || excludedKeys?.has(key)) {
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
    if (excludedKeys?.has(key)) {
      return;
    }
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

function extractStatusCode(payload?: Object): number | undefined {
  if (!payload || typeof payload !== 'object') {
    return undefined;
  }

  const record = payload as Record<string, Object>;
  for (const key of STATUS_FIELD_NAMES) {
    const value = record[key];
    if (typeof value === 'number') {
      return value;
    }
    if (typeof value === 'string') {
      const parsed = Number.parseInt(value, 10);
      if (!Number.isNaN(parsed)) {
        return parsed;
      }
    }
  }

  return undefined;
}
