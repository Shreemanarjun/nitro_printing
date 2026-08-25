// Nitro Print Agent — a first-party local print agent for web apps.
//
// Wraps nitro_printing's native backends (WinSpool / CUPS / AppKit) behind a
// localhost WebSocket, so a web app using the plugin's `agent:` printerId can
// silently print to ANY OS printer with real, spool-confirmed results and
// live printer/job status — no third-party agent required.
//
// Protocol (JSON text frames):
//   → {id, call: 'version'}
//   → {id, call: 'printers'}
//   → {id, call: 'status', printer}
//   → {id, call: 'print', printer, kind: raw|escpos|zpl|text|image|pdf,
//      data: <base64 or plain text for text/zpl>, copies}
//   ← {id, result: ...} | {id, error: '...'}
//   ← {event: 'printerStatus'|'job', data: {...}}   (pushed, no id)
//
// Port: 9629, overridable with --port or NITRO_PRINT_AGENT_PORT. Binds to
// 127.0.0.1 only. ponytail: no auth token yet — localhost-only binding is the
// v1 boundary; add a token handshake before exposing beyond loopback.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:nitro_printing/nitro_printing.dart';

const _defaultPort = 9629;

final _clients = <WebSocket>{};
final _log = ValueNotifier<List<String>>([]);
final _clientCount = ValueNotifier<int>(0);
int _port = _defaultPort;

void _logLine(String s) {
  final next = [..._log.value, '${DateTime.now().toIso8601String().substring(11, 19)}  $s'];
  _log.value = next.length > 200 ? next.sublist(next.length - 200) : next;
}

void _broadcast(Map<String, Object?> event) {
  final payload = jsonEncode(event);
  for (final ws in _clients) {
    ws.add(payload);
  }
}

Map<String, Object?> _printerJson(PrinterInfo p) => {
      'id': p.id,
      'name': p.name,
      'address': p.address,
      'isDefault': p.isDefault,
      'isAvailable': p.isAvailable,
    };

Map<String, Object?> _resultJson(PrintResult r) => {
      'success': r.success,
      'jobId': r.jobId,
      'errorMessage': r.errorMessage,
      'errorCode': r.errorCode,
    };

Map<String, Object?> _statusJson(PrinterStatusDetail d) => {
      'printerId': d.printerId,
      'isOnline': d.isOnline,
      'isReady': d.isReady,
      'hasPaperJam': d.hasPaperJam,
      'isOutOfPaper': d.isOutOfPaper,
      'isOutOfInk': d.isOutOfInk,
      'printerState': d.printerState,
      'stateReasons': d.stateReasons,
      'statusMessage': d.statusMessage,
      'isDuplexSupported': d.isDuplexSupported,
      'isColorSupported': d.isColorSupported,
    };

Future<Object?> _dispatch(Map<String, dynamic> msg) async {
  final printing = NitroPrinting.instance;
  switch (msg['call']) {
    case 'version':
      return 'nitro-print-agent/0.1.0';
    case 'printers':
      final printers = await printing.getAllPrinters();
      return [for (final p in printers) _printerJson(p)];
    case 'status':
      final detail = await printing.getPrinterStatusDetail(
        msg['printer'] as String? ?? '',
        timeoutSeconds: 5,
      );
      return switch (detail) {
        NitroOk<PrinterStatusDetail>(:final value) => _statusJson(value),
        _ => throw Exception('status unavailable for ${msg['printer']}'),
      };
    case 'print':
      final printer = msg['printer'] as String? ?? '';
      final kind = msg['kind'] as String? ?? 'raw';
      final copies = (msg['copies'] as num?)?.toInt() ?? 1;
      final settings = PrintSettings(printerId: printer, copies: copies);
      final raw = msg['data'] as String? ?? '';
      final result = await switch (kind) {
        'text' => printing.printText(raw, settings: settings),
        'zpl' => printing.printZpl(raw, settings: settings),
        'escpos' => printing.printEscPos(base64Decode(raw), settings: settings),
        'image' => printing.printImage(base64Decode(raw), settings: settings),
        'pdf' => printing.printPdf(base64Decode(raw), settings: settings),
        _ => printing.printRaw(base64Decode(raw), settings: settings),
      };
      _logLine('print $kind → ${printer.isEmpty ? '(default)' : printer}: '
          '${result.success ? 'ok ${result.jobId}' : result.errorMessage}');
      return _resultJson(result);
    default:
      throw Exception('unknown call ${msg['call']}');
  }
}

void _serveClient(WebSocket ws) {
  _clients.add(ws);
  _clientCount.value = _clients.length;
  _logLine('client connected (${_clients.length})');
  ws.listen(
    (message) async {
      if (message is! String) return;
      Map<String, dynamic> msg;
      try {
        msg = jsonDecode(message) as Map<String, dynamic>;
      } catch (_) {
        return;
      }
      final id = msg['id'];
      try {
        final result = await _dispatch(msg);
        ws.add(jsonEncode({'id': id, 'result': result}));
      } catch (e) {
        ws.add(jsonEncode({'id': id, 'error': '$e'}));
      }
    },
    onDone: () {
      _clients.remove(ws);
      _clientCount.value = _clients.length;
      _logLine('client disconnected (${_clients.length})');
    },
    cancelOnError: true,
  );
}

Future<void> _startServer() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, _port);
  _logLine('listening on ws://127.0.0.1:$_port');
  server.listen((req) async {
    if (WebSocketTransformer.isUpgradeRequest(req)) {
      _serveClient(await WebSocketTransformer.upgrade(req));
    } else {
      req.response
        ..statusCode = 200
        ..write('nitro-print-agent/0.1.0');
      await req.response.close();
    }
  });

  final printing = NitroPrinting.instance;
  printing.onPrinterStatusChanged().listen((s) => _broadcast({
        'event': 'printerStatus',
        'data': {
          'printerId': s.printerId,
          'isOnline': s.isOnline,
          'isPrinting': s.isPrinting,
          'statusMessage': s.statusMessage,
          'errorCode': s.errorCode,
        },
      }));
  printing.onPrintJobChanged().listen((j) => _broadcast({
        'event': 'job',
        'data': {
          'jobId': j.jobId,
          'state': j.state.name,
          'progress': j.progress,
          'message': j.message,
        },
      }));
}

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  await ensureNitroPrintingReady();
  final portArg = args.indexOf('--port');
  _port = portArg >= 0 && portArg + 1 < args.length
      ? int.tryParse(args[portArg + 1]) ?? _defaultPort
      : int.tryParse(Platform.environment['NITRO_PRINT_AGENT_PORT'] ?? '') ??
          _defaultPort;
  await _startServer();
  runApp(const AgentApp());
}

class AgentApp extends StatelessWidget {
  const AgentApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Nitro Print Agent',
      theme: ThemeData.dark(useMaterial3: true),
      home: Scaffold(
        appBar: AppBar(title: const Text('Nitro Print Agent')),
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SelectableText('Endpoint: ws://127.0.0.1:$_port'),
              const SizedBox(height: 4),
              ValueListenableBuilder(
                valueListenable: _clientCount,
                builder: (_, count, _) => Text('Connected clients: $count'),
              ),
              const Divider(),
              Expanded(
                child: ValueListenableBuilder(
                  valueListenable: _log,
                  builder: (_, lines, _) => ListView.builder(
                    reverse: true,
                    itemCount: lines.length,
                    itemBuilder: (_, i) => Text(
                      lines[lines.length - 1 - i],
                      style: const TextStyle(
                          fontFamily: 'monospace', fontSize: 12),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
