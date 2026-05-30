import 'package:nitro_printing/nitro_printing.dart' as p;
import '../../core/repositories/printer_repository.dart';
import '../../core/signals.dart';

final allPrinters = Signal<List<p.PrinterInfo>?>(null);
final printersLoading = Signal<bool>(false);
final printersError = Signal<String?>(null);
final isDiscovering = Signal<bool>(false);

Future<void> _guard(Future<void> Function() fn) async {
  printersLoading.value = true;
  printersError.value = null;
  try {
    await fn();
  } catch (e) {
    printersError.value = e.toString();
  } finally {
    printersLoading.value = false;
  }
}

Future<void> loadAllPrinters(PrinterRepository repo) => _guard(() async {
      allPrinters.value = await repo.getAllPrinters();
    });

Future<void> toggleDiscovery(PrinterRepository repo) => _guard(() async {
      if (isDiscovering.value) {
        await repo.stopPrinterDiscovery();
        isDiscovering.value = false;
      } else {
        final started = await repo.startPrinterDiscovery();
        isDiscovering.value = started;
      }
    });
