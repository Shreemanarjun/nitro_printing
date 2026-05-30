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
| **Sync printer queries** | ❌ always async | ✅ `getPrintersCount()`, `getPrinterAt()`, `getDefaultPrinter()` are **synchronous** |
| **Raw TCP / ESC-POS / ZPL** | ❌ not supported | ✅ `printRaw`, `printEscPos`, `printZpl` |
| **mDNS/Bonjour discovery** | ❌ | ✅ `startPrinterDiscovery` + `onPrinterDiscovered` stream |
| **IPP detailed status** | ❌ | ✅ `getPrinterStatusDetail` (ink, paper jam, toner, …) |
| **Real-time job streams** | ❌ polling only | ✅ `onPrintJobChanged`, `onPrinterStatusChanged` (zero-copy streams) |
| **Print-to-file (virtual)** | Limited | ✅ `printToFile`, `renderPreview` |
| **Built-in settings UI** | ❌ | ✅ `NitroPrintSettingsPage` — Material 3 full-screen editor |
| **Batch printing** | ❌ | ✅ `printBatch` extension |
| **Platforms** | Android, iOS, macOS, Web | Android, iOS, macOS, Windows, Linux |

---

## Installation

```yaml
dependencies:
  nitro_printing: ^0.0.1
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

#### 1. Compilation Dependencies
The Linux native implementation links against **CUPS** (Common UNIX Printing System). You must install the CUPS development headers and `pkg-config` on your build machine to compile the application:

* **Ubuntu/Debian**:
  ```bash
  sudo apt-get install -y libcups2-dev pkg-config
  ```
* **Fedora/RHEL**:
  ```bash
  sudo dnf install cups-devel pkgconfig
  ```
* **Arch Linux**:
  ```bash
  sudo pacman -S cups pkgconf
  ```

#### 2. Runtime Requirements
A running CUPS daemon (`cupsd`) is required on the target machine for local printer queries and job spooling. This is pre-installed and running on standard desktop Linux distributions, but may need to be installed manually on minimal or headless systems.

---

### 🪟 Windows

No special permissions, configuration, or external dependencies are required. The plugin uses standard Win32 print spooler APIs (like WinSpool) which are built into all Windows environments.

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
PrinterInfo getPrinterAt(int index);
PrinterInfo getDefaultPrinter();
String getPrinterDriverVersion(String printerId);
PrinterCapabilities getPrinterCapabilities(String printerId);
```

**Example — populate a printer list:**
```dart
final count = printing.getPrintersCount();
final printers = [for (int i = 0; i < count; i++) printing.getPrinterAt(i)];
```

---

### Print Operations (`@nitroAsync`)

Marked `@nitroAsync` — dispatched on a background isolate, returns to the main isolate.

```dart
Future<PrintResult> printText(String text, {PrintSettings? settings});
Future<PrintResult> printImage(Uint8List imageData, {PrintSettings? settings});
Future<PrintResult> printPdf(Uint8List pdfData, {PrintSettings? settings});
Future<PrintResult> printDocument(PrintDocument document, {PrintSettings? settings});
Future<bool>        printFile(String filePath, {PrintSettings? settings});
```

**`PrintResult`** contains `success`, `jobId`, `errorMessage`, `errorCode`.

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
Future<PrintJob>  getPrintJobAt(int index);
Future<PrintJob>  getPrintJobStatus(String jobId);
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

/// Set the system-default printer (macOS / Windows only).
Future<bool> setDefaultPrinter(String printerId);
```

---

### Platform UX

```dart
/// Open the OS print queue window for a printer (empty string = all printers).
Future<bool> openSystemPrintQueue(String printerId);

/// Open OS printer-properties dialog (macOS / Windows only).
Future<bool> openPrinterProperties(String printerId);
```

---

### Detailed IPP Status

```dart
/// Query live printer status via IPP Get-Printer-Attributes.
Future<PrinterStatusDetail> getPrinterStatusDetail(
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
  stopOnError: true,
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

| Platform | Print | Discovery | Raw/ESC-POS/ZPL | System Dialog |
|---|---|---|---|---|
| Android | ✅ | ✅ | ✅ | ✅ (Print Services) |
| iOS | ✅ | ✅ | ✅ | ✅ (AirPrint) |
| macOS | ✅ | ✅ | ✅ | ✅ |
| Windows | ✅ | ✅ | ✅ | ✅ |
| Linux | ✅ | ✅ | ✅ | ✅ (CUPS) |
| Web | ❌ | ❌ | ❌ | ❌ |

---

## How It's Built — Nitrogen SDK

`nitro_printing` is powered by the **Nitrogen SDK**, a Flutter port of
[React Native Nitro Modules](https://nitro.margelo.com) originally by Marc Rousavy (Margelo).

### Architecture

```
nitro_printing (this plugin)
└── depends on: nitro ^0.4.3
                └── nitro_annotations ^0.4.3
    dev:        nitro_generator ^0.4.3  (build_runner builder)

nitro_ecosystem/packages/     ← local source of the SDK
├── nitro/                    ← runtime: HybridObject, NitroRuntime, NitroConfig
├── nitro_annotations/        ← @NitroModule, @HybridStruct, @HybridEnum, @nitroAsync, @NitroStream, @ZeroCopy
├── nitro_generator/          ← build_runner builder → *.g.dart + native stubs
└── nitrogen_cli/             ← CLI (nitrogen generate / init / doctor)
```

### Key differences vs. method channels

| Concern | Method channel | Nitrogen |
|---|---|---|
| Per-call overhead | ~0.3 ms (serialize → platform thread → deserialize) | **~0 µs** (direct C ABI via `dart:ffi`) |
| Sync calls | ❌ impossible | ✅ any non-`@nitroAsync` method |
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

Regenerate the Nitrogen glue code after modifying the Dart API spec:

```bash
dart run build_runner build --delete-conflicting-outputs
```

Run the example app:

```bash
cd example
flutter run
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
