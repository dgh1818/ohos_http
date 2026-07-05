import 'dart:async';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'ohos_http_ffi_runtime.dart';
import 'native_http_api_ohos.g.dart';
import 'ohos_multipart_request.dart';
import 'request_id_generator.dart';

/// An OHOS [http.Client] backed by NetworkKit for buffered requests and
/// libcurl FFI for transports that need streaming callbacks.
class OhosHttpClient extends http.BaseClient {
  OhosHttpClient({
    Duration connectTimeout = const Duration(seconds: 30),
    Duration readTimeout = const Duration(seconds: 60),
    NativeHttpApiOhos? nativeApi,
  }) : _nativeApi = nativeApi ?? NativeHttpApiOhos(),
       _connectTimeoutMs = connectTimeout.inMilliseconds,
       _readTimeoutMs = readTimeout.inMilliseconds;

  final NativeHttpApiOhos _nativeApi;
  final int _connectTimeoutMs;
  final int _readTimeoutMs;

  static final Map<int, _PendingNativeStreamRequest> _pendingRequests = {};
  static final Map<int, _PendingMultipartUpload> _pendingMultipartUploads = {};
  static int _nextRequestId = createOhosHttpInitialRequestId();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    // Route OhosMultipartRequest to the libcurl upload path that streams from
    // filePath directly and avoids loading the file into memory.
    if (request is OhosMultipartRequest) {
      return _sendNativeMultipartRequest(request);
    }

