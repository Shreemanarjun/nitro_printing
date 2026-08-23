import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:nitro_printing/nitro_printing.dart' as p;

import 'pdf_view.dart';

/// Full-width live print preview: re-renders (debounced) whenever the text or
/// settings change, and reports what the printed document will actually be —
/// page count, output size, paper geometry, and which settings shaped it.
class PreviewPanel extends StatefulWidget {
  final String text;
  final p.PrintSettings settings;

  /// When true the panel expands to its parent's full height and the PDF
  /// surface fills the remaining space (side-pane layout).
  final bool fillHeight;
  const PreviewPanel({
    super.key,
    required this.text,
    required this.settings,
    this.fillHeight = false,
  });

  @override
  State<PreviewPanel> createState() => _PreviewPanelState();
}

class _PreviewPanelState extends State<PreviewPanel> {
  Timer? _debounce;
  Uint8List? _pdf;
  int _pages = 0;
  int _sheets = 0;
  int _renderMs = 0;
  DateTime? _renderedAt;
  bool _rendering = false;
  bool _expanded = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _render();
  }

  @override
  void didUpdateWidget(PreviewPanel old) {
    super.didUpdateWidget(old);
    if (old.text != widget.text || old.settings != widget.settings) {
      _debounce?.cancel();
      _debounce = Timer(const Duration(milliseconds: 400), _render);
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _render() async {
    if (!mounted) return;
    setState(() => _rendering = true);
    final sw = Stopwatch()..start();
    try {
      final doc = p.PrintDocument(
        id: 'preview',
        title: widget.settings.jobName,
        type: p.DocumentType.plainText,
        data: Uint8List.fromList(widget.text.codeUnits),
      );
      final printing = p.NitroPrinting.instance;
      final preview = await printing.renderPreview(
        doc,
        settings: widget.settings,
      );
      final pages = await printing.getPageCount(doc);
      if (!mounted) return;
      setState(() {
        _pdf = preview.bytes.isEmpty ? null : preview.bytes;
        _pages = pages;
        _sheets = _countSheets(preview.bytes);
        _renderMs = sw.elapsedMilliseconds;
        _renderedAt = DateTime.now();
        _rendering = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _rendering = false;
        _error = '$e';
      });
    }
  }

  /// Physical sheet count from the generated PDF's page tree — differs from
  /// the document page count when copies or N-up layout are active.
  static int _countSheets(Uint8List bytes) {
    final m = RegExp(r'/Count (\d+)')
        .firstMatch(String.fromCharCodes(bytes.take(200000)));
    return m == null ? 0 : int.parse(m.group(1)!);
  }

  String get _paperLabel {
    final s = widget.settings;
    final size = switch (s.paperSize) {
      p.PaperSize.a4 => 'A4',
      p.PaperSize.a5 => 'A5',
      p.PaperSize.letter => 'Letter',
      p.PaperSize.legal => 'Legal',
      p.PaperSize.custom =>
        '${s.customPaperWidth.toStringAsFixed(0)}×${s.customPaperHeight.toStringAsFixed(0)}pt',
    };
    final landscape = s.orientationDegrees % 180 == 90;
    return '$size · ${landscape ? 'landscape' : 'portrait'}';
  }

  List<Widget> _settingChips(BuildContext context) {
    final s = widget.settings;
    Widget chip(IconData icon, String label, {bool active = true}) => Chip(
          avatar: Icon(icon,
              size: 14,
              color: active ? const Color(0xFF6366F1) : Colors.grey),
          label: Text(label, style: const TextStyle(fontSize: 11)),
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
        );
    return [
      chip(Icons.crop_portrait_rounded, _paperLabel),
      chip(Icons.copy_rounded,
          '${s.copies} cop${s.copies == 1 ? 'y' : 'ies'}${s.copies > 1 ? (s.collate ? ' · collated' : ' · uncollated') : ''}'),
      if (s.pagesPerSheet > 1)
        chip(Icons.grid_view_rounded, '${s.pagesPerSheet}-up'),
      if (!s.color) chip(Icons.filter_b_and_w_rounded, 'grayscale'),
      if (s.pageRangeFrom > 0 || s.pageRangeTo > 0)
        chip(Icons.filter_1_rounded,
            'pages ${s.pageRangeFrom > 0 ? s.pageRangeFrom : 1}–${s.pageRangeTo > 0 ? s.pageRangeTo : '∞'}'),
      if (s.headerText.isNotEmpty) chip(Icons.vertical_align_top_rounded, 'header'),
      if (s.footerText.isNotEmpty)
        chip(Icons.vertical_align_bottom_rounded, 'footer'),
      if (s.duplex) chip(Icons.flip_rounded, 'duplex'),
    ];
  }

  Widget _stat(BuildContext context, String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: Theme.of(context)
                .textTheme
                .labelSmall
                ?.copyWith(color: Colors.grey)),
        const SizedBox(height: 2),
        Text(value,
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.w600)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final pdf = _pdf;
    final kb = pdf == null ? '—' : (pdf.length / 1024).toStringAsFixed(1);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: widget.fillHeight ? MainAxisSize.max : MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.preview_rounded,
                    size: 18, color: Color(0xFF6366F1)),
                const SizedBox(width: 8),
                Text('LIVE PREVIEW',
                    style: Theme.of(context).textTheme.labelLarge),
                const SizedBox(width: 12),
                if (_rendering)
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else if (_renderedAt != null)
                  Text(
                    'rendered in ${_renderMs}ms',
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: Colors.grey),
                  ),
                const Spacer(),
                IconButton(
                  tooltip: 'Re-render now',
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  onPressed: _rendering ? null : _render,
                ),
                if (!widget.fillHeight)
                  IconButton(
                    tooltip: _expanded ? 'Collapse' : 'Expand',
                    icon: Icon(
                        _expanded
                            ? Icons.unfold_less_rounded
                            : Icons.unfold_more_rounded,
                        size: 18),
                    onPressed: () => setState(() => _expanded = !_expanded),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 32,
              runSpacing: 12,
              children: [
                _stat(context, 'PAGES', '$_pages'),
                _stat(context, 'SHEETS', _sheets > 0 ? '$_sheets' : '—'),
                _stat(context, 'PDF SIZE', '$kb KB'),
                _stat(context, 'PAPER', _paperLabel),
                _stat(
                  context,
                  'JOB NAME',
                  widget.settings.jobName.isEmpty
                      ? '—'
                      : widget.settings.jobName,
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(spacing: 6, runSpacing: 4, children: _settingChips(context)),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!,
                  style:
                      const TextStyle(color: Colors.redAccent, fontSize: 12)),
            ],
            if (widget.fillHeight) ...[
              const SizedBox(height: 16),
              Expanded(
                child: pdf == null
                    ? Center(
                        child: Text('no output',
                            style: Theme.of(context).textTheme.bodySmall),
                      )
                    : ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: PdfView(bytes: pdf),
                      ),
              ),
            ] else if (pdf != null && _expanded) ...[
              const SizedBox(height: 16),
              SizedBox(
                height: 460,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: PdfView(bytes: pdf),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
