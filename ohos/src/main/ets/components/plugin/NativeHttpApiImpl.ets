import { common, sendableContextManager } from '@kit.AbilityKit';
import { ErrorEvent, MessageEvents, util, worker } from '@kit.ArkTS';
import { BinaryMessenger } from '@ohos/flutter_ohos/src/main/ets/plugin/common/BinaryMessenger';
import {
  FlutterError,
  NativeHttpApiOhos,
  NativeHttpFlutterApiOhos,
  NativeHttpMultipartRequestOhos,
  NativeHttpRequestOhos,
  NativeHttpResponseOhos,
  NativeHttpStreamHeadersOhos,
  Result,
} from './NativeHttpApiOhos.g';
import { NativeHttpRequestCommand } from './NativeHttpRequestWorkerModels';
import { NativeMultipartUploadCommand } from './NativeMultipartUploadWorkerModels';

interface NativeSingleRequestState {
  worker: worker.ThreadWorker;
  result: Result<NativeHttpResponseOhos>;
}

interface NativeStreamRequestState {
  worker: worker.ThreadWorker;
  cancelled: boolean;
}

interface NativeMultipartRequestState {
  worker: worker.ThreadWorker;
  cancelled: boolean;
  result: Result<NativeHttpResponseOhos>;
}

export class NativeHttpApiImpl extends NativeHttpApiOhos {
  private readonly sendableContext?: sendableContextManager.SendableContext;
  private readonly flutterApi: NativeHttpFlutterApiOhos;
  private readonly singleRequests = new Map<number, NativeSingleRequestState>();
  private readonly streamRequests = new Map<number, NativeStreamRequestState>();
  private readonly multipartRequests = new Map<number, NativeMultipartRequestState>();
  private nextRequestId = 1;

  constructor(context: common.Context, binaryMessenger: BinaryMessenger) {
    super();
    this.sendableContext = sendableContextManager.convertFromContext(context);
    this.flutterApi = new NativeHttpFlutterApiOhos(binaryMessenger);
  }

  override sendRequest(requestData: NativeHttpRequestOhos, result: Result<NativeHttpResponseOhos>): void {
    const url = requestData.getUrl();
    if (!url || url.length === 0) {
      result.error(new FlutterError('INVALID_URL', 'invalid_url', 'Request URL is required.'));
      return;
    }

    if (!this.sendableContext) {
      result.error(new FlutterError('INVALID_CONTEXT', 'invalid_context', 'Application context is required.'));
      return;
    }

    const requestId = this.nextRequestId++;
    const t0 = Date.now();

    const requestWorker = new worker.ThreadWorker('./NativeHttpRequestWorker.ets');
    const state: NativeSingleRequestState = { worker: requestWorker, result: result };
    this.singleRequests.set(requestId, state);

    requestWorker.onmessage = (event: MessageEvents) => {
      this.handleSingleRequestWorkerMessage(requestId, event.data as Object, t0);
    };
    requestWorker.onerror = (error: ErrorEvent) => {
      const message = error?.message ?? 'Unknown worker error';
      console.error(`[NativeHttpApi] sendRequest[${requestId}] WORKER_ERROR: ${message}, +${Date.now() - t0}ms`);
      this.finishSingleRequestError(requestId, 'HTTP_REQUEST_WORKER_FAILED', 'http_request_worker_failed', message);
    };
    requestWorker.onexit = (code: number) => {
      if (!this.singleRequests.has(requestId)) {
        return;
      }
      const message = `Request worker exited with code ${code}.`;
      console.error(`[NativeHttpApi] sendRequest[${requestId}] WORKER_EXIT: ${message}, +${Date.now() - t0}ms`);
      this.finishSingleRequestError(requestId, 'HTTP_REQUEST_WORKER_EXITED', 'http_request_worker_exited', message);
    };

    try {
      requestWorker.postMessageWithSharedSendable(
        new NativeHttpRequestCommand(
          requestId,
          'request',
          this.sendableContext,
          this.buildWorkerRequestJson(requestData),
        ),
      );
    } catch (error) {
      const message = `${error}`;
      console.error(`[NativeHttpApi] sendRequest[${requestId}] WORKER_DISPATCH_FAILED: ${message}, +${Date.now() - t0}ms`);
      this.finishSingleRequestError(
        requestId,
        'HTTP_REQUEST_WORKER_DISPATCH_FAILED',
        'http_request_worker_dispatch_failed',
        message,
      );
      return;
    }
  }