    try {
      final body = await request.finalize().toBytes();
      final bodyBytes = Uint8List.fromList(body);
      final requestHeaders = _buildTransportHeaders(request.headers);
      final nativeRequest = NativeHttpRequestOhos(
        method: request.method,
        url: request.url.toString(),
        headers: requestHeaders,
        body: bodyBytes.isEmpty ? null : bodyBytes,
        connectTimeoutMs: _connectTimeoutMs,
        readTimeoutMs: _readTimeoutMs,
      );

      if (_shouldStreamResponse(request)) {
        return _sendStreamingRequest(request, nativeRequest);
      }

      final response = await _nativeApi.sendRequest(nativeRequest);
      final headers = _normalizeResponseHeaders(response.headers);
      return http.StreamedResponse(
        Stream<List<int>>.value(response.body),
        response.statusCode,
        request: request,
        headers: headers,
        contentLength: _parseContentLength(headers) ?? response.body.length,
        isRedirect: false,
        persistentConnection: request.persistentConnection,
      );
    } on PlatformException catch (error) {
      throw http.ClientException(_formatPlatformException(error), request.url);
    } on Exception catch (error) {
      throw http.ClientException(error.toString(), request.url);
    }
  }

  Future<http.StreamedResponse> _sendStreamingRequest(
    http.BaseRequest request,
    NativeHttpRequestOhos nativeRequest,
  ) async {
    final requestId = _nextRequestId++;
    final pending = _PendingNativeStreamRequest(owner: this, request: request);
    _pendingRequests[requestId] = pending;

    _attachStreamAbortTrigger(request, requestId);

    final ffiRuntime = OhosHttpFfiRuntime.instance;
    if (!ffiRuntime.ensureLoaded() ||
        !(ffiRuntime.state?.libcurlEnabled ?? false)) {
      _pendingRequests.remove(requestId);
      final exception = http.ClientException(
        'Streaming responses require the OHOS HTTP FFI transport with libcurl support.',
        request.url,
      );
      pending.fail(exception);
      throw exception;
    }

    pending.cancelTransport = () async {
      ffiRuntime.cancelStreamRequest(requestId);
    };
    try {
      ffiRuntime.sendStreamRequest(
        requestId: requestId,
        method: request.method,
        url: request.url,
        headers: _buildTransportHeaders(request.headers),
        body: nativeRequest.body ?? Uint8List(0),
        connectTimeoutMs: _connectTimeoutMs,
        readTimeoutMs: _readTimeoutMs,
        onHeaders: (statusCode, headers) {
          final current = _pendingRequests[requestId];
          if (current == null) {
            return;
          }
          current.onHeaders(
            NativeHttpStreamHeadersOhos(
              statusCode: statusCode,
              headers: headers,
            ),
          );
        },
        onData: (chunk) {
          _pendingRequests[requestId]?.onData(chunk);
        },
        onComplete: (statusCode) {
          final current = _pendingRequests.remove(requestId);
          current?.onComplete(statusCode);
        },
        onError: (code, message) {
          final current = _pendingRequests.remove(requestId);
          current?.onError(code, message);
        },
      );
      return pending.response;
    } on OhosHttpFfiException catch (error) {
      if (!_pendingRequests.containsKey(requestId)) {
        throw http.RequestAbortedException(request.url);
      }

      _pendingRequests.remove(requestId);
      pending.cancelTransport = null;
      final exception = http.ClientException(error.toString(), request.url);
      pending.fail(exception);
      throw exception;
    }
  }

  @override
  void close() {
    final pendingEntries = _pendingRequests.entries
        .where((entry) => entry.value.owner == this)
        .toList();
    for (final entry in pendingEntries) {
      unawaited(_cancelPendingStreamRequest(entry.key).catchError((_) {}));
    }

    final multipartEntries = _pendingMultipartUploads.entries
        .where((entry) => entry.value.owner == this)
        .toList();
    for (final entry in multipartEntries) {
      unawaited(_cancelPendingMultipartUpload(entry.key).catchError((_) {}));
    }
  }

  /// Send a multipart request through curl FFI using the source file
  /// path directly, avoiding loading the file contents into Dart memory.
  Future<http.StreamedResponse> _sendNativeMultipartRequest(
    OhosMultipartRequest request,
  ) async {
    if (request.files.isEmpty) {
      throw http.ClientException(
        'OhosMultipartRequest must have at least one file',
        request.url,
      );
    }

    request.finalize();

    final file = request.files.first;
    final requestId = _nextRequestId++;
    final pending = _PendingMultipartUpload(
      owner: this,
      onProgress: request.onProgress,
    );
    _pendingMultipartUploads[requestId] = pending;
    _attachMultipartAbortTrigger(request, requestId);

    final ffiRuntime = OhosHttpFfiRuntime.instance;
    if (!ffiRuntime.ensureLoaded() ||
        !(ffiRuntime.state?.libcurlEnabled ?? false)) {
      _pendingMultipartUploads.remove(requestId);
      throw http.ClientException(
        'Multipart uploads require the OHOS HTTP FFI transport with libcurl support.',
        request.url,
      );
    }

    if (!_pendingMultipartUploads.containsKey(requestId)) {
      throw http.RequestAbortedException(request.url);
    }

    pending.cancelTransport = () async {
      ffiRuntime.cancelMultipartRequest(requestId);
    };

    try {
      final response = await ffiRuntime.sendMultipartRequest(
        method: request.method,
        requestId: requestId,
        url: request.url,
        headers: _buildTransportHeaders(request.headers),
        fields: Map<String, String>.from(request.fields),
        fileFieldName: file.field,
        filePath: file.filePath,
        fileName: file.filename,
        contentType: file.contentType,
        connectTimeoutMs: _connectTimeoutMs,
        readTimeoutMs: _readTimeoutMs,
        onProgress: (bytesSent, totalBytes) {
          _pendingMultipartUploads[requestId]?.onProgress?.call(
            bytesSent,
            totalBytes,
          );
        },
      );
      _pendingMultipartUploads.remove(requestId);
      return _buildBufferedResponse(
        request: request,
        statusCode: response.statusCode,
        headers: response.headers,
        body: response.body,
      );
    } on OhosHttpFfiException catch (error) {
      _pendingMultipartUploads.remove(requestId);
      if (error.code == 'HTTP_FFI_REQUEST_ABORTED') {
        throw http.RequestAbortedException(request.url);
      }
      throw http.ClientException(error.toString(), request.url);
    }
  }

  bool _shouldStreamResponse(http.BaseRequest request) {
    final accept = _getHeaderValue(request.headers, 'accept');
    return accept?.contains('application/jsonlines+json') ?? false;
  }

  String? _getHeaderValue(Map<String, String> headers, String headerName) {
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == headerName) {
        return entry.value;
      }
    }
    return null;
  }

  Map<String, String> _buildTransportHeaders(Map<String, String> headers) {
    return Map<String, String>.from(headers);
  }

  int? _parseContentLength(Map<String, String> headers) {
    final value = _getHeaderValue(headers, 'content-length');
    if (value == null || value.isEmpty) {
      return null;
    }
    return int.tryParse(value);
  }

  void _attachStreamAbortTrigger(http.BaseRequest request, int requestId) {
    if (request is! http.Abortable || request.abortTrigger == null) {
      return;
    }

    unawaited(
      request.abortTrigger!.whenComplete(() async {
        await _cancelPendingStreamRequest(requestId);
      }),
    );
  }

  void _attachMultipartAbortTrigger(
    OhosMultipartRequest request,
    int requestId,
  ) {
    if (request.abortTrigger == null) {
      return;
    }

    unawaited(
      request.abortTrigger!.whenComplete(() async {
        await _cancelPendingMultipartUpload(requestId);
      }),
    );
  }

  Future<void> _cancelPendingStreamRequest(int requestId) async {
    final current = _pendingRequests.remove(requestId);
    if (current == null) {
      return;
    }

    current.abort();
    try {
      await current.cancelTransport?.call();
    } catch (_) {}
  }

  Future<void> _cancelPendingMultipartUpload(int requestId) async {
    final current = _pendingMultipartUploads.remove(requestId);
    if (current == null) {
      return;
    }

    try {
      await current.cancelTransport?.call();
    } catch (_) {}
  }

  http.StreamedResponse _buildBufferedResponse({
    required http.BaseRequest request,
    required int statusCode,
    required Map<String, String> headers,
    required Uint8List body,
  }) {
    final responseHeaders = _normalizeResponseHeaders(headers);
    return http.StreamedResponse(
      Stream<List<int>>.value(body),
      statusCode,
      request: request,
      headers: responseHeaders,
      contentLength: _parseContentLength(responseHeaders) ?? body.length,
      isRedirect: false,
      persistentConnection: request.persistentConnection,
    );
  }

  String _formatPlatformException(PlatformException error) {
    final message = error.message;
    if (message == null || message.isEmpty) {
      return error.code;
    }
    return '${error.code}: $message';
  }
}

