# nitro_printing

[![pub version](https://img.shields.io/pub/v/nitro_printing.svg)](https://pub.dev/packages/nitro_printing)
[![Platform](https://img.shields.io/badge/platform-android%20%7C%20ios%20%7C%20macos%20%7C%20windows%20%7C%20linux%20%7C%20web-blue)](https://pub.dev/packages/nitro_printing)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

**[Live demo (web)](https://printing.shreeman.dev/)** — the example app running on WASM.

A Flutter printing plugin built on the [Nitrogen SDK](https://github.com/Shreemanarjun/nitro_ecosystem)
(a Flutter port of [React Native Nitro Modules](https://nitro.margelo.com)): native calls go through
Dart FFI instead of method channels. Docs: https://nitro.shreeman.dev — demo: https://printing.shreeman.dev

---

## Features

- Synchronous printer queries (`getPrintersCount()`, `isPrintingSupported()`)
- Text, image, PDF, and file printing with a full `PrintSettings` model
- Raw TCP, ESC/POS, and ZPL printing
- mDNS/Bonjour printer discovery and IPP status queries
- Print job management with `onPrintJobChanged` / `onPrinterStatusChanged` streams
- Print preview, print-to-file, batch printing
- Built-in Material 3 settings page (`NitroPrintSettingsPage`)
- Android, iOS, macOS, Windows, Linux, and Web (WASM)

---

## Installation

```yaml
dependencies:
  flutter:
    sdk: flutter
  nitro_printing: ^0.0.5
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

### 🌐 Web (WASM)

The web backend is the same C++ module compiled to WebAssembly (bundled
automatically as a Flutter asset — no setup beyond one call). Module
instantiation is asynchronous on web, so await the ready hook before first
use; it is a no-op on every native platform:

```dart
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await ensureNitroPrintingReady(); // instantiates the WASM module on web
  runApp(const App());
}
```

WebUSB and the browser print dialog require a **secure context** (HTTPS or
localhost). See [Web Support](#web-support) for what each API does on web and
which `PrintSettings` fields are respected there.

---

## Quick Start

```dart
import 'package:nitro_printing/nitro_printing.dart';

// Once at startup: instantiates the WASM module on web, no-op on native.
await ensureNitroPrintingReady();

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

### Printer Info & Discovery (`@nitroAsync`)

```dart
Future<List<PrinterInfo>> getAllPrinters();
Future<NitroResultValue<PrinterInfo>> getPrinterAt(int index);
Future<NitroResultValue<PrinterInfo>> getDefaultPrinter();
Future<NitroResultValue<PrinterCapabilities>> getPrinterCapabilities(String printerId);
```

**Example — populate a printer list:**
```dart
final printers = await printing.getAllPrinters();
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
Future<List<PrintResult>> printBatch(List<PrintDocument> documents, bool stopOnError, {PrintSettings? settings});
```

---

### OS Print Dialog (`@nitroAsync`)

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
| Web | ✅ (browser dialog / Web Printing) | ⚠️ WebUSB picker | ✅ (WebUSB / ws relay / TCPSocket) | ✅ (browser dialog) |

---

## Web Support

The web backend is the same C++ implementation compiled to WASM. Capabilities
are feature-detected at runtime; unsupported operations fail with a typed
error instead of hanging.

### Supported on web

| Feature | Notes |
|---|---|
| Document printing (text / HTML / image / PDF) | Browser print dialog, with `PrintSettings` applied to the document: paper size, orientation, margins, copies (collated/uncollated), grayscale, header/footer, page ranges, N-up, job name |
| Silent printing to any OS printer | Via the first-party Nitro Print Agent (`agent:`) or QZ Tray (`qz:`) — spool-confirmed results, native job ids |
| Silent PDF system jobs | Web Printing API in Isolated Web Apps (Chrome 147+), with IPP attributes and page-progress tracking |
| Raw / ESC-POS / ZPL | WebUSB, Web Serial, Web Bluetooth, `ws://` relay, Direct Sockets TCP (IWA), or either local agent. ESC/POS text is CP437-translated; images raster to `GS v 0` |
| Printer enumeration & status | Granted USB/serial/BLE devices, agent printers, and (IWA) the full system list with IPP capabilities and state reasons; live status streams from Web Printing, QZ, and the agent |
| Discovery | USB/serial/BLE device pickers, local-agent probing, and (IWA) one-shot mDNS |
| Preview & export | Page-accurate live preview (copies/N-up/grayscale/decor visible), PDF page counts and page-range extraction, HTML→PDF rasterization, `printToFile` download, `printFile` for `http(s)`/`data:`/`blob:` URLs |
| Job tracking & typed status | Every print tracked with `onPrintJobChanged`; `PrintErrorCode`, `PrintOutcome`, `PrintJob.failureReason`, `lastPrintJob()`, `resumePrintJob` for raw jobs |
| Page decoration | `WebPrintDecor` — per-page watermark/letterhead, HTML header/footer |
| Both web compilers | dart2js and dart2wasm (`--wasm`) |

### Web limitations

| Limitation | Detail / workaround |
|---|---|
| Print-vs-Cancel in the browser dialog is unknowable | No web API reveals it. Dialog prints report `PrintOutcome.dialogShown`; use `dialogDurationMs`/`dialogGuess` heuristics, `PrintOutcomeConfirmation.markJobOutcome` (ask the user), or a verified path (agent / raw / Web Printing) |
| No default-printer concept | `getDefaultPrinter`/`setDefaultPrinter` return `NitroErr`/false everywhere on web |
| No pause/resume of OS jobs, driver version, or OS print-queue/properties UI | No web API in any context |
| Dialog flow cannot force duplex, quality, or media type | The browser dialog owns those; all three work on Web Printing jobs, duplex/quality also via the agents |
| PDF documents print as-is in the dialog flow | Settings apply via `qz:`/`agent:`/Web Printing instead; `pageRange` extraction covers classic-xref PDFs only (others print in full) |
| No system-printer enumeration on the open web | Requires an Isolated Web App or a local agent |
| Device transports are Chromium-only and need a user-gesture grant | WebUSB/Web Serial/Web Bluetooth; Windows WebUSB may additionally need a WinUSB driver (Zadig) for printers claimed by `usbprint.sys` |
| Direct raw TCP only in Isolated Web Apps | On the open web use a `ws://` relay or a local agent |
| HTML rendering is raster-based, inline content only | External images/fonts don't load in the SVG sandbox; HTML previews are JPEG pages, not vector PDF |
| ESC/POS text is CP437 only; batch item status caps at 64 documents | Unmappable glyphs print as `?`; items past 64 report failed |
| Secure context required | HTTPS or localhost; local endpoints (relay/agents) are gated by Chrome's Local Network Access permission |

### How each API behaves on web

| API | Open web (any HTTPS Chromium page) | Isolated Web App (Chrome 147+) |
|---|---|---|
| `printText` / `printImage` / `printDocument` | Browser print dialog (hidden-iframe flow). Plain text with a raw `printerId` (`usb:`/`ws://`/`socket://`) is ESC/POS-encoded (init + text + feed/cut) and sent straight to the thermal printer | same |
| `printPdf` | Browser print dialog; a `qz:` or system printerId prints silently | Web Printing API job with state tracking |
| `printBatch` | Sequential dialog prints, per-item results | same |
| `showPrintDialog` | Browser dialog; `confirmed` = dialog shown & closed (browsers cannot reveal Print-vs-Cancel) | same |
| `printRaw` / `printEscPos` / `printZpl` | WebUSB (`usb:`), Web Serial (`serial:[baud]`), Web Bluetooth (`ble:[name]`), QZ Tray agent (`qz:`, spool-confirmed), or `ws://` relay (websockify). ESC/POS text is CP437-translated; images raster to `GS v 0` | also direct TCPSocket to port 9100, no relay |
| `getAllPrinters` / `getPrinterAt` / `getPrintersCount` | Granted WebUSB devices | + full system printer list (Web Printing) |
| `getPrinterCapabilities` / `getPrinterStatusDetail` | Basic WebUSB info | Full IPP attributes (media, duplex, color, quality, state reasons) |
| `startPrinterDiscovery` | Opens the WebUSB, Web Serial, then Web Bluetooth device pickers (needs a user gesture) and probes the QZ agent; grants emit `onPrinterDiscovered` | + one-shot mDNS query over Direct Sockets UDP (`_ipp`/`_pdl-datastream`/`_printer`) |
| `testPrinterConnection` | USB open-probe or `ws://` reachability | + TCP connect probe |
| `getPrintJobsCount` / `getPrintJobAt` / `getPrintJobStatus` | Every web print is tracked (dialog, raw transports, batch items) with `onPrintJobChanged` events and `lastPrintJob()` | + Web Printing system jobs with page progress |
| `cancelPrintJob` / `clearPrintQueue` | Unknown ids are inert | Cancels/clears Web Printing jobs |
| `resumePrintJob` | Retries a finished raw-transport job's kept payload; dialog/Web Printing jobs are not resumable | same |
| Job failure reasons | `PrintJob.failureReason` — typed (`mediaEmpty`, `mediaJam`, `tonerEmpty`, `coverOpen`, `printerOffline`, …) parsed from the job's error | populated from IPP `printer-state-reasons` |
| Typed errors | `PrintResult.errorKind` → `PrintErrorCode` enum (`noUsbDevice`, `relayTimeout`, `tcpUnavailable`, …) for switch-based handling | same |
| Outcomes | `PrintResult.outcome` / `PrintJob.outcome` → `PrintOutcome`: `printed` only when delivery was verified (raw transports, system jobs); dialog prints report `dialogShown` since no web API reveals Print-vs-Cancel | Web Printing jobs report IPP terminal states incl. `cancelled` |
| Dialog-outcome signals | `PrintResult.dialogDurationMs` (measured via `afterprint`), the `dialogGuess` heuristic, and `PrintOutcomeConfirmation.markJobOutcome(jobId, printed:)` to settle a job after asking the user | not needed (real job states) |
| Page decoration | `WebPrintDecor.configure(backgroundHtml:, headerHtml:, footerHtml:)` — per-page watermark/letterhead and HTML header/footer | same |
| `renderPreview` | PDF documents pass through (`pageRange` extracts a sub-document in wasm); plain text renders to a generated PDF sized by `PrintSettings`; images become a one-page PDF; HTML rasterizes to a multi-page PDF (inline content only) | same |
| `getPageCount` | PDF page-tree walk; text paginated at 60 lines/page; HTML rasterized and counted | same |
| `printToFile` | Browser download — text, images, and HTML render to a real PDF first | same |
| `printFile` | `http(s)://`, `data:`, `blob:` URLs are fetched and printed by sniffed type; filesystem paths return false | same |
| `getDefaultPrinter` / `setDefaultPrinter` | `NitroErr` / false — no default-printer concept on the web | same |
| `pausePrintJob` | false — no web API | same |
| `getPrinterDriverVersion` / `openSystemPrintQueue` / `openPrinterProperties` | Empty / false — OS surface unreachable from the sandbox | same |

The sync `@NitroResult` lookups (`getPrinterAt`, capabilities, status detail,
jobs) are served from the cache the last `getAllPrinters()` populated — call
it first, or they fail with a `NitroErr` that says exactly that.

### `printerId` routing on web

Raw printing and PDF job submission pick their transport from the
`PrintSettings.printerId` scheme:

| `printerId` | Transport |
|---|---|
| *(empty)* or `usb:VID:PID[:serial]` | WebUSB bulk transfer to the (matching) granted USB printer |
| `ws://host:port` / `wss://host:port` | WebSocket→TCP relay (e.g. [websockify](https://github.com/novnc/websockify) forwarding to the printer's port 9100) |
| `socket://host:port` or a bare IP | Direct Sockets `TCPSocket` (Isolated Web Apps only); elsewhere fails with guidance |
| `agent:` or `agent:<printer id>` | First-party [Nitro Print Agent](#nitro-print-agent-the-agent-transport--any-os-printer): silent text/image/PDF/raw to any OS printer through this plugin's own native backends, native job ids and status |
| `qz:` or `qz:Printer Name` | [QZ Tray](https://github.com/qzind/tray) local agent: silent raw and PDF printing to any OS printer, spool-confirmed results, and OS printer status on `onPrinterStatusChanged`. QZ shows its own Allow prompt; `WebPrintAgent.configure(endpoint:)` overrides the default ports |
| A system printer name from `getAllPrinters()` | Web Printing API PDF job (Isolated Web Apps only) |

### Which `PrintSettings` fields are respected on web

Dialog flows apply settings to the document itself (CSS `@page`, content
repetition, grayscale), so they take effect even though the browser dialog can
override them. PDF documents print as-is in the dialog flow; use a `qz:` or
Web Printing printer for attribute control over PDFs.

| Field | Dialog printing (text / HTML / image) | Raw (WebUSB / relay / TCP) | Web Printing PDF job |
|---|---|---|---|
| `printerId` | picks the flow: a Web Printing printer name routes to a silent job; otherwise the user picks the target in the dialog | ✅ selects the transport & device | ✅ selects the printer |
| `copies` | ✅ page content is repeated per copy inside one job | ✅ repeats the payload (`printZpl` always sends once — ZPL carries its own quantity commands) | ✅ `copies` attribute |
| `paperSize` / `customPaperWidth`/`Height` | ✅ CSS `@page size` (A4/A5/letter/legal/custom pt) | n/a | ✅ `media` size name (custom → printer default) |
| `orientationDegrees` | ✅ portrait/landscape via `@page size` | n/a | ✅ `orientation-requested` |
| margins (`marginTop/Right/Bottom/Left`, pt) | ✅ CSS `@page margin` | n/a | — |
| `color` | ✅ `false` renders grayscale | n/a | ✅ `print-color-mode` |
| `duplex` | dialog-controlled by the user | n/a | ✅ `sides` (two-sided-long-edge) |
| `quality` | dialog-controlled by the user | n/a | ✅ `print-quality` (draft/normal/high) |
| `headerText` / `footerText` | ✅ per page (all document types) | n/a | — |
| `pageRangeFrom`/`To` | ✅ plain-text documents (hard-paginated at 60 lines/page) | n/a | ✅ `page-ranges` |
| `fitToPage` | ✅ images scale to page width | n/a | — |
| `pagesPerSheet` | ✅ N-up grid layout (2/4/6/8/16 per sheet) | n/a | — |
| `jobName` | ✅ document title — names the print job and the default save-as-PDF file | — | ✅ job title |
| `networkTimeoutSeconds` | — | ✅ bounds relay/TCP connect + send | — |
| `collate` | n/a (single document) | n/a | ✅ `multiple-document-handling` |
| `mediaType` | not mappable | n/a | ✅ `media-type` (glossy/matte/photo/labels/envelope) |
| `showPrintDialog` | effectively always true — the dialog is the only document path unless `printerId` names a Web Printing printer | n/a | n/a |

`showPrintDialog()`'s `confirmedSettings` echoes the `initialSettings` you
passed (or defaults) — the browser cannot report what the user actually chose
in its dialog.

### Nitro Print Agent (the `agent:` transport — any OS printer)

`agent/` in this repo is a small first-party desktop app that wraps this
plugin's own native backends behind `ws://127.0.0.1:9629`. A web app using an
`agent:` printerId gets silent printing to any OS printer with real native
`PrintResult`s (spool-confirmed `PrintOutcome.printed`, native job ids) and
live printer/job status — no third-party agent.

1. Build and run it: `cd agent && flutter run -d macos` (or `windows`/`linux`;
   distribute the built app to workstations).
2. Print with `PrintSettings(printerId: 'agent:')` (default printer) or
   `'agent:<printer id>'`. Text, image, and PDF go through the native driver;
   raw/ESC-POS/ZPL pass through unchanged.
3. `startPrinterDiscovery()` probes the agent and emits its printers;
   `getPrinterStatusDetail('agent:…')` returns live native status.
4. Non-standard port: `WebPrintAgent.configure(agentEndpoint: 'ws://host:port')`
   (agent side: `--port` or `NITRO_PRINT_AGENT_PORT`).

The agent binds to loopback only and has no auth token yet — keep it on
trusted workstations.

### QZ Tray setup (the `qz:` transport)

[QZ Tray](https://github.com/qzind/tray) is a local print agent that gives web
apps silent, spool-confirmed printing and OS printer status.

1. Download the installer for Windows/macOS/Linux from
   <https://qz.io/download/> and run it. Version 2.2+ bundles its own Java —
   no separate install. The installer also adds a localhost certificate so
   `wss://localhost:8181` works (for Firefox, install QZ Tray after Firefox).
2. Launch QZ Tray — an icon appears in the system tray and the agent listens
   on `wss://localhost:8181` / `ws://localhost:8182`.
3. Print with `PrintSettings(printerId: 'qz:')` (default printer) or
   `'qz:Printer Name'`, or call `startPrinterDiscovery()` to enumerate agent
   printers. On the first request QZ Tray shows an Allow/Block prompt —
   tick "Remember this decision" to persist it. Signed certificates (silent,
   no prompt) are a QZ Tray feature configured on their side; this plugin
   connects in untrusted mode.
4. Non-standard agent host/port:
   `WebPrintAgent.configure(endpoint: 'ws://host:port')`.
5. Auto-start: enable "Launch on startup" in the QZ Tray menu (or install it
   as a Windows service — see <https://qz.io/docs/windows-service>).

### Testing the web backend

```bash
bash web/build_web.sh                                             # needs emsdk
flutter pub run test -p chrome test/nitro_printing_web_test.dart  # dart2js
flutter pub run test -p chrome -c dart2wasm test/nitro_printing_web_test.dart
```

---

## Development

Regenerate the bridge code after modifying `lib/src/nitro_printing.native.dart`:

```bash
nitrogen generate && nitrogen link
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
