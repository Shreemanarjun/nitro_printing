import 'dart:typed_data';
import 'package:nitro/nitro.dart';

part 'nitro_printing.g.dart';

@NitroModule(
  ios: NativeImpl.swift,
  android: NativeImpl.kotlin,
  macos: NativeImpl.swift,
  windows: NativeImpl.cpp,
  linux: NativeImpl.cpp,
)
abstract class NitroPrinting extends HybridObject {
  static final NitroPrinting instance = _NitroPrintingImpl();

  // ── Synchronous quick-lookup (no I/O, sub-microsecond) ───────────────────
  bool isPrintingSupported();
  int getPrintersCount();
  String getPrinterDriverVersion(String printerId);

  // ── Async: printer discovery / info ──────────────────────────────────────

  /// Returns all available printers. Runs off the UI thread (@nitroAsync).
  @nitroAsync
  Future<List<PrinterInfo>> getAllPrinters();

  /// Returns the printer at [index]. Fails with [NitroErr] if out of range.
  @nitroAsync
  @NitroResult()
  Future<NitroResultValue<PrinterInfo>> getPrinterAt(int index);

  /// Returns the system-default printer. Fails with [NitroErr] if none is set.
  @nitroAsync
  @NitroResult()
  Future<NitroResultValue<PrinterInfo>> getDefaultPrinter();

  /// Returns capabilities of [printerId]. Fails with [NitroErr] if printer not found.
  @nitroAsync
  @NitroResult()
  Future<NitroResultValue<PrinterCapabilities>> getPrinterCapabilities(
    String printerId,
  );

  // ── Async: print operations ───────────────────────────────────────────────

  @nitroAsync
  Future<PrintResult> printText(String text, {PrintSettings? settings});

  @nitroAsync
  Future<PrintResult> printImage(
    Uint8List imageData, {
    PrintSettings? settings,
  });

  @nitroAsync
  Future<PrintResult> printPdf(Uint8List pdfData, {PrintSettings? settings});

  @nitroAsync
  Future<PrintResult> printDocument(
    PrintDocument document, {
    PrintSettings? settings,
  });

  @nitroAsync
  Future<bool> printFile(String filePath, {PrintSettings? settings});

  /// Print a batch of [documents] using the native platform job queue.
  ///
  /// More efficient than sequential Dart calls: the native side can
  /// pipeline spooling and avoid repeated bridge round-trips.
  /// Stops at the first failure when [stopOnError] is true.
  @nitroAsync
  Future<List<PrintResult>> printBatch(
    List<PrintDocument> documents,
    bool stopOnError, {
    PrintSettings? settings,
  });

  // ── Async: OS print dialog ────────────────────────────────────────────────

  /// Show the OS print dialog for [document] with [initialSettings] pre-filled.
  ///
  /// Resolves when the user clicks **Print** or **Cancel**:
  /// - [PrintDialogResult.confirmed] == true → user clicked Print;
  ///   [PrintDialogResult.confirmedSettings] holds the chosen options.
  /// - [PrintDialogResult.confirmed] == false → user cancelled.
  ///
  /// Use [PrintDialogController] for a higher-level API.
  @nitroAsync
  Future<PrintDialogResult> showPrintDialog(
    PrintDocument document, {
    PrintSettings? initialSettings,
  });

  // ── Async: export / virtual print ────────────────────────────────────────

  /// Render [document] to PDF bytes without printing (for preview widgets).
  @nitroAsync
  Future<PreviewResult> renderPreview(
    PrintDocument document, {
    PrintSettings? settings,
  });

  /// Count pages [document] would produce with [settings].
  @nitroAsync
  Future<int> getPageCount(PrintDocument document);

  /// Write a rendered PDF of [document] to [outputPath] (virtual/file print).
  @nitroAsync
  Future<bool> printToFile(
    PrintDocument document,
    String outputPath, {
    PrintSettings? settings,
  });

  // ── Async: job management ─────────────────────────────────────────────────

  @nitroAsync
  Future<bool> cancelPrintJob(String jobId);

  @nitroAsync
  Future<bool> pausePrintJob(String jobId);

  @nitroAsync
  Future<bool> resumePrintJob(String jobId);

  @nitroAsync
  Future<bool> clearPrintQueue();

