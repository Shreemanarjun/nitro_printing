import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' show BytesBuilder, Uint8List;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nitro_printing/nitro_printing.dart';

/// Cross-platform verification that the printer configuration selected in Dart
/// is transmitted byte-for-byte by the *native* layer, using fake printers
/// that run inside the test process on loopback.
///
/// Unlike the Patrol suites (Android/iOS UI automation), this is a plain
/// integration test, so it also runs on **macOS** and any other desktop
/// target via `flutter test -d <device>`. It deliberately avoids the
/// system-dialog print path (which presents a modal native panel and blocks a
/// headless run) and exercises only the socket/IPP transports:
///
///   - raw protocol printing (printRaw / printEscPos / printZpl) — socket
///     transport on Android, iOS **and macOS**;
///   - direct-dispatch document printing (printText/printPdf, showPrintDialog
///     = false) — socket transport on Android and iOS.
///
/// Run with:
///   flutter test integration_test/native_transport_test.dart -d macos
///   flutter test integration_test/native_transport_test.dart -d `<ios-sim>`
///   flutter test integration_test/native_transport_test.dart -d `<android>`
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  if (kIsWeb) {
    test('native transport suite', () {},
        skip: 'loopback fake printers need dart:io sockets — native only');
    return;
  }

  late NitroPrinting printing;

  setUp(() => printing = NitroPrinting.instance);
  tearDownAll(() {
    // nitro 0.5.9's NitroRuntime.releaseLib calls DynamicLibrary.close(),
    // which throws "Bad state: DynamicLibrary.process()... can't be closed"
    // on iOS/macOS (the lib is process-linked, not a closeable .so). The
    // dispose still tears down the instance; swallow the upstream throw so it
    // doesn't fail an otherwise-green run.
    try {
      printing.dispose();
    } catch (_) {}
  });

  // On desktop, printText's direct path renders via the platform print system
  // (NSPrintOperation on macOS) rather than a raw socket, so document
  // direct-dispatch byte capture is only asserted where it uses sockets.
  final documentDirectUsesSocket =
      !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  // Platforms with a full native print stack (IPP client, PDF rendering for
  // printToFile). Windows/Linux currently ship only the socket transport.
  final hasNativePrintStack =
      !kIsWeb && (Platform.isAndroid || Platform.isIOS || Platform.isMacOS);

  // ── Raw protocol transport (Android, iOS, macOS) ──────────────────────────

  group('raw protocol transport', () {
    test('printEscPos sends the exact ESC/POS bytes to the printer', () async {
      final printer = FakeNetworkPrinter();
      await printer.start();
      try {
        final escPos = Uint8List.fromList([
          0x1B, 0x40, // ESC @ initialize
          ...ascii.encode('NitroPrinting receipt'),
          0x0A, 0x0A,
          0x1D, 0x56, 0x42, 0x00, // GS V B 0 partial cut
        ]);
        final result = await printing.printEscPos(
          escPos,
          settings: PrintSettings(
            printerId: '127.0.0.1:${printer.port}',
            showPrintDialog: false,
            networkTimeoutSeconds: 10,
          ),
        );
        expect(result.success, isTrue, reason: result.errorMessage);

        final received = await printer.waitForJob();
        expect(received, orderedEquals(escPos));
      } finally {
        await printer.stop();
      }
    });

    test('printZpl sends the exact ZPL script to the printer', () async {
      final printer = FakeNetworkPrinter();
      await printer.start();
      try {
        const zpl = '^XA^FO50,50^A0N,40,40^FDNitroPrinting^FS^XZ';
        final result = await printing.printZpl(
          zpl,
          settings: PrintSettings(
            printerId: '127.0.0.1:${printer.port}',
            showPrintDialog: false,
            networkTimeoutSeconds: 10,
          ),
        );
        expect(result.success, isTrue, reason: result.errorMessage);

        final received = String.fromCharCodes(await printer.waitForJob());
        expect(received, equals(zpl));
      } finally {
        await printer.stop();
      }
    });

    test('printRaw sends arbitrary bytes verbatim', () async {
      final printer = FakeNetworkPrinter();
      await printer.start();
      try {
        final payload = Uint8List.fromList(
          List<int>.generate(256, (i) => i),
        );
        final result = await printing.printRaw(
          payload,
          settings: PrintSettings(
            printerId: '127.0.0.1:${printer.port}',
            showPrintDialog: false,
            networkTimeoutSeconds: 10,
          ),
        );
        expect(result.success, isTrue, reason: result.errorMessage);

        final received = await printer.waitForJob();
        expect(received, orderedEquals(payload));
      } finally {
        await printer.stop();
      }
    });

    test('copies are applied by the native transport for raw prints', () async {
      final printer = FakeNetworkPrinter();
      await printer.start();
      try {
        final payload = Uint8List.fromList(ascii.encode('UNIT'));
        final result = await printing.printRaw(
          payload,
          settings: PrintSettings(
            printerId: '127.0.0.1:${printer.port}',
            showPrintDialog: false,
            copies: 3,
            networkTimeoutSeconds: 10,
          ),
        );
        expect(result.success, isTrue, reason: result.errorMessage);

        final received = await printer.waitForJob();
        expect(
          _countOccurrences(received, payload),
          3,
          reason: 'native transport must write the payload once per copy',
        );
      } finally {
        await printer.stop();
      }
    });
  });

  // ── Connection probe (all platforms) ──────────────────────────────────────

  group('connection probe', () {
    test('testPrinterConnection returns true for a listening printer', () async {
      final printer = FakeNetworkPrinter();
      await printer.start();
      try {
        final reachable = await printing.testPrinterConnection(
          '127.0.0.1:${printer.port}',
          timeoutSeconds: 5,
        );
        expect(reachable, isTrue);
      } finally {
        await printer.stop();
      }
    });

    test('testPrinterConnection returns false for a closed port', () async {
      // Bind and immediately release a port so it is guaranteed closed.
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final closedPort = probe.port;
      await probe.close();

      final reachable = await printing.testPrinterConnection(
        '127.0.0.1:$closedPort',
        timeoutSeconds: 3,
      );
      expect(reachable, isFalse);
    });
  });

  // ── IPP transport (Android, iOS, macOS) ───────────────────────────────────

  group('IPP transport', () {
    test(
      'printRaw over ipp:// posts an IPP job carrying the exact payload',
      () async {
        if (!hasNativePrintStack) return;
        final printer = FakeIppPrinter();
        await printer.start();
        try {
          final payload = Uint8List.fromList(ascii.encode('IPP RAW PAYLOAD'));
          final result = await printing.printRaw(
            payload,
            settings: PrintSettings(
              printerId: 'ipp://127.0.0.1:${printer.port}/ipp/print',
              showPrintDialog: false,
              networkTimeoutSeconds: 10,
              jobName: 'ipp-transport-test',
            ),
          );
          expect(result.success, isTrue, reason: result.errorMessage);

          final request = await printer.waitForRequest();
          expect(request.contentType, 'application/ipp');
          // IPP binary header + attributes precede the document data.
          expect(_containsBytes(request.body, payload), isTrue);
          expect(
            _containsBytes(request.body, ascii.encode('ipp-transport-test')),
            isTrue,
            reason: 'job-name attribute must be transmitted',
          );
        } finally {
          await printer.stop();
        }
      },
    );
  });

  // ── Print to file (Android, iOS, macOS) ───────────────────────────────────

  group('print to file', () {
    test(
      'printToFile renders a PDF honouring the configured paper size',
      () async {
        if (!hasNativePrintStack) return;
        final dir = await Directory.systemTemp.createTemp('nitro_print_test');
        final outputPath = '${dir.path}/out.pdf';
        try {
          final ok = await printing.printToFile(
            PrintDocument(
              id: 'to-file',
              title: 'To File',
              type: DocumentType.plainText,
              data: Uint8List.fromList(ascii.encode('printToFile check')),
            ),
            outputPath,
            settings: PrintSettings(
              paperSize: PaperSize.letter,
              showPrintDialog: false,
            ),
          );
          expect(ok, isTrue);

          final bytes = await File(outputPath).readAsBytes();
          expect(_startsWithBytes(bytes, ascii.encode('%PDF')), isTrue);
          // Letter portrait is integral (612×792 pt) on every platform.
          expect(_mediaBoxes(bytes), contains((width: 612, height: 792)));
        } finally {
          await dir.delete(recursive: true);
        }
      },
    );
  });

  // ── Document direct dispatch (Android, iOS) ───────────────────────────────

  group('document direct-dispatch transport', () {
    test(
      'printText direct dispatch renders a PDF and sends it over the socket',
      () async {
        if (!documentDirectUsesSocket) return;
        final printer = FakeNetworkPrinter();
        await printer.start();
        try {
          final result = await printing.printText(
            'native transport check',
            settings: PrintSettings(
              printerId: '127.0.0.1:${printer.port}',
              showPrintDialog: false,
              networkTimeoutSeconds: 10,
            ),
          );
          expect(result.success, isTrue, reason: result.errorMessage);

          final received = await printer.waitForJob();
          expect(_startsWithBytes(received, ascii.encode('%PDF')), isTrue);
        } finally {
          await printer.stop();
        }
      },
    );

    test(
      'every paper size and orientation renders the exact native page size',
      () async {
        if (!documentDirectUsesSocket) return;
        final printer = FakeNetworkPrinter();
        await printer.start();

        final isIOS = !kIsWeb && Platform.isIOS;
        final a4 = isIOS
            ? (width: 595, height: 841)
            : (width: 595, height: 842);
        final portraitDims = {
          PaperSize.a4: a4,
          PaperSize.a5: isIOS
              ? (width: 419, height: 595)
              : (width: 420, height: 595),
          PaperSize.letter: (width: 612, height: 792),
          PaperSize.legal: (width: 612, height: 1008),
          PaperSize.custom: a4,
        };
        const orientations = [0.0, 90.0, 180.0, 270.0];

        try {
          var jobIndex = 0;
          for (final paper in PaperSize.values) {
            for (final degrees in orientations) {
              final result = await printing.printText(
                'combo $paper/$degrees',
                settings: PrintSettings(
                  printerId: '127.0.0.1:${printer.port}',
                  showPrintDialog: false,
                  paperSize: paper,
                  orientationDegrees: degrees,
                  networkTimeoutSeconds: 10,
                ),
              );
              expect(result.success, isTrue, reason: '$paper/$degrees');

              final portrait = portraitDims[paper]!;
              final rotated = degrees == 90.0 || degrees == 270.0;
              final expected = rotated
                  ? (width: portrait.height, height: portrait.width)
                  : portrait;
              final job = await printer.waitForJob(index: jobIndex);
              expect(
                _mediaBoxes(job),
                contains(expected),
                reason:
                    '$paper at $degrees° must render a '
                    '${expected.width}×${expected.height} pt page natively',
              );
              jobIndex++;
            }
          }
        } finally {
          await printer.stop();
        }
      },
    );
  });
}

