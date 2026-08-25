/// Page decoration for web printing (background graphics + HTML header/
/// footer). A no-op everywhere else.
library;

export 'web_print_decor_stub.dart'
    if (dart.library.js_interop) 'web_print_decor_web.dart';
