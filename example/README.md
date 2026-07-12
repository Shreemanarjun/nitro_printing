# nitro_printing_example

Demonstrates how to use the nitro_printing plugin.

The app has five tabs, each exercising a different part of the plugin API:

| Tab      | What it demonstrates                                              |
| -------- | ----------------------------------------------------------------- |
| Status   | Capability lookups, default printer, IPP status inquiry           |
| Printers | Printer enumeration and mDNS/Bonjour discovery                    |
| Print    | Text/image/PDF printing, batch printing, system dialog vs. direct |
| Raw      | ESC/POS, ZPL, and raw byte-stream network printing                |
| Jobs     | Print queue inspection and job event telemetry streams            |

## Tests

There are two test suites:

- `integration_test/nitro_printing_test.dart` — API-level integration tests
  that call the plugin directly (no UI). Run with:

  ```sh
  flutter test integration_test/nitro_printing_test.dart -d <device>
  ```

- `patrol_test/app_ui_test.dart` — [Patrol](https://patrol.leancode.co) UI
  tests that drive the real app (tab navigation, buttons, text fields, and
  the native Android print dialog). Requires `patrol_cli`
  (`dart pub global activate patrol_cli`). Run with:

  ```sh
  patrol test -d <device>
  ```

  Patrol native setup lives in:
  - `pubspec.yaml` → `patrol:` config block
  - `android/app/build.gradle.kts` + `android/app/src/androidTest/.../MainActivityTest.java`
  - `ios/RunnerUITests/RunnerUITests.m` + the `RunnerUITests` target in
    `ios/Runner.xcodeproj` (already registered in the Podfile and the shared
    Runner scheme)

## Getting Started

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.