// ─────────────────────────── Fake printer ───────────────────────────

/// A raw TCP "network printer" bound to an ephemeral loopback port that
/// captures each connection's full byte stream.
class FakeNetworkPrinter {
  ServerSocket? _server;
  final List<Uint8List> _jobs = [];

  int get port => _server!.port;

  Future<void> start() async {
    _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen((client) {
      final buffer = BytesBuilder(copy: false);
      client.listen(
        buffer.add,
        onDone: () {
          _jobs.add(buffer.toBytes());
          client.destroy();
        },
        onError: (_) => client.destroy(),
      );
    });
  }

  Future<Uint8List> waitForJob({
    int index = 0,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (_jobs.length > index) return _jobs[index];
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw TimeoutException('fake printer received no job', timeout);
  }

  Future<void> stop() async => _server?.close();
}

/// A minimal IPP endpoint: records every request and answers HTTP 200 with an
/// IPP `successful-ok` body so the native client treats the job as accepted.
class FakeIppPrinter {
  HttpServer? _server;
  final List<({Uint8List body, String? contentType})> _requests = [];

  int get port => _server!.port;

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen((request) async {
      final builder = BytesBuilder(copy: false);
      await request.forEach(builder.add);
      _requests.add((
        body: builder.toBytes(),
        contentType: request.headers.contentType?.mimeType,
      ));
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType('application', 'ipp')
        // IPP 1.1, status-code successful-ok, request-id 1, end-of-attributes.
        ..add(const [0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x03]);
      await request.response.close();
    });
  }

