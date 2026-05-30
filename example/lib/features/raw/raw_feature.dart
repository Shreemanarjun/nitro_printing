import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:nitro_printing/nitro_printing.dart' as p;
import '../../core/repositories/printer_repository.dart';
import '../../core/signals.dart';
import 'raw_signals.dart';
import 'widgets/tab_button.dart';
import 'widgets/esc_pos_panel.dart';
import 'widgets/zpl_panel.dart';
import 'widgets/raw_panel.dart';
import 'widgets/result_banner.dart';

// ── Sample ESC/POS receipt bytes ──────────────────────────────────────────────

Uint8List _sampleEscPos(String text) {
  final lines = <int>[];
  lines.addAll([0x1B, 0x40]); // ESC @ — initialize
  lines.addAll([0x1B, 0x61, 0x01]); // ESC a 1 — center align
  lines.addAll([0x1B, 0x45, 0x01]); // ESC E 1 — bold on
  lines.addAll('NitroPrinting\n'.codeUnits);
  lines.addAll([0x1B, 0x45, 0x00]); // ESC E 0 — bold off
  lines.addAll([0x1B, 0x61, 0x00]); // ESC a 0 — left align
  lines.addAll(text.codeUnits);
  lines.addAll('\n\n\n'.codeUnits);
  lines.addAll([0x1D, 0x56, 0x42, 0x00]); // GS V B 0 — partial cut
  return Uint8List.fromList(lines);
}

// ── Sample ZPL label ──────────────────────────────────────────────────────────

String _sampleZpl(String text) =>
    '''
^XA
^FO50,50^A0N,40,40^FDNitroPrinting^FS
^FO50,110^A0N,28,28^FD$text^FS
^FO50,160^BY2^BCN,60,Y,N,N^FD123456789^FS
^XZ
''';

// ── UI ────────────────────────────────────────────────────────────────────────

class RawTab extends StatefulWidget {
  final PrinterRepository repo;
  const RawTab({super.key, required this.repo});

  @override
  State<RawTab> createState() => _RawTabState();
}

