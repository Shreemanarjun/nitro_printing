// Typed catalog of printing error codes and job failure reasons, so callers
// can switch on enums instead of matching strings. The web (WASM) backend
// emits every code below; native backends that set `PrintResult.errorCode`
// map through the same table (unknown codes surface as [PrintErrorCode.unknown]).
import 'package:nitro/nitro.dart' show NitroOk;

import 'nitro_printing.native.dart';

/// Machine-readable print failure categories.
enum PrintErrorCode {
  /// The print succeeded — no error.
  none,

  /// The user (or `cancelRawPrint`) aborted the job.
  cancelled,

  /// The capability does not exist on this platform.
  webUnsupported,

  /// Generic web print failure (no more specific code applied).
  webPrintFailed,

  /// The browser print dialog failed to open or timed out.
  dialogFailed,

  /// No WebUSB printer granted — call `startPrinterDiscovery()` from a tap.
  noUsbDevice,

  /// The granted USB device exposes no bulk-OUT endpoint.
  usbNoEndpoint,

  /// A USB transfer completed with an error status.
  usbTransferFailed,

  /// WebUSB open/claim/transfer threw.
  usbFailed,

  /// This browser has no Web Serial API.
  webSerialUnavailable,

  /// No serial port granted — call `startPrinterDiscovery()` from a tap.
  noSerialDevice,

  /// Web Serial open/write threw.
  serialFailed,

  /// This browser has no Web Bluetooth API.
  webBluetoothUnavailable,

  /// No BLE printer granted — call `startPrinterDiscovery()` from a tap.
  noBleDevice,

  /// The BLE printer exposes no writable characteristic.
  bleNoCharacteristic,

  /// Web Bluetooth connect/write threw.
  bleFailed,

  /// The ws:// relay did not answer in time.
  relayTimeout,

  /// The ws:// relay connection or send failed.
  relayFailed,

  /// Raw TCP needs an Isolated Web App (Direct Sockets) — or a ws:// relay.
  tcpUnavailable,

  /// The Direct Sockets TCP connection or write failed.
  tcpFailed,

  /// The image could not be decoded/rastered.
  imageDecodeFailed,

  /// The printerId names no known Web Printing system printer.
  wpUnknownPrinter,

  /// The Web Printing job submission threw.
  wpSubmitFailed,

  /// The QZ Tray local agent is not reachable (not installed / not running).
  qzUnavailable,

  /// QZ Tray blocked the request (denied in its Allow prompt).
  qzBlocked,

  /// The QZ Tray print call failed.
  qzPrintFailed,

  /// The Nitro Print Agent is not reachable (not installed / not running).
  agentUnavailable,

  /// The Nitro Print Agent's native print call failed.
  agentPrintFailed,

  /// An error code this catalog does not know.
  unknown,
}

