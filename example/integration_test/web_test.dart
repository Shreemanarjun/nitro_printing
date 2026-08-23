// Web (WASM) integration tests — run in a real browser via the
// integration_test harness:
//
//   chromedriver --port=4444
//   flutter drive --driver=test_driver/integration_test.dart \
//     --target=integration_test/web_test.dart -d chrome
//
// The native suites (nitro_printing_test.dart / native_transport_test.dart)
// import dart:io and cannot run on web; this file is the web-safe
// counterpart, asserting the WASM backend's honest "unsupported" surface.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nitro_printing/nitro_printing.dart';

PrintDocument _doc() => PrintDocument(
  id: 'doc-1',
  title: 'Web Integration Test',
  type: DocumentType.plainText,
  data: Uint8List.fromList([1, 2, 3]),
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await ensureNitroPrintingReady();
  });

  group('WASM module', () {
    testWidgets('loads and answers sync calls', (tester) async {
      final p = NitroPrinting.instance;
      expect(p.isPrintingSupported(), isFalse);
      expect(p.getPrintersCount(), 0);
      expect(p.getPrinterDriverVersion('any'), isEmpty);
    });

    testWidgets('enumeration is empty, lookups fail with NitroErr',
        (tester) async {
      final p = NitroPrinting.instance;
      expect(await p.getAllPrinters(), isEmpty);
      expect(await p.getPrinterAt(0), isA<NitroErr<PrinterInfo>>());
      expect(await p.getDefaultPrinter(), isA<NitroErr<PrinterInfo>>());
      expect(
        await p.getPrinterCapabilities('any'),
        isA<NitroErr<PrinterCapabilities>>(),
      );
    });

    testWidgets('print operations fail honestly', (tester) async {
      final p = NitroPrinting.instance;
      final r = await p.printText(
        'hello',
        settings: PrintSettings(printerId: '192.168.1.50', copies: 2),
      );
      expect(r.success, isFalse);
      expect(r.errorCode, 'WEB_UNSUPPORTED');

      final batch = await p.printBatch([_doc(), _doc()], false);
      expect(batch, hasLength(2));
      expect(batch.every((b) => !b.success), isTrue);
    });

    testWidgets('dialog and preview round-trip records', (tester) async {
      final p = NitroPrinting.instance;
      final dialog = await p.showPrintDialog(
        _doc(),
        initialSettings: PrintSettings(printerId: 'p1', copies: 3),
      );
      expect(dialog.confirmed, isFalse);
      expect(dialog.confirmedSettings.printerId, 'p1');
      expect(dialog.confirmedSettings.copies, 3);

      final preview = await p.renderPreview(_doc());
      expect(preview.length, 0);

      expect(await p.getPageCount(_doc()), 0);
    });

    testWidgets('jobs / admin are inert', (tester) async {
      final p = NitroPrinting.instance;
      expect(await p.getPrintJobsCount(), 0);
      expect(await p.cancelPrintJob('j'), isFalse);
      expect(await p.clearPrintQueue(), isFalse);
      expect(await p.testPrinterConnection('10.0.0.1', timeoutSeconds: 1),
          isFalse);
      expect(await p.cancelRawPrint(), isFalse);
    });
  });
}
