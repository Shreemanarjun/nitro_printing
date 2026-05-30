import 'package:nitro_printing/nitro_printing.dart' as p;
import '../../core/repositories/printer_repository.dart';
import '../../core/signals.dart';

// ── Signals ───────────────────────────────────────────────────────────────────

final rawLoading = Signal<bool>(false);
final rawResult = Signal<String?>(null);

// ── Actions ───────────────────────────────────────────────────────────────────

Future<void> runRawAction(Future<p.PrintResult> Function() action) async {
  rawLoading.value = true;
  rawResult.value = null;
  try {
    final r = await action();
    rawResult.value = r.success
        ? 'OK — jobId: ${r.jobId}'
        : 'Failed [${r.errorCode}]: ${r.errorMessage}';
  } catch (e) {
    rawResult.value = 'Error: $e';
  } finally {
    rawLoading.value = false;
  }
}

Future<bool> testPrinterConnectionAction(
  PrinterRepository repo,
  String uri,
  int timeoutSeconds,
) async {
  rawLoading.value = true;
  rawResult.value = null;
  try {
    final ok = await repo.testPrinterConnection(
      uri,
      timeoutSeconds: timeoutSeconds,
    );
    rawResult.value = ok
        ? 'OK — printer socket reachable'
        : 'Failed — printer socket unreachable';
    return ok;
  } catch (e) {
    rawResult.value = 'Connection error: $e';
    return false;
  } finally {
    rawLoading.value = false;
  }
}

Future<bool> cancelRawPrintAction(PrinterRepository repo) async {
  try {
    final cancelled = await repo.cancelRawPrint();
    return cancelled;
  } catch (e) {
    rawResult.value = 'Cancel error: $e';
    return false;
  }
}