  override sendStreamRequest(requestId: number, requestData: NativeHttpRequestOhos, result: Result<void>): void {
    const url = requestData.getUrl();
    if (!url || url.length === 0) {
      result.error(new FlutterError('INVALID_URL', 'invalid_url', 'Request URL is required.'));
      return;
    }

    if (!this.sendableContext) {
      result.error(new FlutterError('INVALID_CONTEXT', 'invalid_context', 'Application context is required.'));
      return;
    }

    this.cancelStreamRequest(requestId);

    const t0 = Date.now();

    const requestWorker = new worker.ThreadWorker('./NativeHttpRequestWorker.ets');
    const state: NativeStreamRequestState = { worker: requestWorker, cancelled: false };
    this.streamRequests.set(requestId, state);

    requestWorker.onmessage = (event: MessageEvents) => {
      this.handleStreamWorkerMessage(requestId, event.data as Object, t0);
    };
    requestWorker.onerror = (error: ErrorEvent) => {
      const message = error?.message ?? 'Unknown worker error';
      console.error(`[NativeHttpApi] sendStreamRequest[${requestId}] WORKER_ERROR: ${message}, +${Date.now() - t0}ms`);
      this.finishStreamRequestError(requestId, 'HTTP_STREAM_WORKER_FAILED', message);
    };
    requestWorker.onexit = (code: number) => {
      const current = this.streamRequests.get(requestId);
      if (!current) {
        return;
      }
      if (current.cancelled) {
        this.cleanupStreamRequest(requestId, current);
        return;
      }
      const message = `Stream worker exited with code ${code}.`;
      console.error(`[NativeHttpApi] sendStreamRequest[${requestId}] WORKER_EXIT: ${message}, +${Date.now() - t0}ms`);
      this.finishStreamRequestError(requestId, 'HTTP_STREAM_WORKER_EXITED', message);
    };

    try {
      requestWorker.postMessageWithSharedSendable(
        new NativeHttpRequestCommand(
          requestId,
          'stream',
          this.sendableContext,
          this.buildWorkerRequestJson(requestData),
        ),
      );
    } catch (error) {
      const message = `${error}`;
      console.error(`[NativeHttpApi] sendStreamRequest[${requestId}] WORKER_DISPATCH_FAILED: ${message}, +${Date.now() - t0}ms`);
      this.cleanupStreamRequest(requestId, state);
      result.error(new FlutterError('HTTP_STREAM_WORKER_DISPATCH_FAILED', 'http_stream_worker_dispatch_failed', message));
      return;
    }
    result.success();
  }

  override cancelStreamRequest(requestId: number): void {
    const state = this.streamRequests.get(requestId);
    if (!state) {
      return;
    }

    state.cancelled = true;
    this.cleanupStreamRequest(requestId, state);
  }