const Map<String, PrintErrorCode> _codeTable = {
  '': PrintErrorCode.none,
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

/// Informational code on successful dialog prints: the browser closed its
/// print dialog but deliberately never reveals Print vs Cancel.
const String kDialogOutcomeUnknown = 'DIALOG_OUTCOME_UNKNOWN';

/// What actually happened to a print, beyond bare success/failure — because
/// "success" is not one thing:
///
/// * [printed] — the pipeline VERIFIED delivery (raw bytes acknowledged by a
///   USB/serial/BLE/relay/TCP transport, or a system print job accepted).
/// * [dialogShown] — the browser print dialog was shown and closed; whether
///   the user hit Print or Cancel is unknowable (no web API reveals it).
/// * [cancelled] / [failed] — the failure cases, typed via [PrintErrorCode].
enum PrintOutcome { printed, dialogShown, cancelled, failed }

extension PrintResultErrorCatalog on PrintResult {
  /// The typed category behind [errorCode]; [PrintErrorCode.none] on success.
  PrintErrorCode get errorKind {
    if (success) return PrintErrorCode.none;
    return _codeTable[errorCode] ?? PrintErrorCode.unknown;
  }

  /// The honest outcome — distinguishes verified delivery from
  /// dialog-shown-but-unknowable. Switch on this instead of [success] when
  /// the difference matters.
  PrintOutcome get outcome {
    if (!success) {
      return errorKind == PrintErrorCode.cancelled
          ? PrintOutcome.cancelled
          : PrintOutcome.failed;
    }
    return errorCode == kDialogOutcomeUnknown
        ? PrintOutcome.dialogShown
        : PrintOutcome.printed;
  }

  /// How long the browser print dialog stayed open, in milliseconds — the
  /// one Print-vs-Cancel signal the web platform leaks (`window.print()`
  /// blocks while the dialog is open). Null outside the dialog flow.
  int? get dialogDurationMs =>
      outcome == PrintOutcome.dialogShown ? _parseDialogMs(errorMessage) : null;

  /// A best-effort guess from [dialogDurationMs] — see [DialogOutcomeGuess]
  /// for its error modes. [DialogOutcomeGuess.notApplicable] outside the
  /// dialog flow.
  DialogOutcomeGuess get dialogGuess =>
      _guessFromMs(outcome == PrintOutcome.dialogShown
          ? _parseDialogMs(errorMessage)
          : null);
}

/// A heuristic reading of the dialog-open time — NOT a fact:
///
/// * [likelyCancelled] — closed in under ~1.2 s. Caveat: pressing Enter
///   immediately PRINTS in Chrome, so a decisive user can print this fast.
/// * [likelyPrinted] — open ≥ ~2.5 s (preview rendered + a click happened).
///   Caveat: a user can also browse the dialog and still cancel.
/// * [unknown] — the ambiguous middle, or no measurement.
///
/// For a definitive answer use [PrintOutcomeConfirmation.markJobOutcome]
/// (ask the user), or a verified path (raw transport / Web Printing job).
enum DialogOutcomeGuess { likelyPrinted, likelyCancelled, unknown, notApplicable }

int? _parseDialogMs(String s) {
  final m = RegExp(r'dialogMs=(\d+)').firstMatch(s);
  return m == null ? null : int.parse(m.group(1)!);
}

DialogOutcomeGuess _guessFromMs(int? ms) {
  if (ms == null) return DialogOutcomeGuess.notApplicable;
  if (ms < 1200) return DialogOutcomeGuess.likelyCancelled;
  if (ms >= 2500) return DialogOutcomeGuess.likelyPrinted;
  return DialogOutcomeGuess.unknown;
}

/// Why a print job ended unsuccessfully — surfaced from IPP
/// printer-state-reasons (paper out, jam, …) where the platform reports them.
enum PrintJobFailureReason {
  /// The job did not fail.
  none,

  /// Out of paper (IPP media-empty / media-needed).
  mediaEmpty,

  /// Paper jam (IPP media-jam).
  mediaJam,

  /// Out of toner/ink (IPP toner-empty / marker-supply-empty).
  tonerEmpty,

  /// Toner/ink low (IPP toner-low / marker-supply-low).
  tonerLow,

  /// A cover or door is open.
  coverOpen,

  /// The printer is offline or stopped.
  printerOffline,

  /// The job was cancelled.
  cancelled,

  /// The job aborted without a more specific reason.
  aborted,

  /// The failure text carried no recognizable reason code.
  unknown,
}

const Map<String, PrintJobFailureReason> _reasonTable = {
  'MEDIA_EMPTY': PrintJobFailureReason.mediaEmpty,
  'MEDIA_JAM': PrintJobFailureReason.mediaJam,
  'TONER_EMPTY': PrintJobFailureReason.tonerEmpty,
  'TONER_LOW': PrintJobFailureReason.tonerLow,
  'COVER_OPEN': PrintJobFailureReason.coverOpen,
  'PRINTER_OFFLINE': PrintJobFailureReason.printerOffline,
  'JOB_CANCELLED': PrintJobFailureReason.cancelled,
  'JOB_ABORTED': PrintJobFailureReason.aborted,
  'CANCELLED': PrintJobFailureReason.cancelled,
};

extension PrintJobFailureCatalog on PrintJob {
  /// The honest outcome of a finished job — see [PrintOutcome]. Jobs still
  /// pending/printing report null.
  PrintOutcome? get outcome => switch (state) {
        PrintState.completed => errorMessage.contains(kDialogOutcomeUnknown)
            ? PrintOutcome.dialogShown
            : PrintOutcome.printed,
        PrintState.cancelled => PrintOutcome.cancelled,
        PrintState.failed => PrintOutcome.failed,
        _ => null,
      };

  /// Parses the "[REASON] detail" convention in [errorMessage]; failed jobs
  /// without a recognized code report [PrintJobFailureReason.unknown].
  PrintJobFailureReason get failureReason {
    if (state != PrintState.failed && state != PrintState.cancelled) {
      return PrintJobFailureReason.none;
    }
    final m = RegExp(r'^\[([A-Z_]+)\]').firstMatch(errorMessage);
    if (m != null) {
      return _reasonTable[m.group(1)] ?? PrintJobFailureReason.unknown;
    }
    // Raw-transport failures store "CODE|message".
    final bar = errorMessage.indexOf('|');
    if (bar > 0) {
      final code = errorMessage.substring(0, bar);
      if (code == 'CANCELLED') return PrintJobFailureReason.cancelled;
    }
    return state == PrintState.cancelled
        ? PrintJobFailureReason.cancelled
        : PrintJobFailureReason.unknown;
  }
}

extension NitroPrintingJobsX on NitroPrinting {
  /// The most recently created print job, or null when none exist.
  Future<PrintJob?> lastPrintJob() async {
    final count = await getPrintJobsCount();
    if (count <= 0) return null;
    final result = await getPrintJobAt(count - 1);
    return result is NitroOk<PrintJob> ? result.value : null;
  }
}
