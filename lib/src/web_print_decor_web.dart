// Web: page decoration reaches the WASM backend's page builders through a
// JS global the dialog and HTML-raster flows read at render time.
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

/// Customizable page decoration for web printing: a background graphic
/// (watermark/letterhead — repeated on every printed page), and rich HTML
/// header/footer that override the plain-text
/// `PrintSettings.headerText`/`footerText`.
///
/// ```dart
/// WebPrintDecor.configure(
///   backgroundHtml:
///       '<img src="data:image/png;base64,…" style="width:100%;opacity:.08">',
///   headerHtml: '<b>ACME Corp</b> — confidential',
/// );
/// await NitroPrinting.instance.printText('…');
/// WebPrintDecor.clear();
/// ```
///
/// External resources are not loaded inside the HTML-raster preview path —
/// use inline content (data: URLs) for graphics.
class WebPrintDecor {
  WebPrintDecor._();

  /// Sets (or, with null, leaves unchanged) the decoration channels.
  static void configure({
    String? backgroundHtml,
    String? headerHtml,
    String? footerHtml,
  }) {
    final decor = _decor();
    if (backgroundHtml != null) decor.setProperty('background'.toJS, backgroundHtml.toJS);
    if (headerHtml != null) decor.setProperty('header'.toJS, headerHtml.toJS);
    if (footerHtml != null) decor.setProperty('footer'.toJS, footerHtml.toJS);
  }

  /// Removes all decoration.
  static void clear() {
    globalContext.setProperty('__nitroWebDecor'.toJS, JSObject());
  }

  static JSObject _decor() {
    var decor = globalContext.getProperty('__nitroWebDecor'.toJS);
    if (decor.isUndefinedOrNull) {
      decor = JSObject();
      globalContext.setProperty('__nitroWebDecor'.toJS, decor);
    }
    return decor as JSObject;
  }
}

/// Configuration for the QZ Tray local print agent
/// (https://github.com/qzind/tray) — the `qz:` printerId transport.
///
/// By default the backend probes QZ Tray's standard localhost endpoints
/// (wss:8181, ws:8182, + fallbacks) only during `startPrinterDiscovery()`.
/// Point [endpoint] at a non-standard agent, or set it before calling
/// `getAllPrinters()` to have agent printers enumerated automatically.
class WebPrintAgent {
  WebPrintAgent._();

  /// Overrides the agent WebSocket endpoint (e.g. `ws://localhost:8182`).
  /// Null restores the default probe list.
  static void configure({String? endpoint}) {
    if (endpoint == null) {
      globalContext.delete('__nitroQzEndpoint'.toJS);
    } else {
      globalContext.setProperty('__nitroQzEndpoint'.toJS, endpoint.toJS);
    }
  }
}

/// Settles a dialog print's unknowable outcome with a definitive answer.
///
/// The browser never reveals Print-vs-Cancel, so the reliable pattern is to
/// ask the user ("Did it print?") and record their answer on the tracked job:
///
/// ```dart
/// final r = await printing.printText('receipt');
/// if (r.outcome == PrintOutcome.dialogShown) {
///   final printed = await askUserDidItPrint(context);
///   PrintOutcomeConfirmation.markJobOutcome(r.jobId, printed: printed);
/// }
/// ```
///
/// The job's state flips to completed/cancelled, `PrintJob.outcome` becomes
/// [definitive] `printed`/`cancelled`, and an `onPrintJobChanged` event fires.
class PrintOutcomeConfirmation {
  PrintOutcomeConfirmation._();

  /// Records the user-confirmed outcome for [jobId]. Returns false when the
  /// job is unknown or still running. No-op (false) outside the web.
  static bool markJobOutcome(String jobId, {required bool printed}) {
    final web = globalContext.getProperty('__nitroWeb'.toJS);
    if (web.isUndefinedOrNull) return false;
    final result = (web as JSObject).callMethod(
      'markJobOutcome'.toJS,
      jobId.toJS,
      printed.toJS,
    );
    return result == true.toJS || (result.dartify() == true);
  }
}
