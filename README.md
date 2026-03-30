# ohos_http

`ohos_http` exposes OpenHarmony `NetworkKit` as a `package:http` client.

It is intended for apps that already manage request headers, auth cookies, and
client certificates on the OHOS side and want Dart HTTP traffic to reuse that
native behavior.

## Usage

```dart
import 'package:ohos_http/ohos_http.dart';

final client = OhosHttpClient();
final response = await client.get(Uri.parse('https://example.com'));
```

The OHOS plugin reads the same persisted request-state and client-certificate
schema used by the Immich OHOS app:

- preference name: `Immich::ClientCert`
- request headers: `requestHeaders`
- server URLs: `serverUrls`
- auth token: `authToken`
- cert fields: `certPath`, `keyPath`, `certType`, `keyPassword`

That keeps the package small and lets an app-native `setRequestHeaders(...)`
bridge populate auth state without extra Dart wiring.
