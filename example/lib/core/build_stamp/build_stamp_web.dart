import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// This build's checksum: a SHA-256 over the compiled main.dart.js, so any
/// rebuild — even without a version bump — shows a different stamp.
Future<String> buildStamp() async {
  try {
    final resp = await web.window.fetch('main.dart.js'.toJS).toDart;
    final buf = await resp.arrayBuffer().toDart;
    final digest = await web.window.crypto.subtle
        .digest('SHA-256'.toJS, buf)
        .toDart as JSArrayBuffer;
    final hex = digest.toDart
        .asUint8List()
        .take(4)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    return 'build $hex';
  } catch (_) {
    return '';
  }
}
