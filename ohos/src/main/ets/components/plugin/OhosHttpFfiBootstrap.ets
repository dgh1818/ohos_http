import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { http } from '@kit.NetworkKit';
import ohosHttpFfi from 'libohos_http_ffi.so';

import { URLSessionManager } from './URLSessionManager';

const OHOS_HTTP_FFI_LIBCURL_ENABLED = 1 << 2;

interface OhosHttpFfiRequest {
  requestId: number;
  dartPort: number;
  method: string;
  url: string;
  headersJson: string;
  body?: Uint8Array;
  connectTimeoutMs?: number;
  readTimeoutMs?: number;
}

interface OhosHttpFfiModule {
  libraryVersion(): number;
  bootstrapState(): number;
  ping(): number;
  installRequestDispatcher(handler: (request: OhosHttpFfiRequest) => void): void;
  completeRequest(requestId: number, dartPort: number, statusCode: number, headersJson: string, body: Uint8Array): void;
  failRequest(requestId: number, dartPort: number, code: string, message: string): void;
}

const module = ohosHttpFfi as OhosHttpFfiModule;
let requestDispatcherInstalled = false;

export function ensureOhosHttpFfiBootstrap(context: common.Context): void {
  const bootstrapState = module.bootstrapState();
  const requiresArkTsDispatcher = (bootstrapState & OHOS_HTTP_FFI_LIBCURL_ENABLED) === 0;
  if (requiresArkTsDispatcher && !requestDispatcherInstalled) {
    module.installRequestDispatcher((request: OhosHttpFfiRequest) => {
      void handleFfiRequest(context, request);
    });
    requestDispatcherInstalled = true;
  }
  module.ping();
}

async function handleFfiRequest(context: common.Context, request: OhosHttpFfiRequest): Promise<void> {
  const client = http.createHttp();
  try {
    const options = buildRequestOptions(request);
    URLSessionManager.applyToOptions(context, options, request.url);
    const response = await client.request(request.url, options);
    URLSessionManager.updateFromResponse(context, request.url, response.header as Object | undefined);

    const bodyBuffer = response.result as ArrayBuffer | undefined;
    const body = bodyBuffer ? new Uint8Array(bodyBuffer) : new Uint8Array(0);
    module.completeRequest(
      request.requestId,
      request.dartPort,
      response.responseCode,
      JSON.stringify(toHeaderRecord(response.header as Object | undefined)),
      body,
    );
  } catch (error) {
    module.failRequest(
      request.requestId,
      request.dartPort,
      'HTTP_REQUEST_FAILED',
      formatFfiError(error as Object),
    );
  } finally {
    try {
      client.destroy();
    } catch (_) {}
  }
}

function buildRequestOptions(request: OhosHttpFfiRequest): http.HttpRequestOptions {
  const options: http.HttpRequestOptions = {
    method: toMethod(request.method),
    header: parseHeaderJson(request.headersJson),
    expectDataType: http.HttpDataType.ARRAY_BUFFER,
    maxLimit: 100 * 1024 * 1024,
  };

  if (request.body && request.body.byteLength > 0) {
    options.extraData = request.body.buffer;
  }
  if (request.connectTimeoutMs !== undefined && request.connectTimeoutMs > 0) {
    options.connectTimeout = request.connectTimeoutMs;
  }
  if (request.readTimeoutMs !== undefined && request.readTimeoutMs > 0) {
    options.readTimeout = request.readTimeoutMs;
  }
  return options;
}

function parseHeaderJson(headersJson: string): Record<string, string> {
  if (!headersJson || headersJson.length === 0) {
    return emptyHeaderRecord();
  }

  try {
    return toHeaderRecord(JSON.parse(headersJson) as Object);
  } catch (_) {
    return emptyHeaderRecord();
  }
}

function emptyHeaderRecord(): Record<string, string> {
  const headers: Record<string, string> = {};
  return headers;
}

function toMethod(method?: string): http.RequestMethod {
  return ((method ?? 'GET').toUpperCase()) as http.RequestMethod;
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

function formatFfiError(error: Object): string {
  const businessError = error as BusinessError;
  const code = businessError?.code !== undefined ? `${businessError.code}` : 'unknown';
  const name = businessError?.name ?? 'unknown';
  const message = businessError?.message ?? `${error}`;
  return `${code}:${name}:${message}`;
}