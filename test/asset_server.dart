// Serves assets/web/ to the browser test with permissive CORS and reports the
// port. Runs on the VM as a hybrid isolate.
//
// Also accepts WebSocket upgrades on /raw and reports each binary message's
// byte count over the channel — the ws:// relay transport's end-to-end test
// target (browser wasm → WebSocket → this server, standing in for websockify).
import 'dart:io';

import 'package:stream_channel/stream_channel.dart';

Future<void> hybridMain(StreamChannel<Object?> channel) async {
  final dir = Directory.current.path;
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    if (req.uri.path == '/raw' &&
        WebSocketTransformer.isUpgradeRequest(req)) {
      final ws = await WebSocketTransformer.upgrade(req);
      ws.listen((message) {
        if (message is List<int>) {
          channel.sink.add('raw:${message.length}');
        }
      });
      return;
    }
    final name = req.uri.path.split('/').last;
    final file = File('$dir/assets/web/$name');
    req.response.headers.set('Access-Control-Allow-Origin', '*');
    if (!file.existsSync()) {
      req.response.statusCode = 404;
      await req.response.close();
      return;
    }
    // The .wasm MUST be served as application/wasm or instantiateStreaming
    // refuses it.
    req.response.headers.contentType = name.endsWith('.wasm')
        ? ContentType('application', 'wasm')
        : ContentType('text', 'javascript');
    await req.response.addStream(file.openRead());
    await req.response.close();
  });
  channel.sink.add(server.port);
  await channel.stream.drain<void>();
}
