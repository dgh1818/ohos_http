# ohos_http agent notes

- Keep the Dart-facing API close to `ok_http` / `cupertino_http`.
- Prefer the smallest possible diff against upstream `immich` mobile code when integrating this package.
- Do not hand-author `.g.dart` / `.g.ets` files from scratch. Generate them from `pigeon/native_http_api_ohos.dart` with `pigeon`.

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
