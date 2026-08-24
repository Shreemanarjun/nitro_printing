// Serves assets/web/ to the browser test with permissive CORS and reports the
// port. Runs on the VM as a hybrid isolate.
//
// Also hosts the transport test doubles:
//   /raw   — WebSocket sink reporting each binary message's byte count
//            (the ws:// relay transport's end-to-end target).
//   /qz    — mock QZ Tray agent speaking the real QZ wire protocol.
//   /agent — mock first-party Nitro Print Agent protocol.
//
// NOTE: `nitrogen link` regenerates this file to its stock version — restore
// these handlers after relinking (the browser suite fails all transport tests
// without them).
import 'dart:convert';
import 'dart:io';

import 'package:stream_channel/stream_channel.dart';

/// Minimal mock of the QZ Tray agent wire protocol (JSON calls with `uid`
/// correlation) — enough to e2e-test the `qz:` transport headlessly.
void _mockQzAgent(WebSocket ws, StreamChannel<Object?> channel) {
  ws.listen((message) {
    if (message is! String) return;
    final msg = jsonDecode(message) as Map<String, dynamic>;
    final uid = msg['uid'];
    Object? result;
    switch (msg['call']) {
      case 'getVersion':
        result = '2.2.6-mock';
      case 'printers.find':
        result = ['Mock Printer', 'Mock Receipt'];
      case 'printers.getDefault':
        result = 'Mock Printer';
      case 'print':
        final params = msg['params'] as Map<String, dynamic>;
        final data = (params['data'] as List).first as Map<String, dynamic>;
        final bytes = base64Decode(data['data'] as String);
        final kind = data['format'] == 'pdf' ? 'qzpdf' : 'qzraw';
        channel.sink.add('$kind:${bytes.length}:${params['printer']['name']}');
        result = null;
      case 'printers.startListening':
        result = null;
        // Push a real-style status stream event after acknowledging.
        Future<void>.delayed(const Duration(milliseconds: 50), () {
          ws.add(jsonEncode({
            'type': 'PRINTER',
            'key': 'Mock Printer',
            'event': jsonEncode({
              'printerName': 'Mock Printer',
              'statusText': 'PAPER_OUT',
            }),
          }));
        });
      default:
        result = null; // certificate message and anything else: ack
    }
    if (uid != null) ws.add(jsonEncode({'uid': uid, 'result': result}));
  });
}

/// Minimal mock of the first-party Nitro Print Agent protocol.
void _mockNitroAgent(WebSocket ws, StreamChannel<Object?> channel) {
  ws.listen((message) {
    if (message is! String) return;
    final msg = jsonDecode(message) as Map<String, dynamic>;
    final id = msg['id'];
    Object? result;
    switch (msg['call']) {
      case 'version':
        result = 'nitro-print-agent/mock';
      case 'printers':
        result = [
          {
            'id': 'Office Laser',
            'name': 'Office Laser',
            'address': 'usb',
            'isDefault': true,
            'isAvailable': true,
          },
        ];
      case 'status':
        result = {
          'printerId': msg['printer'],
          'isOnline': true,
          'isReady': false,
          'hasPaperJam': true,
          'isOutOfPaper': false,
          'isOutOfInk': false,
          'printerState': 'stopped',
          'stateReasons': 'media-jam',
          'statusMessage': 'Paper jam',
          'isDuplexSupported': true,
          'isColorSupported': true,
        };
      case 'print':
        final kind = msg['kind'] as String;
        final data = msg['data'] as String;
        final len = (kind == 'text' || kind == 'zpl')
            ? utf8.encode(data).length
            : base64Decode(data).length;
        channel.sink.add('agent$kind:$len:${msg['printer']}');
        result = {
          'success': true,
          'jobId': 'native-42',
          'errorMessage': '',
          'errorCode': '',
        };
        // Native job lifecycle push, as the real agent forwards it.
        Future<void>.delayed(const Duration(milliseconds: 30), () {
          ws.add(jsonEncode({
            'event': 'job',
            'data': {
              'jobId': 'native-42',
              'state': 'completed',
              'progress': 100,
              'message': '',
            },
          }));
        });
      default:
        result = null;
    }
    ws.add(jsonEncode({'id': id, 'result': result}));
  });
}

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
    if (req.uri.path == '/qz' && WebSocketTransformer.isUpgradeRequest(req)) {
      _mockQzAgent(await WebSocketTransformer.upgrade(req), channel);
      return;
    }
    if (req.uri.path == '/agent' &&
        WebSocketTransformer.isUpgradeRequest(req)) {
      _mockNitroAgent(await WebSocketTransformer.upgrade(req), channel);
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
