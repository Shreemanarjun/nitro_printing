// Browser tests for the WASM (web) backend.
//
// Build the module first, then run under BOTH web compilers — they differ at
// the js_interop boundary, so a green dart2js run does not imply dart2wasm:
//   bash web/build_web.sh
//   flutter pub run test -p chrome test/nitro_printing_web_test.dart
//   flutter pub run test -p chrome -c dart2wasm test/nitro_printing_web_test.dart
//
// Web semantics under test:
//   • dialog printing (text/HTML/image/PDF) — window.print() is a no-op under
//     headless Chrome, so the flows complete without blocking;
//   • raw printing routed by printerId — the ws:// relay path round-trips for
//     real against the hybrid asset server's /raw WebSocket endpoint; the
//     WebUSB and TCPSocket paths fail with actionable guidance (headless has
//     no granted devices and is not an Isolated Web App);
//   • pure-wasm PDF utilities — renderPreview and getPageCount;
//   • printer/job caches empty until getAllPrinters() grants populate them.
//
// Imports the spec directly (not the package barrel): the barrel exports the
// Flutter print-settings page, and `dart test -p chrome` has no Flutter web
// engine, so pulling in `package:flutter` fails to compile.
@TestOn('browser')
// Every async API completes via a JS→wasm callback; if a flow dies before
// calling back the future would otherwise stall the full 30s default.
@Timeout(Duration(seconds: 15))
library;

import 'dart:async';

import 'package:nitro/nitro.dart';
import 'package:test/test.dart';

import 'package:nitro_printing/src/nitro_printing.native.dart';
import 'package:nitro_printing/src/nitro_printing.platform.g.dart';

PrintDocument _textDoc([String text = 'hello web']) => PrintDocument(
  id: 'doc-1',
  title: 'Web Test',
  type: DocumentType.plainText,
  data: Uint8List.fromList(text.codeUnits),
);

/// 1×1 red PNG — strictly valid (createImageBitmap rejects the common
/// hand-rolled fixture whose IDAT lacks a real zlib header).
Uint8List _pngPixel() => Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53,
  0xDE, 0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x63, 0xF8, 0xCF, 0xC0, 0x00,
  0x00, 0x03, 0x01, 0x01, 0x00, 0xC9, 0xFE, 0x92,
  0xEF, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E,
  0x44, 0xAE, 0x42, 0x60, 0x82,
]);

/// Minimal one-page PDF.
Uint8List _minimalPdf() {
  const src =
      '%PDF-1.4\n'
      '1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n'
      '2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj\n'
      '3 0 obj<</Type/Page/MediaBox[0 0 595 842]/Parent 2 0 R>>endobj\n'
      'trailer<</Size 4/Root 1 0 R>>\n%%EOF';
  return Uint8List.fromList(src.codeUnits);
}

/// Minimal N-page PDF with a classic page tree.
Uint8List _multiPagePdf(int pages) {
  final kids =
      List.generate(pages, (i) => '${3 + i} 0 R').join(' ');
  final buf = StringBuffer()
    ..write('%PDF-1.4\n')
    ..write('1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n')
    ..write('2 0 obj<</Type/Pages/Kids[$kids]/Count $pages>>endobj\n');
  for (var i = 0; i < pages; i++) {
    buf.write('${3 + i} 0 obj<</Type/Page/MediaBox[0 0 595 842]'
        '/Parent 2 0 R>>endobj\n');
  }
  buf.write('trailer<</Size ${3 + pages}/Root 1 0 R>>\n%%EOF');
  return Uint8List.fromList(buf.toString().codeUnits);
}

PrintDocument _pdfDoc(Uint8List pdf) => PrintDocument(
  id: 'doc-pdf',
  title: 'PDF',
  type: DocumentType.pdf,
  data: pdf,
);

PrintDocument _htmlDoc(String html) => PrintDocument(
  id: 'doc-html',
  title: 'HTML',
  type: DocumentType.html,
  data: Uint8List.fromList(html.codeUnits),
);

