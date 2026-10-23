# emu_hook

Routes a Flutter app's HTTP requests for chosen hosts through a running
[emu](https://github.com/HuanSuh/emu) session, so `emu mock` can answer them with
canned responses (or pass them on to the real server) — without changing the
app's base URLs.

```yaml
dependencies:
  emu_hook:
    git: { url: https://github.com/HuanSuh/emu, path: packages/emu_hook }
```

```dart
import 'package:emu_hook/emu_hook.dart';
import 'package:flutter/foundation.dart';

void main() {
  if (kDebugMode && EmuHttp.enabled) EmuHttp.install();
  runApp(const App());
}
```

- `EmuHttp.enabled` is a compile-time constant, true only when `emu up` passed
  `--dart-define=EMU_MOCK=<host:port>` (it does when emu.yaml has `mocks.hosts`).
  Any other build — a plain `flutter run`, the IDE, release — is untouched and
  drops the hook.
- Only the hosts in `EMU_MOCK_HOSTS` are routed. Their requests reach emu as
  plain HTTP with the URL and `Host` header unchanged (`https://` origins on the
  port, `http://` ones on port + 1), so no certificate is involved.
- Other hosts connect exactly as before: the app's `findProxy`,
  `connectionFactory`, `badCertificateCallback` and `keyLog` still apply.
- Install it after any `HttpOverrides` of the app's own — it wraps whatever is
  current.
- Covers everything on `dart:io` `HttpClient` (`package:http`, Dio). WebViews and
  platform-channel networking are not covered.

See the emu README, "API mocks", for `mocks:` and `emu mock`.