  override sendMultipartRequest(
    requestId: number,
    requestData: NativeHttpMultipartRequestOhos,
    result: Result<NativeHttpResponseOhos>,
  ): void {
    const t0 = Date.now();

    const url = requestData.getUrl();
    if (!url || url.length === 0) {
      result.error(new FlutterError('INVALID_URL', 'invalid_url', 'Request URL is required.'));
      return;
    }

    const filePath = requestData.getFilePath();
    if (!filePath || filePath.length === 0) {
      result.error(new FlutterError('INVALID_FILE_PATH', 'invalid_file_path', 'File path is required.'));
      return;
    }

    if (!this.sendableContext) {
      result.error(new FlutterError('INVALID_CONTEXT', 'invalid_context', 'Application context is required.'));
      return;
    }

    this.cancelMultipartRequest(requestId);

    const uploadWorker = new worker.ThreadWorker('./NativeMultipartUploadWorker.ets');
    const state: NativeMultipartRequestState = {
      worker: uploadWorker,
      cancelled: false,
      result: result,
    };
    this.multipartRequests.set(requestId, state);

    uploadWorker.onmessage = (event: MessageEvents) => {
      this.handleMultipartWorkerMessage(requestId, event.data as Object, t0);
    };
    uploadWorker.onerror = (error: ErrorEvent) => {
      const message = error?.message ?? 'Unknown worker error';
      console.error(`[NativeHttpApi] sendMultipartRequest[${requestId}] WORKER_ERROR: ${message}, +${Date.now() - t0}ms`);
      this.finishMultipartRequestError(requestId, 'HTTP_MULTIPART_WORKER_FAILED', 'http_multipart_worker_failed', message);
    };
    uploadWorker.onexit = (code: number) => {
      const current = this.multipartRequests.get(requestId);
      if (!current) {
        return;
      }
      if (current.cancelled) {
        this.cleanupMultipartRequest(requestId, current);
        return;
      }
      const message = `Multipart upload worker exited with code ${code}.`;
      console.error(`[NativeHttpApi] sendMultipartRequest[${requestId}] WORKER_EXIT: ${message}, +${Date.now() - t0}ms`);
      this.finishMultipartRequestError(requestId, 'HTTP_MULTIPART_WORKER_EXITED', 'http_multipart_worker_exited', message);
    };

    const command = new NativeMultipartUploadCommand(
      requestId,
      this.sendableContext,
      this.buildMultipartWorkerRequestJson(requestData),
    );
    try {
      uploadWorker.postMessageWithSharedSendable(command);
    } catch (error) {
      const message = `${error}`;
      console.error(`[NativeHttpApi] sendMultipartRequest[${requestId}] WORKER_DISPATCH_FAILED: ${message}, +${Date.now() - t0}ms`);
      this.finishMultipartRequestError(
        requestId,
        'HTTP_MULTIPART_WORKER_DISPATCH_FAILED',
        'http_multipart_worker_dispatch_failed',
        message,
      );
      return;
    }
  }

  override cancelMultipartRequest(requestId: number): void {
    const state = this.multipartRequests.get(requestId);
    if (!state) {
      return;
    }
    state.cancelled = true;
    state.result.error(new FlutterError('CANCELLED', 'cancelled', 'Multipart upload was cancelled.'));
    this.cleanupMultipartRequest(requestId, state);
  }

  private handleSingleRequestWorkerMessage(requestId: number, payloadObj: Object, t0: number): void {
    const current = this.singleRequests.get(requestId);
    if (!current) {
      return;
    }

    const payload = payloadObj as Record<string, Object>;
    const command = payload['command'] as string | undefined;
    switch (command) {
      case 'requestSuccess': {
        const statusCode = (payload['statusCode'] as number | undefined) ?? 200;
        const headers = this.toHeaderMap(payload['headers'] as Object | undefined);
        const body = payload['body'] as Uint8Array | undefined;
        this.finishSingleRequestSuccess(
          requestId,
          new NativeHttpResponseOhos(statusCode, headers, body ?? new Uint8Array(0)),
        );
        return;
      }
      case 'requestError': {
        const code = (payload['code'] as string | undefined) ?? 'HTTP_REQUEST_FAILED';
        const name = (payload['name'] as string | undefined) ?? 'http_request_failed';
        const message = (payload['message'] as string | undefined) ?? 'Request failed.';
        console.error(`[NativeHttpApi] sendRequest[${requestId}] FAILED: ${message}, +${Date.now() - t0}ms`);
        this.finishSingleRequestError(requestId, code, name, message);
        return;
      }
      default:
        console.error(`[NativeHttpApi] sendRequest[${requestId}] UNKNOWN_WORKER_MESSAGE: ${command ?? 'undefined'}, +${Date.now() - t0}ms`);
        this.finishSingleRequestError(
          requestId,
          'HTTP_REQUEST_WORKER_PROTOCOL_ERROR',
          'http_request_worker_protocol_error',
          'Request worker returned an unknown message.',
        );
    }
  }

