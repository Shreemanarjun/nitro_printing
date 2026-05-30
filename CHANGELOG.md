## 0.0.1

Initial release of `nitro_printing` — a high-performance Flutter printing plugin built on [NitroModules](https://nitro.margelo.com) with JSI/FFI and zero method-channel overhead.

### Added

- **Core Printing**: Support for printing text, image, PDF, HTML, local files, and retrieving all printers via native synchronous `getAllPrinters()`.
- **Export & Preview**: Virtual printing features like page count calculation, preview rendering, and writing to file.
- **Raw Printing**: Raw socket, ESC/POS, and ZPL protocol support with network job cancellation.
- **Job Management**: APIs to query status, pause, resume, cancel, or clear queues.
- **Printer & Status Queries**: Synchronous capabilities/driver version checks, and detailed real-time IPP status (ink levels, paper jams).
- **Discovery & Connections**: mDNS/Bonjour printer discovery, TCP connectivity checks, default printer settings, and real-time status/discovery streams.
- **Example App & Built-in UI**: Fully customizable Material 3 `NitroPrintSettingsPage` and a demo app showing printer operations and live discovery.
- **Integration Tests**: Comprehensive suite covering printer retrieval, discovery, preview rendering, platform UI, print jobs, and settings.
- **Cross-platform**: Native Swift/Kotlin/C++ implementations for Android, iOS, macOS, Windows, and Linux.