  @nitroAsync
  Future<int> getPrintJobsCount();

  /// Returns the job at [index]. Fails with [NitroErr] if out of range.
  @nitroAsync
  @NitroResult()
  Future<NitroResultValue<PrintJob>> getPrintJobAt(int index);

  /// Look up a single job by [jobId]. Fails with [NitroErr] if not found.
  @nitroAsync
  @NitroResult()
  Future<NitroResultValue<PrintJob>> getPrintJobStatus(String jobId);

  // ── Async: discovery ─────────────────────────────────────────────────────

  /// Start Bonjour/mDNS discovery for IPP printers.
  @nitroAsync
  Future<bool> startPrinterDiscovery();

  @nitroAsync
  Future<bool> stopPrinterDiscovery();

  // ── Async: connection / admin ─────────────────────────────────────────────

  /// TCP probe to [printerId] host:port. [timeoutSeconds] bounds the wait (default 5 s).
  @nitroAsync
  Future<bool> testPrinterConnection(String printerId, {int? timeoutSeconds});

  /// Set system-default printer by name/ID. No-op on iOS/Android.
  @nitroAsync
  Future<bool> setDefaultPrinter(String printerId);

  // ── Async: platform UX ───────────────────────────────────────────────────

  /// Open OS print-queue window. Pass empty string for all printers.
  @nitroAsync
  Future<bool> openSystemPrintQueue(String printerId);

  /// Open OS printer-properties dialog. macOS/Windows only.
  @nitroAsync
  Future<bool> openPrinterProperties(String printerId);

  // ── Async: raw protocol printing ─────────────────────────────────────────

  /// Send raw bytes directly to the printer via TCP socket or IPP.
  @nitroAsync
  Future<PrintResult> printRaw(Uint8List data, {PrintSettings? settings});

  /// Send ESC/POS-encoded bytes to a thermal receipt printer via TCP socket.
  @nitroAsync
  Future<PrintResult> printEscPos(
    Uint8List escPosData, {
    PrintSettings? settings,
  });

  /// Send ZPL label data to a Zebra printer via TCP.
  @nitroAsync
  Future<PrintResult> printZpl(String zpl, {PrintSettings? settings});

  /// Cancel any in-progress raw/ESC-POS/ZPL network print job.
  @nitroAsync
  Future<bool> cancelRawPrint();

  // ── Async: detailed printer status ───────────────────────────────────────

  /// Query detailed printer status via IPP Get-Printer-Attributes.
  /// Fails with [NitroErr] when the printer is unreachable within [timeoutSeconds].
  @nitroAsync
  @NitroResult()
  Future<NitroResultValue<PrinterStatusDetail>> getPrinterStatusDetail(
    String printerId, {
    int? timeoutSeconds,
  });

  // ── Streams ───────────────────────────────────────────────────────────────

  @NitroStream(backpressure: Backpressure.dropLatest)
  Stream<PrintJobUpdate> onPrintJobChanged();

  @NitroStream(backpressure: Backpressure.dropLatest)
  Stream<PrinterStatus> onPrinterStatusChanged();

  @NitroStream(backpressure: Backpressure.dropLatest)
  Stream<DiscoveredPrinter> onPrinterDiscovered();
}

// ── Enums ─────────────────────────────────────────────────────────────────────

@HybridEnum()
enum PrintState { idle, printing, completed, cancelled, failed, paused }

@HybridEnum()
enum PrintQuality { draft, normal, high, best }

@HybridEnum()
enum PaperSize { a4, a5, letter, legal, custom }

@HybridEnum()
enum DocumentType { plainText, html, pdf, image }

@HybridEnum()
enum MediaType { plain, glossy, matte, photo, label, envelope }

@HybridEnum()
enum PrintDialogState { idle, showing, confirmed, cancelled }

// ── Types ─────────────────────────────────────────────────────────────────────
// Rules used below:
//   @HybridRecord  — has String fields or enum fields (binary-encodes once, no per-call strdup)
//   @HybridStruct  — no String fields AND carries Uint8List (zero-copy TypedData support)

@HybridRecord()
class PrinterInfo {
  final String id;
  final String name;
  final String address;
  final bool isDefault;
  final bool isAvailable;