  private finishSingleRequestSuccess(requestId: number, response: NativeHttpResponseOhos): void {
    const current = this.singleRequests.get(requestId);
    if (!current) {
      return;
    }

    this.singleRequests.delete(requestId);
    try {
      current.result.success(response);
    } finally {
      try {
        current.worker.terminate();
      } catch (_) {}
    }
  }

  private finishSingleRequestError(requestId: number, code: string, name: string, message: string): void {
    const current = this.singleRequests.get(requestId);
    if (!current) {
      return;
    }

    this.singleRequests.delete(requestId);
    try {
      current.result.error(new FlutterError(code, name, message));
    } finally {
      try {
        current.worker.terminate();
      } catch (_) {}
    }
  }

  private handleStreamWorkerMessage(requestId: number, payloadObj: Object, t0: number): void {
    const current = this.streamRequests.get(requestId);
    if (!current || current.cancelled) {
      return;
    }

    const payload = payloadObj as Record<string, Object>;
    const command = payload['command'] as string | undefined;
    switch (command) {
      case 'streamHeaders': {
        const statusCode = (payload['statusCode'] as number | undefined) ?? -1;
        const headers = this.toHeaderMap(payload['headers'] as Object | undefined);
        this.flutterApi.onStreamHeaders(
          requestId,
          new NativeHttpStreamHeadersOhos(statusCode, headers),
          { reply: () => {} },
        );
        return;
      }
      case 'streamData': {
        const chunk = payload['chunk'] as Uint8Array | undefined;
        if (chunk && chunk.length > 0) {
          this.flutterApi.onStreamData(requestId, chunk, { reply: () => {} });
        }
        return;
      }
      case 'streamComplete': {
        const statusCode = (payload['statusCode'] as number | undefined) ?? 200;
        this.flutterApi.onStreamComplete(requestId, statusCode, { reply: () => {} });
        this.cleanupStreamRequest(requestId, current);
        return;
      }
      case 'streamError': {
        const code = (payload['code'] as string | undefined) ?? 'HTTP_STREAM_FAILED';
        const message = (payload['message'] as string | undefined) ?? 'Stream request failed.';
        console.error(`[NativeHttpApi] sendStreamRequest[${requestId}] FAILED: ${message}, +${Date.now() - t0}ms`);
        this.finishStreamRequestError(requestId, code, message);
        return;
      }
      default:
        console.error(`[NativeHttpApi] sendStreamRequest[${requestId}] UNKNOWN_WORKER_MESSAGE: ${command ?? 'undefined'}, +${Date.now() - t0}ms`);
        this.finishStreamRequestError(
          requestId,
          'HTTP_STREAM_WORKER_PROTOCOL_ERROR',
          'Stream worker returned an unknown message.',
        );
    }
  }

  private finishStreamRequestError(requestId: number, code: string, message: string): void {
    const current = this.streamRequests.get(requestId);
    if (!current || current.cancelled) {
      this.cleanupStreamRequest(requestId, current);
      return;
    }

    this.flutterApi.onStreamError(requestId, code, message, { reply: () => {} });
    this.cleanupStreamRequest(requestId, current);
  }

  private cleanupStreamRequest(requestId: number, state?: NativeStreamRequestState): void {
    const current = state ?? this.streamRequests.get(requestId);
    if (!current) {
      return;
    }

    this.streamRequests.delete(requestId);
    try {
      current.worker.terminate();
    } catch (_) {}
  }

  private cleanupMultipartRequest(requestId: number, state?: NativeMultipartRequestState): void {
    const current = state ?? this.multipartRequests.get(requestId);
    if (!current) {
      return;
    }
    this.multipartRequests.delete(requestId);
    try {
      current.worker.terminate();
    } catch (_) {}
  }

