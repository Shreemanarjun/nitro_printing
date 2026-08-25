// Unit tests for the typed error/outcome catalog (lib/src/print_error_catalog.dart).
//
// Pure Dart on the VM: PrintResult/PrintJob are plain records and the catalog
// is string parsing, so nothing here touches the native library or a browser.
// This is the suite the CI coverage gate measures.
import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_printing/nitro_printing.dart';

PrintResult _ok({String code = '', String message = ''}) =>
    PrintResult(success: true, errorCode: code, errorMessage: message);

PrintResult _fail({String code = '', String message = ''}) =>
    PrintResult(success: false, errorCode: code, errorMessage: message);

PrintJob _job(PrintState state, {String error = ''}) => PrintJob(
      id: 'j1',
      printerId: 'p1',
      documentTitle: 'doc',
      state: state,
      progress: 0,
      createdAtMillis: 0,
      completedAtMillis: 0,
      errorMessage: error,
      pagesPrinted: 0,
    );

void main() {
  group('PrintResult.errorKind', () {
    test('success is none regardless of the code field', () {
      expect(_ok().errorKind, PrintErrorCode.none);
      expect(_ok(code: kDialogOutcomeUnknown).errorKind, PrintErrorCode.none);
    });

    test('empty code on a failure maps to none', () {
      expect(_fail().errorKind, PrintErrorCode.none);
    });

    test('unrecognized code maps to unknown', () {
      expect(_fail(code: 'NOT_A_REAL_CODE').errorKind, PrintErrorCode.unknown);
    });

    test('every catalogued code maps to a distinct enum value', () {
      const codes = <String, PrintErrorCode>{
        'CANCELLED': PrintErrorCode.cancelled,
        'WEB_UNSUPPORTED': PrintErrorCode.webUnsupported,
        'WEB_PRINT_FAILED': PrintErrorCode.webPrintFailed,
        'DIALOG_FAILED': PrintErrorCode.dialogFailed,
        'NO_USB_DEVICE': PrintErrorCode.noUsbDevice,
        'USB_NO_ENDPOINT': PrintErrorCode.usbNoEndpoint,
        'USB_TRANSFER_FAILED': PrintErrorCode.usbTransferFailed,
        'USB_FAILED': PrintErrorCode.usbFailed,
        'WEB_SERIAL_UNAVAILABLE': PrintErrorCode.webSerialUnavailable,
        'NO_SERIAL_DEVICE': PrintErrorCode.noSerialDevice,
        'SERIAL_FAILED': PrintErrorCode.serialFailed,
        'WEB_BLUETOOTH_UNAVAILABLE': PrintErrorCode.webBluetoothUnavailable,
        'NO_BLE_DEVICE': PrintErrorCode.noBleDevice,
        'BLE_NO_CHARACTERISTIC': PrintErrorCode.bleNoCharacteristic,
        'BLE_FAILED': PrintErrorCode.bleFailed,
        'RELAY_TIMEOUT': PrintErrorCode.relayTimeout,
        'RELAY_FAILED': PrintErrorCode.relayFailed,
        'TCP_UNAVAILABLE': PrintErrorCode.tcpUnavailable,
        'TCP_FAILED': PrintErrorCode.tcpFailed,
        'IMAGE_DECODE_FAILED': PrintErrorCode.imageDecodeFailed,
        'WP_UNKNOWN_PRINTER': PrintErrorCode.wpUnknownPrinter,
        'WP_SUBMIT_FAILED': PrintErrorCode.wpSubmitFailed,
        'QZ_UNAVAILABLE': PrintErrorCode.qzUnavailable,
        'QZ_BLOCKED': PrintErrorCode.qzBlocked,
        'QZ_PRINT_FAILED': PrintErrorCode.qzPrintFailed,
        'AGENT_UNAVAILABLE': PrintErrorCode.agentUnavailable,
        'AGENT_PRINT_FAILED': PrintErrorCode.agentPrintFailed,
      };
      codes.forEach((code, expected) {
        expect(_fail(code: code).errorKind, expected, reason: code);
      });
      // Nothing collapses onto `unknown` by accident.
      expect(codes.values.toSet().length, codes.length);
    });
  });

  group('PrintResult.outcome', () {
    test('verified success is printed', () {
      expect(_ok().outcome, PrintOutcome.printed);
    });

    test('dialog success is dialogShown, not printed', () {
      expect(_ok(code: kDialogOutcomeUnknown).outcome, PrintOutcome.dialogShown);
    });

    test('cancelled failure is cancelled', () {
      expect(_fail(code: 'CANCELLED').outcome, PrintOutcome.cancelled);
    });

    test('any other failure is failed', () {
      expect(_fail(code: 'TCP_FAILED').outcome, PrintOutcome.failed);
      expect(_fail(code: 'NOPE').outcome, PrintOutcome.failed);
    });
  });

  group('PrintResult.dialogDurationMs', () {
    test('parses dialogMs from the dialog message', () {
      final r = _ok(
        code: kDialogOutcomeUnknown,
        message: '[DIALOG_OUTCOME_UNKNOWN] dialogMs=1847',
      );
      expect(r.dialogDurationMs, 1847);
    });

    test('is null outside the dialog flow even when the text carries dialogMs',
        () {
      expect(_ok(message: 'dialogMs=1847').dialogDurationMs, isNull);
      expect(_fail(code: 'TCP_FAILED', message: 'dialogMs=99').dialogDurationMs,
          isNull);
    });

    test('is null when the dialog message carries no measurement', () {
      expect(_ok(code: kDialogOutcomeUnknown).dialogDurationMs, isNull);
    });
  });

  group('PrintResult.dialogGuess', () {
    DialogOutcomeGuess guessFor(int ms) => _ok(
          code: kDialogOutcomeUnknown,
          message: 'dialogMs=$ms',
        ).dialogGuess;

    test('under the lower bound reads as likely cancelled', () {
      expect(guessFor(0), DialogOutcomeGuess.likelyCancelled);
      expect(guessFor(1199), DialogOutcomeGuess.likelyCancelled);
    });

    test('the ambiguous middle stays unknown', () {
      expect(guessFor(1200), DialogOutcomeGuess.unknown);
      expect(guessFor(2499), DialogOutcomeGuess.unknown);
    });

    test('at or above the upper bound reads as likely printed', () {
      expect(guessFor(2500), DialogOutcomeGuess.likelyPrinted);
      expect(guessFor(60000), DialogOutcomeGuess.likelyPrinted);
    });

    test('no measurement or non-dialog flow is notApplicable', () {
      expect(_ok(code: kDialogOutcomeUnknown).dialogGuess,
          DialogOutcomeGuess.notApplicable);
      expect(_ok(message: 'dialogMs=3000').dialogGuess,
          DialogOutcomeGuess.notApplicable);
    });
  });

  group('PrintJob.outcome', () {
    test('completed is printed, or dialogShown when marked unknowable', () {
      expect(_job(PrintState.completed).outcome, PrintOutcome.printed);
      expect(
        _job(PrintState.completed,
                error: '[$kDialogOutcomeUnknown] dialogMs=900')
            .outcome,
        PrintOutcome.dialogShown,
      );
    });

    test('terminal failure states map through', () {
      expect(_job(PrintState.cancelled).outcome, PrintOutcome.cancelled);
      expect(_job(PrintState.failed).outcome, PrintOutcome.failed);
    });

    test('non-terminal states have no outcome yet', () {
      expect(_job(PrintState.printing).outcome, isNull);
    });
  });

  group('PrintJob.failureReason', () {
    test('a job that did not fail reports none', () {
      expect(_job(PrintState.completed).failureReason,
          PrintJobFailureReason.none);
      expect(
          _job(PrintState.printing).failureReason, PrintJobFailureReason.none);
    });

    test('parses the [REASON] prefix convention', () {
      const cases = <String, PrintJobFailureReason>{
        'MEDIA_EMPTY': PrintJobFailureReason.mediaEmpty,
        'MEDIA_JAM': PrintJobFailureReason.mediaJam,
        'TONER_EMPTY': PrintJobFailureReason.tonerEmpty,
        'TONER_LOW': PrintJobFailureReason.tonerLow,
        'COVER_OPEN': PrintJobFailureReason.coverOpen,
        'PRINTER_OFFLINE': PrintJobFailureReason.printerOffline,
        'JOB_ABORTED': PrintJobFailureReason.aborted,
      };
      cases.forEach((code, expected) {
        expect(
          _job(PrintState.failed, error: '[$code] printer said so')
              .failureReason,
          expected,
          reason: code,
        );
      });
    });

    test('an unrecognized [REASON] is unknown, not a silent none', () {
      expect(
        _job(PrintState.failed, error: '[WAT] mystery').failureReason,
        PrintJobFailureReason.unknown,
      );
    });

    test('raw-transport "CODE|message" cancellation is recognized', () {
      expect(
        _job(PrintState.failed, error: 'CANCELLED|user aborted').failureReason,
        PrintJobFailureReason.cancelled,
      );
      expect(
        _job(PrintState.failed, error: 'TCP_FAILED|connection refused')
            .failureReason,
        PrintJobFailureReason.unknown,
      );
    });

    test('a cancelled job falls back to cancelled without any code', () {
      expect(_job(PrintState.cancelled).failureReason,
          PrintJobFailureReason.cancelled);
    });

    test('a failed job with no parseable text is unknown', () {
      expect(_job(PrintState.failed).failureReason,
          PrintJobFailureReason.unknown);
    });
  });
}