class _RawTabState extends State<RawTab> with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  final _printerCtrl = TextEditingController();
  final _textCtrl = TextEditingController(text: 'Hello from NitroPrinting!');
  final _zplCtrl = TextEditingController();
  final _timeoutCtrl = TextEditingController(text: '30');

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 3, vsync: this);
    _zplCtrl.text = _sampleZpl('Sample Label');
    _tabs.addListener(_onTabChanged);
  }

  @override
  void dispose() {
    _tabs.removeListener(_onTabChanged);
    _tabs.dispose();
    _printerCtrl.dispose();
    _textCtrl.dispose();
    _zplCtrl.dispose();
    _timeoutCtrl.dispose();
    super.dispose();
  }

  void _onTabChanged() {
    if (mounted) setState(() {});
  }

  int get _timeoutSeconds => int.tryParse(_timeoutCtrl.text.trim()) ?? 30;

  p.PrintSettings get _settings => p.PrintSettings(
    printerId: _printerCtrl.text.trim(),
    showPrintDialog: false,
    networkTimeoutSeconds: _timeoutSeconds,
  );

  Future<void> _run(Future<p.PrintResult> Function() fn) async {
    if (_printerCtrl.text.trim().isEmpty) {
      _show(
        'Enter a printer IP or URI first (e.g. 192.168.1.100 or socket://192.168.1.100:9100)',
      );
      return;
    }
    await runRawAction(fn);
  }

  Future<void> _cancel() async {
    final cancelled = await cancelRawPrintAction(widget.repo);
    _show(cancelled ? 'Print job cancelled' : 'No active print to cancel');
  }

  void _show(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg, style: const TextStyle(fontWeight: FontWeight.w500)),
        backgroundColor: const Color(0xFF131B2E),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final isWide = size.width >= 950;

    return ListenableBuilder(
      listenable: createListenableFromSignals([rawLoading, rawResult]),
      builder: (context, _) {
        final loading = rawLoading.value;
        final result = rawResult.value;

        final configCard = Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'PRINTER ENDPOINT',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
                const SizedBox(height: 12),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _printerCtrl,
                        decoration: InputDecoration(
                          labelText: 'Printer TCP Address / URI',
                          hintText:
                              '192.168.1.100 or socket://192.168.1.100:9100',
                          prefixIcon: const Icon(
                            Icons.router_rounded,
                            color: Color(0xFF64748B),
                          ),
                          suffixIcon: IconButton(
                            icon: const Icon(
                              Icons.network_check_rounded,
                              color: Color(0xFF6366F1),
                            ),
                            tooltip: 'Test socket connection',
                            onPressed: loading
                                ? null
                                : () async {
                                    final uri = _printerCtrl.text.trim();
                                    if (uri.isEmpty) return;
                                    await testPrinterConnectionAction(
                                      widget.repo,
                                      uri,
                                      _timeoutSeconds,
                                    );
                                  },
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    SizedBox(
                      width: 100,
                      child: TextField(
                        controller: _timeoutCtrl,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Timeout',
                          suffixText: 's',
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );

        final tabControls = Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  child: Text(
                    'PROTOCOL FORMAT',
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: const Color(0xFF64748B),
                    ),
                  ),
                ),
                TabButton(
                  isSelected: _tabs.index == 0,
                  label: 'ESC/POS Thermal Receipt',
                  icon: Icons.receipt_long_rounded,
                  onTap: () => setState(() => _tabs.animateTo(0)),
                ),
                TabButton(
                  isSelected: _tabs.index == 1,
                  label: 'Zebra ZPL Label Language',
                  icon: Icons.label_important_rounded,
                  onTap: () => setState(() => _tabs.animateTo(1)),
                ),
                TabButton(
                  isSelected: _tabs.index == 2,
                  label: 'Raw Binary Byte Stream',
                  icon: Icons.data_object_rounded,
                  onTap: () => setState(() => _tabs.animateTo(2)),
                ),
              ],
            ),
          ),
        );

        final tabContents = [
          EscPosPanel(
            textCtrl: _textCtrl,
            loading: loading,
            onSend: () => _run(
              () => widget.repo.printEscPos(
                _sampleEscPos(_textCtrl.text),
                settings: _settings,
              ),
            ),
          ),
          ZplPanel(
            zplCtrl: _zplCtrl,
            loading: loading,
            onSend: () => _run(
              () => widget.repo.printZpl(_zplCtrl.text, settings: _settings),
            ),
            onPreview: () {
              showDialog(
                context: context,
                builder: (_) => ZplPreviewDialog(zpl: _zplCtrl.text),
              );
            },
          ),
          RawPanel(
            loading: loading,
            onSend: (bytes) =>
                _run(() => widget.repo.printRaw(bytes, settings: _settings)),
          ),
        ];

        return Scaffold(
          appBar: AppBar(
            title: const Row(
              children: [
                Icon(
                  Icons.terminal_rounded,
                  color: Color(0xFF6366F1),
                  size: 22,
                ),
                SizedBox(width: 10),
                Text(
                  'Low-Level Network Printing',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
            backgroundColor: Colors.transparent,
            elevation: 0,
            bottom: !isWide
                ? TabBar(
                    controller: _tabs,
                    indicatorColor: const Color(0xFF6366F1),
                    labelColor: Colors.white,
                    unselectedLabelColor: const Color(0xFF94A3B8),
                    tabs: const [
                      Tab(
                        icon: Icon(Icons.receipt_long_rounded),
                        text: 'ESC/POS',
                      ),
                      Tab(
                        icon: Icon(Icons.label_important_rounded),
                        text: 'ZPL',
                      ),
                      Tab(
                        icon: Icon(Icons.data_object_rounded),
                        text: 'Raw Bytes',
                      ),
                    ],
                  )
                : null,
          ),
          body: Column(
            children: [
              if (result != null)
                ResultBanner(
                  result: result,
                  onDismiss: () => rawResult.value = null,
                ),
              if (loading)
                Container(
                  color: const Color(0xFFEF4444).withValues(alpha: 0.05),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 8,
                  ),
                  child: Row(
                    children: [
                      const Expanded(
                        child: LinearProgressIndicator(
                          backgroundColor: Color(0xFF1E293B),
                          color: Color(0xFFEF4444),
                        ),
                      ),
                      const SizedBox(width: 16),
                      TextButton.icon(
                        icon: const Icon(Icons.cancel_rounded, size: 16),
                        label: Text(
                          'Cancel',
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ).apply(color: Colors.red),
                        ),
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.red,
                        ),
                        onPressed: _cancel,
                      ),
                    ],
                  ),
                ),
              Expanded(
                child: isWide
                    ? Padding(
                        padding: const EdgeInsets.all(24),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              width: 320,
                              child: ListView(
                                children: [
                                  configCard,
                                  const SizedBox(height: 16),
                                  tabControls,
                                ],
                              ),
                            ),
                            const SizedBox(width: 24),
                            Expanded(
                              child: Card(
                                child: Padding(
                                  padding: const EdgeInsets.all(20),
                                  child: IndexedStack(
                                    index: _tabs.index,
                                    children: tabContents,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      )
                    : TabBarView(
                        controller: _tabs,
                        children: tabContents
                            .map((p) => SingleChildScrollView(child: p))
                            .toList(),
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}
