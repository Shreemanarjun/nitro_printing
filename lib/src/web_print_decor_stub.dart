// Native platforms: page decoration is handled by the OS print stack —
// the web decor hooks are no-ops here.
class WebPrintDecor {
  WebPrintDecor._();

  /// No-op outside the web.
  static void configure({
    String? backgroundHtml,
    String? headerHtml,
    String? footerHtml,
  }) {}

  /// No-op outside the web.
  static void clear() {}
}

/// The QZ Tray agent transport is web-only; native platforms print directly.
class WebPrintAgent {
  WebPrintAgent._();

  /// No-op outside the web.
  static void configure({String? endpoint, String? agentEndpoint}) {}
}

/// Native platforms report real print outcomes — there is nothing to settle.
class PrintOutcomeConfirmation {
  PrintOutcomeConfirmation._();

  /// Always false outside the web.
  static bool markJobOutcome(String jobId, {required bool printed}) => false;
}
