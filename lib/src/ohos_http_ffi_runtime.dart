import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:ffi/ffi.dart';

import 'ohos_http_ffi_bindings.dart';
import 'request_id_generator.dart';

const int _kBootstrapCompiled = 1 << 0;
const int _kDispatcherInstalled = 1 << 1;
const int _kLibcurlEnabled = 1 << 2;
const int _kExpectedPingValue = 0x4F484646;
const int _kDispatchOk = 0;

final class OhosHttpFfiResponsePayload {
  const OhosHttpFfiResponsePayload({
    required this.statusCode,
    required this.headers,
    required this.body,
  });

  final int statusCode;
  final Map<String, String> headers;
  final Uint8List body;
}

final class OhosHttpFfiStreamHandlers {
  const OhosHttpFfiStreamHandlers({
    required this.onHeaders,
    required this.onData,
    required this.onComplete,
    required this.onError,
  });

  final void Function(int? statusCode, Map<String, String> headers) onHeaders;
  final void Function(Uint8List chunk) onData;
  final void Function(int statusCode) onComplete;
  final void Function(String code, String message) onError;
}

final class OhosHttpFfiMultipartHandlers {
  const OhosHttpFfiMultipartHandlers({
    required this.completer,
    required this.onProgress,
  });

  final Completer<OhosHttpFfiResponsePayload> completer;
  final void Function(int bytesSent, int totalBytes)? onProgress;
}

final class OhosHttpFfiException implements Exception {
  const OhosHttpFfiException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => '$code: $message';
}

final class OhosHttpFfiState {
  const OhosHttpFfiState({
    required this.libraryVersion,
    required this.bootstrapState,
    required this.pingValue,
  });

  final int libraryVersion;
  final int bootstrapState;
  final int pingValue;

  bool get bootstrapCompiled => (bootstrapState & _kBootstrapCompiled) != 0;

  bool get dispatcherInstalled => (bootstrapState & _kDispatcherInstalled) != 0;

  bool get libcurlEnabled => (bootstrapState & _kLibcurlEnabled) != 0;

  bool get pingMatches => pingValue == _kExpectedPingValue;

  bool get transportReady =>
      bootstrapCompiled &&
      pingMatches &&
      (libcurlEnabled || dispatcherInstalled);
}

final class OhosHttpFfiRuntime {
  OhosHttpFfiRuntime._();

  static final OhosHttpFfiRuntime instance = OhosHttpFfiRuntime._();

  ffi.DynamicLibrary? _library;
  OhosHttpFfiBindings? _bindings;
  OhosHttpFfiState? _state;
  Object? _loadError;
  StackTrace? _loadStackTrace;
  ReceivePort? _receivePort;
  int _nextRequestId = createOhosHttpInitialRequestId();
  final Map<int, Completer<OhosHttpFfiResponsePayload>> _pendingRequests =
      <int, Completer<OhosHttpFfiResponsePayload>>{};
  final Map<int, OhosHttpFfiStreamHandlers> _pendingStreamRequests =
      <int, OhosHttpFfiStreamHandlers>{};
  final Map<int, OhosHttpFfiMultipartHandlers> _pendingMultipartRequests =
      <int, OhosHttpFfiMultipartHandlers>{};

  bool get isLoaded => _bindings != null;

  OhosHttpFfiState? get state => _state;

  Object? get loadError => _loadError;

  StackTrace? get loadStackTrace => _loadStackTrace;

  bool get isTransportReady {
    _refreshState();
    return _state?.transportReady ?? false;
  }

  bool ensureLoaded() {
    if (_bindings != null) {
      _refreshState();
      return true;
    }
    if (defaultTargetPlatform != TargetPlatform.ohos) {
      return false;
    }

    try {
      final library = ffi.DynamicLibrary.open('libohos_http_ffi.so');
      final bindings = OhosHttpFfiBindings(library);
      final initResult = bindings.initializeApiDl(
        ffi.NativeApi.initializeApiDLData,
      );
      if (initResult != 0) {
        throw StateError('Failed to initialize Dart DL API: $initResult');
      }
      _library = library;
      _bindings = bindings;
      _receivePort = ReceivePort('ohos_http_ffi_runtime');
      _receivePort!.listen(_handleNativeMessage);
      _refreshState();
      return true;
    } catch (error, stackTrace) {
      _loadError ??= error;
      _loadStackTrace ??= stackTrace;
      return false;
    }
  }

