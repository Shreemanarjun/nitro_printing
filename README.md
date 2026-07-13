# nitro_printing

[![pub version](https://img.shields.io/pub/v/nitro_printing.svg)](https://pub.dev/packages/nitro_printing)
[![Platform](https://img.shields.io/badge/platform-android%20%7C%20ios%20%7C%20macos%20%7C%20windows%20%7C%20linux-blue)](https://pub.dev/packages/nitro_printing)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

A **high-performance Flutter printing plugin** built on top of the **Nitrogen SDK** —
a Flutter port of [Nitro Modules for React Native](https://nitro.margelo.com) that calls
native code **directly via Dart FFI**, completely bypassing Flutter method channels.

---

## What is Nitro / Nitrogen?

[Nitro Modules](https://nitro.margelo.com) is a React Native library by Marc Rousavy (Margelo)
that replaces the JS bridge with **zero-overhead JSI bindings**. The Nitrogen SDK
([`nitro`](https://pub.dev/packages/nitro) · [`nitro_generator`](https://pub.dev/packages/nitro_generator) · [`nitrogen_cli`](https://pub.dev/packages/nitrogen_cli))
is a **Flutter port** of that same concept — it replaces method channels with pure
**Dart FFI** (C ABI) calls, using `dart:ffi` and a code-generation pipeline
(`build_runner` + `nitro_generator`) that turns a single annotated Dart file into
type-safe Dart ↔ Kotlin / Swift / C++ bridge code.

```
nitro ecosystem (Flutter port of React Native Nitro Modules)
├── nitro               ← runtime: HybridObject, annotations, NitroRuntime
├── nitro_annotations   ← @NitroModule, @HybridStruct, @HybridEnum, @nitroAsync, @NitroStream
├── nitro_generator     ← build_runner builder → generates *.g.dart + native stubs
└── nitrogen_cli        ← CLI: scaffold plugins, run generator, doctor
```

> **Repository:** https://github.com/Shreemanarjun/nitro_ecosystem
>
> **Docs:** https://nitro.shreeman.dev

---

## Why nitro_printing vs. existing packages?

| Feature | `printing` (pub.dev) | `nitro_printing` |
|---|---|---|
| **Bridge** | Method channels (async serialize/deserialize) | Nitrogen JSI/FFI — **zero serialization overhead** |
| **Sync printer queries** | ❌ always async | ✅ `isPrintingSupported()`, `getPrintersCount()`, `getPrinterDriverVersion()` are **synchronous** |
| **Zero-hop async** | ❌ | ✅ `@nitroNativeAsync` — native coroutine/Task posts straight back to Dart, no isolate hop |
| **Raw TCP / ESC-POS / ZPL** | ❌ not supported | ✅ `printRaw`, `printEscPos`, `printZpl` |
| **mDNS/Bonjour discovery** | ❌ | ✅ `startPrinterDiscovery` + `onPrinterDiscovered` stream |
| **IPP detailed status** | ❌ | ✅ `getPrinterStatusDetail` (ink, paper jam, toner, …) |
| **Real-time job streams** | ❌ polling only | ✅ `onPrintJobChanged`, `onPrinterStatusChanged` (zero-copy streams) |
| **Print-to-file (virtual)** | Limited | ✅ `printToFile`, `renderPreview` |
| **Built-in settings UI** | ❌ | ✅ `NitroPrintSettingsPage` — Material 3 full-screen editor |
| **Batch printing** | ❌ | ✅ `printBatch` extension |
| **Platforms** | Android, iOS, macOS, Web | Android, iOS, macOS, Windows, Linux (all but Web) |

---

## Installation

```yaml
dependencies:
  flutter:
    sdk: flutter
  nitro_printing: ^0.0.4
```

```bash
flutter pub get
```

---

## Required Platform Setup

Before running your application, ensure you have configured the required permissions and system packages for your target platforms:

### 🤖 Android

The plugin requires the `INTERNET` permission to connect to network printers (IPP, TCP raw sockets) and to run mDNS discovery.

In your app's `android/app/src/main/AndroidManifest.xml`, ensure the following is present:
```xml
<uses-permission android:name="android.permission.INTERNET"/>
```
*(Note: The plugin's own manifest includes this permission, so Gradle will merge it automatically, but it is recommended to declare it in the main app.)*

---

### 🍎 iOS

The plugin uses Apple's Bonjour/mDNS framework (`NetServiceBrowser`) to search for network-enabled IPP printers. On iOS 14+, you must declare local network permissions and the specific Bonjour services the app will query in `ios/Runner/Info.plist`:

1. **Local Network Usage Description**: A description explaining why local network access is needed.
2. **Bonjour Services**: The list of service types (`_ipp._tcp` and `_ipps._tcp`).

Add the following keys to your `Info.plist`:
```xml
<key>NSLocalNetworkUsageDescription</key>
<string>This app requires access to the local network to discover and connect to network printers.</string>
<key>NSBonjourServices</key>
<array>
  <string>_ipp._tcp</string>
  <string>_ipps._tcp</string>
</array>
```

---

### 💻 macOS

#### 1. Sandbox Entitlements
If your macOS app has App Sandbox enabled (default for Flutter templates), you must add the printing and network client entitlements in both `macos/Runner/DebugProfile.entitlements` and `macos/Runner/Release.entitlements`:
```xml
<!-- Allow printing operations -->
<key>com.apple.security.print</key>
<true/>

<!-- Allow outgoing network connections to TCP/IPP/mDNS printers -->
<key>com.apple.security.network.client</key>
<true/>
```

#### 2. Local Network & Bonjour (macOS 11+)
If sandbox is enabled and you are performing printer discovery, declare the Bonjour service details in `macos/Runner/Info.plist` (similar to iOS):
```xml
<key>NSLocalNetworkUsageDescription</key>
<string>This app requires access to the local network to discover and connect to network printers.</string>
<key>NSBonjourServices</key>
<array>
  <string>_ipp._tcp</string>
  <string>_ipps._tcp</string>
</array>
```

---

### 🐧 Linux

No external dependencies are required by the plugin itself — the Linux backend
is a pure C++ FFI implementation using TCP sockets (no CUPS linkage). You only
need the standard Flutter Linux desktop toolchain:

```bash
sudo apt-get install -y ninja-build libgtk-3-dev
```

> **Current scope on Linux:** network/raw printing (`printRaw`, `printEscPos`,
> `printZpl`, dialog-less `printText`/`printPdf`/`printDocument` routed to a
> printer URI) and `testPrinterConnection`. OS print-stack features (system
> print dialog, printer enumeration, job queue, previews) are not implemented
> yet and return graceful failure results instead of crashing or hanging.

---

### 🪟 Windows

No special permissions, configuration, or external dependencies are required —
the Windows backend is a pure C++ FFI implementation using Winsock TCP sockets.

> **Current scope on Windows:** same as Linux — network/raw printing and
> connection probing; OS print-stack features (dialog, spooler queue,
> enumeration, previews) return graceful failure results until a WinSpool
> backend lands.

---

## Quick Start

```dart
import 'package:nitro_printing/nitro_printing.dart';

final printing = NitroPrinting.instance;

// Synchronous — no await, no Isolate
if (!printing.isPrintingSupported()) return;

// Print a PDF
final pdfBytes = await loadPdfAsset();
final result = await printing.printPdf(
  pdfBytes,
  settings: PrintSettings(
    printerId: 'My Printer',
    paperSize: PaperSize.a4,
    quality: PrintQuality.high,
    duplex: true,
  ),
);

if (result.success) {
  print('Job ID: ${result.jobId}');
}
```

---

## API Reference

### `NitroPrinting.instance`

The singleton entry point. Defined as a `@NitroModule` extending `HybridObject` —
the Nitrogen runtime creates the FFI bridge automatically via code generation.

---

### Synchronous Queries (no `await`, no Isolate overhead)

These are direct Dart FFI calls that execute in < 1 µs — safe to call on the UI thread.

```dart
bool isPrintingSupported();
int getPrintersCount();
String getPrinterDriverVersion(String printerId);
```

---

### Printer Info & Lookups

`getAllPrinters` runs on the zero-hop `@nitroNativeAsync` path; the
`NitroResultValue` lookups are `@nitroAsync` + `@NitroResult` — failures come
back as a typed `NitroErr` instead of a thrown exception.

```dart
Future<List<PrinterInfo>> getAllPrinters();                                    // @nitroNativeAsync
Future<NitroResultValue<PrinterInfo>> getPrinterAt(int index);                 // NitroOk | NitroErr
Future<NitroResultValue<PrinterInfo>> getDefaultPrinter();
Future<NitroResultValue<PrinterCapabilities>> getPrinterCapabilities(String printerId);
```

```dart
switch (await printing.getDefaultPrinter()) {
  case NitroOk(:final value): print('Default: ${value.name}');
  case NitroErr(:final message): print('No default printer: $message');
}
```

**Example — populate a printer list:**
```dart
final printers = await printing.getAllPrinters();
```

---

### Print Operations (`@nitroNativeAsync`)

Marked `@nitroNativeAsync` — the zero-hop native-async path. The native side
runs the work on its own Kotlin coroutine / Swift Task / C++ worker thread and
posts the result straight back to Dart (`Dart_PostCObject`) — no background
isolate is spawned. Errors thrown natively complete the `Future` with a
catchable exception.

```dart
Future<PrintResult> printText(String text, {PrintSettings? settings});
Future<PrintResult> printImage(Uint8List imageData, {PrintSettings? settings});
Future<PrintResult> printPdf(Uint8List pdfData, {PrintSettings? settings});
Future<PrintResult> printDocument(PrintDocument document, {PrintSettings? settings});
Future<bool>        printFile(String filePath, {PrintSettings? settings});
Future<List<PrintResult>> printBatch(List<PrintDocument> documents, bool stopOnError, {PrintSettings? settings});
```

---

### OS Print Dialog (`@nitroNativeAsync`)

Show the native OS print dialog, or use the controller for advanced flows:

```dart
Future<PrintDialogResult> showPrintDialog(PrintDocument document, {PrintSettings? initialSettings});

// Controller for orchestration:
final controller = PrintDialogController(initialSettings: PrintSettings(copies: 2));
final result = await controller.showDialog(document);
if (result.confirmed) {
  // result.confirmedSettings reflects user choices
  await controller.printDirect(document);
}
```

**`PrintResult`** contains `success`, `jobId`, `errorMessage`, `errorCode`.

> **Platform behaviour of `showPrintDialog: true`:** on **Android** the call
> resolves as soon as the job is handed to the print spooler (fire-and-forget);
> on **iOS/macOS** the native panel is modal — the `Future` resolves when the
> user confirms or cancels. On **Windows/Linux** the dialog is not implemented
> yet and a failure `PrintResult` (`UNSUPPORTED_PLATFORM`) is returned. For
> headless/automated flows use `showPrintDialog: false` with a `printerId`.

---

### Export / Virtual Print

```dart
/// Render a document to PDF bytes without sending to a printer (for previews).
Future<PreviewResult> renderPreview(PrintDocument document, {PrintSettings? settings});

/// Count how many pages a document will produce.
Future<int> getPageCount(PrintDocument document);

/// Write a rendered PDF to disk (virtual / file print).
Future<bool> printToFile(PrintDocument document, String outputPath, {PrintSettings? settings});
```

---

### Raw Protocol Printing

Direct TCP socket output — no OS print dialog, no driver needed.

```dart
/// Send raw bytes to a printer on port 9100 or via IPP.
Future<PrintResult> printRaw(Uint8List data, {PrintSettings? settings});

/// ESC/POS thermal receipt printers (socket://host:port).
Future<PrintResult> printEscPos(Uint8List escPosData, {PrintSettings? settings});

/// ZPL label printers (Zebra, socket://host:9100).
Future<PrintResult> printZpl(String zpl, {PrintSettings? settings});

/// Cancel any in-progress raw/ESC-POS/ZPL network job.
Future<bool> cancelRawPrint();
```

Set `PrintSettings.printerId` to an IP address or URI (`socket://192.168.1.5:9100`, `ipp://...`).

---

### Print Job Management

```dart
Future<bool>      cancelPrintJob(String jobId);
Future<bool>      pausePrintJob(String jobId);
Future<bool>      resumePrintJob(String jobId);
Future<bool>      clearPrintQueue();
Future<int>       getPrintJobsCount();
Future<NitroResultValue<PrintJob>> getPrintJobAt(int index);
Future<NitroResultValue<PrintJob>> getPrintJobStatus(String jobId);
```

---

### Printer Discovery (mDNS/Bonjour)

```dart
Future<bool> startPrinterDiscovery();
Future<bool> stopPrinterDiscovery();

// @NitroStream — zero-copy reactive stream of discovered IPP printers
Stream<DiscoveredPrinter> onPrinterDiscovered();
```

**Example:**
```dart
final sub = printing.onPrinterDiscovered().listen((p) {
  print('Found: ${p.name} at ${p.uri}');
});
await printing.startPrinterDiscovery();
// ... later:
await printing.stopPrinterDiscovery();
await sub.cancel();
```

---

### Connection & Administration

```dart
/// TCP probe — check if a printer is reachable.
Future<bool> testPrinterConnection(String printerId, {int? timeoutSeconds});

/// Set the system-default printer (currently effective on macOS via lpadmin;
/// returns false elsewhere).
Future<bool> setDefaultPrinter(String printerId);
```

---

### Platform UX

```dart
/// Open the OS print queue window for a printer (empty string = all printers).
Future<bool> openSystemPrintQueue(String printerId);

/// Open OS printer-properties dialog (currently macOS; returns false elsewhere).
Future<bool> openPrinterProperties(String printerId);
```

---

### Detailed IPP Status

```dart
/// Query live printer status via IPP Get-Printer-Attributes.
Future<NitroResultValue<PrinterStatusDetail>> getPrinterStatusDetail(
  String printerId, {
  int? timeoutSeconds,
});
```

`PrinterStatusDetail` exposes: `isOnline`, `isReady`, `hasPaperJam`, `isOutOfPaper`,
`isOutOfInk`, per-channel ink levels (`inkLevelBlack/Cyan/Magenta/Yellow`), `tonerLevel`,
`paperLevel`, `jobsInQueue`, `printerState`, `stateReasons`, and more.

---

### Real-Time Streams (`@NitroStream`)

All streams are annotated with `@NitroStream(backpressure: Backpressure.dropLatest)` —
the Nitrogen runtime uses `Dart_PostCObject` to push events from the native thread directly
to Dart with no method-channel round-trip.

```dart
Stream<PrintJobUpdate>    onPrintJobChanged();      // job state + progress
Stream<PrinterStatus>     onPrinterStatusChanged();  // online/offline, ink, queue depth
Stream<DiscoveredPrinter> onPrinterDiscovered();    // mDNS discovery events
```

---

### Batch Printing (Dart-side orchestration)

```dart
final results = await printing.printBatch(
  [doc1, doc2, doc3],
  true, // stopOnError
  settings: PrintSettings(copies: 2),
);
```

---

### Built-in Print Settings UI

A Material 3 full-screen settings editor — no extra dependency needed.

```dart
final settings = await NitroPrintSettingsPage.show(context);
if (settings != null) {
  await printing.printPdf(pdfBytes, settings: settings);
}
```

The page exposes: printer picker, show-dialog toggle, job name, paper size (including custom
pt dimensions), orientation, copies stepper, pages-per-sheet, page range, fit-to-page,
quality, media type, color/duplex/collate toggles, header/footer text, and input tray.

---

## Data Models

### `PrintSettings`

| Field | Type | Default | Description |
|---|---|---|---|
| `printerId` | `String` | `''` | Printer ID / IP / URI |
| `paperSize` | `PaperSize` | `.a4` | a4, a5, letter, legal, custom |
| `orientationDegrees` | `double` | `0.0` | 0=portrait, 90=landscape, 180/270=reverse |
| `quality` | `PrintQuality` | `.normal` | draft, normal, high, best |
| `copies` | `int` | `1` | Number of copies |
| `collate` | `bool` | `false` | Collate multi-copy jobs |
| `duplex` | `bool` | `false` | Double-sided |
| `color` | `bool` | `true` | Color vs grayscale |
| `marginTop/Bottom/Left/Right` | `double` | `0` | Margins in PostScript points |
| `jobName` | `String` | `''` | Spooler job name |
| `pagesPerSheet` | `int` | `1` | 1, 2, 4, 6, 8, 16 |
| `showPrintDialog` | `bool` | `true` | `false` = silent direct print |
| `pageRangeFrom/To` | `int` | `0` | 1-based; 0 = start/end |
| `customPaperWidth/Height` | `double` | `0` | Points, when `paperSize == .custom` |
| `fitToPage` | `bool` | `false` | Scale to printable area |
| `mediaType` | `MediaType` | `.plain` | plain, glossy, matte, photo, label, envelope |
| `headerText` / `footerText` | `String` | `''` | Per-page header/footer |
| `inputTray` | `String` | `''` | Tray name, e.g. `"Tray 1"` |
| `networkTimeoutSeconds` | `int` | `30` | TCP/IPP timeout |

### Other Models

| Model | Key Fields |
|---|---|
| `PrinterInfo` | `id`, `name`, `address`, `isDefault`, `isAvailable` |
| `PrinterCapabilities` | color, duplex, copy count, paper sizes, quality levels, max DPI, borderless, input trays |
| `PrintJob` | `id`, `printerId`, `documentTitle`, `state` (`PrintState`), `progress` (0–100), `createdAt`, `completedAt`, `errorMessage`, `pagesPrinted` |
| `PrintDocument` | `id`, `title`, `type` (`DocumentType`: plainText/html/pdf/image), `data` (`Uint8List`) |
| `DiscoveredPrinter` | `id`, `name`, `host`, `port`, `serviceType` (e.g. `_ipp._tcp`), `uri`, `isAvailable` |
| `PrinterStatusDetail` | `isOnline`, `isReady`, `hasPaperJam`, `isOutOfPaper`, ink levels per channel, `tonerLevel`, `paperLevel`, `stateReasons` |

---

## Platform Support

All platforms are supported **except Web**. Every platform ships the raw
network-printing transport (TCP 9100 / ESC-POS / ZPL / IPP) and connection
probing; the OS print stack (dialog, spooler, enumeration, previews) is
implemented on Android, iOS, and macOS, and is planned for Windows/Linux
(those methods currently return graceful failure results, never crash/hang).

| Capability | Android | iOS | macOS | Windows | Linux | Web |
|---|---|---|---|---|---|---|
| Raw / ESC-POS / ZPL over TCP | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |
| Direct dispatch to printer URI (`showPrintDialog: false`) | ✅ | ✅ | ✅¹ | ✅² | ✅² | ❌ |
| IPP direct print + detailed status | ✅ | ✅ | ✅ | ⏳ | ⏳ | ❌ |
| `testPrinterConnection` | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |
| System print dialog | ✅ (Print Services) | ✅ (AirPrint) | ✅ | ⏳ | ⏳ | ❌ |
| Printer enumeration / capabilities | ✅ | ✅ | ✅ | ⏳ | ⏳ | ❌ |
| Job queue (list/pause/resume/cancel) | ✅ | ✅ | ✅ | ⏳ | ⏳ | ❌ |
| mDNS/Bonjour discovery | ✅ | ✅ | ✅ | ⏳ | ⏳ | ❌ |
| Preview / page count / print-to-file | ✅ | ✅ | ✅ | ⏳ | ⏳ | ❌ |
| Real-time job/status streams | ✅ | ✅ | ✅ | ⏳ | ⏳ | ❌ |

¹ macOS document printing goes through `NSPrintOperation` (OS print system) rather than a raw socket.
² Windows/Linux direct dispatch sends the payload bytes over the socket (PDF bytes as-is; text as UTF-8) — rendering to PDF happens on the mobile/macOS backends.
⏳ = planned; the API exists on every platform and returns an honest failure result today.

---

## How It's Built — Nitrogen SDK

`nitro_printing` is powered by the **Nitrogen SDK**, a Flutter port of
[React Native Nitro Modules](https://nitro.margelo.com) originally by Marc Rousavy (Margelo).

### Architecture

```
nitro_printing (this plugin)
└── depends on: nitro ^0.5.11
                └── nitro_annotations
    dev:        nitro_generator ^0.5.11  (build_runner builder)

nitro_ecosystem/packages/     ← source of the SDK
├── nitro/                    ← runtime: HybridObject, NitroRuntime, NitroConfig
├── nitro_annotations/        ← @NitroModule, @HybridStruct, @HybridEnum, @nitroAsync, @nitroNativeAsync, @NitroResult, @NitroStream, @ZeroCopy
├── nitro_generator/          ← build_runner builder → *.g.dart + native stubs
└── nitrogen_cli/             ← CLI (nitrogen generate / link / doctor)
```

### Key differences vs. method channels

| Concern | Method channel | Nitrogen |
|---|---|---|
| Per-call overhead | ~0.3 ms (serialize → platform thread → deserialize) | **~0 µs** (direct C ABI via `dart:ffi`) |
| Sync calls | ❌ impossible | ✅ any non-async method |
| Async calls | Always channel round-trip | `@nitroNativeAsync` — native coroutine/Task posts straight back (no isolate hop) |
| Typed errors | Exceptions in strings | `@NitroResult` → `NitroOk` / `NitroErr` sealed results |
| Streams | EventChannel + serialized JSON | `@NitroStream` → `Dart_PostCObject` direct push |
| Large buffers | Copied twice (platform → Dart) | `@ZeroCopy` → pointer handoff, zero copies |
| Code to write | Dart + platform channel + boilerplate | **1 `.native.dart` file** + generated everything |

### How code generation works

1. You write `lib/src/nitro_printing.native.dart` — a single abstract Dart class annotated with `@NitroModule`.
2. Running `dart run build_runner build` invokes `nitro_generator`, which outputs:
   - `lib/src/nitro_printing.g.dart` — the Dart FFI bridge (`_NitroPrintingImpl`)
   - Native stub headers for Kotlin (Android), Swift (iOS/macOS), C++ (Windows/Linux)
3. Platform implementations (`NitroPrintingPlugin.kt`, `SwiftNitroPrintingPlugin.swift`, etc.) fill in the business logic against the generated spec.

---

## Development

Regenerate + re-link the Nitrogen glue code after modifying the Dart API spec
(`lib/src/nitro_printing.native.dart`):

```bash
nitrogen generate   # runs the code generator (build_runner) with live output
nitrogen link       # wires the generated native bridges into every build system
nitrogen doctor     # verifies the plugin is production-ready
```

Run the example app:

```bash
cd example
flutter run
```

### Testing

The example ships three test layers (all green in CI on Android, iOS, macOS,
Linux, and Windows — see `.github/workflows/ci.yml`):

```bash
cd example

# API-level integration tests (all platforms):
flutter test integration_test/nitro_printing_test.dart -d <device>

# Native transport verification against an in-process fake network printer
# (byte-exact ESC-POS/ZPL, PDF page-size/copies sweeps, IPP attributes):
flutter test integration_test/native_transport_test.dart -d <device>

# Patrol UI + native-automation suites (Android & iOS):
dart pub global activate patrol_cli
patrol test -d <device>
```

---

## Related

- [nitro](https://pub.dev/packages/nitro) — Nitrogen runtime (Flutter port of RN Nitro Modules)
- [nitro_generator](https://pub.dev/packages/nitro_generator) — `build_runner` code generator
- [nitrogen_cli](https://pub.dev/packages/nitrogen_cli) — CLI scaffold & doctor tool
- [nitro_ecosystem repository](https://github.com/Shreemanarjun/nitro_ecosystem) — source of the SDK
- [Nitro Modules (React Native)](https://nitro.margelo.com) — the original RN library this is ported from

---

## License

MIT — see [LICENSE](LICENSE).