  PrinterInfo({
    required this.id,
    required this.name,
    this.address = '',
    this.isDefault = false,
    this.isAvailable = true,
  });
}

@HybridRecord()
class PrinterCapabilities {
  final bool supportsColor;
  final bool supportsDuplex;
  final bool supportsCopy;
  final int maxCopies;
  final double minMarginTop;
  final double minMarginBottom;
  final double minMarginLeft;
  final double minMarginRight;
  final bool supportsA4;
  final bool supportsA5;
  final bool supportsLetter;
  final bool supportsLegal;
  final bool supportsDraftQuality;
  final bool supportsNormalQuality;
  final bool supportsHighQuality;
  final bool supportsBestQuality;
  final int maxResolutionDpi;
  final bool supportsCustomPaper;
  final bool supportsBorderless;

  /// Comma-separated list of input tray names (e.g. "Tray 1,Manual Feed").
  final String inputTrays;

  PrinterCapabilities({
    this.supportsColor = true,
    this.supportsDuplex = false,
    this.supportsCopy = false,
    this.maxCopies = 1,
    this.minMarginTop = 0,
    this.minMarginBottom = 0,
    this.minMarginLeft = 0,
    this.minMarginRight = 0,
    this.supportsA4 = true,
    this.supportsA5 = true,
    this.supportsLetter = true,
    this.supportsLegal = true,
    this.supportsDraftQuality = true,
    this.supportsNormalQuality = true,
    this.supportsHighQuality = true,
    this.supportsBestQuality = true,
    this.maxResolutionDpi = 600,
    this.supportsCustomPaper = false,
    this.supportsBorderless = false,
    this.inputTrays = '',
  });
}

@HybridRecord()
class PrintSettings {
  final String printerId;
  final PaperSize paperSize;

  /// 0.0 = portrait, 90.0 = landscape, 180.0 = reverse-portrait, 270.0 = reverse-landscape.
  final double orientationDegrees;
  final PrintQuality quality;
  final int copies;
  final bool collate;
  final bool duplex;
  final bool color;
  final double marginTop;
  final double marginBottom;
  final double marginLeft;
  final double marginRight;
  final String jobName;

  /// Pages laid out per physical sheet (1, 2, 4, 6, 8, 16).
  final int pagesPerSheet;

  /// false = silent direct print to [printerId] without a dialog.
  final bool showPrintDialog;

  /// First page of range to print (1-based). 0 = print from the start.
  final int pageRangeFrom;

  /// Last page of range to print (1-based). 0 = print to the end.
  final int pageRangeTo;

  /// Width in PostScript points for PaperSize.custom.
  final double customPaperWidth;

  /// Height in PostScript points for PaperSize.custom.
  final double customPaperHeight;

  /// Scale content to fill the printable area.
  final bool fitToPage;
  final MediaType mediaType;

  /// Text printed at the top of every page.
  final String headerText;

  /// Text printed at the bottom of every page.
  final String footerText;

  /// Printer input tray name, e.g. "Tray 1". Empty = printer default.
  final String inputTray;

  /// Timeout in seconds for TCP socket and IPP network operations. 0 = use platform default (30 s).
  final int networkTimeoutSeconds;

  PrintSettings({
    this.printerId = '',
    this.paperSize = PaperSize.a4,
    this.orientationDegrees = 0.0,
    this.quality = PrintQuality.normal,
    this.copies = 1,
    this.collate = false,
    this.duplex = false,
    this.color = true,
    this.marginTop = 0,
    this.marginBottom = 0,
    this.marginLeft = 0,
    this.marginRight = 0,
    this.jobName = '',
    this.pagesPerSheet = 1,
    this.showPrintDialog = true,
    this.pageRangeFrom = 0,
    this.pageRangeTo = 0,
    this.customPaperWidth = 0,
    this.customPaperHeight = 0,
    this.fitToPage = false,
    this.mediaType = MediaType.plain,
    this.headerText = '',
    this.footerText = '',
    this.inputTray = '',
    this.networkTimeoutSeconds = 30,
  });
}

@HybridRecord()
class PrintDocument {
  final String id;
  final String title;
  final DocumentType type;
  final Uint8List data;

  PrintDocument({
    required this.id,
    required this.title,
    required this.type,
    required this.data,
  });
}