  ffi.DynamicLibrary? get library => _library;

  bool configureRequestState({
    required Map<String, String> headers,
    required List<String> serverUrls,
    String? token,
  }) {
    if (!ensureLoaded() || _bindings == null) {
      return false;
    }

    final headersPtr = jsonEncode(headers).toNativeUtf8();
    final serverUrlsPtr = jsonEncode(serverUrls).toNativeUtf8();
    final tokenPtr = (token ?? '').toNativeUtf8();

    try {
      final status = _bindings!.setRequestState(
        headersPtr,
        serverUrlsPtr,
        tokenPtr,
      );
      if (status != _kDispatchOk) {
        throw OhosHttpFfiException(
          'HTTP_FFI_SESSION_SYNC_FAILED',
          'Failed to synchronize curl request state with status $status.',
        );
      }
      return true;
    } finally {
      malloc.free(headersPtr);
      malloc.free(serverUrlsPtr);
      malloc.free(tokenPtr);
    }
  }

  /// Sets the CA bundle path for curl to verify server certificates.
  ///
  /// Pass an empty string to clear the CA bundle and fall back to curl's
  /// default behavior.
  bool setCaBundlePath(String caBundlePath) {
    if (!ensureLoaded() || _bindings == null) {
      return false;
    }

    final caBundlePathPtr = caBundlePath.toNativeUtf8();
    try {
      final status = _bindings!.setCaBundlePath(caBundlePathPtr);
      if (status != _kDispatchOk) {
        throw OhosHttpFfiException(
          'HTTP_FFI_CA_BUNDLE_FAILED',
          'Failed to set CA bundle path with status $status.',
        );
      }
      return true;
    } finally {
      malloc.free(caBundlePathPtr);
    }
  }

  Future<OhosHttpFfiResponsePayload> sendRequest({
    required String method,
    required Uri url,
    required Map<String, String> headers,
    required Uint8List body,
    required int connectTimeoutMs,
    required int readTimeoutMs,
  }) {
    if (!ensureLoaded() || _bindings == null || _receivePort == null) {
      throw const OhosHttpFfiException(
        'HTTP_FFI_NOT_LOADED',
        'OHOS HTTP FFI runtime is not loaded.',
      );
    }

    _refreshState();
    if (!(_state?.transportReady ?? false)) {
      throw const OhosHttpFfiException(
        'HTTP_FFI_TRANSPORT_NOT_READY',
        'OHOS HTTP FFI transport is not ready.',
      );
    }

    final requestId = _nextRequestId++;
    final completer = Completer<OhosHttpFfiResponsePayload>();
    _pendingRequests[requestId] = completer;

    final methodPtr = method.toNativeUtf8();
    final urlPtr = url.toString().toNativeUtf8();
    final headersPtr = jsonEncode(headers).toNativeUtf8();
    ffi.Pointer<ffi.Uint8> bodyPtr = ffi.nullptr;
    if (body.isNotEmpty) {
      bodyPtr = malloc.allocate<ffi.Uint8>(body.length);
      bodyPtr.asTypedList(body.length).setAll(0, body);
    }

    try {
      final dispatchResult = _bindings!.sendRequestAsync(
        requestId,
        _receivePort!.sendPort.nativePort,
        methodPtr,
        urlPtr,
        headersPtr,
        bodyPtr,
        body.length,
        connectTimeoutMs,
        readTimeoutMs,
      );
      if (dispatchResult != _kDispatchOk) {
        _pendingRequests.remove(requestId);
        throw OhosHttpFfiException(
          'HTTP_FFI_DISPATCH_FAILED',
          'Native dispatch failed immediately with code $dispatchResult.',
        );
      }
      return completer.future;
    } finally {
      malloc.free(methodPtr);
      malloc.free(urlPtr);
      malloc.free(headersPtr);
      if (bodyPtr != ffi.nullptr) {
        malloc.free(bodyPtr);
      }
    }
  }

