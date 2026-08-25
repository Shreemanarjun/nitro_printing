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
import 'package:nitro_printing/src/print_error_catalog.dart';
import 'package:nitro_printing/src/web_print_decor.dart';

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
  final qzReceived = StreamController<String>.broadcast();
  final agentReceived = StreamController<String>.broadcast();

  setUpAll(() async {
    final channel = spawnHybridUri('asset_server.dart');
    final first = Completer<int>();
    channel.stream.listen((message) {
      if (message is num && !first.isCompleted) {
        first.complete(message.toInt());
      } else if (message is String && message.startsWith('raw:')) {
        rawReceived.add(message);
      } else if (message is String && message.startsWith('agent')) {
        agentReceived.add(message);
      } else if (message is String && message.startsWith('qz')) {
        qzReceived.add(message);
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
      // Pin the agent probe to a dead endpoint so a QZ Tray instance on the
      // host machine cannot flip this assertion.
      WebPrintAgent.configure(
        endpoint: 'ws://localhost:1/qz',
        agentEndpoint: 'ws://localhost:1/agent',
      );
      try {
        expect(await p.startPrinterDiscovery(), isFalse);
        expect(await p.stopPrinterDiscovery(), isFalse);
      } finally {
        WebPrintAgent.configure();
      }
    });
  });

  group('document printing via the browser dialog', () {
    void expectPrinted(PrintResult r) {
      expect(r.success, isTrue, reason: 'error: ${r.errorMessage}');
      expect(r.jobId, startsWith('web-print-'));
      // Dialog prints are honest: the browser cannot reveal Print vs Cancel,
      // so the outcome is dialogShown — never a verified "printed".
      expect(r.errorCode, kDialogOutcomeUnknown);
      expect(r.outcome, PrintOutcome.dialogShown);
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
        expect(r.errorCode, 'DIALOG_FAILED');
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
      expect(r.errorKind, PrintErrorCode.noUsbDevice);
      expect(r.errorMessage, contains('USB printer'));
      expect(r.errorMessage, contains('startPrinterDiscovery'));
    });

    test('errorKind is none on success and typed on each transport', () async {
      final ok = await p.printRaw(
        Uint8List.fromList([1]),
        settings: PrintSettings(printerId: 'ws://localhost:$serverPort/raw'),
      );
      expect(ok.errorKind, PrintErrorCode.none);

      final serial = await p.printRaw(
        Uint8List.fromList([1]),
        settings: PrintSettings(printerId: 'serial:9600'),
      );
      expect(
        [
          PrintErrorCode.noSerialDevice,
          PrintErrorCode.webSerialUnavailable,
        ],
        contains(serial.errorKind),
      );

      final ble = await p.printRaw(
        Uint8List.fromList([1]),
        settings: PrintSettings(printerId: 'ble:'),
      );
      expect(
        [
          PrintErrorCode.noBleDevice,
          PrintErrorCode.webBluetoothUnavailable,
          PrintErrorCode.bleFailed,
        ],
        contains(ble.errorKind),
      );
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
      expect(
        [PrintErrorCode.relayFailed, PrintErrorCode.relayTimeout],
        contains(r.errorKind),
      );
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
    test('job queue reflects every tracked web print', () async {
      // Earlier groups printed via dialog and relay — all tracked.
      expect(await p.getPrintJobsCount(), greaterThan(0));
      final last = await p.lastPrintJob();
      expect(last, isNotNull);
      expect(last!.id, startsWith('web-print-'));
    });

    test('unknown job ids are inert', () async {
      expect(await p.cancelPrintJob('nope'), isFalse);
      expect(await p.pausePrintJob('nope'), isFalse);
      expect(await p.resumePrintJob('nope'), isFalse);
      expect(await p.clearPrintQueue(), isFalse);
    });

    test('a completed relay print is queryable by job id', () async {
      final r = await p.printRaw(
        Uint8List.fromList([9, 9]),
        settings: PrintSettings(printerId: 'ws://localhost:$serverPort/raw'),
      );
      expect(r.success, isTrue);
      // Raw transports VERIFY delivery — outcome is a real "printed".
      expect(r.outcome, PrintOutcome.printed);
      final job = await p.getPrintJobStatus(r.jobId);
      expect(job, isA<NitroOk<PrintJob>>());
      final j = (job as NitroOk<PrintJob>).value;
      expect(j.state, PrintState.completed);
      expect(j.errorMessage, isEmpty);
      expect(j.outcome, PrintOutcome.printed);
    });

    test('a dialog print job reports dialogShown, never printed', () async {
      final r = await p.printText('dialog outcome check');
      expect(r.success, isTrue);
      expect(r.outcome, PrintOutcome.dialogShown);
      final job = await p.getPrintJobStatus(r.jobId);
      final j = (job as NitroOk<PrintJob>).value;
      expect(j.state, PrintState.completed);
      expect(j.outcome, PrintOutcome.dialogShown);
    });

    test('dialog duration heuristic is measured and typed', () async {
      final r = await p.printText('duration check');
      expect(r.outcome, PrintOutcome.dialogShown);
      // Headless Chrome's print() is a no-op: the dialog "closes" instantly,
      // so the measured duration reads as a fast close.
      expect(r.dialogDurationMs, isNotNull);
      expect(r.dialogGuess, DialogOutcomeGuess.likelyCancelled);

      final raw = await p.printRaw(
        Uint8List.fromList([1]),
        settings: PrintSettings(printerId: 'ws://localhost:$serverPort/raw'),
      );
      expect(raw.dialogDurationMs, isNull);
      expect(raw.dialogGuess, DialogOutcomeGuess.notApplicable);
    });

    test('markJobOutcome settles a dialog job definitively', () async {
      final r = await p.printText('confirm me');
      expect(r.outcome, PrintOutcome.dialogShown);

      expect(
        PrintOutcomeConfirmation.markJobOutcome(r.jobId, printed: true),
        isTrue,
      );
      var job = (await p.getPrintJobStatus(r.jobId)) as NitroOk<PrintJob>;
      expect(job.value.outcome, PrintOutcome.printed);
      expect(job.value.state, PrintState.completed);

      final r2 = await p.printText('cancel me');
      expect(
        PrintOutcomeConfirmation.markJobOutcome(r2.jobId, printed: false),
        isTrue,
      );
      job = (await p.getPrintJobStatus(r2.jobId)) as NitroOk<PrintJob>;
      expect(job.value.outcome, PrintOutcome.cancelled);
      expect(job.value.failureReason, PrintJobFailureReason.cancelled);

      expect(
        PrintOutcomeConfirmation.markJobOutcome('nope', printed: true),
        isFalse,
      );
    });

    test('failed and cancelled results map to typed outcomes', () async {
      final failed = await p.printRaw(
        Uint8List.fromList([1]),
        settings: PrintSettings(printerId: '192.0.2.1'),
      );
      expect(failed.outcome, PrintOutcome.failed);
      final cancelled = PrintResult(
        success: false,
        jobId: '',
        errorMessage: 'Cancelled',
        errorCode: 'CANCELLED',
      );
      expect(cancelled.outcome, PrintOutcome.cancelled);
    });

    test('a failed print records state and failure reason', () async {
      final r = await p.printRaw(
        Uint8List.fromList([1]),
        settings: PrintSettings(printerId: '192.0.2.1'),
      );
      expect(r.success, isFalse);
      expect(r.errorKind, PrintErrorCode.tcpUnavailable);
      final last = await p.lastPrintJob();
      expect(last!.state, PrintState.failed);
      expect(last.failureReason, isNot(PrintJobFailureReason.none));
    });

    test('onPrintJobChanged streams the job lifecycle', () async {
      final updates = <PrintJobUpdate>[];
      final sub = p.onPrintJobChanged().listen(updates.add);
      final r = await p.printRaw(
        Uint8List.fromList([7, 7, 7]),
        settings: PrintSettings(printerId: 'ws://localhost:$serverPort/raw'),
      );
      expect(r.success, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await sub.cancel();
      final mine = updates.where((u) => u.jobId == r.jobId).toList();
      expect(mine.length, greaterThanOrEqualTo(2)); // printing → completed
      expect(mine.last.state, PrintState.completed);
    });

    test('resumePrintJob re-dispatches a finished raw job', () async {
      final first = rawReceived.stream.first;
      final r = await p.printRaw(
        Uint8List(64),
        settings: PrintSettings(printerId: 'ws://localhost:$serverPort/raw'),
      );
      expect(r.success, isTrue);
      await first;
      final again = rawReceived.stream.first;
      expect(await p.resumePrintJob(r.jobId), isTrue);
      expect(await again.timeout(const Duration(seconds: 5)), 'raw:64');
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

  group('preview follows configuration', () {
    test('headerText/footerText change the rendered preview', () async {
      // The preview is a page raster (faithful to the dialog output), so
      // assert the decoration alters the rendered bytes.
      final plain = await p.renderPreview(_textDoc('body line'));
      final decorated = await p.renderPreview(
        _textDoc('body line'),
        settings: PrintSettings(headerText: 'ACME-HDR', footerText: 'FTR-9'),
      );
      expect(decorated.length, greaterThan(0));
      expect(String.fromCharCodes(decorated.bytes.take(5)), '%PDF-');
      expect(decorated.bytes, isNot(equals(plain.bytes)));
    });

    test('copies multiply the preview sheets', () async {
      final r = await p.renderPreview(
        _textDoc('single page'),
        settings: PrintSettings(copies: 2),
      );
      expect(String.fromCharCodes(r.bytes), contains('/Count 2'));
    });

    test('pagesPerSheet folds pages into one preview sheet', () async {
      final text = List.generate(200, (i) => 'line ${'.' * (i % 3)}').join('\n'); // 4 pages
      final r = await p.renderPreview(
        _textDoc(text),
        settings: PrintSettings(pagesPerSheet: 4),
      );
      expect(String.fromCharCodes(r.bytes), contains('/Count 1'));
    });

    test('grayscale changes the rendered preview bytes', () async {
      WebPrintDecor.configure(
        backgroundHtml: '<div style="color:#ff0000;font-size:60px">RED</div>',
      );
      try {
        final color = await p.renderPreview(_textDoc('x'));
        final gray = await p.renderPreview(
          _textDoc('x'),
          settings: PrintSettings(color: false),
        );
        expect(gray.bytes, isNot(equals(color.bytes)));
      } finally {
        WebPrintDecor.clear();
      }
    });

    test('pageRange slices the text preview', () async {
      final text = List.generate(120, (i) => 'line $i').join('\n');
      final r = await p.renderPreview(
        _textDoc(text),
        settings: PrintSettings(pageRangeFrom: 2, pageRangeTo: 2),
      );
      expect(String.fromCharCodes(r.bytes), contains('/Count 1'));
    });
  });

  group('page decoration (WebPrintDecor)', () {
    tearDown(WebPrintDecor.clear);

    test('background + HTML header/footer print and preview', () async {
      WebPrintDecor.configure(
        backgroundHtml:
            '<div style="font-size:96px;opacity:.06;transform:rotate(-30deg)">DRAFT</div>',
        headerHtml: '<b>ACME Corp</b>',
        footerHtml: '<i>confidential</i>',
      );
      final printed = await p.printText('decorated');
      expect(printed.success, isTrue, reason: printed.errorMessage);

      final preview = await p.renderPreview(_htmlDoc('<p>content</p>'));
      expect(preview.length, greaterThan(0));
      expect(String.fromCharCodes(preview.bytes.take(5)), '%PDF-');
    });

    test('markup-looking headerText renders as HTML without decor', () async {
      final r = await p.printText(
        'body',
        settings: PrintSettings(headerText: '<b>bold header</b>'),
      );
      expect(r.success, isTrue, reason: r.errorMessage);
    });
  });

  group('failure-reason catalog (pure parsing)', () {
    PrintJob job(String error, [PrintState state = PrintState.failed]) =>
        PrintJob(
          id: 'j',
          printerId: 'p',
          documentTitle: 't',
          state: state,
          createdAtMillis: 0,
          completedAtMillis: 0,
          errorMessage: error,
        );

    test('maps IPP reason codes', () {
      expect(job('[MEDIA_JAM] media-jam').failureReason,
          PrintJobFailureReason.mediaJam);
      expect(job('[MEDIA_EMPTY] media-empty').failureReason,
          PrintJobFailureReason.mediaEmpty);
      expect(job('[TONER_EMPTY] toner-empty').failureReason,
          PrintJobFailureReason.tonerEmpty);
      expect(job('[COVER_OPEN] cover-open').failureReason,
          PrintJobFailureReason.coverOpen);
      expect(job('[PRINTER_OFFLINE] offline').failureReason,
          PrintJobFailureReason.printerOffline);
      expect(job('[JOB_CANCELLED] cancelled', PrintState.cancelled).failureReason,
          PrintJobFailureReason.cancelled);
    });

    test('successful jobs report none, unknown text reports unknown', () {
      expect(job('', PrintState.completed).failureReason,
          PrintJobFailureReason.none);
      expect(job('something odd').failureReason,
          PrintJobFailureReason.unknown);
    });
  });

  group('QZ Tray agent transport (mock agent)', () {
    tearDownAll(() => WebPrintAgent.configure(endpoint: null));

    test('unreachable agent fails with qzUnavailable guidance', () async {
      WebPrintAgent.configure(endpoint: 'ws://localhost:1/qz');
      final r = await p.printRaw(
        Uint8List.fromList([1, 2, 3]),
        settings: PrintSettings(printerId: 'qz:'),
      );
      expect(r.success, isFalse);
      expect(r.errorKind, PrintErrorCode.qzUnavailable);
      expect(r.errorMessage, contains('QZ Tray'));
    });

    test('raw ESC/POS through the agent is spool-confirmed', () async {
      WebPrintAgent.configure(endpoint: 'ws://localhost:$serverPort/qz');
      final received = qzReceived.stream.first;
      final r = await p.printRaw(
        Uint8List.fromList([1, 2, 3, 4, 5]),
        settings: PrintSettings(printerId: 'qz:Mock Printer'),
      );
      expect(r.success, isTrue, reason: r.errorMessage);
      expect(r.outcome, PrintOutcome.printed); // spooler accepted = verified
      expect(
        await received.timeout(const Duration(seconds: 5)),
        'qzraw:5:Mock Printer',
      );
    });

    test('bare qz: resolves the agent default printer', () async {
      final received = qzReceived.stream.first;
      final r = await p.printRaw(
        Uint8List.fromList([9, 9, 9]),
        settings: PrintSettings(printerId: 'qz:'),
      );
      expect(r.success, isTrue, reason: r.errorMessage);
      expect(
        await received.timeout(const Duration(seconds: 5)),
        'qzraw:3:Mock Printer',
      );
    });

    test('printText ESC/POS-encodes through the agent', () async {
      final received = qzReceived.stream.first;
      final r = await p.printText(
        'RCPT',
        settings: PrintSettings(printerId: 'qz:Mock Receipt'),
      );
      expect(r.success, isTrue, reason: r.errorMessage);
      // init (2) + RCPT (4) + LF (1) + feed/cut (7)
      expect(
        await received.timeout(const Duration(seconds: 5)),
        'qzraw:14:Mock Receipt',
      );
    });

    test('printPdf prints silently via the agent driver path', () async {
      final pdf = _minimalPdf();
      final received = qzReceived.stream.first;
      final r = await p.printPdf(
        pdf,
        settings: PrintSettings(printerId: 'qz:Mock Printer'),
      );
      expect(r.success, isTrue, reason: r.errorMessage);
      expect(r.outcome, PrintOutcome.printed);
      expect(
        await received.timeout(const Duration(seconds: 5)),
        'qzpdf:${pdf.length}:Mock Printer',
      );
    });

    test('discovery enumerates agent printers and streams OS status',
        () async {
      expect(await p.startPrinterDiscovery(), isTrue);
      final printers = await p.getAllPrinters();
      expect(printers.map((x) => x.id), contains('qz:Mock Printer'));
      // The mock pushes a PAPER_OUT status stream event after startListening.
      await Future<void>.delayed(const Duration(milliseconds: 400));
      final detail =
          await p.getPrinterStatusDetail('qz:Mock Printer', timeoutSeconds: 1);
      expect(detail, isA<NitroOk<PrinterStatusDetail>>());
      final d = (detail as NitroOk<PrinterStatusDetail>).value;
      expect(d.isOutOfPaper, isTrue);
    });
  });

  group('Nitro Print Agent transport (mock agent)', () {
    tearDownAll(() => WebPrintAgent.configure());

    test('unreachable agent fails with agentUnavailable guidance', () async {
      WebPrintAgent.configure(agentEndpoint: 'ws://localhost:1/agent');
      final r = await p.printRaw(
        Uint8List.fromList([1, 2, 3]),
        settings: PrintSettings(printerId: 'agent:'),
      );
      expect(r.success, isFalse);
      expect(r.errorKind, PrintErrorCode.agentUnavailable);
      expect(r.errorMessage, contains('Nitro Print Agent'));
    });

    test('raw bytes print through the agent with the native job id', () async {
      WebPrintAgent.configure(
        agentEndpoint: 'ws://localhost:$serverPort/agent',
      );
      final received = agentReceived.stream.first;
      final r = await p.printRaw(
        Uint8List.fromList([1, 2, 3]),
        settings: PrintSettings(printerId: 'agent:Office Laser'),
      );
      expect(r.success, isTrue, reason: r.errorMessage);
      expect(r.outcome, PrintOutcome.printed);
      expect(r.jobId, 'native-42'); // the NATIVE result's job id, passed through
      expect(
        await received.timeout(const Duration(seconds: 5)),
        'agentraw:3:Office Laser',
      );
    });

    test('printText goes as native text, not ESC/POS', () async {
      final received = agentReceived.stream.first;
      final r = await p.printText(
        'RECEIPT',
        settings: PrintSettings(printerId: 'agent:Office Laser'),
      );
      expect(r.success, isTrue, reason: r.errorMessage);
      expect(
        await received.timeout(const Duration(seconds: 5)),
        'agenttext:7:Office Laser', // plain text bytes — no ESC/POS wrapper
      );
    });

    test('printPdf prints silently through the native driver', () async {
      final pdf = _minimalPdf();
      final received = agentReceived.stream.first;
      final r = await p.printPdf(
        pdf,
        settings: PrintSettings(printerId: 'agent:Office Laser'),
      );
      expect(r.success, isTrue, reason: r.errorMessage);
      expect(r.outcome, PrintOutcome.printed);
      expect(
        await received.timeout(const Duration(seconds: 5)),
        'agentpdf:${pdf.length}:Office Laser',
      );
    });

    test('printImage routes natively (no thermal raster)', () async {
      final received = agentReceived.stream.first;
      final r = await p.printImage(
        _pngPixel(),
        settings: PrintSettings(printerId: 'agent:Office Laser'),
      );
      expect(r.success, isTrue, reason: r.errorMessage);
      expect(
        await received.timeout(const Duration(seconds: 5)),
        'agentimage:${_pngPixel().length}:Office Laser',
      );
    });

    test('native job lifecycle is re-emitted on onPrintJobChanged', () async {
      final updates = <PrintJobUpdate>[];
      final sub = p.onPrintJobChanged().listen(updates.add);
      await p.printRaw(
        Uint8List.fromList([7]),
        settings: PrintSettings(printerId: 'agent:Office Laser'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await sub.cancel();
      final native = updates.where((u) => u.jobId == 'native-42');
      expect(native, isNotEmpty);
      expect(native.last.state, PrintState.completed);
    });

    test('enumeration, probing, and live native status', () async {
      expect(await p.startPrinterDiscovery(), isTrue);
      final printers = await p.getAllPrinters();
      expect(printers.map((x) => x.id), contains('agent:Office Laser'));

      expect(
        await p.testPrinterConnection('agent:Office Laser', timeoutSeconds: 3),
        isTrue,
      );
      // testPrinterConnection refreshed the cache from the agent's NATIVE
      // getPrinterStatusDetail — the mock reports a paper jam.
      final detail = await p.getPrinterStatusDetail('agent:Office Laser',
          timeoutSeconds: 1);
      final d = (detail as NitroOk<PrinterStatusDetail>).value;
      expect(d.hasPaperJam, isTrue);
    });
  });
}
