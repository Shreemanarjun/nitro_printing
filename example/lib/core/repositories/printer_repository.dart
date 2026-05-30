import 'dart:typed_data';
import 'package:nitro_printing/nitro_printing.dart' as p;

abstract class PrinterRepository {
  // ── Synchronous quick-lookup ───────────────────────────────────────────────
  Future<bool> isPrintingSupported();
  Future<int> getPrintersCount();
  Future<List<p.PrinterInfo>> getAllPrinters();
  Future<p.PrinterInfo> getPrinterAt(int index);
  Future<p.PrinterInfo> getDefaultPrinter();
  Future<p.PrinterCapabilities> getPrinterCapabilities(String printerId);
  Future<String> getPrinterDriverVersion(String printerId);

  // ── Standard print operations ─────────────────────────────────────────────
  Future<p.PrintResult> printText(String text, {p.PrintSettings? settings});
  Future<p.PrintResult> printImage(Uint8List data, {p.PrintSettings? settings});
  Future<p.PrintResult> printPdf(Uint8List data, {p.PrintSettings? settings});
  Future<p.PrintResult> printDocument(p.PrintDocument doc, {p.PrintSettings? settings});
  Future<bool> printFile(String filePath, {p.PrintSettings? settings});
  Future<List<p.PrintResult>> printBatch(
    List<p.PrintDocument> documents,
    bool stopOnError, {
    p.PrintSettings? settings,
  });

  // ── Raw protocol printing ─────────────────────────────────────────────────
  Future<p.PrintResult> printRaw(Uint8List data, {p.PrintSettings? settings});
  Future<p.PrintResult> printEscPos(Uint8List escPosData, {p.PrintSettings? settings});
  Future<p.PrintResult> printZpl(String zpl, {p.PrintSettings? settings});
  Future<bool> cancelRawPrint();

  // ── Export / virtual print ────────────────────────────────────────────────
  Future<p.PreviewResult> renderPreview(p.PrintDocument doc, {p.PrintSettings? settings});
  Future<int> getPageCount(p.PrintDocument doc);
  Future<bool> printToFile(p.PrintDocument doc, String outputPath, {p.PrintSettings? settings});

  // ── Job management ─────────────────────────────────────────────────────────
  Future<bool> cancelPrintJob(String jobId);
  Future<bool> pausePrintJob(String jobId);
  Future<bool> resumePrintJob(String jobId);
  Future<bool> clearPrintQueue();
  Future<int> getPrintJobsCount();
  Future<p.PrintJob> getPrintJobAt(int index);
  Future<p.PrintJob> getPrintJobStatus(String jobId);

  // ── Printer status ────────────────────────────────────────────────────────
  Future<p.PrinterStatusDetail> getPrinterStatusDetail(String printerId, {int? timeoutSeconds});

  // ── Discovery ─────────────────────────────────────────────────────────────
  Future<bool> startPrinterDiscovery();
  Future<bool> stopPrinterDiscovery();

  // ── Connection / admin ────────────────────────────────────────────────────
  Future<bool> testPrinterConnection(String printerId, {int? timeoutSeconds});
  Future<bool> setDefaultPrinter(String printerId);

  // ── Platform UX ───────────────────────────────────────────────────────────
  Future<bool> openSystemPrintQueue(String printerId);
  Future<bool> openPrinterProperties(String printerId);

  // ── Streams ───────────────────────────────────────────────────────────────
  Stream<p.PrintJobUpdate> onPrintJobChanged();
  Stream<p.PrinterStatus> onPrinterStatusChanged();
  Stream<p.DiscoveredPrinter> onPrinterDiscovered();
}

class NitroPrinterRepository implements PrinterRepository {
  final p.NitroPrinting _i = p.NitroPrinting.instance;

  @override Future<bool> isPrintingSupported() => Future.value(_i.isPrintingSupported());
  @override Future<int> getPrintersCount() => Future.value(_i.getPrintersCount());
  @override Future<List<p.PrinterInfo>> getAllPrinters() => Future.value(_i.getAllPrinters());
  @override Future<p.PrinterInfo> getPrinterAt(int index) => Future.value(_i.getPrinterAt(index));
  @override Future<p.PrinterInfo> getDefaultPrinter() => Future.value(_i.getDefaultPrinter());
  @override Future<p.PrinterCapabilities> getPrinterCapabilities(String printerId) =>
      Future.value(_i.getPrinterCapabilities(printerId));
  @override Future<String> getPrinterDriverVersion(String printerId) =>
      Future.value(_i.getPrinterDriverVersion(printerId));

