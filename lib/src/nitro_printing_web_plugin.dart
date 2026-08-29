import 'package:flutter_web_plugins/flutter_web_plugins.dart';

/// Web registration hook for the Flutter plugin system.
///
/// The web backend is the plugin's own C++ core compiled to WASM and loaded by
/// `ensureNitroPrintingReady()` — there is no method channel to wire up, so
/// this does nothing. Flutter still requires a `pluginClass` before a plugin
/// may declare `web:` in its `platforms:` map, and without that declaration
/// pub.dev does not list Web among the supported platforms.
class NitroPrintingWeb {
  /// Called by Flutter's generated web plugin registrant. Intentionally empty.
  static void registerWith(Registrar registrar) {}
}
