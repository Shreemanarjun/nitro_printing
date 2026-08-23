// Browser tests for the WASM (web) backend.
//
// Build the module first, then run under BOTH web compilers — they differ at
// the js_interop boundary, so a green dart2js run does not imply dart2wasm:
//   bash web/build_web.sh
//   flutter pub run test -p chrome test/nitro_printing_web_test.dart
//   flutter pub run test -p chrome -c dart2wasm test/nitro_printing_web_test.dart
//
// Web semantics under test: document printing IS implemented (hidden-iframe
// browser print dialog; window.print() is a no-op under headless Chrome so
// flows complete without blocking), printToFile is a browser download, while
// enumeration / raw TCP / job queues fail honestly.
//
// Imports the spec directly (not the package barrel): the barrel exports the
// Flutter print-settings page, and `dart test -p chrome` has no Flutter web
// engine, so pulling in `package:flutter` fails to compile.
@TestOn('browser')
library;


import 'package:nitro/nitro.dart';
import 'package:test/test.dart';

import 'package:nitro_printing/src/nitro_printing.native.dart';
import 'package:nitro_printing/src/nitro_printing.platform.g.dart';

PrintDocument _textDoc() => PrintDocument(
  id: 'doc-1',
  title: 'Web Test',
  type: DocumentType.plainText,
  data: Uint8List.fromList('hello web'.codeUnits),
);

