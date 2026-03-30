import { common } from '@kit.AbilityKit';
import { http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { BinaryMessenger } from '@ohos/flutter_ohos/src/main/ets/plugin/common/BinaryMessenger';
import {
  FlutterError,
  NativeHttpApiOhos,
  NativeHttpFlutterApiOhos,
  NativeHttpRequestOhos,
  NativeHttpResponseOhos,
  NativeHttpStreamHeadersOhos,
  Result,
} from './NativeHttpApiOhos.g';
import { URLSessionManager } from './URLSessionManager';

interface NativeStreamRequestState {
  request: http.HttpRequest;
  cancelled: boolean;
  responseCode?: number;
  streamEnded: boolean;
}

export class NativeHttpApiImpl extends NativeHttpApiOhos {
  private ctx?: common.Context;
  private readonly flutterApi: NativeHttpFlutterApiOhos;
  private readonly streamRequests = new Map<number, NativeStreamRequestState>();
  private readonly statusFieldNames = new Set<string>(['responseCode', 'statusCode', 'status', 'code']);

  constructor(context: common.Context, binaryMessenger: BinaryMessenger) {
    super();
    this.ctx = context;
    this.flutterApi = new NativeHttpFlutterApiOhos(binaryMessenger);
  }

  override async sendRequest(requestData: NativeHttpRequestOhos, result: Result<NativeHttpResponseOhos>): Promise<void> {
    const url = requestData.getUrl();
    if (!url || url.length === 0) {
      result.error(new FlutterError('INVALID_URL', 'invalid_url', 'Request URL is required.'));
      return;
    }

    const request = http.createHttp();
    try {
      const options = this.buildRequestOptions(requestData, false);
      URLSessionManager.applyToOptions(this.ctx, options, url);

      const response = await request.request(url, options);
      URLSessionManager.updateFromResponse(this.ctx, url, response.header as Object | undefined);
      const responseHeaders = this.toHeaderMap(response.header as Object | undefined);
      const buffer = response.result as ArrayBuffer | undefined;
      const bodyBytes = buffer ? new Uint8Array(buffer) : new Uint8Array(0);

      result.success(new NativeHttpResponseOhos(response.responseCode, responseHeaders, bodyBytes));
    } catch (error) {
      const businessError = error as BusinessError;
      const message = businessError?.message ?? `${error}`;
      result.error(new FlutterError('HTTP_REQUEST_FAILED', 'http_request_failed', message));
    } finally {
      request.destroy();
    }
  }

  override sendStreamRequest(requestId: number, requestData: NativeHttpRequestOhos, result: Result<void>): void {
    const url = requestData.getUrl();
    if (!url || url.length === 0) {
      result.error(new FlutterError('INVALID_URL', 'invalid_url', 'Request URL is required.'));
      return;
    }

    this.cancelStreamRequest(requestId);

    const request = http.createHttp();
    const state: NativeStreamRequestState = {
      request,
      cancelled: false,
      streamEnded: false,
    };
    this.streamRequests.set(requestId, state);
    this.attachStreamListeners(requestId, state, url);

    try {
      const options = this.buildRequestOptions(requestData, true);
      URLSessionManager.applyToOptions(this.ctx, options, url);

      request.requestInStream(url, options).then((statusCode: number) => {
        const current = this.streamRequests.get(requestId);
        if (!current || current.cancelled) {
          this.cleanupStreamRequest(requestId, current);
          return;
        }

        current.responseCode = statusCode;
        this.tryCompleteStreamRequest(requestId, current);
      }).catch((error: Error) => {
        this.handleStreamError(requestId, error);
      });

      result.success();
    } catch (error) {
      this.cleanupStreamRequest(requestId, state);
      const businessError = error as BusinessError;
      const message = businessError?.message ?? `${error}`;
      result.error(new FlutterError('HTTP_STREAM_START_FAILED', 'http_stream_start_failed', message));
    }
  }

  override cancelStreamRequest(requestId: number): void {
    const state = this.streamRequests.get(requestId);
    if (!state) {
      return;
    }

    state.cancelled = true;
    this.cleanupStreamRequest(requestId, state);
  }

  private buildRequestOptions(requestData: NativeHttpRequestOhos, isStreaming: boolean): http.HttpRequestOptions {
    const options: http.HttpRequestOptions = {
      method: this.toMethod(requestData.getMethod()),
      header: this.toHeaderRecord(requestData.getHeaders()),
      expectDataType: http.HttpDataType.ARRAY_BUFFER,
    };

    if (!isStreaming) {
      options.maxLimit = 100 * 1024 * 1024;
    }

    const body = requestData.getBody();
    if (body && body.length > 0) {
      options.extraData = new Uint8Array(body).buffer;
    }
    return options;
  }

  private attachStreamListeners(requestId: number, state: NativeStreamRequestState, url: string): void {
    state.request.on('headersReceive', (headerObj: Object) => {
      const current = this.streamRequests.get(requestId);
      if (!current || current.cancelled) {
        return;
      }

      URLSessionManager.updateFromResponse(this.ctx, url, headerObj);
      const headers = this.toHeaderMap(headerObj, this.statusFieldNames);
      const statusCode = this.extractStatusCode(headerObj) ?? -1;
      this.flutterApi.onStreamHeaders(
        requestId,
        new NativeHttpStreamHeadersOhos(statusCode, headers),
        { reply: () => {} },
      );
    });

    state.request.on('dataReceive', (chunk: ArrayBuffer) => {
      const current = this.streamRequests.get(requestId);
      if (!current || current.cancelled || chunk.byteLength === 0) {
        return;
      }

      const chunkBytes = new Uint8Array(chunk);
      this.flutterApi.onStreamData(
        requestId,
        chunkBytes,
        { reply: () => {} },
      );
    });

    state.request.on('dataEnd', () => {
      const current = this.streamRequests.get(requestId);
      if (!current || current.cancelled) {
        return;
      }

      current.streamEnded = true;
      this.tryCompleteStreamRequest(requestId, current);
    });
  }

  private tryCompleteStreamRequest(requestId: number, state?: NativeStreamRequestState): void {
    const current = state ?? this.streamRequests.get(requestId);
    if (!current || current.cancelled || !current.streamEnded || current.responseCode === undefined) {
      return;
    }

    this.flutterApi.onStreamComplete(requestId, current.responseCode, { reply: () => {} });
    this.cleanupStreamRequest(requestId, current);
  }

  private handleStreamError(requestId: number, error: Error): void {
    const state = this.streamRequests.get(requestId);
    if (!state || state.cancelled) {
      this.cleanupStreamRequest(requestId, state);
      return;
    }

    const businessError = error as BusinessError;
    const message = businessError?.message ?? `${error}`;
    this.flutterApi.onStreamError(requestId, 'HTTP_STREAM_FAILED', message, { reply: () => {} });
    this.cleanupStreamRequest(requestId, state);
  }

  private cleanupStreamRequest(requestId: number, state?: NativeStreamRequestState): void {
    const current = state ?? this.streamRequests.get(requestId);
    if (!current) {
      return;
    }

    this.streamRequests.delete(requestId);
    try {
      current.request.off('headersReceive');
    } catch (_) {}
    try {
      current.request.off('dataReceive');
    } catch (_) {}
    try {
      current.request.off('dataEnd');
    } catch (_) {}
    try {
      current.request.destroy();
    } catch (_) {}
  }

  private toMethod(method?: string): http.RequestMethod {
    return ((method ?? 'GET').toUpperCase()) as http.RequestMethod;
  }

  private toHeaderRecord(headers?: Map<string, string>): Record<string, string> {
    const record: Record<string, string> = {};
    if (!headers) {
      return record;
    }

    headers.forEach((value: string, key: string) => {
      if (key) {
        record[key] = value ?? '';
      }
    });

    return record;
  }

  private toHeaderMap(headers?: Object, excludedKeys?: Set<string>): Map<string, string> {
    const result = new Map<string, string>();
    if (!headers || typeof headers !== 'object') {
      return result;
    }

    if (headers instanceof Map) {
      headers.forEach((value: Object, key: string) => {
        if (!key || excludedKeys?.has(key)) {
          return;
        }

        const normalizedValue = this.toHeaderValue(value);
        if (normalizedValue !== undefined) {
          result.set(key, normalizedValue);
        }
      });
      return result;
    }

    const record = headers as Record<string, Object>;
    Object.keys(record).forEach((key) => {
      if (excludedKeys?.has(key)) {
        return;
      }

      const normalizedValue = this.toHeaderValue(record[key]);
      if (normalizedValue !== undefined) {
        result.set(key, normalizedValue);
      }
    });
    return result;
  }

  private toHeaderValue(value?: Object): string | undefined {
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

  private extractStatusCode(payload?: Object): number | undefined {
    if (!payload || typeof payload !== 'object') {
      return undefined;
    }

    const record = payload as Record<string, Object>;
    for (const key of this.statusFieldNames) {
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
}
