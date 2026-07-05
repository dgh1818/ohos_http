import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart';

typedef _Int32Native = ffi.Int32 Function();
typedef _Int32Dart = int Function();
typedef _InitializeApiDlNative = ffi.IntPtr Function(ffi.Pointer<ffi.Void>);
typedef _InitializeApiDlDart = int Function(ffi.Pointer<ffi.Void>);
typedef _SetRequestStateNative =
    ffi.Int32 Function(ffi.Pointer<Utf8>, ffi.Pointer<Utf8>, ffi.Pointer<Utf8>);
typedef _SetRequestStateDart =
    int Function(ffi.Pointer<Utf8>, ffi.Pointer<Utf8>, ffi.Pointer<Utf8>);
typedef _SendRequestAsyncNative =
    ffi.Int32 Function(
      ffi.Int64,
      ffi.Int64,
      ffi.Pointer<Utf8>,
      ffi.Pointer<Utf8>,
      ffi.Pointer<Utf8>,
      ffi.Pointer<ffi.Uint8>,
      ffi.Int32,
      ffi.Int32,
      ffi.Int32,
    );
typedef _SendRequestAsyncDart =
    int Function(
      int,
      int,
      ffi.Pointer<Utf8>,
      ffi.Pointer<Utf8>,
      ffi.Pointer<Utf8>,
      ffi.Pointer<ffi.Uint8>,
      int,
      int,
      int,
    );
typedef _SendStreamRequestAsyncNative =
    ffi.Int32 Function(
      ffi.Int64,
      ffi.Int64,
      ffi.Pointer<Utf8>,
      ffi.Pointer<Utf8>,
      ffi.Pointer<Utf8>,
      ffi.Pointer<ffi.Uint8>,
      ffi.Int32,
      ffi.Int32,
      ffi.Int32,
    );
typedef _SendStreamRequestAsyncDart =
    int Function(
      int,
      int,
      ffi.Pointer<Utf8>,
      ffi.Pointer<Utf8>,
      ffi.Pointer<Utf8>,
      ffi.Pointer<ffi.Uint8>,
      int,
      int,
      int,
    );
typedef _CancelStreamRequestNative = ffi.Int32 Function(ffi.Int64);
typedef _CancelStreamRequestDart = int Function(int);
typedef _SendMultipartRequestAsyncNative =
    ffi.Int32 Function(
      ffi.Int64,
      ffi.Int64,
      ffi.Pointer<Utf8>,
      ffi.Pointer<Utf8>,
      ffi.Pointer<Utf8>,
      ffi.Pointer<Utf8>,
      ffi.Pointer<Utf8>,
      ffi.Int32,
      ffi.Int32,
    );
typedef _SendMultipartRequestAsyncDart =
    int Function(
      int,
      int,
      ffi.Pointer<Utf8>,
      ffi.Pointer<Utf8>,
      ffi.Pointer<Utf8>,
      ffi.Pointer<Utf8>,
      ffi.Pointer<Utf8>,
      int,
      int,
    );
typedef _CancelMultipartRequestNative = ffi.Int32 Function(ffi.Int64);
typedef _CancelMultipartRequestDart = int Function(int);
typedef _SetCaBundlePathNative = ffi.Int32 Function(ffi.Pointer<Utf8>);
typedef _SetCaBundlePathDart = int Function(ffi.Pointer<Utf8>);