@HybridRecord()
class PrintJob {
  final String id;
  final String printerId;
  final String documentTitle;
  final PrintState state;
  final int progress;
  final int createdAtMillis;
  final int completedAtMillis;
  final String errorMessage;
  final int pagesPrinted;

  PrintJob({
    required this.id,
    required this.printerId,
    required this.documentTitle,
    required this.state,
    this.progress = 0,
    required this.createdAtMillis,
    this.completedAtMillis = 0,
    this.errorMessage = '',
    this.pagesPrinted = 0,
  });

  DateTime? get createdAt => createdAtMillis > 0
      ? DateTime.fromMillisecondsSinceEpoch(createdAtMillis)
      : null;
  DateTime? get completedAt => completedAtMillis > 0
      ? DateTime.fromMillisecondsSinceEpoch(completedAtMillis)
      : null;
}

@HybridRecord()
class PrintResult {
  final bool success;
  final String jobId;
  final String errorMessage;
  final String errorCode;

  PrintResult({
    required this.success,
    this.jobId = '',
    this.errorMessage = '',
    this.errorCode = '',
  });
}

@HybridRecord()
class PrintDialogResult {
  /// true if the user confirmed (clicked Print); false if they cancelled.
  final bool confirmed;

  /// Settings chosen by the user in the OS dialog.
  /// Always present — holds the initial settings when [confirmed] is false.
  final PrintSettings confirmedSettings;

  /// Non-empty when the dialog failed to open or an OS error occurred.
  final String errorMessage;

  PrintDialogResult({
    required this.confirmed,
    required this.confirmedSettings,
    this.errorMessage = '',
  });
}

@HybridRecord()
class PrintJobUpdate {
  final String jobId;
  final PrintState state;
  final int progress;
  final String message;

  PrintJobUpdate({
    required this.jobId,
    required this.state,
    this.progress = 0,
    this.message = '',
  });
}

@HybridRecord()
class PrinterStatus {
  final String printerId;
  final bool isOnline;
  final bool isPrinting;
  final int jobsInQueue;
  final String statusMessage;
  final int inkLevel;
  final int tonerLevel;

  /// Paper remaining: 0-100, -1 = unknown.
  final int paperLevel;
  final String errorCode;
  final bool isWarmingUp;

  PrinterStatus({
    required this.printerId,
    this.isOnline = true,
    this.isPrinting = false,
    this.jobsInQueue = 0,
    this.statusMessage = '',
    this.inkLevel = -1,
    this.tonerLevel = -1,
    this.paperLevel = -1,
    this.errorCode = '',
    this.isWarmingUp = false,
  });
}

@HybridStruct()
class PreviewResult {
  @ZeroCopy()
  final Uint8List bytes;
  final int length;

  PreviewResult({required this.bytes, required this.length});
}

@HybridRecord()
class DiscoveredPrinter {
  final String id;
  final String name;
  final String host;
  final int port;

  /// Bonjour service type, e.g. "_ipp._tcp".
  final String serviceType;

  /// Full IPP URI, e.g. "ipp://192.168.1.5:631/ipp/print".
  final String uri;
  final bool isAvailable;

  DiscoveredPrinter({
    required this.id,
    required this.name,
    this.host = '',
    this.port = 631,
    this.serviceType = '_ipp._tcp',
    this.uri = '',
    this.isAvailable = true,
  });
}

@HybridRecord()
class PrinterStatusDetail {
  final String printerId;
  final bool isOnline;
  final bool isReady;
  final bool hasPaperJam;
  final bool isOutOfPaper;
  final bool isOutOfInk;

  /// 0–100; -1 = unknown.
  final int inkLevelBlack;
  final int inkLevelCyan;
  final int inkLevelMagenta;
  final int inkLevelYellow;
  final int tonerLevel;

  /// Paper remaining 0–100; -1 = unknown.
  final int paperLevel;
  final int jobsInQueue;
  final bool isWarmingUp;

  /// "idle", "processing", or "stopped".
  final String printerState;

  /// Comma-separated IPP printer-state-reasons (e.g. "media-jam,toner-low").
  final String stateReasons;
  final String statusMessage;
  final String errorCode;
  final bool isDuplexSupported;
  final bool isColorSupported;

