## 0.0.6

### Changed

- Nitrogen SDK 0.7.4 to 0.7.5 (`nitro` / `nitro_generator` / `nitro_annotations` / `nitrogen_cli`); all platform bridges regenerated.

### Fixed

- `web` is now declared in the plugin's `platforms:` map. 0.0.5 shipped the WASM backend but never declared the platform, so pub.dev did not list Web as supported. Registration is a no-op stub (`NitroPrintingWeb`) — the backend is the WASM module loaded by `ensureNitroPrintingReady()`, not a method channel — but Flutter requires a `pluginClass` before `web:` may be declared.

## 0.0.5

### Added

- Web (WASM) support: the same C++ core compiled with Emscripten, feature-detected at runtime. Dialog printing (text/HTML/image/PDF) applies `PrintSettings` via CSS `@page` — paper size, orientation, margins, copies (collated or not), grayscale, header/footer, page ranges, N-up, job name. `printToFile` downloads a PDF; `printFile` prints `http(s)`/`data:`/`blob:` URLs.
- Web raw transports, selected by `PrintSettings.printerId` scheme: WebUSB (`usb:`), Web Serial (`serial:[baud]`), Web Bluetooth (`ble:[name]`), WebSocket relay (`ws://`), Direct Sockets TCP in Isolated Web Apps (`socket://` or bare IP). ESC/POS text is CP437-encoded; images raster to `GS v 0`.
- QZ Tray transport (`qz:`): silent raw and PDF printing through the [QZ Tray](https://github.com/qzind/tray) agent, with spool-confirmed results, printer enumeration, and status on `onPrinterStatusChanged`.
- Nitro Print Agent (`agent:`): local agent app in `agent/` exposing this plugin's native backends over a localhost WebSocket — silent text/image/PDF/raw to any OS printer, with native job ids and lifecycle events. Configure via `WebPrintAgent.configure(agentEndpoint:)`.
- Web Printing API + mDNS (Isolated Web Apps, Chrome 147+): printer enumeration with IPP capabilities and state reasons, silent PDF jobs with page progress and IPP attributes (copies, duplex, color, quality, orientation, media, page ranges, collation, number-up, print-scaling), and mDNS discovery over Direct Sockets UDP.
- `renderPreview` rasters the same pipeline the dialog prints, so copies, N-up, grayscale, and decoration are accurate. PDF `pageRange` extraction on wasm, `getPageCount` via PDF page trees, HTML to multi-page PDF.
- Job tracking on web — every print (dialog, raw, batch, agent) is a tracked job: `onPrintJobChanged`, `PrintErrorCode` catalog (`PrintResult.errorKind`), `PrintOutcome` (`printed` only on verified delivery, `dialogShown` where the browser hides Print-vs-Cancel), `dialogDurationMs`/`dialogGuess`, `PrintOutcomeConfirmation.markJobOutcome`, `PrintJob.failureReason`, `lastPrintJob()`, `resumePrintJob`.
- `WebPrintDecor`: per-page background graphics (watermark/letterhead) and HTML header/footer for dialog and preview.
- Web multi-instance: `createNitroPrintingInstance(key)` builds one `HybridNitroPrinting` per key, each with its own printer/job caches, agent socket and status poll. Stream events reach only the instance that emitted them; `dispose()` releases that instance's native and JS state.
- Web JPEG encoding runs on a worker pool (`min(4, hardwareConcurrency)`), so rasterisation no longer blocks the main thread and pages encode in parallel. Falls back inline where `Worker` is unavailable or CSP-blocked.

### Changed

- Nitrogen SDK 0.5.11 to 0.7.4 (`nitro` / `nitro_generator` / `nitro_annotations` / `nitrogen_cli`); all platform bridges regenerated. `@nitroNativeAsync` now works on web — the 0.0.4 `UnsupportedError` note no longer applies.
- The spec singleton comes from `createNitroPrintingInstance()`. Await `ensureNitroPrintingReady()` in `main()` — a no-op on native platforms.

### Fixed

- Web: helpers are rebuilt when the WASM module instance changes. A Flutter hot restart kept `globalThis` but replaced the module, so the first call after one threw `RuntimeError: memory access out of bounds`.
- Web: job history is capped at 200 entries, evicting finished jobs first. Every print appended a record that was never released.
- Nitro Print Agent prints silently — `showPrintDialog` defaults to true, so the agent opened a modal print panel in its own process and the browser call blocked until it was dismissed.
- Example: the LIVE PREVIEW header no longer overflows at phone widths.

### Example app

- Two-pane Print tab: configuration left, full-height live preview right, with page/sheet/size stats, active-setting chips, and a double-buffered PDF viewer.
- Page decoration panel, header/footer fields, expanded Document Settings (media type, margins, page range, collate, fit-to-page, custom paper size).
- Jobs tab last-job card with typed failure reason and Resume.
- Web integration test target (`integration_test/web_test.dart`).

### Testing

- 130 browser tests under both dart2js and dart2wasm: WebSocket-relay byte round-trips, mock QZ Tray and Nitro Print Agent servers, preview fidelity (copies/N-up/geometry in the output PDF), and the full error/outcome catalog. Instance isolation, hot-restart recovery, job-history capping and worker offload are covered.
- Patrol suites green in CI on iOS (24/24) and Android (24/24).

## 0.0.4

### Changed

- **Zero-hop native async (`@nitroNativeAsync`)**: Migrated 26 async API methods from `@nitroAsync` to nitro 0.5.9's zero-hop native-async path. Native work now runs directly on a Kotlin coroutine / Swift Task and posts the result back through a Dart port — no background isolate dispatch. Natively thrown errors complete the returned `Future` with a catchable exception. The 6 `@NitroResult` methods (`getPrinterAt`, `getDefaultPrinter`, `getPrinterCapabilities`, `getPrintJobAt`, `getPrintJobStatus`, `getPrinterStatusDetail`) remain on `@nitroAsync`, which the result encoding requires. Note: `@nitroNativeAsync` methods throw `UnsupportedError` on web.
- **Nitrogen SDK upgrade**: Upgraded `nitro` / `nitro_generator` to `0.5.9` and regenerated all platform bridges (`nitrogen generate` + `nitrogen link`).

### Added

- **Windows/Linux C++ backend**: Implemented a real cross-platform TCP socket transport (POSIX + winsock, non-blocking connect with select-based timeout) for `printRaw` / `printEscPos` / `printZpl` / `testPrinterConnection` and dialog-less document dispatch, plus honest failure results for OS-print-stack features not available in a headless native backend. Windows and Linux use per-platform-separated sources (`windows/src/` / `linux/src/HybridNitroPrinting.cpp`, spec `WindowsNativeImpl.cpp` / `LinuxNativeImpl.cpp`) so they can diverge independently. Verified to compile against the regenerated bridge.
- **Nitro 0.5.10**: Upgraded `nitro` / `nitro_generator` to 0.5.10, which fixes the two C-bridge generator bugs that previously blocked all desktop builds (the `@NitroResult` record shims assigning `NitroCppBuffer` to `std::string`, and optional record params dereferencing a null pointer — reported as nitro_ecosystem#9).
- **iOS HTML direct dispatch**: `printDocument`/`printHtml` with `showPrintDialog: false` now render the markup to PDF and send it over the network transport, matching the text/PDF/image direct paths (previously HTML always forced the modal print dialog).

### Fixed

- **iOS text orientation**: `printText` now honours `orientationDegrees` on iOS by swapping page dimensions for landscape (90°/270°), matching the image path and the Android/macOS behaviour. Previously iOS text prints were always portrait.
- **Android registration API**: Migrated `NitroPrintingPlugin` to the new `registerFactory` bridge API and updated `printBatch` to the properly typed `List<PrintDocument>` signature introduced by the 0.5.9 generator.

### Testing & CI

- **API suite runs on every platform**: print-invoking tests now pick the safe
  mode per platform — Android keeps the (fire-and-forget) dialog, iOS runs
  dialog-less (fails fast with NO_PRINTER instead of blocking on the modal
  panel), and desktop skips OS-print calls entirely because dialog-less
  printing there would reach the physical default printer. 161/161 green on
  macOS and Android.
- **Extended transport suite**: `testPrinterConnection` positive/negative
  probes against a live fake printer, IPP `printRaw` end-to-end against a fake
  IPP endpoint (job-name + payload verified in the request), and `printToFile`
  PDF output verified against the configured paper size.
- **GitHub Actions CI** (`.github/workflows/ci.yml`): analyze + Android
  emulator (integration + Patrol) + iOS simulator (integration + Patrol) +
  macOS, Linux, and Windows desktop integration runs.

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