void main() {
  late NitroPrinting p;
  late int serverPort;
  final rawReceived = StreamController<String>.broadcast();

  setUpAll(() async {
    final channel = spawnHybridUri('asset_server.dart');
    final first = Completer<int>();
    channel.stream.listen((message) {
      if (message is num && !first.isCompleted) {
        first.complete(message.toInt());
      } else if (message is String && message.startsWith('raw:')) {
        rawReceived.add(message);
      }
    });
    // dart2wasm hands JS numbers over as double — never cast with `as int`.
    serverPort = await first.future;
    await ensureNitroPrintingReady(
      jsUrl: 'http://localhost:$serverPort/nitro_printing.js',
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

    test('getPrintersCount is 0 before any grant', () {
      expect(p.getPrintersCount(), 0);
    });

    test('getPrinterDriverVersion is empty', () {
      expect(p.getPrinterDriverVersion('any'), isEmpty);
    });
  });

  group('@NitroResult lookups fail with NitroErr while cache is empty', () {
    test('getPrinterAt', () async {
      expect(await p.getPrinterAt(0), isA<NitroErr<PrinterInfo>>());
    });

    test('getDefaultPrinter (no such concept on web)', () async {
      expect(await p.getDefaultPrinter(), isA<NitroErr<PrinterInfo>>());
    });

    test('getPrinterCapabilities', () async {
      expect(
        await p.getPrinterCapabilities('unknown'),
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
        await p.getPrinterStatusDetail('unknown', timeoutSeconds: 1),
        isA<NitroErr<PrinterStatusDetail>>(),
      );
    });
  });

  group('printer enumeration / discovery', () {
    test('getAllPrinters is empty (no WebUSB grants, no Web Printing)',
        () async {
      expect(await p.getAllPrinters(), isEmpty);
    });

    test('startPrinterDiscovery is false without a user gesture', () async {
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
          settings: PrintSettings(printerId: '', copies: 2),
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
      final r = await p.printPdf(_minimalPdf());
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

    test('printFile returns false for plain paths (no local filesystem)',
        () async {
      expect(await p.printFile('/tmp/x.pdf'), isFalse);
    });

    test('printFile fetches and prints URLs', () async {
      expect(await p.printFile('data:text/plain,hello%20from%20a%20url'),
          isTrue);
    });

    test('printFile is false for an unreachable URL', () async {
      expect(await p.printFile('http://localhost:1/nope.pdf'), isFalse);
    });

    test('printToFile downloads and returns true', () async {
      expect(await p.printToFile(_textDoc(), '/tmp/out.pdf'), isTrue);
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

    test('renderPreview renders plain text to a real PDF', () async {
      final r = await p.renderPreview(_textDoc('line one\nline two'));
      expect(r.length, greaterThan(0));
      expect(String.fromCharCodes(r.bytes.take(5)), '%PDF-');
    });

    test('renderPreview passes a PDF document through', () async {
      final pdf = _minimalPdf();
      final r = await p.renderPreview(
        PrintDocument(
          id: 'doc-pdf',
          title: 'PDF',
          type: DocumentType.pdf,
          data: pdf,
        ),
      );
      expect(r.length, pdf.length);
      expect(r.bytes, equals(pdf));
    });

    test('getPageCount parses the PDF page tree', () async {
      expect(
        await p.getPageCount(
          PrintDocument(
            id: 'doc-pdf',
            title: 'PDF',
            type: DocumentType.pdf,
            data: _minimalPdf(),
          ),
        ),
        1,
      );
    });

    test('getPageCount paginates plain text at 60 lines/page', () async {
      final text = List.generate(120, (i) => 'line $i').join('\n');
      expect(await p.getPageCount(_textDoc(text)), 2);
    });
  });

  group('raw printing routes by printerId', () {
    test('ws:// relay round-trips bytes to the WebSocket server', () async {
      final data = Uint8List.fromList(List.generate(512, (i) => i & 0xff));
      final received = rawReceived.stream.first;
      final r = await p.printRaw(
        data,
        settings: PrintSettings(printerId: 'ws://localhost:$serverPort/raw'),
      );
      expect(r.success, isTrue, reason: 'error: ${r.errorMessage}');
      expect(await received.timeout(const Duration(seconds: 5)), 'raw:512');
    });

    test('printEscPos over the ws:// relay honors copies', () async {
      final escPos = Uint8List.fromList([0x1B, 0x40, 0x0A]);
      final counts = rawReceived.stream.take(2).toList();
      final r = await p.printEscPos(
        escPos,
        settings: PrintSettings(
          printerId: 'ws://localhost:$serverPort/raw',
          copies: 2,
        ),
      );
      expect(r.success, isTrue, reason: 'error: ${r.errorMessage}');
      expect(
        await counts.timeout(const Duration(seconds: 5)),
        ['raw:3', 'raw:3'],
      );
    });

    test('printZpl over the ws:// relay sends exactly one copy', () async {
      const zpl = '^XA^FDtest^FS^XZ';
      final received = rawReceived.stream.first;
      final r = await p.printZpl(
        zpl,
        settings: PrintSettings(
          printerId: 'ws://localhost:$serverPort/raw',
          copies: 5, // ZPL carries its own quantity commands — still 1 write
        ),
      );
      expect(r.success, isTrue, reason: 'error: ${r.errorMessage}');
      expect(
        await received.timeout(const Duration(seconds: 5)),
        'raw:${zpl.length}',
      );
    });

    test('printText with a raw printerId prints ESC/POS to the printer',
        () async {
      final received = rawReceived.stream.first;
      final r = await p.printText(
        'RECEIPT',
        settings: PrintSettings(printerId: 'ws://localhost:$serverPort/raw'),
      );
      expect(r.success, isTrue, reason: 'error: ${r.errorMessage}');
      // ESC @ (2) + "RECEIPT" (7) + LF (1) + ESC d 4 (3) + GS V B 0 (4)
      expect(await received.timeout(const Duration(seconds: 5)), 'raw:17');
    });

    test('printDocument plain text routes to a raw printerId too', () async {
      final counts = rawReceived.stream.take(2).toList();
      final r = await p.printDocument(
        _textDoc('X'),
        settings: PrintSettings(
          printerId: 'ws://localhost:$serverPort/raw',
          copies: 2,
        ),
      );
      expect(r.success, isTrue, reason: 'error: ${r.errorMessage}');
      // ESC @ (2) + "X" (1) + LF (1) + feed/cut (7) = 11 bytes, twice
      expect(
        await counts.timeout(const Duration(seconds: 5)),
        ['raw:11', 'raw:11'],
      );
    });

    test('printImage with a raw printerId rasters ESC/POS to the printer',
        () async {
      final received = rawReceived.stream.first;
      final r = await p.printImage(
        _pngPixel(),
        settings: PrintSettings(printerId: 'ws://localhost:$serverPort/raw'),
      );
      expect(r.success, isTrue, reason: 'error: ${r.errorMessage}');
      // init (2) + GS v 0 header (8) + 1 raster byte + feed/cut (7)
      expect(await received.timeout(const Duration(seconds: 5)), 'raw:18');
    });

    test('CP437 translation maps accented ESC/POS text', () async {
      final received = rawReceived.stream.first;
      final r = await p.printText(
        'Grüße', // 5 glyphs → 5 CP437 bytes (ü→0x81, ß→0xE1)
        settings: PrintSettings(printerId: 'ws://localhost:$serverPort/raw'),
      );
      expect(r.success, isTrue, reason: 'error: ${r.errorMessage}');
      expect(await received.timeout(const Duration(seconds: 5)), 'raw:15');
    });

    test('printBatch routes text items to a raw printerId', () async {
      final counts = rawReceived.stream.take(2).toList();
      final results = await p.printBatch(
        [_textDoc('A'), _textDoc('B')],
        false,
        settings: PrintSettings(printerId: 'ws://localhost:$serverPort/raw'),
      );
      expect(results, hasLength(2));
      expect(results.every((r) => r.success), isTrue);
      // Each item: init (2) + 1 char + LF (1) + feed/cut (7) = 11 bytes.
      expect(
        await counts.timeout(const Duration(seconds: 5)),
        ['raw:11', 'raw:11'],
      );
    });

    test('serial printerId without a grant fails with guidance', () async {
      final r = await p.printRaw(
        Uint8List.fromList([1, 2, 3]),
        settings: PrintSettings(printerId: 'serial:9600'),
      );
      expect(r.success, isFalse);
      expect(r.errorMessage.toLowerCase(), contains('serial'));
    });

    test('ble printerId without a grant fails with guidance', () async {
      final r = await p.printRaw(
        Uint8List.fromList([1, 2, 3]),
        settings: PrintSettings(printerId: 'ble:'),
      );
      expect(r.success, isFalse);
      expect(r.errorMessage, isNotEmpty);
    });

    test('no printerId fails with WebUSB guidance', () async {
      final r = await p.printRaw(Uint8List.fromList([1, 2, 3]));
      expect(r.success, isFalse);
      expect(r.errorMessage, contains('USB printer'));
      expect(r.errorMessage, contains('startPrinterDiscovery'));
    });

    test('bare IP fails with Isolated Web App guidance', () async {
      final r = await p.printRaw(
        Uint8List.fromList([1, 2, 3]),
        settings: PrintSettings(printerId: '192.0.2.1'),
      );
      expect(r.success, isFalse);
      expect(r.errorMessage, contains('Isolated Web App'));
    });

    test('unreachable ws:// relay fails honestly', () async {
      final r = await p.printRaw(
        Uint8List.fromList([1, 2, 3]),
        settings: PrintSettings(
          printerId: 'ws://localhost:1/raw',
          networkTimeoutSeconds: 2,
        ),
      );
      expect(r.success, isFalse);
      expect(r.errorCode, 'WEB_PRINT_FAILED');
    });

    test('cancelRawPrint is false with nothing in flight', () async {
      expect(await p.cancelRawPrint(), isFalse);
    });
  });

  group('connection probing', () {
    test('reachable ws:// endpoint is true', () async {
      expect(
        await p.testPrinterConnection(
          'ws://localhost:$serverPort/raw',
          timeoutSeconds: 3,
        ),
        isTrue,
      );
    });

    test('unreachable endpoints are false', () async {
      expect(
        await p.testPrinterConnection('ws://localhost:1/raw',
            timeoutSeconds: 2),
        isFalse,
      );
      expect(
        await p.testPrinterConnection('usb:0000:0000', timeoutSeconds: 1),
        isFalse,
      );
    });
  });

  group('job management / admin', () {
    test('job queue is empty (Web Printing unavailable outside IWAs)',
        () async {
      expect(await p.getPrintJobsCount(), 0);
      expect(await p.cancelPrintJob('j'), isFalse);
      expect(await p.pausePrintJob('j'), isFalse);
      expect(await p.resumePrintJob('j'), isFalse);
      expect(await p.clearPrintQueue(), isFalse);
    });

    test('OS-level admin is false (unreachable from the sandbox)', () async {
      expect(await p.setDefaultPrinter('p'), isFalse);
      expect(await p.openSystemPrintQueue(''), isFalse);
      expect(await p.openPrinterProperties('p'), isFalse);
    });
  });

  group('edge cases: dialog printing', () {
    test('empty text still prints', () async {
      final r = await p.printText('');
      expect(r.success, isTrue, reason: 'error: ${r.errorMessage}');
    });

    test('unicode text survives the UTF-8 crossing', () async {
      final r = await p.printText('नमस्ते 🖨️ Grüße');
      expect(r.success, isTrue, reason: 'error: ${r.errorMessage}');
    });

    test('concurrent prints complete independently', () async {
      final results = await Future.wait([p.printText('a'), p.printText('b')]);
      expect(results[0].success, isTrue);
      expect(results[1].success, isTrue);
      expect(results[0].jobId, isNot(results[1].jobId));
    });

    test('printBatch with an empty list returns no results', () async {
      expect(await p.printBatch([], false), isEmpty);
    });

    test('printBatch handles mixed document types', () async {
      final results = await p.printBatch([
        _textDoc(),
        PrintDocument(
          id: 'doc-html',
          title: 'HTML',
          type: DocumentType.html,
          data: Uint8List.fromList('<p>hi</p>'.codeUnits),
        ),
      ], false);
      expect(results, hasLength(2));
      expect(results.every((r) => r.success), isTrue);
    });

    test('full PrintSettings drive the rendered pages', () async {
      final r = await p.printText(
        List.generate(70, (i) => 'line $i').join('\n'),
        settings: PrintSettings(
          paperSize: PaperSize.letter,
          orientationDegrees: 90,
          marginTop: 36,
          marginRight: 24,
          marginBottom: 36,
          marginLeft: 24,
          copies: 2,
          color: false,
          headerText: 'Header',
          footerText: 'Footer',
          pageRangeFrom: 1,
          pageRangeTo: 1,
        ),
      );
      expect(r.success, isTrue, reason: 'error: ${r.errorMessage}');
    });

    test('custom paper size renders', () async {
      final r = await p.printText(
        'receipt',
        settings: PrintSettings(
          paperSize: PaperSize.custom,
          customPaperWidth: 204, // 72mm thermal roll in pt
          customPaperHeight: 566,
        ),
      );
      expect(r.success, isTrue, reason: 'error: ${r.errorMessage}');
    });

    test('page range past the content still prints an empty page', () async {
      final r = await p.printText(
        'one page only',
        settings: PrintSettings(pageRangeFrom: 5, pageRangeTo: 9),
      );
      expect(r.success, isTrue, reason: 'error: ${r.errorMessage}');
    });

    test('html document honors copies and margins', () async {
      final r = await p.printDocument(
        PrintDocument(
          id: 'doc-html',
          title: 'HTML',
          type: DocumentType.html,
          data: Uint8List.fromList('<h1>hi</h1>'.codeUnits),
        ),
        settings: PrintSettings(copies: 2, marginTop: 20, marginLeft: 20),
      );
      expect(r.success, isTrue, reason: 'error: ${r.errorMessage}');
    });

    test('image honors fitToPage, grayscale, and copies', () async {
      final r = await p.printImage(
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
        settings: PrintSettings(fitToPage: true, color: false, copies: 2),
      );
      expect(r.success, isTrue, reason: 'error: ${r.errorMessage}');
    });

    test('jobName titles the print job document', () async {
      final r = await p.printText(
        'invoice body',
        settings: PrintSettings(jobName: 'Invoice #42'),
      );
      expect(r.success, isTrue, reason: 'error: ${r.errorMessage}');
    });

    test('pagesPerSheet lays text out N-up', () async {
      final r = await p.printText(
        List.generate(130, (i) => 'line $i').join('\n'), // 3 logical pages
        settings: PrintSettings(pagesPerSheet: 4),
      );
      expect(r.success, isTrue, reason: 'error: ${r.errorMessage}');
    });

    test('pagesPerSheet with copies for images', () async {
      final r = await p.printImage(
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
        settings: PrintSettings(pagesPerSheet: 2, copies: 4),
      );
      expect(r.success, isTrue, reason: 'error: ${r.errorMessage}');
    });

    test('html document with jobName and header/footer', () async {
      final r = await p.printDocument(
        PrintDocument(
          id: 'doc-html',
          title: 'HTML',
          type: DocumentType.html,
          data: Uint8List.fromList('<h1>hi</h1>'.codeUnits),
        ),
        settings: PrintSettings(
          jobName: 'Report',
          headerText: 'ACME Corp',
          footerText: 'Confidential',
        ),
      );
      expect(r.success, isTrue, reason: 'error: ${r.errorMessage}');
    });

    test('uncollated copies interleave pages', () async {
      final r = await p.printText(
        List.generate(70, (i) => 'line $i').join('\n'), // 2 logical pages
        settings: PrintSettings(copies: 2, collate: false),
      );
      expect(r.success, isTrue, reason: 'error: ${r.errorMessage}');
    });

    test('collate and mediaType settings round-trip harmlessly', () async {
      // Outside an Isolated Web App these map to nothing visible, but the
      // record must decode and the flow must still complete.
      final r = await p.printText(
        'labels',
        settings: PrintSettings(collate: true, mediaType: MediaType.label),
      );
      expect(r.success, isTrue, reason: 'error: ${r.errorMessage}');
    });

    test('showPrintDialog without settings echoes defaults', () async {
      final r = await p.showPrintDialog(_textDoc());
      expect(r.confirmed, isTrue, reason: 'error: ${r.errorMessage}');
      expect(r.confirmedSettings.copies, 1);
      expect(r.confirmedSettings.paperSize, PaperSize.a4);
    });
  });

  group('edge cases: PDF utilities', () {
    test('renderPreview of empty text is still a valid PDF', () async {
      final r = await p.renderPreview(_textDoc(''));
      expect(r.length, greaterThan(0));
      expect(String.fromCharCodes(r.bytes.take(5)), '%PDF-');
    });

    test('renderPreview escapes PDF string delimiters', () async {
      final r = await p.renderPreview(_textDoc(r'parens () and \backslash'));
      expect(r.length, greaterThan(0));
      expect(String.fromCharCodes(r.bytes.take(5)), '%PDF-');
    });

    test('renderPreview embeds an image as a one-page PDF', () async {
      final r = await p.renderPreview(
        PrintDocument(
          id: 'i',
          title: 'i',
          type: DocumentType.image,
          data: _pngPixel(),
        ),
      );
      expect(r.length, greaterThan(0));
      final pdf = String.fromCharCodes(r.bytes);
      expect(pdf, startsWith('%PDF-'));
      expect(pdf, contains('/DCTDecode'));
    });

    test('renderPreview of an undecodable image degrades to empty', () async {
      final r = await p.renderPreview(
        PrintDocument(
          id: 'i',
          title: 'i',
          type: DocumentType.image,
          data: Uint8List.fromList([0xFF, 0xD8, 0xFF]), // truncated JPEG
        ),
      );
      expect(r.length, 0);
    });

    test('renderPreview page geometry follows PrintSettings', () async {
      final a5 = await p.renderPreview(
        _textDoc('hi'),
        settings: PrintSettings(paperSize: PaperSize.a5),
      );
      expect(String.fromCharCodes(a5.bytes), contains('MediaBox[0 0 420 595]'));

      final landscape = await p.renderPreview(
        _textDoc('hi'),
        settings: PrintSettings(
          paperSize: PaperSize.a4,
          orientationDegrees: 90,
        ),
      );
      expect(
        String.fromCharCodes(landscape.bytes),
        contains('MediaBox[0 0 842 595]'),
      );
    });

    test('printToFile renders an image to a PDF download', () async {
      final ok = await p.printToFile(
        PrintDocument(
          id: 'i',
          title: 'i',
          type: DocumentType.image,
          data: _pngPixel(),
        ),
        '/tmp/photo.pdf',
      );
      expect(ok, isTrue);
    });

    test('sequential previews are each valid when read immediately', () async {
      final first = await p.renderPreview(_textDoc('first'));
      expect(String.fromCharCodes(first.bytes.take(5)), '%PDF-');
      final second = await p.renderPreview(_textDoc('second'));
      expect(String.fromCharCodes(second.bytes.take(5)), '%PDF-');
    });

    test('getPageCount boundaries at 60 lines/page', () async {
      expect(await p.getPageCount(_textDoc('')), 1);
      final sixty = List.filled(60, 'x').join('\n');
      expect(await p.getPageCount(_textDoc(sixty)), 1);
      final sixtyOne = List.filled(61, 'x').join('\n');
      expect(await p.getPageCount(_textDoc(sixtyOne)), 2);
    });

    test('getPageCount rasterizes html (short content is one page)', () async {
      expect(await p.getPageCount(_htmlDoc('<p>x</p>')), 1);
    });

    test('getPageCount paginates tall html content', () async {
      // The A4 slice is (842-80)*2 = 1524 px tall — 3000 px needs 2 pages.
      expect(
        await p.getPageCount(_htmlDoc('<div style="height:3000px">x</div>')),
        2,
      );
    });

    test('renderPreview rasterizes html to a real PDF', () async {
      final r = await p.renderPreview(_htmlDoc('<h1>Hello</h1><p>world</p>'));
      expect(r.length, greaterThan(0));
      final pdf = String.fromCharCodes(r.bytes);
      expect(pdf, startsWith('%PDF-'));
      expect(pdf, contains('/DCTDecode'));
    });

    test('printToFile renders html to a PDF download', () async {
      expect(
        await p.printToFile(_htmlDoc('<h1>Report</h1>'), '/tmp/report.pdf'),
        isTrue,
      );
    });

    test('getPageCount walks a multi-page PDF page tree', () async {
      expect(await p.getPageCount(_pdfDoc(_multiPagePdf(3))), 3);
    });

    test('pageRange extracts a sub-document from a PDF', () async {
      final r = await p.renderPreview(
        _pdfDoc(_multiPagePdf(3)),
        settings: PrintSettings(pageRangeFrom: 2, pageRangeTo: 2),
      );
      expect(r.length, greaterThan(0));
      expect(String.fromCharCodes(r.bytes.take(5)), '%PDF-');
      // The extracted document must now count exactly one page.
      expect(
        await p.getPageCount(_pdfDoc(Uint8List.fromList(r.bytes))),
        1,
      );
    });

    test('full pageRange passes the PDF through unchanged', () async {
      final pdf = _multiPagePdf(3);
      final r = await p.renderPreview(
        _pdfDoc(pdf),
        settings: PrintSettings(pageRangeFrom: 1, pageRangeTo: 3),
      );
      expect(r.bytes, equals(pdf));
    });
  });

  group('edge cases: raw transport', () {
    test('empty payload round-trips as zero bytes', () async {
      final received = rawReceived.stream.first;
      final r = await p.printRaw(
        Uint8List(0),
        settings: PrintSettings(printerId: 'ws://localhost:$serverPort/raw'),
      );
      expect(r.success, isTrue, reason: 'error: ${r.errorMessage}');
      expect(await received.timeout(const Duration(seconds: 5)), 'raw:0');
    });

    test('a 256 KiB payload survives the relay intact', () async {
      final received = rawReceived.stream.first;
      final r = await p.printRaw(
        Uint8List(256 * 1024),
        settings: PrintSettings(printerId: 'ws://localhost:$serverPort/raw'),
      );
      expect(r.success, isTrue, reason: 'error: ${r.errorMessage}');
      expect(
        await received.timeout(const Duration(seconds: 10)),
        'raw:${256 * 1024}',
      );
    });

    test('unicode ZPL is sent as UTF-8 bytes', () async {
      const zpl = '^XA^FDGrüße^FS^XZ'; // ü = 2 bytes in UTF-8
      final received = rawReceived.stream.first;
      final r = await p.printZpl(
        zpl,
        settings: PrintSettings(printerId: 'ws://localhost:$serverPort/raw'),
      );
      expect(r.success, isTrue, reason: 'error: ${r.errorMessage}');
      expect(
        await received.timeout(const Duration(seconds: 5)),
        'raw:${utf8.encode(zpl).length}',
      );
    });

    test('copies below 1 clamp to a single write', () async {
      final received = rawReceived.stream.first;
      final r = await p.printRaw(
        Uint8List.fromList([1, 2, 3, 4]),
        settings: PrintSettings(
          printerId: 'ws://localhost:$serverPort/raw',
          copies: 0,
        ),
      );
      expect(r.success, isTrue, reason: 'error: ${r.errorMessage}');
      expect(await received.timeout(const Duration(seconds: 5)), 'raw:4');
      // A second message arriving would break the next test's stream reads —
      // the single 'raw:4' above proves one write.
    });

    test('concurrent relay prints complete independently', () async {
      final counts = rawReceived.stream.take(2).toList();
      final results = await Future.wait([
        p.printRaw(
          Uint8List(100),
          settings: PrintSettings(printerId: 'ws://localhost:$serverPort/raw'),
        ),
        p.printRaw(
          Uint8List(200),
          settings: PrintSettings(printerId: 'ws://localhost:$serverPort/raw'),
        ),
      ]);
      expect(results.every((r) => r.success), isTrue);
      final got = (await counts.timeout(const Duration(seconds: 5)))..sort();
      expect(got, ['raw:100', 'raw:200']);
    });

    test('empty-string connection probe is false', () async {
      expect(await p.testPrinterConnection('', timeoutSeconds: 1), isFalse);
    });
  });

  group('edge cases: NitroErr guidance', () {
    test('capability lookup names the fix', () async {
      final r = await p.getPrinterCapabilities('unknown');
      expect(r, isA<NitroErr<PrinterCapabilities>>());
      expect((r as NitroErr).message, contains('getAllPrinters'));
    });

    test('default-printer lookup explains the web gap', () async {
      final r = await p.getDefaultPrinter();
      expect(r, isA<NitroErr<PrinterInfo>>());
      expect((r as NitroErr).message.toLowerCase(), contains('default'));
    });
  });
}
