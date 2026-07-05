# ohos_http agent notes

- Keep the Dart-facing API close to `ok_http` / `cupertino_http`.
- Prefer the smallest possible diff against upstream `immich` mobile code when integrating this package.
- Do not hand-author `.g.dart` / `.g.ets` files from scratch. Generate them from `pigeon/native_http_api_ohos.dart` with `pigeon`.

## Temporary multipart transport

The libcurl multipart upload path is a temporary workaround for the current OpenHarmony/Huawei NetworkKit multipart behavior where `multiFormDataList` with `remoteFileName` can load the file into memory before handing it to curl.

After Huawei fixes that system API behavior, switch multipart upload back to the system NetworkKit API and remove the extra libcurl-only workaround surface where possible, while keeping the Dart-facing API aligned with `ok_http` / `cupertino_http`.

Once the system API path is fixed and verified, remove the bundled libcurl transport and its native dependency libraries as well. Keeping libcurl only for this workaround significantly increases the install package size.

## Known OHOS Pigeon issue

After generating `ohos/src/main/ets/components/plugin/NativeHttpApiOhos.g.ets`, fix the generated ArkTS byte fields from `number[]` to `Uint8Array`.

Affected generated API surface:

- `NativeHttpRequestOhos.body`
- `NativeHttpResponseOhos.body`
- `NativeHttpFlutterApiOhos.onStreamData(..., chunkArg, ...)`

Update the related setter/getter/constructor/fromList signatures and casts as well.

Reason:

- OHOS `StandardMessageCodec` encodes `Uint8Array` as a typed byte array that Dart decodes as `Uint8List`.
- If ArkTS sends `number[]`, Dart receives a plain `List<Object?>`, and `NativeHttpResponseOhos.decode` / stream decode will fail with a `Uint8List` cast error.

Before finishing substantial plugin changes, verify with `flutter build hap --release` from `f:\\immich_ohos\\mobile`.