  @override Future<p.PrintResult> printText(String text, {p.PrintSettings? settings}) =>
      _i.printText(text, settings: settings);
  @override Future<p.PrintResult> printImage(Uint8List data, {p.PrintSettings? settings}) =>
      _i.printImage(data, settings: settings);
  @override Future<p.PrintResult> printPdf(Uint8List data, {p.PrintSettings? settings}) =>
      _i.printPdf(data, settings: settings);
  @override Future<p.PrintResult> printDocument(p.PrintDocument doc, {p.PrintSettings? settings}) =>
      _i.printDocument(doc, settings: settings);
  @override Future<bool> printFile(String filePath, {p.PrintSettings? settings}) =>
      _i.printFile(filePath, settings: settings);
  @override Future<List<p.PrintResult>> printBatch(
    List<p.PrintDocument> documents,
    bool stopOnError, {
    p.PrintSettings? settings,
  }) => _i.printBatch(documents, stopOnError, settings: settings);

  @override Future<p.PrintResult> printRaw(Uint8List data, {p.PrintSettings? settings}) =>
      _i.printRaw(data, settings: settings);
  @override Future<p.PrintResult> printEscPos(Uint8List escPosData, {p.PrintSettings? settings}) =>
      _i.printEscPos(escPosData, settings: settings);
  @override Future<p.PrintResult> printZpl(String zpl, {p.PrintSettings? settings}) =>
      _i.printZpl(zpl, settings: settings);
  @override Future<bool> cancelRawPrint() => _i.cancelRawPrint();

  @override Future<p.PreviewResult> renderPreview(p.PrintDocument doc, {p.PrintSettings? settings}) =>
      _i.renderPreview(doc, settings: settings);
  @override Future<int> getPageCount(p.PrintDocument doc) => _i.getPageCount(doc);
  @override Future<bool> printToFile(p.PrintDocument doc, String outputPath, {p.PrintSettings? settings}) =>
      _i.printToFile(doc, outputPath, settings: settings);

  @override Future<bool> cancelPrintJob(String jobId) => _i.cancelPrintJob(jobId);
  @override Future<bool> pausePrintJob(String jobId) => _i.pausePrintJob(jobId);
  @override Future<bool> resumePrintJob(String jobId) => _i.resumePrintJob(jobId);
  @override Future<bool> clearPrintQueue() => _i.clearPrintQueue();
  @override Future<int> getPrintJobsCount() => _i.getPrintJobsCount();
  @override Future<p.PrintJob> getPrintJobAt(int index) => _i.getPrintJobAt(index);
  @override Future<p.PrintJob> getPrintJobStatus(String jobId) => _i.getPrintJobStatus(jobId);

  @override Future<p.PrinterStatusDetail> getPrinterStatusDetail(String printerId, {int? timeoutSeconds}) =>
      _i.getPrinterStatusDetail(printerId, timeoutSeconds: timeoutSeconds);

  @override Future<bool> startPrinterDiscovery() => _i.startPrinterDiscovery();
  @override Future<bool> stopPrinterDiscovery() => _i.stopPrinterDiscovery();

  @override Future<bool> testPrinterConnection(String printerId, {int? timeoutSeconds}) =>
      _i.testPrinterConnection(printerId, timeoutSeconds: timeoutSeconds);
  @override Future<bool> setDefaultPrinter(String printerId) =>
      _i.setDefaultPrinter(printerId);

  @override Future<bool> openSystemPrintQueue(String printerId) =>
      _i.openSystemPrintQueue(printerId);
  @override Future<bool> openPrinterProperties(String printerId) =>
      _i.openPrinterProperties(printerId);

  @override Stream<p.PrintJobUpdate> onPrintJobChanged() => _i.onPrintJobChanged();
  @override Stream<p.PrinterStatus> onPrinterStatusChanged() => _i.onPrinterStatusChanged();
  @override Stream<p.DiscoveredPrinter> onPrinterDiscovered() => _i.onPrinterDiscovered();
}
