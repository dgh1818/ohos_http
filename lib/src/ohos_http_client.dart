import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'native_http_api_ohos.g.dart';

/// An OHOS [http.Client] backed by NetworkKit through a native plugin bridge.
class OhosHttpClient extends http.BaseClient {
  OhosHttpClient({NativeHttpApiOhos? nativeApi})
    : _nativeApi = nativeApi ?? NativeHttpApiOhos(),
      _supportsNativeStreamCallbacks = ui.RootIsolateToken.instance != null {
    if (_supportsNativeStreamCallbacks) {
      _streamBridge ??= _NativeHttpFlutterApiBridge();
      NativeHttpFlutterApiOhos.setUp(_streamBridge);
    }
  }

  final NativeHttpApiOhos _nativeApi;
  final bool _supportsNativeStreamCallbacks;

  static _NativeHttpFlutterApiBridge? _streamBridge;
  static final Map<int, _PendingNativeStreamRequest> _pendingRequests = {};
  static int _nextRequestId = 1;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    try {
      final body = await request.finalize().toBytes();
      final nativeRequest = NativeHttpRequestOhos(
        method: request.method,
        url: request.url.toString(),
        headers: Map<String, String>.from(request.headers),
        body: body.isEmpty ? null : body,
      );

      if (_shouldStreamResponse(request)) {
        return _sendStreamingRequest(request, nativeRequest);
      }

      final response = await _nativeApi.sendRequest(nativeRequest);
      final headers = Map<String, String>.from(response.headers);
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

    if (request is http.Abortable && request.abortTrigger != null) {
      unawaited(
        request.abortTrigger!.whenComplete(() async {
          final current = _pendingRequests.remove(requestId);
          if (current == null) {
            return;
          }
          current.abort();
          try {
            await _nativeApi.cancelStreamRequest(requestId);
          } catch (_) {}
        }),
      );
    }

    try {
      await _nativeApi.sendStreamRequest(requestId, nativeRequest);
      return await pending.response;
    } on PlatformException catch (error) {
      _pendingRequests.remove(requestId);
      final exception = http.ClientException(
        _formatPlatformException(error),
        request.url,
      );
      pending.fail(exception);
      throw exception;
    } on Exception catch (error) {
      _pendingRequests.remove(requestId);
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
      _pendingRequests.remove(entry.key);
      entry.value.abort();
      unawaited(_nativeApi.cancelStreamRequest(entry.key).catchError((_) {}));
    }
  }

  bool _shouldStreamResponse(http.BaseRequest request) {
    if (!_supportsNativeStreamCallbacks) {
      return false;
    }

    if (request.url.path.endsWith('/sync/stream')) {
      return true;
    }

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

  int? _parseContentLength(Map<String, String> headers) {
    final value = _getHeaderValue(headers, 'content-length');
    if (value == null || value.isEmpty) {
      return null;
    }
    return int.tryParse(value);
  }

  String _formatPlatformException(PlatformException error) {
    final message = error.message;
    if (message == null || message.isEmpty) {
      return error.code;
    }
    return '${error.code}: $message';
  }
}

class _PendingNativeStreamRequest {
  _PendingNativeStreamRequest({required this.owner, required this.request});

  final OhosHttpClient owner;
  final http.BaseRequest request;

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
    _headers = Map<String, String>.from(response.headers);
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

class _NativeHttpFlutterApiBridge extends NativeHttpFlutterApiOhos {
  @override
  Future<void> onStreamHeaders(
    int requestId,
    NativeHttpStreamHeadersOhos response,
  ) async {
    OhosHttpClient._pendingRequests[requestId]?.onHeaders(response);
  }

  @override
  Future<void> onStreamData(int requestId, Uint8List chunk) async {
    OhosHttpClient._pendingRequests[requestId]?.onData(chunk);
  }

  @override
  Future<void> onStreamComplete(int requestId, int statusCode) async {
    final pending = OhosHttpClient._pendingRequests.remove(requestId);
    pending?.onComplete(statusCode);
  }

  @override
  Future<void> onStreamError(int requestId, String code, String message) async {
    final pending = OhosHttpClient._pendingRequests.remove(requestId);
    pending?.onError(code, message);
  }
}