void main() {
  late NitroPrinting p;

  setUpAll(() async {
    final channel = spawnHybridUri('asset_server.dart');
    // dart2wasm hands JS numbers over as double — never cast with `as int`.
    final port = ((await channel.stream.first)! as num).toInt();
    await ensureNitroPrintingReady(
      jsUrl: 'http://localhost:$port/nitro_printing.js',
    );
    p = NitroPrinting.instance;
  });

  test('module loads and the bridge answers', () {
    expect(p, isNotNull);
  });

  group('sync quick-lookup', () {
    test('isPrintingSupported is true (browser print dialog)', () {
      expect(p.isPrintingSupported(), isTrue);
    });

    test('getPrintersCount is 0 (no enumeration API)', () {
      expect(p.getPrintersCount(), 0);
    });

    test('getPrinterDriverVersion is empty', () {
      expect(p.getPrinterDriverVersion('any'), isEmpty);
    });
  });

  group('@NitroResult lookups fail with NitroErr', () {
    test('getPrinterAt', () async {
      expect(await p.getPrinterAt(0), isA<NitroErr<PrinterInfo>>());
    });

    test('getDefaultPrinter', () async {
      expect(await p.getDefaultPrinter(), isA<NitroErr<PrinterInfo>>());
    });

    test('getPrinterCapabilities', () async {
      expect(
        await p.getPrinterCapabilities('any'),
        isA<NitroErr<PrinterCapabilities>>(),
      );
    });

    test('getPrintJobAt', () async {
      expect(await p.getPrintJobAt(0), isA<NitroErr<PrintJob>>());
    });

    test('getPrintJobStatus', () async {
      expect(await p.getPrintJobStatus('job'), isA<NitroErr<PrintJob>>());
    });

    test('getPrinterStatusDetail', () async {
      expect(
        await p.getPrinterStatusDetail('any', timeoutSeconds: 1),
        isA<NitroErr<PrinterStatusDetail>>(),
      );
    });
  });

  group('printer enumeration / discovery', () {
    test('getAllPrinters returns an empty list', () async {
      expect(await p.getAllPrinters(), isEmpty);
    });

    test('start/stopPrinterDiscovery return false', () async {
      expect(await p.startPrinterDiscovery(), isFalse);
      expect(await p.stopPrinterDiscovery(), isFalse);
    });
  });

  group('document printing via the browser dialog', () {
    void expectPrinted(PrintResult r) {
      expect(r.success, isTrue, reason: 'error: ${r.errorMessage}');
      expect(r.jobId, startsWith('web-print-'));
      expect(r.errorCode, isEmpty);
    }

    test('printText succeeds', () async {
      expectPrinted(await p.printText('hello'));
    });

    test('printText with settings record round-trip', () async {
      expectPrinted(
        await p.printText(
          'hello',
          settings: PrintSettings(printerId: 'ignored-on-web', copies: 2),
        ),
      );
    });

    test('printImage succeeds', () async {
      // 1×1 red PNG
      expectPrinted(
        await p.printImage(
          Uint8List.fromList(const [
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
            0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
            0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
            0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53,
            0xDE, 0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41,
            0x54, 0x08, 0xD7, 0x63, 0xF8, 0xCF, 0xC0, 0x00,
            0x00, 0x00, 0x02, 0x00, 0x01, 0xE2, 0x21, 0xBC,
            0x33, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E,
            0x44, 0xAE, 0x42, 0x60, 0x82,
          ]),
        ),
      );
    });

    test('printDocument (plain text) succeeds', () async {
      expectPrinted(await p.printDocument(_textDoc()));
    });

    test('printDocument (html) succeeds', () async {
      expectPrinted(
        await p.printDocument(
          PrintDocument(
            id: 'doc-html',
            title: 'HTML',
            type: DocumentType.html,
            data: Uint8List.fromList('<h1>hi</h1>'.codeUnits),
          ),
        ),
      );
    });

    test('printPdf completes (viewer-dependent)', () async {
      // Headless Chrome may not host the PDF viewer in an iframe — accept
      // either a success or the flow's honest timeout failure.
      final r = await p.printPdf(Uint8List.fromList('%PDF-1.4'.codeUnits));
      if (!r.success) {
        expect(r.errorCode, 'WEB_PRINT_FAILED');
      }
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('printBatch prints each document sequentially', () async {
      final results = await p.printBatch([_textDoc(), _textDoc()], false);
      expect(results, hasLength(2));
      for (final r in results) {
        expectPrinted(r);
      }
    });

    test('printBatch with stopOnError completes when nothing fails', () async {
      final results = await p.printBatch([_textDoc(), _textDoc()], true);
      expect(results, hasLength(2));
    });

    test('printFile returns false (no local filesystem)', () async {
      expect(await p.printFile('/tmp/x.pdf'), isFalse);
    });

    test('printToFile downloads and returns true', () async {
      expect(await p.printToFile(_textDoc(), '/tmp/out.txt'), isTrue);
    });
  });

  group('dialog / preview / page count', () {
    test('showPrintDialog confirms and echoes settings', () async {
      final settings = PrintSettings(printerId: 'p1', copies: 3);
      final r = await p.showPrintDialog(_textDoc(), initialSettings: settings);
      // `confirmed` means the dialog was shown and closed — browsers cannot
      // reveal Print-vs-Cancel.
      expect(r.confirmed, isTrue, reason: 'error: ${r.errorMessage}');
      expect(r.confirmedSettings.printerId, 'p1');
      expect(r.confirmedSettings.copies, 3);
    });

    test('renderPreview returns an empty preview', () async {
      final r = await p.renderPreview(_textDoc());
      expect(r.length, 0);
      expect(r.bytes, isEmpty);
    });

    test('getPageCount is 0 (no layout engine)', () async {
      expect(await p.getPageCount(_textDoc()), 0);
    });
  });

  group('job management / admin', () {
    test('job controls return false', () async {
      expect(await p.cancelPrintJob('j'), isFalse);
      expect(await p.pausePrintJob('j'), isFalse);
      expect(await p.resumePrintJob('j'), isFalse);
      expect(await p.clearPrintQueue(), isFalse);
    });

    test('getPrintJobsCount is 0', () async {
      expect(await p.getPrintJobsCount(), 0);
    });

    test('connection / admin return false', () async {
      expect(
        await p.testPrinterConnection('10.0.0.1', timeoutSeconds: 1),
        isFalse,
      );
      expect(await p.setDefaultPrinter('p'), isFalse);
      expect(await p.openSystemPrintQueue(''), isFalse);
      expect(await p.openPrinterProperties('p'), isFalse);
    });
  });

  group('raw protocol printing fails honestly (no TCP)', () {
    void expectUnsupported(PrintResult r) {
      expect(r.success, isFalse);
      expect(r.errorCode, 'WEB_UNSUPPORTED');
      expect(r.errorMessage, isNotEmpty);
    }

    test('printRaw', () async {
      expectUnsupported(await p.printRaw(Uint8List.fromList([1, 2, 3])));
    });

    test('printEscPos', () async {
      expectUnsupported(await p.printEscPos(Uint8List.fromList([0x1B, 0x40])));
    });

    test('printZpl', () async {
      expectUnsupported(await p.printZpl('^XA^FDtest^FS^XZ'));
    });

    test('cancelRawPrint returns false', () async {
      expect(await p.cancelRawPrint(), isFalse);
    });
  });
}