  Future<({Uint8List body, String? contentType})> waitForRequest({
    int index = 0,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (_requests.length > index) return _requests[index];
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw TimeoutException('fake IPP printer received no request', timeout);
  }

  Future<void> stop() async => _server?.close(force: true);
}

// ─────────────────────── byte helpers ───────────────────────

bool _startsWithBytes(Uint8List data, List<int> prefix) {
  if (data.length < prefix.length) return false;
  for (var i = 0; i < prefix.length; i++) {
    if (data[i] != prefix[i]) return false;
  }
  return true;
}

int _indexOfBytes(Uint8List data, List<int> pattern, [int start = 0]) {
  outer:
  for (var i = start; i + pattern.length <= data.length; i++) {
    for (var j = 0; j < pattern.length; j++) {
      if (data[i + j] != pattern[j]) continue outer;
    }
    return i;
  }
  return -1;
}

bool _containsBytes(Uint8List data, List<int> pattern) =>
    _indexOfBytes(data, pattern) != -1;

int _countOccurrences(Uint8List data, List<int> pattern) {
  var count = 0;
  var index = _indexOfBytes(data, pattern);
  while (index != -1) {
    count++;
    index = _indexOfBytes(data, pattern, index + pattern.length);
  }
  return count;
}

List<({int width, int height})> _mediaBoxes(Uint8List pdf) {
  final text = String.fromCharCodes(pdf);
  return RegExp(
    r'/MediaBox\s*\[\s*0(?:\.0+)?\s+0(?:\.0+)?\s+(\d+)(?:\.\d+)?\s+(\d+)(?:\.\d+)?\s*\]',
  )
      .allMatches(text)
      .map(
        (m) => (width: int.parse(m.group(1)!), height: int.parse(m.group(2)!)),
      )
      .toList();
}