final class OhosHttpFfiBindings {
  OhosHttpFfiBindings(ffi.DynamicLibrary library)
    : _libraryVersion = library.lookupFunction<_Int32Native, _Int32Dart>(
        'ohos_http_ffi_library_version',
      ),
      _bootstrapState = library.lookupFunction<_Int32Native, _Int32Dart>(
        'ohos_http_ffi_bootstrap_state',
      ),
      _ping = library.lookupFunction<_Int32Native, _Int32Dart>(
        'ohos_http_ffi_ping',
      ),
      _initializeApiDl = library
          .lookupFunction<_InitializeApiDlNative, _InitializeApiDlDart>(
            'ohos_http_ffi_initialize_dart_api',
          ),
      _setRequestState = library
          .lookupFunction<_SetRequestStateNative, _SetRequestStateDart>(
            'ohos_http_ffi_set_request_state',
          ),
      _sendRequestAsync = library
          .lookupFunction<_SendRequestAsyncNative, _SendRequestAsyncDart>(
            'ohos_http_ffi_send_request_async',
          ),
      _sendStreamRequestAsync = library
          .lookupFunction<
            _SendStreamRequestAsyncNative,
            _SendStreamRequestAsyncDart
          >('ohos_http_ffi_send_stream_request_async'),
      _cancelStreamRequest = library
          .lookupFunction<_CancelStreamRequestNative, _CancelStreamRequestDart>(
            'ohos_http_ffi_cancel_stream_request',
          ),
      _sendMultipartRequestAsync = library
          .lookupFunction<
            _SendMultipartRequestAsyncNative,
            _SendMultipartRequestAsyncDart
          >('ohos_http_ffi_send_multipart_request_async'),
      _cancelMultipartRequest = library
          .lookupFunction<
            _CancelMultipartRequestNative,
            _CancelMultipartRequestDart
          >('ohos_http_ffi_cancel_multipart_request'),
      _setCaBundlePath = library
          .lookupFunction<_SetCaBundlePathNative, _SetCaBundlePathDart>(
            'ohos_http_ffi_set_ca_bundle_path',
          );

  final _Int32Dart _libraryVersion;
  final _Int32Dart _bootstrapState;
  final _Int32Dart _ping;
  final _InitializeApiDlDart _initializeApiDl;
  final _SetRequestStateDart _setRequestState;
  final _SendRequestAsyncDart _sendRequestAsync;
  final _SendStreamRequestAsyncDart _sendStreamRequestAsync;
  final _CancelStreamRequestDart _cancelStreamRequest;
  final _SendMultipartRequestAsyncDart _sendMultipartRequestAsync;
  final _CancelMultipartRequestDart _cancelMultipartRequest;
  final _SetCaBundlePathDart _setCaBundlePath;

  int libraryVersion() => _libraryVersion();

  int bootstrapState() => _bootstrapState();

  int ping() => _ping();

  int initializeApiDl(ffi.Pointer<ffi.Void> data) => _initializeApiDl(data);

  int setRequestState(
    ffi.Pointer<Utf8> headersJson,
    ffi.Pointer<Utf8> serverUrlsJson,
    ffi.Pointer<Utf8> token,
  ) => _setRequestState(headersJson, serverUrlsJson, token);

  int sendRequestAsync(
    int requestId,
    int dartPort,
    ffi.Pointer<Utf8> method,
    ffi.Pointer<Utf8> url,
    ffi.Pointer<Utf8> headersJson,
    ffi.Pointer<ffi.Uint8> body,
    int bodyLength,
    int connectTimeoutMs,
    int readTimeoutMs,
  ) => _sendRequestAsync(
    requestId,
    dartPort,
    method,
    url,
    headersJson,
    body,
    bodyLength,
    connectTimeoutMs,
    readTimeoutMs,
  );

  int sendStreamRequestAsync(
    int requestId,
    int dartPort,
    ffi.Pointer<Utf8> method,
    ffi.Pointer<Utf8> url,
    ffi.Pointer<Utf8> headersJson,
    ffi.Pointer<ffi.Uint8> body,
    int bodyLength,
    int connectTimeoutMs,
    int readTimeoutMs,
  ) => _sendStreamRequestAsync(
    requestId,
    dartPort,
    method,
    url,
    headersJson,
    body,
    bodyLength,
    connectTimeoutMs,
    readTimeoutMs,
  );

  int cancelStreamRequest(int requestId) => _cancelStreamRequest(requestId);

  int sendMultipartRequestAsync(
    int requestId,
    int dartPort,
    ffi.Pointer<Utf8> method,
    ffi.Pointer<Utf8> url,
    ffi.Pointer<Utf8> headersJson,
    ffi.Pointer<Utf8> fieldsJson,
    ffi.Pointer<Utf8> filesJson,
    int connectTimeoutMs,
    int readTimeoutMs,
  ) => _sendMultipartRequestAsync(
    requestId,
    dartPort,
    method,
    url,
    headersJson,
    fieldsJson,
    filesJson,
    connectTimeoutMs,
    readTimeoutMs,
  );

  int cancelMultipartRequest(int requestId) =>
      _cancelMultipartRequest(requestId);

  int setCaBundlePath(ffi.Pointer<Utf8> caBundlePath) =>
      _setCaBundlePath(caBundlePath);
}