  private handleMultipartWorkerMessage(requestId: number, payloadObj: Object, t0: number): void {
    const current = this.multipartRequests.get(requestId);
    if (!current || current.cancelled) {
      return;
    }

    const payload = payloadObj as Record<string, Object>;
    const command = payload['command'] as string | undefined;
    switch (command) {
      case 'progressUpdate': {
        const bytesSent = (payload['bytesSent'] as number | undefined) ?? 0;
        const totalBytes = (payload['totalBytes'] as number | undefined) ?? 0;
        if (totalBytes > 0) {
          this.flutterApi.onUploadProgress(requestId, bytesSent, totalBytes, { reply: () => {} });
        }
        return;
      }
      case 'success': {
        const statusCode = (payload['statusCode'] as number | undefined) ?? 200;
        const responseHeaders = this.toHeaderMap(payload['headers'] as Object | undefined);
        const bodyStr = payload['body'] as string | undefined;
        const bodyBytes = bodyStr && bodyStr.length > 0
          ? new util.TextEncoder().encodeInto(bodyStr)
          : new Uint8Array(0);
        this.finishMultipartRequestSuccess(
          requestId,
          new NativeHttpResponseOhos(statusCode, responseHeaders, bodyBytes),
        );
        return;
      }
      case 'error': {
        const code = (payload['code'] as string | undefined) ?? 'HTTP_MULTIPART_FAILED';
        const name = (payload['name'] as string | undefined) ?? 'http_multipart_failed';
        const message = (payload['message'] as string | undefined) ?? 'Multipart upload failed.';
        console.error(`[NativeHttpApi] sendMultipartRequest[${requestId}] FAILED: ${message}, +${Date.now() - t0}ms`);
        this.finishMultipartRequestError(requestId, code, name, message);
        return;
      }
      default:
        console.error(`[NativeHttpApi] sendMultipartRequest[${requestId}] UNKNOWN_WORKER_MESSAGE: ${command ?? 'undefined'}, +${Date.now() - t0}ms`);
        this.finishMultipartRequestError(
          requestId,
          'HTTP_MULTIPART_WORKER_PROTOCOL_ERROR',
          'http_multipart_worker_protocol_error',
          'Multipart upload worker returned an unknown message.',
        );
    }
  }

  private finishMultipartRequestSuccess(requestId: number, response: NativeHttpResponseOhos): void {
    const current = this.multipartRequests.get(requestId);
    if (!current) {
      return;
    }

    this.multipartRequests.delete(requestId);
    try {
      current.result.success(response);
    } finally {
      try {
        current.worker.terminate();
      } catch (_) {}
    }
  }

  private finishMultipartRequestError(requestId: number, code: string, name: string, message: string): void {
    const current = this.multipartRequests.get(requestId);
    if (!current) {
      return;
    }

    this.multipartRequests.delete(requestId);
    try {
      current.result.error(new FlutterError(code, name, message));
    } finally {
      try {
        current.worker.terminate();
      } catch (_) {}
    }
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

  private encodeBodyForWorker(body?: Uint8Array): string | undefined {
    if (!body || body.length === 0) {
      return undefined;
    }
    return new util.Base64Helper().encodeToStringSync(body);
  }

  private buildWorkerRequestJson(requestData: NativeHttpRequestOhos): string {
    return JSON.stringify({
      method: requestData.getMethod() ?? 'GET',
      url: requestData.getUrl() ?? '',
      headers: this.toHeaderRecord(requestData.getHeaders()),
      bodyBase64: this.encodeBodyForWorker(requestData.getBody()),
      connectTimeoutMs: requestData.getConnectTimeoutMs(),
      readTimeoutMs: requestData.getReadTimeoutMs(),
    });
  }

  private buildMultipartWorkerRequestJson(requestData: NativeHttpMultipartRequestOhos): string {
    return JSON.stringify({
      method: requestData.getMethod() ?? 'POST',
      url: requestData.getUrl() ?? '',
      headers: this.toHeaderRecord(requestData.getHeaders()),
      fields: this.toHeaderRecord(requestData.getFields()),
      fileFieldName: requestData.getFileFieldName() ?? '',
      filePath: requestData.getFilePath() ?? '',
      fileName: requestData.getFileName() ?? '',
      contentType: requestData.getContentType() ?? '',
      connectTimeoutMs: requestData.getConnectTimeoutMs(),
      readTimeoutMs: requestData.getReadTimeoutMs(),
    });
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
}
