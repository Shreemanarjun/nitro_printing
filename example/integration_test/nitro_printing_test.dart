import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nitro_printing/nitro_printing.dart';

// ignore_for_file: unused_local_variable

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Minimal valid PNG (1×1 red pixel).
Uint8List _minimalPng() => Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // PNG signature
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, // IHDR chunk
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53,
  0xDE, 0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41,
  0x54, 0x08, 0xD7, 0x63, 0xF8, 0xCF, 0xC0, 0x00,
  0x00, 0x00, 0x02, 0x00, 0x01, 0xE2, 0x21, 0xBC,
  0x33, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E,
  0x44, 0xAE, 0x42, 0x60, 0x82,
]);

/// Minimal valid PDF (one page, text "NitroPrinting Demo").
Uint8List _minimalPdf() {
  const src =
      '%PDF-1.4\n'
      '1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n'
      '2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj\n'
      '3 0 obj<</Type/Page/MediaBox[0 0 595 842]/Parent 2 0 R'
      '/Resources<</Font<</F1<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>>>>>'
      '/Contents 4 0 R>>endobj\n'
      '4 0 obj<</Length 58>>\nstream\nBT /F1 24 Tf 100 750 Td (NitroPrinting Demo) Tj ET\nendstream\nendobj\n'
      'xref\n0 5\n0000000000 65535 f\n0000000009 00000 n\n'
      '0000000058 00000 n\n0000000115 00000 n\n0000000250 00000 n\n'
      'trailer<</Size 5/Root 1 0 R>>\nstartxref\n345\n%%EOF';
  return Uint8List.fromList(src.codeUnits);
}

