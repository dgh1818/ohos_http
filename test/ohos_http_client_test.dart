import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:ohos_http/src/native_http_api_ohos.g.dart';
import 'package:ohos_http/src/ohos_http_client.dart';

class _ThrowingNativeHttpApi extends NativeHttpApiOhos {
  @override
  Future<NativeHttpResponseOhos> sendRequest(
    NativeHttpRequestOhos request,
  ) async {
    throw PlatformException(
      code: 'HTTP_REQUEST_FAILED',
      message: 'http_request_failed',
      details: '2300028:BusinessError:SSL certificate verification failed',
    );
  }
}

void main() {
  test('includes platform exception details in client errors', () async {
    final client = OhosHttpClient(nativeApi: _ThrowingNativeHttpApi());
    final request = http.Request('GET', Uri.parse('https://example.com'));

    await expectLater(
      client.send(request),
      throwsA(
        isA<http.ClientException>().having(
          (error) => error.message,
          'message',
          contains(
            'HTTP_REQUEST_FAILED: http_request_failed: '
            '2300028:BusinessError:SSL certificate verification failed',
          ),
        ),
      ),
    );
  });
}
