export 'package:nitro/nitro.dart' show NitroResultValue, NitroOk, NitroErr;
export 'src/nitro_printing.native.dart';
// Web needs the WASM module instantiated before first use; a no-op on native.
export 'src/nitro_printing.platform.g.dart' show ensureNitroPrintingReady;
// Typed error/job-failure catalog + lastPrintJob helper.
export 'src/print_error_catalog.dart';
// Web page decoration (background graphics, HTML header/footer).
export 'src/web_print_decor.dart';
export 'src/print_settings_page.dart';
