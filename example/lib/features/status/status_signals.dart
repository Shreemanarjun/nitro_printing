import 'package:nitro_printing/nitro_printing.dart' as p;
import '../../core/repositories/printer_repository.dart';
import '../../core/signals.dart';

// ── Signals ───────────────────────────────────────────────────────────────────

final isSupported = Signal<bool?>(null);
final printersCount = Signal<int?>(null);
final defaultPrinter = Signal<p.PrinterInfo?>(null);
final printerCapabilities = Signal<p.PrinterCapabilities?>(null);
final driverVersion = Signal<String?>(null);
final printerStatusDetail = Signal<p.PrinterStatusDetail?>(null);
final statusLoading = Signal<bool>(false);
final statusError = Signal<String?>(null);

// ── Actions ───────────────────────────────────────────────────────────────────

Future<void> _guard(Future<void> Function() fn) async {
  statusLoading.value = true;
  statusError.value = null;
  try {
    await fn();
  } catch (e) {
    statusError.value = e.toString();
  } finally {
    statusLoading.value = false;
  }
}

Future<void> checkPrintingSupported(PrinterRepository repo) => _guard(() async {
  isSupported.value = await repo.isPrintingSupported();
});

Future<void> loadPrintersCount(PrinterRepository repo) => _guard(() async {
  printersCount.value = await repo.getPrintersCount();
});

Future<void> loadDefaultPrinter(PrinterRepository repo) => _guard(() async {
  final r = await repo.getDefaultPrinter();
  if (r case p.NitroOk(:final value)) defaultPrinter.value = value;
});

Future<void> loadCapabilities(PrinterRepository repo) => _guard(() async {
  final printerResult = await repo.getDefaultPrinter();
  if (printerResult case p.NitroOk(:final value)) {
    final capsResult = await repo.getPrinterCapabilities(value.id);
    if (capsResult case p.NitroOk(:final value)) printerCapabilities.value = value;
  }
});

Future<void> loadDriverVersion(PrinterRepository repo) => _guard(() async {
  final printerResult = await repo.getDefaultPrinter();
  if (printerResult case p.NitroOk(:final value)) {
    driverVersion.value = await repo.getPrinterDriverVersion(value.id);
  }
});

Future<void> loadStatusDetail(PrinterRepository repo, String printerId) =>
    _guard(() async {
      final r = await repo.getPrinterStatusDetail(printerId);
      if (r case p.NitroOk(:final value)) printerStatusDetail.value = value;
    });
