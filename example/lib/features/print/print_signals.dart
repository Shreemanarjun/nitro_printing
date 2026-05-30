import 'dart:typed_data';
import 'package:nitro_printing/nitro_printing.dart' as p;
import '../../core/repositories/printer_repository.dart';
import '../../core/signals.dart';

// ── Signals ───────────────────────────────────────────────────────────────────

final printSettings = Signal<p.PrintSettings>(p.PrintSettings());
final printResult = Signal<String?>(null);
final printLoading = Signal<bool>(false);
final batchResults = Signal<List<p.PrintResult>?>(null);

void updatePrintSettings(p.PrintSettings s) => printSettings.value = s;

// ── Actions ───────────────────────────────────────────────────────────────────

Future<void> printTextAction(PrinterRepository repo, String text) =>
    _run(() => repo.printText(text, settings: printSettings.value));

Future<void> printImageAction(PrinterRepository repo, Uint8List data) =>
    _run(() => repo.printImage(data, settings: printSettings.value));

Future<void> printPdfAction(PrinterRepository repo, Uint8List data) =>
    _run(() => repo.printPdf(data, settings: printSettings.value));

Future<void> _run(Future<p.PrintResult> Function() action) async {
  printLoading.value = true;
  printResult.value = null;
  batchResults.value = null;
  try {
    final r = await action();
    printResult.value = r.success
        ? 'OK — jobId: ${r.jobId}'
        : 'Failed [${r.errorCode}]: ${r.errorMessage}';
  } catch (e) {
    printResult.value = 'Error: $e';
  } finally {
    printLoading.value = false;
  }
}

Future<void> runBatchPrintAction(PrinterRepository repo, p.PrintSettings settings) async {
  printLoading.value = true;
  printResult.value = null;
  batchResults.value = null;
  try {
    final docs = [
      p.PrintDocument(
        id: 'batch-1',
        title: 'Batch Doc 1',
        type: p.DocumentType.plainText,
        data: Uint8List.fromList('Batch document 1\n\nPrinted by NitroPrinting.'.codeUnits),
      ),
      p.PrintDocument(
        id: 'batch-2',
        title: 'Batch Doc 2',
        type: p.DocumentType.plainText,
        data: Uint8List.fromList('Batch document 2\n\nSecond document in batch.'.codeUnits),
      ),
      p.PrintDocument(
        id: 'batch-3',
        title: 'Batch Doc 3',
        type: p.DocumentType.plainText,
        data: Uint8List.fromList('Batch document 3\n\nFinal document in batch.'.codeUnits),
      ),
    ];
    final results = await repo.printBatch(docs, true, settings: settings);
    batchResults.value = results;
    final success = results.where((r) => r.success).length;
    printResult.value = 'Batch: $success/${results.length} documents printed';
  } catch (e) {
    printResult.value = 'Error: $e';
  } finally {
    printLoading.value = false;
  }
}