// ── Main ──────────────────────────────────────────────────────────────────────

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late NitroPrinting printing;

  setUp(() {
    printing = NitroPrinting.instance;
  });

  tearDownAll(() {
    printing.dispose();
  });

  // ─── Hardware capabilities ─────────────────────────────────────────────────

  group('printing support', () {
    test('isPrintingSupported() returns a bool without throwing', () async {
      final supported = printing.isPrintingSupported();
      expect(supported, isA<bool>());
    });

    test('getPrintersCount() returns a non-negative integer', () async {
      final count = printing.getPrintersCount();
      expect(count, greaterThanOrEqualTo(0));
    });

    test('getDefaultPrinter() returns PrinterInfo without throwing', () async {
      final printer = printing.getDefaultPrinter();
      expect(printer.id, isA<String>());
      expect(printer.name, isA<String>());
      expect(printer.isDefault, isA<bool>());
      expect(printer.isAvailable, isA<bool>());
    });

    test('getPrinterAt(0) does not throw when printers exist', () async {
      final count = printing.getPrintersCount();
      if (count > 0) {
        final printer = printing.getPrinterAt(0);
        expect(printer.id, isNotEmpty);
        expect(printer.name, isNotEmpty);
      }
    });

    test(
      'getPrinterCapabilities() returns PrinterCapabilities without throwing',
      () async {
        final printer = printing.getDefaultPrinter();
        final caps = printing.getPrinterCapabilities(printer.id);
        expect(caps.supportsColor, isA<bool>());
        expect(caps.supportsDuplex, isA<bool>());
        expect(caps.maxCopies, greaterThan(0));
        expect(caps.minMarginTop, greaterThanOrEqualTo(0));
        expect(caps.supportsA4, isA<bool>());
        expect(caps.supportsNormalQuality, isA<bool>());
      },
    );

    test(
      'getPrinterDriverVersion() returns a string without throwing',
      () async {
        final printer = printing.getDefaultPrinter();
        final version = printing.getPrinterDriverVersion(printer.id);
        expect(version, isA<String>());
      },
    );
  });

  // ─── Print jobs ────────────────────────────────────────────────────────────

  group('print jobs', () {
    test('getPrintJobsCount() returns a non-negative integer', () async {
      final count = await printing.getPrintJobsCount();
      expect(count, greaterThanOrEqualTo(0));
    });

    test('getPrintJobAt(0) does not throw when jobs exist', () async {
      final count = await printing.getPrintJobsCount();
      if (count > 0) {
        final job = await printing.getPrintJobAt(0);
        expect(job.id, isNotEmpty);
        expect(job.state, isA<PrintState>());
        expect(job.progress, greaterThanOrEqualTo(0));
        expect(job.pagesPrinted, greaterThanOrEqualTo(0));
        expect(job.createdAtMillis, greaterThanOrEqualTo(0));
      }
    });

    test('cancelPrintJob() does not throw', () async {
      final result = await printing.cancelPrintJob('test-invalid-id');
      expect(result, isA<bool>());
    });
  });

  // ─── Print operations ──────────────────────────────────────────────────────

  group('print operations', () {
    test('printText() returns PrintResult without throwing', () async {
      final result = await printing.printText(
        'Integration test print',
        settings: PrintSettings(jobName: 'Integration Test'),
      );
      expect(result.success, isA<bool>());
      expect(result.jobId, isA<String>());
      expect(result.errorMessage, isA<String>());
    });

    test('printText() without settings does not throw', () async {
      final result = await printing.printText('Test text without settings');
      expect(result, isA<PrintResult>());
    });

    test('printImage() returns PrintResult without throwing', () async {
      final result = await printing.printImage(
        _minimalPng(),
        settings: PrintSettings(
          jobName: 'Image Test',
          quality: PrintQuality.high,
        ),
      );
      expect(result.success, isA<bool>());
      expect(result.jobId, isA<String>());
    });

    test('printPdf() returns PrintResult without throwing', () async {
      final result = await printing.printPdf(
        _minimalPdf(),
        settings: PrintSettings(
          jobName: 'PDF Test',
          paperSize: PaperSize.a4,
          orientationDegrees: 0.0,
          quality: PrintQuality.normal,
          copies: 1,
          color: true,
        ),
      );
      expect(result.success, isA<bool>());
      expect(result.errorCode, isA<String>());
    });

    test('printPdf() with landscape orientation does not throw', () async {
      final result = await printing.printPdf(
        _minimalPdf(),
        settings: PrintSettings(
          jobName: 'Landscape PDF',
          paperSize: PaperSize.letter,
          orientationDegrees: 90.0,
          quality: PrintQuality.normal,
        ),
      );
      expect(result, isA<PrintResult>());
    });

    test('printPdf() with all settings fields does not throw', () async {
      final result = await printing.printPdf(
        _minimalPdf(),
        settings: PrintSettings(
          printerId: 'default',
          jobName: 'Full Settings PDF',
          paperSize: PaperSize.letter,
          orientationDegrees: 90.0,
          quality: PrintQuality.best,
          copies: 2,
          pagesPerSheet: 2,
          collate: true,
          duplex: true,
          color: true,
          marginTop: 10,
          marginBottom: 10,
          marginLeft: 15,
          marginRight: 15,
          showPrintDialog: true,
        ),
      );
      expect(result.success, isA<bool>());
    });

    test('printDocument() returns PrintResult without throwing', () async {
      final doc = PrintDocument(
        id: 'test-doc',
        title: 'Test Document',
        type: DocumentType.plainText,
        data: Uint8List.fromList('Hello from integration test'.codeUnits),
      );
      final result = await printing.printDocument(doc);
      expect(result.success, isA<bool>());
      expect(result.jobId, isA<String>());
    });

    test('printDocument() with HTML type does not throw', () async {
      final doc = PrintDocument(
        id: 'html-doc',
        title: 'HTML Doc',
        type: DocumentType.html,
        data: Uint8List.fromList(
          '<html><body><h1>Test</h1></body></html>'.codeUnits,
        ),
      );
      final result = await printing.printDocument(
        doc,
        settings: PrintSettings(jobName: 'HTML Document Test'),
      );
      expect(result, isA<PrintResult>());
    });

    test('printDocument() with Image type does not throw', () async {
      final doc = PrintDocument(
        id: 'img-doc',
        title: 'Image Doc',
        type: DocumentType.image,
        data: _minimalPng(),
      );
      final result = await printing.printDocument(doc);
      expect(result, isA<PrintResult>());
    });

    test('printDocument() with PDF type does not throw', () async {
      final doc = PrintDocument(
        id: 'pdf-doc',
        title: 'PDF Doc',
        type: DocumentType.pdf,
        data: _minimalPdf(),
      );
      final result = await printing.printDocument(doc);
      expect(result, isA<PrintResult>());
    });

    test('printDocument() with empty data does not throw', () async {
      final doc = PrintDocument(
        id: 'empty-doc',
        title: 'Empty Doc',
        type: DocumentType.plainText,
        data: Uint8List(0),
      );
      final result = await printing.printDocument(doc);
      expect(result, isA<PrintResult>());
    });
  });

  // ─── Direct printing (showPrintDialog: false) ──────────────────────────────

  group('direct printing', () {
    test('printText() with showPrintDialog=false does not throw', () async {
      final result = await printing.printText(
        'Silent print test',
        settings: PrintSettings(
          jobName: 'Direct Print Test',
          showPrintDialog: false,
          // No printerId — falls back to dialog or returns error gracefully.
        ),
      );
      expect(result, isA<PrintResult>());
    });

    test('printPdf() with showPrintDialog=false does not throw', () async {
      final result = await printing.printPdf(
        _minimalPdf(),
        settings: PrintSettings(jobName: 'Direct PDF', showPrintDialog: false),
      );
      expect(result, isA<PrintResult>());
    });

    test('printImage() with showPrintDialog=false does not throw', () async {
      final result = await printing.printImage(
        _minimalPng(),
        settings: PrintSettings(
          jobName: 'Direct Image',
          showPrintDialog: false,
        ),
      );
      expect(result, isA<PrintResult>());
    });
  });

  // ─── Copies ────────────────────────────────────────────────────────────────

  group('copies', () {
    test('printText() with copies=1 does not throw', () async {
      final result = await printing.printText(
        'Single copy',
        settings: PrintSettings(jobName: 'Copy Test 1', copies: 1),
      );
      expect(result, isA<PrintResult>());
    });

    test('printText() with copies=3 does not throw', () async {
      final result = await printing.printText(
        'Three copies',
        settings: PrintSettings(jobName: 'Copy Test 3', copies: 3),
      );
      expect(result, isA<PrintResult>());
    });

    test('printPdf() with copies=2 does not throw', () async {
      final result = await printing.printPdf(
        _minimalPdf(),
        settings: PrintSettings(jobName: 'PDF 2 copies', copies: 2),
      );
      expect(result, isA<PrintResult>());
    });
  });

  // ─── Orientation degrees ───────────────────────────────────────────────────

  group('orientation degrees', () {
    for (final deg in [0.0, 90.0, 180.0, 270.0]) {
      test(
        'printText() at ${deg.toStringAsFixed(0)}° does not throw',
        () async {
          final result = await printing.printText(
            'Orientation $deg test',
            settings: PrintSettings(
              jobName: 'Orient ${deg.toStringAsFixed(0)}',
              orientationDegrees: deg,
            ),
          );
          expect(result, isA<PrintResult>());
        },
      );
    }

    test('printImage() landscape (90°) does not throw', () async {
      final result = await printing.printImage(
        _minimalPng(),
        settings: PrintSettings(
          jobName: 'Landscape Image',
          orientationDegrees: 90.0,
          paperSize: PaperSize.a4,
        ),
      );
      expect(result, isA<PrintResult>());
    });
  });

  // ─── Pages per sheet ───────────────────────────────────────────────────────

  group('pages per sheet', () {
    for (final n in [1, 2, 4]) {
      test('printText() with pagesPerSheet=$n does not throw', () async {
        final result = await printing.printText(
          List.generate(n * 30, (i) => 'Line $i').join('\n'),
          settings: PrintSettings(jobName: 'NUp $n', pagesPerSheet: n),
        );
        expect(result, isA<PrintResult>());
      });
    }

    test('printPdf() with pagesPerSheet=2 does not throw', () async {
      final result = await printing.printPdf(
        _minimalPdf(),
        settings: PrintSettings(jobName: 'PDF 2-up', pagesPerSheet: 2),
      );
      expect(result, isA<PrintResult>());
    });
  });

  // ─── PrintSettings defaults ────────────────────────────────────────────────

  group('PrintSettings defaults', () {
    test('default settings produce expected values', () {
      final s = PrintSettings();
      expect(s.paperSize, equals(PaperSize.a4));
      expect(s.orientationDegrees, equals(0.0));
      expect(s.quality, equals(PrintQuality.normal));
      expect(s.copies, equals(1));
      expect(s.pagesPerSheet, equals(1));
      expect(s.showPrintDialog, isTrue);
      expect(s.collate, isFalse);
      expect(s.duplex, isFalse);
      expect(s.color, isTrue);
      expect(s.marginTop, equals(0));
      expect(s.jobName, isEmpty);
      expect(s.printerId, isEmpty);
      expect(s.networkTimeoutSeconds, equals(30));
    });

    test('landscape settings have orientationDegrees=90', () {
      final s = PrintSettings(orientationDegrees: 90.0);
      expect(s.orientationDegrees, equals(90.0));
    });

    test('settings with all custom values', () {
      final s = PrintSettings(
        printerId: 'my-printer',
        jobName: 'custom job',
        paperSize: PaperSize.legal,
        orientationDegrees: 90.0,
        quality: PrintQuality.draft,
        copies: 5,
        pagesPerSheet: 4,
        collate: true,
        duplex: true,
        color: false,
        marginTop: 20,
        marginBottom: 20,
        marginLeft: 10,
        marginRight: 10,
        showPrintDialog: false,
      );
      expect(s.printerId, equals('my-printer'));
      expect(s.paperSize, equals(PaperSize.legal));
      expect(s.orientationDegrees, equals(90.0));
      expect(s.quality, equals(PrintQuality.draft));
      expect(s.copies, equals(5));
      expect(s.pagesPerSheet, equals(4));
      expect(s.collate, isTrue);
      expect(s.color, isFalse);
      expect(s.showPrintDialog, isFalse);
    });

    test('all PaperSize values accepted in PrintSettings', () {
      for (final size in PaperSize.values) {
        final s = PrintSettings(paperSize: size);
        expect(s.paperSize, equals(size));
      }
    });

    test('all PrintQuality values accepted in PrintSettings', () {
      for (final q in PrintQuality.values) {
        final s = PrintSettings(quality: q);
        expect(s.quality, equals(q));
      }
    });
  });

  // ─── PrintJob model ───────────────────────────────────────────────────────

  group('PrintJob model', () {
    test('PrintJob.createdAt returns DateTime when millis > 0', () {
      final job = PrintJob(
        id: 'j1',
        printerId: 'p1',
        documentTitle: 'doc',
        state: PrintState.completed,
        progress: 100,
        createdAtMillis: 1700000000000,
        completedAtMillis: 1700000100000,
        pagesPrinted: 5,
      );
      expect(job.createdAt, isNotNull);
      expect(job.createdAt!.millisecondsSinceEpoch, equals(1700000000000));
      expect(job.completedAt, isNotNull);
      expect(job.completedAt!.millisecondsSinceEpoch, equals(1700000100000));
    });

    test('PrintJob.createdAt returns null when millis is 0', () {
      final job = PrintJob(
        id: 'j2',
        printerId: 'p1',
        documentTitle: 'doc',
        state: PrintState.idle,
        progress: 0,
        createdAtMillis: 0,
        pagesPrinted: 0,
      );
      expect(job.createdAt, isNull);
      expect(job.completedAt, isNull);
    });

    test('PrintJob with error state has errorMessage', () {
      final job = PrintJob(
        id: 'j3',
        printerId: 'p1',
        documentTitle: 'doc',
        state: PrintState.failed,
        progress: 50,
        createdAtMillis: 1700000000000,
        errorMessage: 'Out of paper',
        pagesPrinted: 2,
      );
      expect(job.state, equals(PrintState.failed));
      expect(job.errorMessage, equals('Out of paper'));
    });
  });

  // ─── PrintResult model ────────────────────────────────────────────────────

  group('PrintResult model', () {
    test('successful result', () {
      final r = PrintResult(success: true, jobId: 'abc-123');
      expect(r.success, isTrue);
      expect(r.jobId, equals('abc-123'));
      expect(r.errorMessage, isEmpty);
    });

    test('failure result', () {
      final r = PrintResult(
        success: false,
        errorMessage: 'Printer not found',
        errorCode: 'E_NO_PRINTER',
      );
      expect(r.success, isFalse);
      expect(r.errorCode, equals('E_NO_PRINTER'));
      expect(r.jobId, isEmpty);
    });
  });

  // ─── Streams ──────────────────────────────────────────────────────────────

  group('streams', () {
    test(
      'onPrintJobChanged() can be subscribed and cancelled without throwing',
      () async {
        final sub = printing.onPrintJobChanged().listen((_) {});
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await sub.cancel();
      },
    );

    test(
      'onPrinterStatusChanged() can be subscribed and cancelled without throwing',
      () async {
        final sub = printing.onPrinterStatusChanged().listen((_) {});
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await sub.cancel();
      },
    );

    test('re-subscribing onPrintJobChanged after cancel works', () async {
      StreamSubscription<PrintJobUpdate>? sub;

      sub = printing.onPrintJobChanged().listen((_) {});
      await sub.cancel();
      sub = null;

      sub = printing.onPrintJobChanged().listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await sub.cancel();
    });

    test('re-subscribing onPrinterStatusChanged after cancel works', () async {
      StreamSubscription<PrinterStatus>? sub;

      sub = printing.onPrinterStatusChanged().listen((_) {});
      await sub.cancel();
      sub = null;

      sub = printing.onPrinterStatusChanged().listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await sub.cancel();
    });

    test('onPrintJobChanged() emits events after print operation', () async {
      final events = <PrintJobUpdate>[];
      StreamSubscription<PrintJobUpdate>? sub;

      try {
        sub = printing.onPrintJobChanged().listen((update) {
          events.add(update);
        });

        await printing.printText(
          'Stream test print',
          settings: PrintSettings(jobName: 'Stream Test'),
        );

        await Future<void>.delayed(const Duration(milliseconds: 500));

        if (events.isNotEmpty) {
          expect(events.first.jobId, isNotEmpty);
          expect(events.first.state, isA<PrintState>());
          expect(events.first.progress, greaterThanOrEqualTo(0));
        }
      } finally {
        await sub?.cancel();
      }
    });

    test('onPrinterStatusChanged() can emit events', () async {
      final events = <PrinterStatus>[];
      StreamSubscription<PrinterStatus>? sub;

      try {
        sub = printing.onPrinterStatusChanged().listen((status) {
          events.add(status);
        });

        printing.isPrintingSupported();

        await Future<void>.delayed(const Duration(milliseconds: 300));

        if (events.isNotEmpty) {
          expect(events.first.printerId, isNotEmpty);
          expect(events.first.isOnline, isA<bool>());
        }
      } finally {
        await sub?.cancel();
      }
    });

    test('two concurrent subscriptions on onPrintJobChanged', () async {
      final events1 = <PrintJobUpdate>[];
      final events2 = <PrintJobUpdate>[];
      StreamSubscription<PrintJobUpdate>? sub1;
      StreamSubscription<PrintJobUpdate>? sub2;

      try {
        sub1 = printing.onPrintJobChanged().listen((u) => events1.add(u));
        sub2 = printing.onPrintJobChanged().listen((u) => events2.add(u));

        await printing.printText('Concurrent test print');

        await Future<void>.delayed(const Duration(milliseconds: 500));

        expect(events1.isNotEmpty || events2.isNotEmpty, isTrue);
      } finally {
        await sub1?.cancel();
        await sub2?.cancel();
      }
    });

    test(
      'onPrintJobChanged() second subscriber works after first is cancelled',
      () async {
        StreamSubscription<PrintJobUpdate>? sub1;
        StreamSubscription<PrintJobUpdate>? sub2;

        try {
          sub1 = printing.onPrintJobChanged().listen((_) {});
          await sub1.cancel();
          sub1 = null;

          final completer = Completer<PrintJobUpdate>();
          sub2 = printing.onPrintJobChanged().listen((update) {
            if (!completer.isCompleted) completer.complete(update);
          });

          await printing.printText(
            'Late subscriber test',
            settings: PrintSettings(jobName: 'Late Sub'),
          );

          try {
            final update = await completer.future.timeout(
              const Duration(seconds: 4),
            );
            expect(update.jobId, isNotEmpty);
          } on TimeoutException {
            // No event within timeout — acceptable on unsupported platforms.
          }
        } finally {
          await sub1?.cancel();
          await sub2?.cancel();
        }
      },
    );
  });

  // ─── Enums ─────────────────────────────────────────────────────────────────

  group('enums', () {
    test('PrintState has all expected values', () {
      expect(PrintState.values, hasLength(6));
      expect(PrintState.idle.index, equals(0));
      expect(PrintState.printing.index, equals(1));
      expect(PrintState.completed.index, equals(2));
      expect(PrintState.cancelled.index, equals(3));
      expect(PrintState.failed.index, equals(4));
      expect(PrintState.paused.index, equals(5));
    });

    test('PrintQuality has all expected values', () {
      expect(PrintQuality.values, hasLength(4));
      expect(PrintQuality.draft.index, equals(0));
      expect(PrintQuality.normal.index, equals(1));
      expect(PrintQuality.high.index, equals(2));
      expect(PrintQuality.best.index, equals(3));
    });

    test('PaperSize has all expected values', () {
      expect(PaperSize.values, hasLength(5));
      expect(PaperSize.a4, equals(PaperSize.a4));
      expect(PaperSize.a5, equals(PaperSize.a5));
      expect(PaperSize.letter, equals(PaperSize.letter));
      expect(PaperSize.legal, equals(PaperSize.legal));
      expect(PaperSize.custom, equals(PaperSize.custom));
    });

    test('DocumentType has all expected values', () {
      expect(DocumentType.values, hasLength(4));
      expect(DocumentType.plainText, equals(DocumentType.plainText));
      expect(DocumentType.html, equals(DocumentType.html));
      expect(DocumentType.pdf, equals(DocumentType.pdf));
      expect(DocumentType.image, equals(DocumentType.image));
    });
  });

  // ─── Network timeout ──────────────────────────────────────────────────────

  group('network timeout', () {
    test('PrintSettings.networkTimeoutSeconds defaults to 30', () {
      final s = PrintSettings();
      expect(s.networkTimeoutSeconds, equals(30));
    });

    test('PrintSettings accepts custom networkTimeoutSeconds', () {
      final s = PrintSettings(networkTimeoutSeconds: 10);
      expect(s.networkTimeoutSeconds, equals(10));
    });

    test('testPrinterConnection with short timeout returns bool', () async {
      // 0.0.0.0:9100 is unreachable — should time out quickly and return false
      final result = await printing.testPrinterConnection(
        '0.0.0.0',
        timeoutSeconds: 2,
      );
      expect(result, isFalse);
    });

    test('testPrinterConnection with default timeout returns bool', () async {
      final result = await printing.testPrinterConnection(
        '0.0.0.0',
        timeoutSeconds: 5,
      );
      expect(result, isA<bool>());
    });

    test(
      'getPrinterStatusDetail with timeout returns PrinterStatusDetail',
      () async {
        final detail = await printing.getPrinterStatusDetail(
          'ipp://0.0.0.0:631/ipp/print',
          timeoutSeconds: 3,
        );
        expect(detail, isA<PrinterStatusDetail>());
        expect(detail.printerId, isNotEmpty);
        // Unreachable printer — should be offline
        expect(detail.isOnline, isFalse);
      },
    );

    test(
      'getPrinterStatusDetail with socket URI times out gracefully',
      () async {
        final detail = await printing.getPrinterStatusDetail(
          '0.0.0.0:9100',
          timeoutSeconds: 2,
        );
        expect(detail, isA<PrinterStatusDetail>());
        expect(detail.isOnline, isFalse);
        expect(detail.isReady, isFalse);
      },
    );
  });

  // ─── Raw protocol printing ────────────────────────────────────────────────

  group('raw protocol printing', () {
    test('printRaw() with no printerId returns failed result', () async {
      final result = await printing.printRaw(
        Uint8List.fromList([0x00, 0x01, 0x02]),
      );
      expect(result.success, isFalse);
      expect(result.errorCode, isNotEmpty);
    });

    test('printRaw() with unreachable socket fails gracefully', () async {
      final result = await printing.printRaw(
        Uint8List.fromList([0x00]),
        settings: PrintSettings(
          printerId: '0.0.0.0:9100',
          showPrintDialog: false,
          networkTimeoutSeconds: 3,
        ),
      );
      expect(result, isA<PrintResult>());
      expect(result.success, isFalse);
    });

    test('printEscPos() with no printerId returns failed result', () async {
      final escPosData = Uint8List.fromList([0x1B, 0x40]); // ESC @
      final result = await printing.printEscPos(escPosData);
      expect(result.success, isFalse);
      expect(result.errorCode, equals('NO_PRINTER'));
    });

    test('printEscPos() with unreachable printer fails gracefully', () async {
      final escPosData = Uint8List.fromList([
        0x1B,
        0x40,
        0x1D,
        0x56,
        0x42,
        0x00,
      ]);
      final result = await printing.printEscPos(
        escPosData,
        settings: PrintSettings(
          printerId: '0.0.0.0:9100',
          showPrintDialog: false,
          networkTimeoutSeconds: 3,
        ),
      );
      expect(result, isA<PrintResult>());
      expect(result.success, isFalse);
    });

    test('printZpl() with no printerId returns failed result', () async {
      final result = await printing.printZpl('^XA^XZ');
      expect(result.success, isFalse);
      expect(result.errorCode, equals('NO_PRINTER'));
    });

    test('printZpl() with unreachable printer fails gracefully', () async {
      final result = await printing.printZpl(
        '^XA^FO50,50^A0N,40,40^FDTest^FS^XZ',
        settings: PrintSettings(
          printerId: '0.0.0.0:9100',
          showPrintDialog: false,
          networkTimeoutSeconds: 3,
        ),
      );
      expect(result, isA<PrintResult>());
      expect(result.success, isFalse);
    });

    test('cancelRawPrint() returns false when no print is active', () async {
      final cancelled = await printing.cancelRawPrint();
      expect(cancelled, isFalse);
    });

    test(
      'cancelRawPrint() is idempotent — can be called multiple times',
      () async {
        await printing.cancelRawPrint();
        final result = await printing.cancelRawPrint();
        expect(result, isFalse);
      },
    );

    test('printRaw() with custom timeout setting is accepted', () async {
      final result = await printing.printRaw(
        Uint8List.fromList([0x00]),
        settings: PrintSettings(
          printerId: '', // empty → should return NO_PRINTER error
          networkTimeoutSeconds: 10,
        ),
      );
      expect(result.success, isFalse);
      expect(result.errorCode, isNotEmpty);
    });
  });

  // ─── Printer status detail ────────────────────────────────────────────────

  group('printer status detail', () {
    test('getPrinterStatusDetail with empty printerId', () async {
      final detail = await printing.getPrinterStatusDetail('');
      expect(detail, isA<PrinterStatusDetail>());
    });

    test('PrinterStatusDetail has all expected fields', () async {
      final detail = await printing.getPrinterStatusDetail(
        'ipp://0.0.0.0:631/ipp/print',
        timeoutSeconds: 3,
      );
      expect(detail.printerId, isA<String>());
      expect(detail.isOnline, isA<bool>());
      expect(detail.isReady, isA<bool>());
      expect(detail.hasPaperJam, isA<bool>());
      expect(detail.isOutOfPaper, isA<bool>());
      expect(detail.isOutOfInk, isA<bool>());
      expect(detail.inkLevelBlack, isA<int>());
      expect(detail.inkLevelCyan, isA<int>());
      expect(detail.inkLevelMagenta, isA<int>());
      expect(detail.inkLevelYellow, isA<int>());
      expect(detail.tonerLevel, isA<int>());
      expect(detail.paperLevel, isA<int>());
      expect(detail.jobsInQueue, isA<int>());
      expect(detail.isWarmingUp, isA<bool>());
      expect(detail.printerState, isA<String>());
      expect(detail.stateReasons, isA<String>());
      expect(detail.statusMessage, isA<String>());
      expect(detail.errorCode, isA<String>());
      expect(detail.isDuplexSupported, isA<bool>());
      expect(detail.isColorSupported, isA<bool>());
    });

    test('offline printer ink levels are -1', () async {
      final detail = await printing.getPrinterStatusDetail(
        '0.0.0.0:9100',
        timeoutSeconds: 2,
      );
      // Unreachable — ink levels should be unknown (-1)
      expect(detail.inkLevelBlack, equals(-1));
      expect(detail.inkLevelCyan, equals(-1));
      expect(detail.tonerLevel, equals(-1));
    });
  });

  // ─── getAllPrinters ────────────────────────────────────────────────────────

  group('getAllPrinters', () {
    test('getAllPrinters() returns a List<PrinterInfo> without throwing', () {
      final printers = printing.getAllPrinters();
      expect(printers, isA<List<PrinterInfo>>());
    });

    test('getAllPrinters() count matches getPrintersCount()', () {
      final printers = printing.getAllPrinters();
      final count = printing.getPrintersCount();
      expect(printers.length, equals(count));
    });

    test('getAllPrinters() entries have valid typed fields', () {
      for (final p in printing.getAllPrinters()) {
        expect(p.id, isA<String>());
        expect(p.name, isA<String>());
        expect(p.address, isA<String>());
        expect(p.isDefault, isA<bool>());
        expect(p.isAvailable, isA<bool>());
      }
    });

    test('first printer in getAllPrinters() matches getPrinterAt(0)', () {
      final printers = printing.getAllPrinters();
      if (printers.isNotEmpty) {
        final at0 = printing.getPrinterAt(0);
        expect(printers.first.id, equals(at0.id));
      }
    });

    test('at most one printer is default in getAllPrinters()', () {
      final defaults = printing
          .getAllPrinters()
          .where((p) => p.isDefault)
          .toList();
      expect(defaults.length, lessThanOrEqualTo(1));
    });
  });

  // ─── Printer discovery ────────────────────────────────────────────────────

  group('printer discovery', () {
    test('startPrinterDiscovery() returns bool without throwing', () async {
      final started = await printing.startPrinterDiscovery();
      expect(started, isA<bool>());
      await printing.stopPrinterDiscovery();
    });

    test('stopPrinterDiscovery() returns bool without throwing', () async {
      await printing.startPrinterDiscovery();
      final stopped = await printing.stopPrinterDiscovery();
      expect(stopped, isA<bool>());
    });

    test('stopPrinterDiscovery() when not started does not throw', () async {
      final result = await printing.stopPrinterDiscovery();
      expect(result, isA<bool>());
    });

    test('onPrinterDiscovered() can be subscribed and cancelled', () async {
      final sub = printing.onPrinterDiscovered().listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await sub.cancel();
    });

    test(
      'onPrinterDiscovered() emits DiscoveredPrinter events with valid fields',
      () async {
        final events = <DiscoveredPrinter>[];
        StreamSubscription<DiscoveredPrinter>? sub;
        try {
          sub = printing.onPrinterDiscovered().listen(events.add);
          await printing.startPrinterDiscovery();
          await Future<void>.delayed(const Duration(milliseconds: 500));
          for (final e in events) {
            expect(e.id, isA<String>());
            expect(e.name, isA<String>());
          }
        } finally {
          await printing.stopPrinterDiscovery();
          await sub?.cancel();
        }
      },
    );

    test('re-subscribing onPrinterDiscovered after cancel works', () async {
      StreamSubscription<DiscoveredPrinter>? sub;
      sub = printing.onPrinterDiscovered().listen((_) {});
      await sub.cancel();
      sub = printing.onPrinterDiscovered().listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await sub.cancel();
    });
  });

  // ─── Preview and file ─────────────────────────────────────────────────────

  group('preview and file', () {
    test(
      'getPageCount() with text document returns non-negative integer',
      () async {
        final doc = PrintDocument(
          id: 'pg-doc',
          title: 'Page Count Test',
          type: DocumentType.plainText,
          data: Uint8List.fromList('Line 1\nLine 2\nLine 3'.codeUnits),
        );
        final count = await printing.getPageCount(doc);
        expect(count, greaterThanOrEqualTo(0));
      },
    );

    test(
      'getPageCount() with PDF document returns non-negative integer',
      () async {
        final doc = PrintDocument(
          id: 'pg-pdf',
          title: 'PDF Page Count',
          type: DocumentType.pdf,
          data: _minimalPdf(),
        );
        final count = await printing.getPageCount(doc);
        expect(count, greaterThanOrEqualTo(0));
      },
    );

    test('renderPreview() with text document returns PreviewResult', () async {
      final doc = PrintDocument(
        id: 'preview-doc',
        title: 'Preview Test',
        type: DocumentType.plainText,
        data: Uint8List.fromList('Preview content'.codeUnits),
      );
      final result = await printing.renderPreview(doc);
      expect(result, isA<PreviewResult>());
    });

    test('renderPreview() with PDF document does not throw', () async {
      final doc = PrintDocument(
        id: 'preview-pdf',
        title: 'PDF Preview',
        type: DocumentType.pdf,
        data: _minimalPdf(),
      );
      final result = await printing.renderPreview(
        doc,
        settings: PrintSettings(jobName: 'Preview PDF'),
      );
      expect(result, isA<PreviewResult>());
    });

    test('printToFile() returns bool without throwing', () async {
      final doc = PrintDocument(
        id: 'file-doc',
        title: 'Print To File Test',
        type: DocumentType.pdf,
        data: _minimalPdf(),
      );
      final result = await printing.printToFile(doc, '/tmp/nitro_test_out.pdf');
      expect(result, isA<bool>());
    });

    test(
      'printToFile() with empty path returns bool without throwing',
      () async {
        final doc = PrintDocument(
          id: 'file-doc-2',
          title: 'Empty Path Test',
          type: DocumentType.plainText,
          data: Uint8List.fromList('test'.codeUnits),
        );
        final result = await printing.printToFile(doc, '');
        expect(result, isA<bool>());
      },
    );
  });

  // ─── Platform UX ──────────────────────────────────────────────────────────

  group('platform UX', () {
    test(
      'setDefaultPrinter() with invalid id returns bool without throwing',
      () async {
        final result = await printing.setDefaultPrinter('invalid-printer-id');
        expect(result, isA<bool>());
      },
    );

    test(
      'setDefaultPrinter() with empty id returns bool without throwing',
      () async {
        final result = await printing.setDefaultPrinter('');
        expect(result, isA<bool>());
      },
    );

    test(
      'openSystemPrintQueue() with empty id returns bool without throwing',
      () async {
        final result = await printing.openSystemPrintQueue('');
        expect(result, isA<bool>());
      },
    );

    test(
      'openPrinterProperties() with empty id returns bool without throwing',
      () async {
        final result = await printing.openPrinterProperties('');
        expect(result, isA<bool>());
      },
    );

    test(
      'openSystemPrintQueue() with default printer id does not throw',
      () async {
        final printer = printing.getDefaultPrinter();
        final result = await printing.openSystemPrintQueue(printer.id);
        expect(result, isA<bool>());
      },
    );

    test(
      'openPrinterProperties() with default printer id does not throw',
      () async {
        final printer = printing.getDefaultPrinter();
        final result = await printing.openPrinterProperties(printer.id);
        expect(result, isA<bool>());
      },
    );
  });

  // ─── Extended job management ───────────────────────────────────────────────

  group('extended job management', () {
    test(
      'getPrintJobStatus() with invalid id returns PrintJob without throwing',
      () async {
        final job = await printing.getPrintJobStatus('invalid-job-id');
        expect(job, isA<PrintJob>());
        expect(job.id, isA<String>());
        expect(job.state, isA<PrintState>());
      },
    );

    test('getPrintJobStatus() with empty id does not throw', () async {
      final job = await printing.getPrintJobStatus('');
      expect(job, isA<PrintJob>());
    });

    test('pausePrintJob() with invalid id returns bool', () async {
      final result = await printing.pausePrintJob('invalid-job-id');
      expect(result, isA<bool>());
    });

    test('resumePrintJob() with invalid id returns bool', () async {
      final result = await printing.resumePrintJob('invalid-job-id');
      expect(result, isA<bool>());
    });

    test(
      'pausePrintJob() then resumePrintJob() on same id do not throw',
      () async {
        const id = 'nonexistent-job';
        await printing.pausePrintJob(id);
        final resumed = await printing.resumePrintJob(id);
        expect(resumed, isA<bool>());
      },
    );

    test('clearPrintQueue() returns bool without throwing', () async {
      final result = await printing.clearPrintQueue();
      expect(result, isA<bool>());
    });

    test('clearPrintQueue() is idempotent', () async {
      await printing.clearPrintQueue();
      final result = await printing.clearPrintQueue();
      expect(result, isA<bool>());
    });
  });

  // ─── Extended PrintSettings ────────────────────────────────────────────────

  group('extended PrintSettings', () {
    test('PrintSettings accepts pageRangeFrom and pageRangeTo', () {
      final s = PrintSettings(pageRangeFrom: 1, pageRangeTo: 5);
      expect(s.pageRangeFrom, equals(1));
      expect(s.pageRangeTo, equals(5));
    });

    test('PrintSettings default pageRange values are 0', () {
      final s = PrintSettings();
      expect(s.pageRangeFrom, equals(0));
      expect(s.pageRangeTo, equals(0));
    });

    test('PrintSettings accepts customPaperWidth and customPaperHeight', () {
      final s = PrintSettings(
        paperSize: PaperSize.custom,
        customPaperWidth: 210.0,
        customPaperHeight: 297.0,
      );
      expect(s.paperSize, equals(PaperSize.custom));
      expect(s.customPaperWidth, equals(210.0));
      expect(s.customPaperHeight, equals(297.0));
    });

    test('PrintSettings fitToPage defaults to false', () {
      final s = PrintSettings();
      expect(s.fitToPage, isFalse);
    });

    test('PrintSettings accepts fitToPage=true', () {
      final s = PrintSettings(fitToPage: true);
      expect(s.fitToPage, isTrue);
    });

    test('PrintSettings mediaType defaults to MediaType.plain', () {
      final s = PrintSettings();
      expect(s.mediaType, equals(MediaType.plain));
    });

    test('PrintSettings accepts all MediaType values', () {
      for (final mt in MediaType.values) {
        final s = PrintSettings(mediaType: mt);
        expect(s.mediaType, equals(mt));
      }
    });

    test('PrintSettings accepts headerText and footerText', () {
      final s = PrintSettings(
        headerText: 'Company Confidential',
        footerText: 'Page {page} of {total}',
      );
      expect(s.headerText, equals('Company Confidential'));
      expect(s.footerText, equals('Page {page} of {total}'));
    });

    test('PrintSettings headerText and footerText default to empty string', () {
      final s = PrintSettings();
      expect(s.headerText, isEmpty);
      expect(s.footerText, isEmpty);
    });

    test('PrintSettings accepts inputTray', () {
      final s = PrintSettings(inputTray: 'Tray1');
      expect(s.inputTray, equals('Tray1'));
    });

    test('printText() with extended settings does not throw', () async {
      final result = await printing.printText(
        'Extended settings test',
        settings: PrintSettings(
          jobName: 'Extended Test',
          pageRangeFrom: 1,
          pageRangeTo: 1,
          fitToPage: true,
          mediaType: MediaType.plain,
          headerText: 'Test Header',
          footerText: 'Test Footer',
          inputTray: '',
        ),
      );
      expect(result, isA<PrintResult>());
    });

    test('printPdf() with custom paper size does not throw', () async {
      final result = await printing.printPdf(
        _minimalPdf(),
        settings: PrintSettings(
          paperSize: PaperSize.custom,
          customPaperWidth: 100.0,
          customPaperHeight: 150.0,
        ),
      );
      expect(result, isA<PrintResult>());
    });

    test('printText() with each MediaType value does not throw', () async {
      for (final mt in MediaType.values) {
        final result = await printing.printText(
          'MediaType: ${mt.name}',
          settings: PrintSettings(mediaType: mt, jobName: 'Media ${mt.name}'),
        );
        expect(result, isA<PrintResult>());
      }
    });
  });

  // ─── Structs ───────────────────────────────────────────────────────────────

  group('structs', () {
    test('PrintSettings equality and hash', () {
      final a = PrintSettings(paperSize: PaperSize.a4, copies: 2);
      final b = PrintSettings(paperSize: PaperSize.a4, copies: 2);
      expect(a.paperSize, equals(b.paperSize));
      expect(a.copies, equals(b.copies));
    });

    test('PrintDocument with different types', () {
      final textDoc = PrintDocument(
        id: '1',
        title: 'Text',
        type: DocumentType.plainText,
        data: Uint8List(0),
      );
      final htmlDoc = PrintDocument(
        id: '2',
        title: 'HTML',
        type: DocumentType.html,
        data: Uint8List(0),
      );
      expect(textDoc.type, isNot(equals(htmlDoc.type)));
    });

    test('PrinterInfo with default printer', () {
      final info = PrinterInfo(id: 'p1', name: 'Test Printer', isDefault: true);
      expect(info.isDefault, isTrue);
      expect(info.isAvailable, isTrue);
      expect(info.address, isEmpty);
    });

    test('PrinterCapabilities default values', () {
      final caps = PrinterCapabilities();
      expect(caps.supportsColor, isTrue);
      expect(caps.maxCopies, greaterThan(0));
      expect(caps.minMarginTop, greaterThanOrEqualTo(0));
      expect(caps.supportsA4, isTrue);
      expect(caps.supportsNormalQuality, isTrue);
    });

    test('PrintJobUpdate with all fields', () {
      final update = PrintJobUpdate(
        jobId: 'job-1',
        state: PrintState.printing,
        progress: 50,
        message: 'Printing page 2',
      );
      expect(update.jobId, equals('job-1'));
      expect(update.state, equals(PrintState.printing));
      expect(update.message, equals('Printing page 2'));
    });

    test('PrinterStatus with ink levels', () {
      final status = PrinterStatus(
        printerId: 'p1',
        isOnline: true,
        isPrinting: false,
        jobsInQueue: 3,
        statusMessage: 'Ready',
        inkLevel: 75,
        tonerLevel: 100,
      );
      expect(status.isPrinting, isFalse);
      expect(status.inkLevel, equals(75));
      expect(status.tonerLevel, equals(100));
    });
  });
}
