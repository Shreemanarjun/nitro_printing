## 0.0.4

### Changed

- **Zero-hop native async (`@nitroNativeAsync`)**: Migrated 26 async API methods from `@nitroAsync` to nitro 0.5.9's zero-hop native-async path. Native work now runs directly on a Kotlin coroutine / Swift Task and posts the result back through a Dart port — no background isolate dispatch. Natively thrown errors complete the returned `Future` with a catchable exception. The 6 `@NitroResult` methods (`getPrinterAt`, `getDefaultPrinter`, `getPrinterCapabilities`, `getPrintJobAt`, `getPrintJobStatus`, `getPrinterStatusDetail`) remain on `@nitroAsync`, which the result encoding requires. Note: `@nitroNativeAsync` methods throw `UnsupportedError` on web.
- **Nitrogen SDK upgrade**: Upgraded `nitro` / `nitro_generator` to `0.5.9` and regenerated all platform bridges (`nitrogen generate` + `nitrogen link`).

### Fixed

- **iOS text orientation**: `printText` now honours `orientationDegrees` on iOS by swapping page dimensions for landscape (90°/270°), matching the image path and the Android/macOS behaviour. Previously iOS text prints were always portrait.
- **Android registration API**: Migrated `NitroPrintingPlugin` to the new `registerFactory` bridge API and updated `printBatch` to the properly typed `List<PrintDocument>` signature introduced by the 0.5.9 generator.

### Example app

- **Patrol test suites**: Added full [Patrol](https://patrol.leancode.co) native UI test infrastructure (Android instrumentation, iOS `RunnerUITests` target) with 24 tests across four suites: app UI flows, native print-spooler handoff incl. a complete Save-as-PDF print, in-process fake TCP/IPP network printers asserting transmitted bytes (exhaustive paper-size × orientation and copies sweeps, byte-exact ESC/POS and ZPL, IPP attributes), and native print-dialog preset verification (paper size, orientation, color).
- **Cross-platform transport tests**: Added `integration_test/native_transport_test.dart`, a plain integration suite that runs on Android, iOS **and macOS** (`flutter test`) and asserts the native layer transmits the selected configuration byte-for-byte to a fake in-process TCP printer, over the non-blocking socket transports (raw ESC/POS/ZPL/bytes on all three; direct-dispatch PDF with paper-size/orientation/copies sweeps on mobile).
- **macOS network entitlement**: Added `com.apple.security.network.client` to the example's macOS entitlements so the sandboxed app can reach network printers (the native `NWConnection` socket transport otherwise times out).
- **Raw tab on phones**: The printer endpoint / timeout card is now shown on narrow layouts too (previously desktop-width only).
- **Cleartext IPP**: Example Android manifest now sets `usesCleartextTraffic="true"` so `ipp://` (HTTP) network printers are reachable.

## 0.0.3

### Added

- **Batch Printing & Print Dialog**: Updated API methods for batch printing and native print dialog support.

### Changed

- **Nitrogen SDK Upgrade**: Upgraded `nitro` and `nitro_generator` dependencies to `0.4.5`.
- **API Refactor**: Removed `HybridNitroPrinting` implementation and integrated native Dart API headers directly.
- **Codebase Cleanup**: Removed auto-generated bridge files from VCS and cleaned up native interface definitions.

## 0.0.2

### Fixed

- **`getAllPrinters()` crash on iOS/macOS**: Fixed Swift bridge serialization of printer lists by using `encodeIndexedList` instead of `encodeList`.

### Added

- **Native `getAllPrinters()` on all platforms**: Implemented native printer retrieval across Android, iOS, macOS, Windows, Linux, and stub.
- **Example app updates**: Added a new "Printers" tab demonstrating synchronous printer list retrieval, live discovery toggle, status badges, and pull-to-refresh.
- **Integration tests**: Added comprehensive integration tests covering `getAllPrinters`, printer discovery stream sub/unsub, preview/render, platform UI, print jobs, and settings.

## 0.0.1

Initial release of `nitro_printing` — a high-performance Flutter printing plugin built on [Nitro for Flutter](https://nitro.shreeman.dev) with zero method-channel overhead.

### Added

- **Core Printing**: Support for printing text, image, PDF, HTML, and local files.
- **Export & Preview**: Virtual printing features like page count calculation, preview rendering, and writing to file.
- **Raw Printing**: Raw socket, ESC/POS, and ZPL protocol support with network job cancellation.
- **Job Management**: APIs to query status, pause, resume, cancel, or clear queues.
- **Printer & Status Queries**: Synchronous capabilities/driver version checks, and detailed real-time IPP status (ink levels, paper jams).
- **Discovery & Connections**: mDNS/Bonjour printer discovery, TCP connectivity checks, default printer settings, and real-time status/discovery streams.
- **Example App & Built-in UI**: Fully customizable Material 3 `NitroPrintSettingsPage` and a demo app showing print operations and settings.
- **Cross-platform**: Native Swift/Kotlin/C++ implementations for Android, iOS, macOS, Windows, and Linux.