  void sendStreamRequest({
    required int requestId,
    required String method,
    required Uri url,
    required Map<String, String> headers,
    required Uint8List body,
    required int connectTimeoutMs,
    required int readTimeoutMs,
    required void Function(int? statusCode, Map<String, String> headers)
    onHeaders,
    required void Function(Uint8List chunk) onData,
    required void Function(int statusCode) onComplete,
    required void Function(String code, String message) onError,
  }) {
    if (!ensureLoaded() || _bindings == null || _receivePort == null) {
      throw const OhosHttpFfiException(
        'HTTP_FFI_NOT_LOADED',
        'OHOS HTTP FFI runtime is not loaded.',
      );
    }

    _refreshState();
    if (!(_state?.libcurlEnabled ?? false)) {
      throw const OhosHttpFfiException(
        'HTTP_FFI_STREAMING_NOT_SUPPORTED',
        'OHOS HTTP FFI streaming requires libcurl support.',
      );
    }

    final methodPtr = method.toNativeUtf8();
    final urlPtr = url.toString().toNativeUtf8();
    final headersPtr = jsonEncode(headers).toNativeUtf8();
    ffi.Pointer<ffi.Uint8> bodyPtr = ffi.nullptr;
    if (body.isNotEmpty) {
      bodyPtr = malloc.allocate<ffi.Uint8>(body.length);
      bodyPtr.asTypedList(body.length).setAll(0, body);
    }

    _pendingStreamRequests[requestId] = OhosHttpFfiStreamHandlers(
      onHeaders: onHeaders,
      onData: onData,
      onComplete: onComplete,
      onError: onError,
    );

    try {
      final dispatchResult = _bindings!.sendStreamRequestAsync(
        requestId,
        _receivePort!.sendPort.nativePort,
        methodPtr,
        urlPtr,
        headersPtr,
        bodyPtr,
        body.length,
        connectTimeoutMs,
        readTimeoutMs,
      );
      if (dispatchResult != _kDispatchOk) {
        _pendingStreamRequests.remove(requestId);
        throw OhosHttpFfiException(
          'HTTP_FFI_DISPATCH_FAILED',
          'Native stream dispatch failed immediately with code $dispatchResult.',
        );
      }
    } finally {
      malloc.free(methodPtr);
      malloc.free(urlPtr);
      malloc.free(headersPtr);
      if (bodyPtr != ffi.nullptr) {
        malloc.free(bodyPtr);
      }
    }
  }

  void cancelStreamRequest(int requestId) {
    final bindings = _bindings;
    if (!ensureLoaded() || bindings == null) {
      return;
    }

    _pendingStreamRequests.remove(requestId);
    bindings.cancelStreamRequest(requestId);
  }

