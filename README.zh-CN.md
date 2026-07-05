# ohos_http

语言：[English](README.md) | 中文

`ohos_http` 将 OpenHarmony NetworkKit 暴露为一个 `package:http` client，并为 OHOS 上需要流式回调或基于文件路径的 multipart 上传场景提供临时的 libcurl transport。

应用代码只应使用公开的 Dart 入口：

```dart
import 'package:ohos_http/ohos_http.dart';
```

不要在应用代码里直接调用生成的 Pigeon API 或 FFI runtime 类。除非被 `ohos_http.dart` 导出，否则 `lib/src/` 下的文件都属于实现细节。

## 公开 API

| API | 用途 |
| --- | --- |
| `OhosHttpClient` | 兼容 `package:http` 的 OHOS HTTP client。 |
| `OhosMultipartRequest` | 携带源文件路径的 multipart request，用于 native 上传。 |
| `OhosMultipartFile` | `OhosMultipartRequest` 的文件 part 描述。 |

## 创建 Client

```dart
final client = OhosHttpClient();
```

可选超时配置：

```dart
final client = OhosHttpClient(
  connectTimeout: const Duration(seconds: 10),
  readTimeout: const Duration(minutes: 2),
);
```

`close()` 会取消该 client 拥有的未完成 streaming 和 multipart 请求。

```dart
client.close();
```

## 普通缓冲请求

`OhosHttpClient` 继承自 `http.BaseClient`，所以普通 `package:http` helper 可以直接使用：

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

携带 Dart body 的 POST：

```dart
final response = await client.post(
  Uri.parse('https://example.com/api/items'),
  headers: <String, String>{
    'Content-Type': 'application/json',
  },
  body: '{"name":"demo"}',
);
```

普通缓冲请求在 native 侧通过 worker 使用 OHOS NetworkKit。

## 流式响应

当请求的 `Accept` header 包含 `application/jsonlines+json` 时，响应会通过 libcurl FFI transport 走流式回调。

示例：

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
  // 处理每一行 JSONL event。
  print(line);
}
```

如果 libcurl FFI transport 不可用，streaming 请求会抛出 `http.ClientException`。

## Multipart 上传

OHOS 上从磁盘上传文件时使用 `OhosMultipartRequest`。文件路径会传给 native libcurl 上传路径，因此 Dart client 不会在内存里构造完整 multipart body。

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

当前限制：`OhosHttpClient` 只发送 `OhosMultipartRequest.files` 中的第一个文件。需要上传多个文件时，请每个请求只添加一个文件。

## 取消请求

multipart 上传可以通过完成 `abortTrigger` 来取消：

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
  // 上传已取消。
}
```

对于使用 `package:http` abortable request 类型的 streaming 请求，client 会把 abort 转发给 native transport。调用 `close()` 也会取消该 `OhosHttpClient` 拥有的未完成 streaming 和 multipart transport。

## Native 请求状态和证书

OHOS plugin 会读取 Immich OHOS app 使用的同一套持久化 request state 和 client certificate schema：

- preference name: `Immich::ClientCert`
- request headers: `requestHeaders`
- server URLs: `serverUrls`
- auth token: `authToken`
- cert fields: `certPath`, `keyPath`, `certType`, `keyPassword`

native 层会把这些状态应用到发出的请求上。如果应用已经有 OHOS bridge 用来设置请求 header 或导入 client certificate，就不需要再通过 Dart client 传递这些值。

当 app sandbox 中存在 CA bundle 时，OHOS NetworkKit 路径会设置 `HttpRequestOptions.caPath`，libcurl FFI 路径会设置 `CURLOPT_CAINFO`。这样两个 native transport 都可以校验由私有 CA 签发的服务器证书。

## 临时 libcurl Transport

libcurl multipart 上传路径是临时方案。它用于规避当前 OpenHarmony/Huawei NetworkKit multipart 行为：`multiFormDataList` 搭配 `remoteFileName` 时，文件内容可能在交给 curl 之前先被加载进内存。

等这个系统 API 行为修复并验证后，multipart 上传应改回 NetworkKit，并移除 bundled libcurl transport 和相关 native 依赖库，以减小安装包体积。
