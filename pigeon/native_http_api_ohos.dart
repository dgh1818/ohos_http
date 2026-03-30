import 'package:pigeon/pigeon.dart';

class NativeHttpRequestOhos {
  String method;
  String url;
  Map<String, String> headers;
  Uint8List? body;

  NativeHttpRequestOhos(this.method, this.url, this.headers, this.body);
}

class NativeHttpResponseOhos {
  int statusCode;
  Map<String, String> headers;
  Uint8List body;

  NativeHttpResponseOhos(this.statusCode, this.headers, this.body);
}

class NativeHttpStreamHeadersOhos {
  int? statusCode;
  Map<String, String> headers;

  NativeHttpStreamHeadersOhos(this.statusCode, this.headers);
}

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/src/native_http_api_ohos.g.dart',
    arkTSOut: 'ohos/src/main/ets/components/plugin/NativeHttpApiOhos.g.ets',
    arkTSOptions: ArkTSOptions(),
    dartOptions: DartOptions(),
    dartPackageName: 'ohos_http',
  ),
)
@HostApi()
abstract class NativeHttpApiOhos {
  @async
  NativeHttpResponseOhos sendRequest(NativeHttpRequestOhos request);

  @async
  void sendStreamRequest(int requestId, NativeHttpRequestOhos request);

  void cancelStreamRequest(int requestId);
}

@FlutterApi()
abstract class NativeHttpFlutterApiOhos {
  @async
  void onStreamHeaders(int requestId, NativeHttpStreamHeadersOhos response);

  @async
  void onStreamData(int requestId, Uint8List chunk);

  @async
  void onStreamComplete(int requestId, int statusCode);

  @async
  void onStreamError(int requestId, String code, String message);
}
