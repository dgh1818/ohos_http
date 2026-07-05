# ohos_http

Language: English | [中文](README.zh-CN.md)

`ohos_http` exposes OpenHarmony NetworkKit as a `package:http` client and adds
temporary libcurl-backed transports for OHOS cases that need streaming callbacks
or file-path multipart upload.

Use only the public Dart entrypoint:

```dart
import 'package:ohos_http/ohos_http.dart';
```

Do not call generated Pigeon APIs or FFI runtime classes directly from app code.
Files under `lib/src/` are implementation details unless exported by
`ohos_http.dart`.

## Public API

| API | Purpose |
| --- | --- |
| `OhosHttpClient` | `package:http` compatible client for OHOS. |
| `OhosMultipartRequest` | Multipart request that carries a source file path for native upload. |
| `OhosMultipartFile` | File part descriptor for `OhosMultipartRequest`. |

## Client Construction

```dart
final client = OhosHttpClient();
```

Optional timeouts:

```dart
final client = OhosHttpClient(
  connectTimeout: const Duration(seconds: 10),
  readTimeout: const Duration(minutes: 2),
);
```

`close()` cancels pending streaming and multipart requests owned by that client.

```dart
client.close();
```

## Buffered Requests

`OhosHttpClient` extends `http.BaseClient`, so normal `package:http` request
helpers work:

```dart
final response = await client.get(
  Uri.parse('https://example.com/api/server-info'),
  headers: <String, String>{
    'Accept': 'application/json',
  },
);

if (response.statusCode != 200) {
  throw Exception('Request failed: ${response.statusCode}');
}
```

POST with a Dart body:

```dart
final response = await client.post(
  Uri.parse('https://example.com/api/items'),
  headers: <String, String>{
    'Content-Type': 'application/json',
  },
  body: '{"name":"demo"}',
);
```

For ordinary buffered requests, the native side uses OHOS NetworkKit through a
worker.

## Streaming Responses

Streaming responses are routed through the libcurl FFI transport when the
request `Accept` header contains `application/jsonlines+json`.

Example:

```dart
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:ohos_http/ohos_http.dart';

final client = OhosHttpClient();
final request = http.Request(
  'GET',
  Uri.parse('https://example.com/api/sync/stream'),
)
  ..headers['Accept'] = 'application/jsonlines+json';

final response = await client.send(request);

await for (final line in response.stream
    .transform(utf8.decoder)
    .transform(const LineSplitter())) {
  // Handle each JSONL event.
  print(line);
}
```

If the libcurl FFI transport is unavailable, streaming requests fail with
`http.ClientException`.

## Multipart Upload

Use `OhosMultipartRequest` when uploading one or more files from disk on OHOS.
Each file path is passed to the native libcurl upload path, so the Dart client
does not build the full multipart body in memory.

```dart
import 'package:ohos_http/ohos_http.dart';

final request = OhosMultipartRequest(
  'POST',
  Uri.parse('https://example.com/api/assets'),
);

request.headers.addAll(<String, String>{
  'Authorization': 'Bearer token',
});

request.fields.addAll(<String, String>{
  'deviceAssetId': 'local-id',
  'deviceId': 'ohos-device',
});

request.files.add(
  const OhosMultipartFile(
    field: 'assetData',
    filePath: '/data/storage/el2/base/files/photo.jpg',
    filename: 'photo.jpg',
    contentType: 'image/jpeg',
  ),
);

request.onProgress = (bytesSent, totalBytes) {
  print('$bytesSent / $totalBytes');
};

final response = await OhosHttpClient().send(request);
```

## Cancellation

For multipart upload, complete `abortTrigger` to cancel:

```dart
import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:ohos_http/ohos_http.dart';

final cancel = Completer<void>();

final request = OhosMultipartRequest('POST', uploadUri)
  ..abortTrigger = cancel.future;

final future = OhosHttpClient().send(request);

cancel.complete();

try {
  await future;
} on http.RequestAbortedException {
  // Upload was cancelled.
}
```

For streaming requests using `package:http` abortable request types, the client
forwards the abort to the native transport. Calling `close()` also cancels
pending streaming and multipart transports owned by that `OhosHttpClient`.

## Native Request State And Certificates

The OHOS plugin reads the same persisted request-state and client-certificate
schema used by the Immich OHOS app:

- preference name: `Immich::ClientCert`
- request headers: `requestHeaders`
- server URLs: `serverUrls`
- auth token: `authToken`
- cert fields: `certPath`, `keyPath`, `certType`, `keyPassword`

The native layer applies that state to outgoing requests. Apps that already have
an OHOS bridge for setting request headers or importing client certificates do
not need to pass those values through the Dart client.

When a CA bundle is available in the app sandbox, the OHOS NetworkKit path sets
`HttpRequestOptions.caPath`, and the libcurl FFI path sets `CURLOPT_CAINFO`.
This lets both native transports verify servers signed by an imported private
CA.

## Temporary libcurl Transport

The libcurl multipart upload path is temporary. It exists to avoid the current
OpenHarmony/Huawei NetworkKit multipart behavior where `multiFormDataList` with
`remoteFileName` can load file content into memory before curl receives it.

After that system API behavior is fixed and verified, multipart upload should
move back to NetworkKit and the bundled libcurl transport/dependency libraries
should be removed to reduce install package size.