  Future<OhosHttpFfiResponsePayload> sendMultipartRequest({
    required int requestId,
    required String method,
    required Uri url,
    required Map<String, String> headers,
    required Map<String, String> fields,
    required String fileFieldName,
    required String filePath,
    required String fileName,
    required String contentType,
    required int connectTimeoutMs,
    required int readTimeoutMs,
    void Function(int bytesSent, int totalBytes)? onProgress,
  }) {
    if (!ensureLoaded() || _bindings == null || _receivePort == null) {
      throw const OhosHttpFfiException(
        'HTTP_FFI_NOT_LOADED',
        'OHOS HTTP FFI runtime is not loaded.',
      );
    }

    _refreshState();
    if (!(_state?.libcurlEnabled ?? false)) {
      throw const OhosHttpFfiException(
        'HTTP_FFI_MULTIPART_NOT_SUPPORTED',
        'OHOS HTTP FFI multipart uploads require libcurl support.',
      );
    }

    final completer = Completer<OhosHttpFfiResponsePayload>();
    _pendingMultipartRequests[requestId] = OhosHttpFfiMultipartHandlers(
      completer: completer,
      onProgress: onProgress,
    );

    final methodPtr = method.toNativeUtf8();
    final urlPtr = url.toString().toNativeUtf8();
    final headersPtr = jsonEncode(headers).toNativeUtf8();
    final fieldsPtr = jsonEncode(fields).toNativeUtf8();
    final fileFieldNamePtr = fileFieldName.toNativeUtf8();
    final filePathPtr = filePath.toNativeUtf8();
    final fileNamePtr = fileName.toNativeUtf8();
    final contentTypePtr = contentType.toNativeUtf8();

    try {
      final dispatchResult = _bindings!.sendMultipartRequestAsync(
        requestId,
        _receivePort!.sendPort.nativePort,
        methodPtr,
        urlPtr,
        headersPtr,
        fieldsPtr,
        fileFieldNamePtr,
        filePathPtr,
        fileNamePtr,
        contentTypePtr,
        connectTimeoutMs,
        readTimeoutMs,
      );
      if (dispatchResult != _kDispatchOk) {
        _pendingMultipartRequests.remove(requestId);
        throw OhosHttpFfiException(
          'HTTP_FFI_DISPATCH_FAILED',
          'Native multipart dispatch failed immediately with code $dispatchResult.',
        );
      }
      return completer.future;
    } finally {
      malloc.free(methodPtr);
      malloc.free(urlPtr);
      malloc.free(headersPtr);
      malloc.free(fieldsPtr);
      malloc.free(fileFieldNamePtr);
      malloc.free(filePathPtr);
      malloc.free(fileNamePtr);
      malloc.free(contentTypePtr);
    }
  }

  void cancelMultipartRequest(int requestId) {
    final bindings = _bindings;
    if (!ensureLoaded() || bindings == null) {
      return;
    }

    final pending = _pendingMultipartRequests.remove(requestId);
    if (pending != null && !pending.completer.isCompleted) {
      pending.completer.completeError(
        const OhosHttpFfiException(
          'HTTP_FFI_REQUEST_ABORTED',
          'OHOS HTTP FFI request was aborted.',
        ),
      );
    }
    bindings.cancelMultipartRequest(requestId);
  }

  void _refreshState() {
    final bindings = _bindings;
    if (bindings == null) {
      return;
    }
    _state = OhosHttpFfiState(
      libraryVersion: bindings.libraryVersion(),
      bootstrapState: bindings.bootstrapState(),
      pingValue: bindings.ping(),
    );
  }

  void _handleNativeMessage(dynamic message) {
    if (message is! List<Object?> || message.length < 2) {
      return;
    }

    final requestId = message[0] as int?;
    if (requestId == null) {
      return;
    }

    final messageKind = message[1];
    if (messageKind is String) {
      _handleNativeTaggedMessage(requestId, messageKind, message);
      return;
    }

    final completer = _pendingRequests.remove(requestId);
    if (completer != null) {
      _completeResponseCompleter(completer, message);
      return;
    }

    final multipart = _pendingMultipartRequests.remove(requestId);
    if (multipart == null) {
      return;
    }

    _completeResponseCompleter(multipart.completer, message);
  }

  void _completeResponseCompleter(
    Completer<OhosHttpFfiResponsePayload> completer,
    List<Object?> message,
  ) {
    if (completer.isCompleted) {
      return;
    }

    final ok = message[1] as int? ?? 0;
    if (ok == 1) {
      final statusCode = message.length > 2 ? (message[2] as int? ?? 200) : 200;
      final headersJson = message.length > 3
          ? (message[3] as String? ?? '{}')
          : '{}';
      final body = _decodeNativeBytes(message.length > 4 ? message[4] : null);
      completer.complete(
        OhosHttpFfiResponsePayload(
          statusCode: statusCode,
          headers: _decodeHeaders(headersJson),
          body: body,
        ),
      );
      return;
    }

    final code = message.length > 2
        ? '${message[2]}'
        : 'HTTP_FFI_REQUEST_FAILED';
    final errorMessage = message.length > 3
        ? '${message[3]}'
        : 'OHOS HTTP FFI request failed.';
    completer.completeError(OhosHttpFfiException(code, errorMessage));
  }

