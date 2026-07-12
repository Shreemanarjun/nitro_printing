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