  PrinterStatusDetail({
    required this.printerId,
    this.isOnline = false,
    this.isReady = false,
    this.hasPaperJam = false,
    this.isOutOfPaper = false,
    this.isOutOfInk = false,
    this.inkLevelBlack = -1,
    this.inkLevelCyan = -1,
    this.inkLevelMagenta = -1,
    this.inkLevelYellow = -1,
    this.tonerLevel = -1,
    this.paperLevel = -1,
    this.jobsInQueue = 0,
    this.isWarmingUp = false,
    this.printerState = '',
    this.stateReasons = '',
    this.statusMessage = '',
    this.errorCode = '',
    this.isDuplexSupported = false,
    this.isColorSupported = false,
  });
}

// ── PrintDialogController ─────────────────────────────────────────────────────

/// Dart-side controller for orchestrating the OS print dialog flow.
///
/// Creates a stateful wrapper around a [PrintDocument] + [PrintSettings] pair
/// that drives the OS print dialog and/or direct print operations.
///
/// ```dart
/// final controller = PrintDialogController(
///   document: doc,
///   initialSettings: PrintSettings(copies: 2),
/// );
///
/// // Show the OS dialog and wait for user confirmation:
/// final dialogResult = await controller.showDialog();
/// if (dialogResult.confirmed) {
///   // confirmedSettings reflect what the user chose in the dialog
/// }
///
/// // Or skip the dialog and print directly:
/// final printResult = await controller.printDirect(doc);
/// ```
class PrintDialogController {
  final NitroPrinting _printing;
  PrintSettings _settings;
  PrintDialogState _state;

  PrintDialogController({
    PrintSettings? initialSettings,
    NitroPrinting? printing,
  })  : _printing = printing ?? NitroPrinting.instance,
        _settings = initialSettings ?? PrintSettings(),
        _state = PrintDialogState.idle;

  /// Current dialog lifecycle state.
  PrintDialogState get state => _state;

  /// Settings that will be passed to the OS dialog or [printDirect].
  PrintSettings get currentSettings => _settings;

  /// Replace [currentSettings] before calling [showDialog] or [printDirect].
  void updateSettings(PrintSettings settings) {
    _settings = settings;
  }

  /// Reset to [PrintDialogState.idle], optionally replacing [currentSettings].
  void reset({PrintSettings? settings}) {
    _state = PrintDialogState.idle;
    if (settings != null) _settings = settings;
  }

  /// Show the OS print dialog for [document] with [currentSettings] pre-filled.
  ///
  /// Transitions [state]:
  /// - → [PrintDialogState.showing] while the dialog is open
  /// - → [PrintDialogState.confirmed] if the user clicked **Print**
  /// - → [PrintDialogState.cancelled] if the user dismissed without printing
  ///
  /// On confirmation, [currentSettings] is updated to reflect the user's choices.
  Future<PrintDialogResult> showDialog(PrintDocument document) async {
    _state = PrintDialogState.showing;
    try {
      final result = await _printing.showPrintDialog(
        document,
        initialSettings: _settings,
      );
      if (result.confirmed) {
        _settings = result.confirmedSettings;
        _state = PrintDialogState.confirmed;
      } else {
        _state = PrintDialogState.cancelled;
      }
      return result;
    } catch (_) {
      _state = PrintDialogState.cancelled;
      rethrow;
    }
  }

  /// Print [document] directly using [currentSettings], bypassing the OS dialog.
  ///
  /// Transitions [state] to [PrintDialogState.confirmed] immediately.
  Future<PrintResult> printDirect(PrintDocument document) async {
    _state = PrintDialogState.confirmed;
    return _printing.printDocument(document, settings: _settings);
  }

  /// Show the OS dialog and, if the user confirms, print [document].
  ///
  /// Returns a [PrintResult] for both outcomes:
  /// - Cancelled: `success = false`, `errorCode = 'CANCELLED'`
  /// - Confirmed: result from the actual native print call
  Future<PrintResult> showAndPrint(PrintDocument document) async {
    final dialogResult = await showDialog(document);
    if (!dialogResult.confirmed) {
      return PrintResult(
        success: false,
        errorMessage: 'User cancelled the print dialog.',
        errorCode: 'CANCELLED',
      );
    }
    return _printing.printDocument(document, settings: dialogResult.confirmedSettings);
  }
}