  void _handleNativeTaggedMessage(
    int requestId,
    String tag,
    List<Object?> message,
  ) {
    final handlers = _pendingStreamRequests[requestId];
    if (handlers != null) {
      _handleNativeStreamMessage(requestId, tag, message, handlers);
      return;
    }

    final multipart = _pendingMultipartRequests[requestId];
    if (multipart == null) {
      return;
    }

    switch (tag) {
      case 'uploadProgress':
        multipart.onProgress?.call(
          message.length > 2 ? (message[2] as int? ?? 0) : 0,
          message.length > 3 ? (message[3] as int? ?? 0) : 0,
        );
        return;
      case 'complete':
        _pendingMultipartRequests.remove(requestId);
        _completeResponseCompleter(multipart.completer, <Object?>[
          requestId,
          1,
          message.length > 2 ? message[2] : 200,
          message.length > 3 ? message[3] : '{}',
          message.length > 4 ? message[4] : Uint8List(0),
        ]);
        return;
      case 'error':
        _pendingMultipartRequests.remove(requestId);
        _completeResponseCompleter(multipart.completer, <Object?>[
          requestId,
          0,
          message.length > 2 ? message[2] : 'HTTP_FFI_REQUEST_FAILED',
          message.length > 3 ? message[3] : 'OHOS HTTP FFI request failed.',
        ]);
        return;
    }
  }

  void _handleNativeStreamMessage(
    int requestId,
    String tag,
    List<Object?> message,
    OhosHttpFfiStreamHandlers handlers,
  ) {
    switch (tag) {
      case 'headers':
        final statusCode = message.length > 2 ? message[2] as int? : null;
        final headersJson = message.length > 3
            ? (message[3] as String? ?? '{}')
            : '{}';
        handlers.onHeaders(statusCode, _decodeHeaders(headersJson));
        return;
      case 'chunk':
        final chunk = _decodeNativeBytes(
          message.length > 2 ? message[2] : null,
        );
        handlers.onData(chunk);
        return;
      case 'complete':
        _pendingStreamRequests.remove(requestId);
        handlers.onComplete(
          message.length > 2 ? (message[2] as int? ?? 200) : 200,
        );
        return;
      case 'error':
        _pendingStreamRequests.remove(requestId);
        final code = message.length > 2
            ? '${message[2]}'
            : 'HTTP_FFI_REQUEST_FAILED';
        final errorMessage = message.length > 3
            ? '${message[3]}'
            : 'OHOS HTTP FFI request failed.';
        handlers.onError(code, errorMessage);
        return;
    }
  }

  Uint8List _decodeNativeBytes(Object? value) {
    if (value == null) {
      return Uint8List(0);
    }
    if (value is Uint8List) {
      return value;
    }
    if (value is TypedData) {
      return value.buffer.asUint8List(value.offsetInBytes, value.lengthInBytes);
    }
    if (value is ByteBuffer) {
      return value.asUint8List();
    }
    if (value is List<int>) {
      return Uint8List.fromList(value);
    }
    if (value is List) {
      final bytes = Uint8List(value.length);
      for (var index = 0; index < value.length; index++) {
        final byte = value[index];
        if (byte is! int) {
          return Uint8List(0);
        }
        bytes[index] = byte;
      }
      return bytes;
    }
    if (value is String) {
      return Uint8List.fromList(utf8.encode(value));
    }
    return Uint8List(0);
  }

  Map<String, String> _decodeHeaders(String headersJson) {
    try {
      final decoded = jsonDecode(headersJson);
      if (decoded is Map<String, dynamic>) {
        final headers = <String, String>{};
        for (final entry in decoded.entries) {
          final key = entry.key.toLowerCase();
          final value = '${entry.value}';
          final existing = headers[key];
          if (existing == null || existing.isEmpty) {
            headers[key] = value;
            continue;
          }
          if (value.isNotEmpty) {
            headers[key] = '$existing, $value';
          }
        }
        return headers;
      }
    } catch (_) {}
    return const <String, String>{};
  }
}
