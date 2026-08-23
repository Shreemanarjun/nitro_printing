// Web (WASM) integration tests — run in a real browser via the
// integration_test harness:
//
//   chromedriver --port=4444
//   flutter drive --driver=test_driver/integration_test.dart \
//     --target=integration_test/web_test.dart -d chrome
//
// The native suites (nitro_printing_test.dart / native_transport_test.dart)
// import dart:io and cannot run on web; this file is the web-safe
// counterpart. It sticks to APIs that never open the browser print dialog —
// flutter drive runs HEADED Chrome, where window.print() would block the run.
// The dialog flows and the ws:// relay transport are covered headlessly by
// the plugin's test/nitro_printing_web_test.dart.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nitro_printing/nitro_printing.dart';

PrintDocument _textDoc([String text = 'hello web']) => PrintDocument(
  id: 'doc-1',
  title: 'Web Integration Test',
  type: DocumentType.plainText,
  data: Uint8List.fromList(text.codeUnits),
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await ensureNitroPrintingReady();
  });

  group('WASM module', () {
    testWidgets('loads and answers sync calls', (tester) async {
      final p = NitroPrinting.instance;
      expect(p.isPrintingSupported(), isTrue);
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
        await p.getPrinterCapabilities('unknown'),
        isA<NitroErr<PrinterCapabilities>>(),
      );
    });

    testWidgets('raw printing routes by printerId', (tester) async {
      final p = NitroPrinting.instance;

      final noDevice = await p.printRaw(Uint8List.fromList([1, 2, 3]));
      expect(noDevice.success, isFalse);
      expect(noDevice.errorMessage, contains('USB printer'));

      final bareIp = await p.printEscPos(
        Uint8List.fromList([0x1B, 0x40]),
        settings: PrintSettings(printerId: '192.0.2.1'),
      );
      expect(bareIp.success, isFalse);
      expect(bareIp.errorMessage, contains('Isolated Web App'));
    });

    testWidgets('pure-wasm PDF utilities work', (tester) async {
      final p = NitroPrinting.instance;

      final preview = await p.renderPreview(_textDoc('one\ntwo'));
      expect(preview.length, greaterThan(0));
      expect(String.fromCharCodes(preview.bytes.take(5)), '%PDF-');

      final text = List.generate(120, (i) => 'line $i').join('\n');
      expect(await p.getPageCount(_textDoc(text)), 2);
    });

    testWidgets('jobs / admin are inert outside Isolated Web Apps',
        (tester) async {
      final p = NitroPrinting.instance;
      expect(await p.getPrintJobsCount(), 0);
      expect(await p.cancelPrintJob('j'), isFalse);
      expect(await p.clearPrintQueue(), isFalse);
      expect(await p.testPrinterConnection('usb:0000:0000', timeoutSeconds: 1),
          isFalse);
      expect(await p.cancelRawPrint(), isFalse);
    });
  });
}