Map<String, String> _normalizeResponseHeaders(Map<String, String> headers) {
  final normalized = <String, String>{};
  for (final entry in headers.entries) {
    final key = entry.key.toLowerCase();
    final existing = normalized[key];
    if (existing == null || existing.isEmpty) {
      normalized[key] = entry.value;
      continue;
    }
    if (entry.value.isNotEmpty) {
      normalized[key] = '$existing, ${entry.value}';
    }
  }
  return normalized;
}

class _PendingNativeStreamRequest {
  _PendingNativeStreamRequest({required this.owner, required this.request});

  final OhosHttpClient owner;
  final http.BaseRequest request;
  Future<void> Function()? cancelTransport;

  final StreamController<List<int>> _controller = StreamController<List<int>>();
  final Completer<http.StreamedResponse> _responseCompleter =
      Completer<http.StreamedResponse>();
  final List<Uint8List> _bufferedChunks = [];

  Timer? _responseFallbackTimer;
  Map<String, String> _headers = const {};
  int? _statusCode;
  bool _receivedHeadersEvent = false;
  bool _finished = false;

  Future<http.StreamedResponse> get response => _responseCompleter.future;

  void onHeaders(NativeHttpStreamHeadersOhos response) {
    if (_finished) {
      return;
    }

    _receivedHeadersEvent = true;
    _headers = _normalizeResponseHeaders(response.headers);
    final statusCode = response.statusCode;
    if (statusCode != null && statusCode > 0) {
      _statusCode = statusCode;
    }
    _completeResponse();
  }

  void onData(Uint8List chunk) {
    if (_finished) {
      return;
    }

    if (!_responseCompleter.isCompleted) {
      _bufferedChunks.add(Uint8List.fromList(chunk));
      _responseFallbackTimer ??= Timer(const Duration(milliseconds: 100), () {
        _completeResponse(force: true);
      });
      return;
    }

    _controller.add(chunk);
  }

  void onComplete(int statusCode) {
    if (_finished) {
      return;
    }

    _statusCode ??= statusCode;
    _completeResponse(force: true);
    if (statusCode >= 400 && _responseCompleter.isCompleted) {
      _controller.addError(
        http.ClientException('HTTP $statusCode', request.url),
      );
    }
    _finish();
  }

  void onError(String code, String message) {
    if (_finished) {
      return;
    }

    final exception = http.ClientException('$code: $message', request.url);
    fail(exception);
  }

  void abort() {
    if (_finished) {
      return;
    }

    fail(http.RequestAbortedException(request.url));
  }

  void fail(Object error) {
    if (_finished) {
      return;
    }

    _responseFallbackTimer?.cancel();
    _responseFallbackTimer = null;

    if (!_responseCompleter.isCompleted) {
      _responseCompleter.completeError(error);
    } else {
      _controller.addError(error);
    }
    _finish();
  }

  void _completeResponse({bool force = false}) {
    if (_responseCompleter.isCompleted) {
      _flushBufferedChunks();
      return;
    }

    if (!force && !_receivedHeadersEvent && _statusCode == null) {
      return;
    }

    _responseFallbackTimer?.cancel();
    _responseFallbackTimer = null;

    final headers = Map<String, String>.from(_headers);
    _responseCompleter.complete(
      http.StreamedResponse(
        _controller.stream,
        _statusCode ?? 200,
        request: request,
        headers: headers,
        contentLength: _parseContentLength(headers),
        isRedirect: false,
        persistentConnection: request.persistentConnection,
      ),
    );
    _flushBufferedChunks();
  }

  void _flushBufferedChunks() {
    if (_bufferedChunks.isEmpty) {
      return;
    }

    for (final chunk in _bufferedChunks) {
      _controller.add(chunk);
    }
    _bufferedChunks.clear();
  }

  void _finish() {
    if (_finished) {
      return;
    }

    _finished = true;
    _responseFallbackTimer?.cancel();
    _responseFallbackTimer = null;
    _bufferedChunks.clear();
    unawaited(_controller.close());
  }

  int? _parseContentLength(Map<String, String> headers) {
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == 'content-length') {
        return int.tryParse(entry.value);
      }
    }
    return null;
  }
}

class _PendingMultipartUpload {
  _PendingMultipartUpload({required this.owner, this.onProgress});

  final OhosHttpClient owner;
  final void Function(int bytesSent, int totalBytes)? onProgress;
  Future<void> Function()? cancelTransport;
}
