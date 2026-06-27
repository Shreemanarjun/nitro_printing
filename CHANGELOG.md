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
