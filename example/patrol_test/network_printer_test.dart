import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' show BytesBuilder;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrol/patrol.dart';

import 'package:nitro_printing/nitro_printing.dart' as np;
import 'package:nitro_printing_example/main.dart' as app;

import 'scroll_helpers.dart';

/// Patrol tests that verify the printer configuration selected in the app is
/// exactly what the native layer transmits, using fake network printers that
/// run inside the test process on loopback.
///
///  - [FakeNetworkPrinter] — a raw TCP listener (like a JetDirect/9100
///    printer). Everything the native socket transport sends is captured and
///    asserted byte-for-byte.
///  - [FakeIppPrinter] — a minimal IPP-over-HTTP endpoint that records the
///    IPP request and replies successful-ok, so the native IPP path
///    (`ipp://` routing) completes for real.
///
/// This proves settings propagation end-to-end: UI selection → Dart
/// PrintSettings → nitro bridge → native PDF generation / IPP attributes /
/// socket transport.
///
/// Run with:
///   patrol test -t patrol_test/network_printer_test.dart -d `<device>`
///
/// Works on Android and iOS (both implement directPrint/socketPrint/ippPrint
/// natively); no-ops elsewhere.
void main() {
  bool isMobile() => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  Future<void> boot(PatrolIntegrationTester $) async {
    app.main();
    await $.pumpAndSettle();
    await $('Printer Status Dashboard').waitUntilVisible();
  }

  Future<void> openPrintTabDirectMode(PatrolIntegrationTester $) async {
    await $('Print').tap();
    await $('Document Printing Panel').waitUntilVisible();
    await $('Direct Dispatch').tap();
    await $('ROUTING ADDRESS').waitUntilVisible();
  }

  Future<void> setRoutingAddress(PatrolIntegrationTester $, String uri) async {
    await $(TextField)
        .containing('Direct Destination Printer ID / URL')
        .enterText(uri);
    await $.pumpAndSettle();
  }

  /// Enters the raw-tab printer endpoint and dismisses the soft keyboard so it
  /// doesn't occlude the send button on iOS (where the keyboard stays up after
  /// enterText and covers the lower part of the panel).
  Future<void> enterRawEndpoint(PatrolIntegrationTester $, int port) async {
    await $(TextField)
        .containing('Printer TCP Address / URI')
        .enterText('127.0.0.1:$port');
    // Remove focus so the soft keyboard hides — iOS keeps it up after
    // enterText, covering the send button in the (short, non-scrolling)
    // ESC/POS panel so scrollTo can't bring it into a hit-testable position.
    FocusManager.instance.primaryFocus?.unfocus();
    await $.pumpAndSettle();
  }

  /// Brings [label] into view inside the Print tab and taps it.
  Future<void> scrollToAndTap(PatrolIntegrationTester $, String label) async {
    await tapInList($, $(label));
  }

  /// Scrolls the Raw tab's per-tab vertical scrollable (keyed
  /// `rawPanelScroll_<tabIndex>`) to [label] and taps it. Targeting the keyed
  /// scrollable avoids grabbing the TabBarView's horizontal PageView, which
  /// `find.byType(Scrollable).hitTestable()` may pick first on iOS.
  Future<void> scrollRawPanelTo(
    PatrolIntegrationTester $,
    int tabIndex,
    String label,
  ) async {
    final scrollable = find
        .descendant(
          of: find.byKey(ValueKey('rawPanelScroll_$tabIndex')),
          matching: find.byType(Scrollable),
        )
        .first;
    await $(label).scrollTo(view: scrollable, step: 300, maxScrolls: 40).tap();
  }

  /// Changes a settings-panel dropdown from its [current] label to [option].
  Future<void> selectDropdownOption(
    PatrolIntegrationTester $,
    String current,
    String option,
  ) async {
    await scrollToAndTap($, current);
    await $(option).waitUntilVisible();
    await $(option).tap();
  }

  /// Scrolls back up to the result banner at the top of the Print tab's list
  /// and waits for [pattern] to show.
  Future<void> expectResultBanner(
    PatrolIntegrationTester $,
    Pattern pattern,
  ) async {
    await revealInList($, $(pattern), towardsTop: true);
    await $(pattern).first.waitUntilVisible();
  }

  // ───────────────────────── Fake printers ─────────────────────────

  patrolTest(
    'direct print to a network printer delivers a rendered PDF payload',
    ($) async {
      if (!isMobile()) return;
      final printer = FakeNetworkPrinter();
      await printer.start();

      try {
        await boot($);
        await openPrintTabDirectMode($);
        await setRoutingAddress($, '127.0.0.1:${printer.port}');
        await scrollToAndTap($, 'Print Text');

        await expectResultBanner($, RegExp('OK — jobId:'));

        final job = await printer.waitForJob();
        expect(
          _startsWithBytes(job, ascii.encode('%PDF')),
          isTrue,
          reason: 'the native layer must render text to a PDF payload',
        );
        // Default settings: one copy, A4 portrait. Android renders an
        // integral 595×842 pt MediaBox; iOS uses exact points (841.89 → 841).
        expect(_countOccurrences(job, ascii.encode('%PDF')), 1);
        final expectedA4 = Platform.isIOS
            ? (width: 595, height: 841)
            : (width: 595, height: 842);
        expect(_mediaBoxes(job), contains(expectedA4));
      } finally {
        await printer.stop();
      }
    },
  );

  patrolTest('copies selected in the UI reach the native socket transport', (
    $,
  ) async {
    if (!isMobile()) return;
    final printer = FakeNetworkPrinter();
    await printer.start();

    try {
      await boot($);
      await openPrintTabDirectMode($);
      await setRoutingAddress($, '127.0.0.1:${printer.port}');
      await selectDropdownOption($, '1 copies', '3 copies');
      await scrollToAndTap($, 'Print Text');

      await expectResultBanner($, RegExp('OK — jobId:'));

      // The native transport writes the payload once per copy.
      final job = await printer.waitForJob();
      expect(
        _countOccurrences(job, ascii.encode('%PDF')),
        3,
        reason: 'copies=3 must be applied by the native transport',
      );
    } finally {
      await printer.stop();
    }
  });

  patrolTest(
    'paper size and orientation selected in the UI reach the native '
    'PDF generator',
    ($) async {
      if (!isMobile()) return;
      final printer = FakeNetworkPrinter();
      await printer.start();

      try {
        await boot($);
        await openPrintTabDirectMode($);
        await setRoutingAddress($, '127.0.0.1:${printer.port}');
        await selectDropdownOption($, 'A4', 'LETTER');
        await selectDropdownOption($, 'Portrait', 'Landscape');
        await scrollToAndTap($, 'Print Text');

        await expectResultBanner($, RegExp('OK — jobId:'));

        // Letter landscape = 792×612 pt page — the native renderer must have
        // used exactly the configuration selected in the UI.
        final job = await printer.waitForJob();
        expect(
          _mediaBoxes(job),
          contains((width: 792, height: 612)),
          reason: 'native page size must match Letter landscape',
        );
      } finally {
        await printer.stop();
      }
    },
  );

  // NOTE: no "/" in patrolTest names — the Android Test Orchestrator uses the
  // test name as a file name and aborts the run on path separators.
  patrolTest('ESC-POS payload arrives byte-exact at the network printer', (
    $,
  ) async {
    if (!isMobile()) return;
    final printer = FakeNetworkPrinter();
    await printer.start();

    try {
      await boot($);
      await $('Raw').tap();
      await $('Low-Level Network Printing').waitUntilVisible();

      await enterRawEndpoint($, printer.port);
      await scrollRawPanelTo($, 0, 'Dispatch ESC/POS Payload');

      // The raw result banner is pinned above the scrollable content.
      await $(RegExp('OK — jobId:')).waitUntilVisible();

      final job = await printer.waitForJob();
      // ESC @ (initialize) leads the stream…
      expect(_startsWithBytes(job, [0x1B, 0x40]), isTrue);
      // …the receipt header and default body text are embedded…
      expect(_containsBytes(job, ascii.encode('NitroPrinting')), isTrue);
      expect(
        _containsBytes(job, ascii.encode('Hello from NitroPrinting!')),
        isTrue,
      );
      // …and the partial-cut command terminates it.
      expect(_endsWithBytes(job, [0x1D, 0x56, 0x42, 0x00]), isTrue);
    } finally {
      await printer.stop();
    }
  });

  patrolTest('ZPL script arrives intact at the network printer', ($) async {
    if (!isMobile()) return;
    final printer = FakeNetworkPrinter();
    await printer.start();

    try {
      await boot($);
      await $('Raw').tap();
      await $('Low-Level Network Printing').waitUntilVisible();

      await $('ZPL').tap();
      await $('ZPL II Programming Language').waitUntilVisible();

      await enterRawEndpoint($, printer.port);
      await scrollRawPanelTo($, 1, 'Transmit ZPL Label');

      await $(RegExp('OK — jobId:')).waitUntilVisible();

      final zpl = String.fromCharCodes(await printer.waitForJob());
      expect(zpl, contains('^XA'));
      expect(zpl, contains('NitroPrinting'));
      expect(zpl, contains('^XZ'));
    } finally {
      await printer.stop();
    }
  });

  patrolTest(
    'every paper size and orientation combination is rendered natively with '
    'the exact page dimensions',
    ($) async {
      if (!isMobile()) return;
      final printer = FakeNetworkPrinter();
      await printer.start();

      // Expected portrait page dimensions (whole PDF points — _mediaBoxes
      // truncates fractions) per paper size. Android renders integral sizes
      // (A4 = 595×842); iOS uses exact points (595.28×841.89 → 595×841).
      // PaperSize.custom without explicit dimensions falls back to A4.
      final a4 = Platform.isIOS
          ? (width: 595, height: 841)
          : (width: 595, height: 842);
      final portraitDims = {
        np.PaperSize.a4: a4,
        np.PaperSize.a5: Platform.isIOS
            ? (width: 419, height: 595)
            : (width: 420, height: 595),
        np.PaperSize.letter: (width: 612, height: 792),
        np.PaperSize.legal: (width: 612, height: 1008),
        np.PaperSize.custom: a4,
      };
      const orientations = [0.0, 90.0, 180.0, 270.0];

      try {
        // Exhaustive sweep through the full plugin → bridge → native →
        // socket pipeline (the UI dropdown path for these settings is
        // covered by the tests above).
        var jobIndex = 0;
        for (final paper in np.PaperSize.values) {
          for (final degrees in orientations) {
            final result = await np.NitroPrinting.instance.printText(
              'combination test $paper/$degrees',
              settings: np.PrintSettings(
                jobName: 'combo-$jobIndex',
                paperSize: paper,
                orientationDegrees: degrees,
                showPrintDialog: false,
                printerId: '127.0.0.1:${printer.port}',
              ),
            );
            expect(
              result.success,
              isTrue,
              reason: '$paper at $degrees° must print',
            );

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

  patrolTest('every copies count is applied by the native transport', (
    $,
  ) async {
    if (!isMobile()) return;
    final printer = FakeNetworkPrinter();
    await printer.start();

    try {
      for (var copies = 1; copies <= 5; copies++) {
        final result = await np.NitroPrinting.instance.printText(
          'copies sweep $copies',
          settings: np.PrintSettings(
            jobName: 'copies-$copies',
            copies: copies,
            showPrintDialog: false,
            printerId: '127.0.0.1:${printer.port}',
          ),
        );
        expect(result.success, isTrue, reason: 'copies=$copies must print');

        final job = await printer.waitForJob(index: copies - 1);
        expect(
          _countOccurrences(job, ascii.encode('%PDF')),
          copies,
          reason: 'native transport must write the payload $copies times',
        );
      }
    } finally {
      await printer.stop();
    }
  });

  patrolTest(
    'IPP direct print posts the selected configuration as IPP attributes',
    ($) async {
      if (!isMobile()) return;
      final printer = FakeIppPrinter();
      await printer.start();

      try {
        await boot($);
        await openPrintTabDirectMode($);
        await setRoutingAddress($, 'ipp://127.0.0.1:${printer.port}/ipp/print');
        await selectDropdownOption($, '1 copies', '2 copies');
        await scrollToAndTap($, 'Print Text');

        await expectResultBanner($, RegExp('OK — jobId:'));

        final request = await printer.waitForRequest();
        expect(request.contentType, 'application/ipp');
        // The configuration chosen in the UI must be encoded in the IPP job.
        expect(
          _ippIntAttribute(request.body, 'copies'),
          2,
          reason: 'copies attribute must match the UI selection',
        );
        expect(
          _containsBytes(request.body, ascii.encode('application/pdf')),
          isTrue,
          reason: 'document-format must be transmitted',
        );
        expect(
          _containsBytes(request.body, ascii.encode('%PDF')),
          isTrue,
          reason: 'the rendered document must follow the IPP header',
        );
      } finally {
        await printer.stop();
      }
    },
  );
}

// ─────────────────────────── Fakes ───────────────────────────

/// A raw TCP "network printer" (JetDirect-style, like port 9100) bound to an
/// ephemeral loopback port. Captures each connection's full byte stream.
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

bool _endsWithBytes(Uint8List data, List<int> suffix) {
  if (data.length < suffix.length) return false;
  final offset = data.length - suffix.length;
  for (var i = 0; i < suffix.length; i++) {
    if (data[offset + i] != suffix[i]) return false;
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

/// Extracts every `/MediaBox [0 0 w h]` page size (in whole points) from a
/// PDF byte stream.
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

/// Reads a big-endian IPP integer attribute (value-tag 0x21) named [name].
int? _ippIntAttribute(Uint8List body, String name) {
  final nameBytes = ascii.encode(name);
  for (var i = 0; i + nameBytes.length + 9 <= body.length; i++) {
    if (body[i] != 0x21) continue;
    if (body[i + 1] != 0x00 || body[i + 2] != nameBytes.length) continue;
    var matches = true;
    for (var j = 0; j < nameBytes.length; j++) {
      if (body[i + 3 + j] != nameBytes[j]) {
        matches = false;
        break;
      }
    }
    if (!matches) continue;
    final valueOffset = i + 3 + nameBytes.length;
    if (body[valueOffset] != 0x00 || body[valueOffset + 1] != 0x04) continue;
    return (body[valueOffset + 2] << 24) |
        (body[valueOffset + 3] << 16) |
        (body[valueOffset + 4] << 8) |
        body[valueOffset + 5];
  }
  return null;
}
