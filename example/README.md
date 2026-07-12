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

  > On **iOS and macOS**, the print methods that use the default
  > `showPrintDialog: true` present a *modal* native print panel
  > (`UIPrintInteractionController` / `NSPrintPanel`) and wait for a user to
  > confirm or cancel. In a headless test run there is no user, so those
  > specific tests block/time out. This is correct platform behaviour, not a
  > plugin fault — Android's spooler handoff is fire-and-forget, which is why
  > the same suite passes there. Use the transport suite below for
  > non-blocking iOS/macOS coverage.

- `integration_test/native_transport_test.dart` — cross-platform
  verification (Android, iOS **and macOS**) that the configuration selected
  in Dart is transmitted byte-for-byte by the *native* layer, using a fake
  TCP printer running inside the test process. Exercises only the
  non-blocking socket transports (raw ESC/POS · ZPL · raw bytes on all three
  platforms; direct-dispatch PDF rendering with paper-size/orientation/copies
  sweeps on Android + iOS). Run with:

  ```sh
  flutter test integration_test/native_transport_test.dart -d macos
  flutter test integration_test/native_transport_test.dart -d <ios-simulator>
  ```

- `patrol_test/` — [Patrol](https://patrol.leancode.co) UI tests. Requires
  `patrol_cli` (`dart pub global activate patrol_cli`). Run with:

  ```sh
  patrol test -d <device>                                  # everything
  patrol test -t patrol_test/native_print_test.dart -d ... # one file
  ```

  - `app_ui_test.dart` — drives the app UI: tab navigation, buttons, text
    fields, discovery/telemetry toggles.
  - `native_print_test.dart` — Android-native printing paths: handoff to the
    system print spooler for text/PDF/image, a complete print via the
    spooler's "Save as PDF" destination (verified in the native spool
    afterwards), and the dialog-less direct-dispatch transport
    (NO_PRINTER validation, closed-socket failure, batch stop-on-error).
  - `network_printer_test.dart` — spins up fake network printers (raw TCP
    and IPP) *inside the test process* and asserts the bytes the native
    layer transmits: PDF rendering, ESC/POS and ZPL payloads byte-for-byte,
    IPP attributes, and exhaustive configuration sweeps (every paper size ×
    orientation as PDF MediaBox dimensions, every copies count as payload
    repetitions).
  - `native_dialog_config_test.dart` — opens the Android print dialog and
    verifies its native spinners are preset to the configuration selected
    in the app (paper size, orientation, color; the framework does not
    accept a preset copies count, which is asserted too).

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
