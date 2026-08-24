import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:nitro_printing/nitro_printing.dart' as p;
import '../../core/repositories/printer_repository.dart';
import '../../core/signals.dart';
import 'print_signals.dart';
import 'widgets/batch_results_card.dart' as widgets;
import 'widgets/decor_panel.dart' as widgets;
import 'widgets/direct_print_info.dart' as widgets;
import 'widgets/mode_switcher.dart' as widgets;
import 'widgets/preview_panel.dart' as widgets;
import 'widgets/print_button.dart' as widgets;
import 'widgets/result_banner.dart' as widgets;
import 'widgets/settings_panel.dart' as widgets;

class PrintTab extends StatefulWidget {
  final PrinterRepository repo;
  const PrintTab({super.key, required this.repo});

  @override
  State<PrintTab> createState() => _PrintTabState();
}

class _PrintTabState extends State<PrintTab> {
  final _textCtrl = TextEditingController(
    text:
        'Hello from NitroPrinting!\n\nThis is a test print.\n'
        'Line 3\nLine 4\nLine 5\nLine 6\nLine 7\nLine 8',
  );
  final _jobCtrl = TextEditingController(text: 'Test Print');
  final _printerIdCtrl = TextEditingController();
  final _headerCtrl = TextEditingController();
  final _footerCtrl = TextEditingController();

  p.PaperSize _paperSize = p.PaperSize.a4;
  double _orientationDegrees = 0.0;
  p.PrintQuality _quality = p.PrintQuality.normal;
  bool _color = true;
  bool _duplex = false;
  bool _collate = true;
  bool _fitToPage = false;
  int _copies = 1;
  int _pagesPerSheet = 1;
  p.MediaType _mediaType = p.MediaType.plain;
  double _marginPt = 0.0;
  int _pageFrom = 0;
  int _pageTo = 0;
  double _customWidth = 420.0;
  double _customHeight = 595.0;
  bool _showDialog = true;
  bool _isHtml = false;

  @override
  void dispose() {
    _textCtrl.dispose();
    _jobCtrl.dispose();
    _printerIdCtrl.dispose();
    _headerCtrl.dispose();
    _footerCtrl.dispose();
    super.dispose();
  }

  p.PrintSettings _build() => p.PrintSettings(
    jobName: _jobCtrl.text,
    headerText: _headerCtrl.text,
    footerText: _footerCtrl.text,
    printerId: _printerIdCtrl.text.trim(),
    paperSize: _paperSize,
    orientationDegrees: _orientationDegrees,
    quality: _quality,
    color: _color,
    duplex: _duplex,
    collate: _collate,
    fitToPage: _fitToPage,
    copies: _copies,
    pagesPerSheet: _pagesPerSheet,
    mediaType: _mediaType,
    marginTop: _marginPt,
    marginBottom: _marginPt,
    marginLeft: _marginPt,
    marginRight: _marginPt,
    pageRangeFrom: _pageFrom,
    pageRangeTo: _pageTo,
    customPaperWidth: _customWidth,
    customPaperHeight: _customHeight,
    showPrintDialog: _showDialog,
  );

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final isWide = size.width >= 900;

    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.print_rounded, color: Color(0xFF6366F1), size: 22),
            SizedBox(width: 10),
            Text(
              'Document Printing Panel',
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
      ),
      body: ListenableBuilder(
        listenable: createListenableFromSignals([
          printResult,
          printLoading,
          batchResults,
        ]),
        builder: (context, _) {
          final loading = printLoading.value;
          final result = printResult.value;
          final batch = batchResults.value;

          final settingsColumn = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'ROUTING & MODE',
                style: Theme.of(context).textTheme.labelLarge,
              ),
              const SizedBox(height: 12),
              widgets.ModeSwitcher(
                showDialog: _showDialog,
                onChanged: (v) => setState(() => _showDialog = v),
              ),
              const SizedBox(height: 16),

              AnimatedCrossFade(
                firstChild: const SizedBox.shrink(),
                secondChild: Column(
                  children: [
                    widgets.DirectPrintInfo(controller: _printerIdCtrl),
                    const SizedBox(height: 16),
                  ],
                ),
                crossFadeState: _showDialog
                    ? CrossFadeState.showFirst
                    : CrossFadeState.showSecond,
                duration: const Duration(milliseconds: 200),
              ),

              Text(
                'DOCUMENT SETTINGS',
                style: Theme.of(context).textTheme.labelLarge,
              ),
              const SizedBox(height: 12),
              widgets.SettingsPanel(
                paperSize: _paperSize,
                orientationDegrees: _orientationDegrees,
                quality: _quality,
                color: _color,
                duplex: _duplex,
                collate: _collate,
                fitToPage: _fitToPage,
                copies: _copies,
                pagesPerSheet: _pagesPerSheet,
                mediaType: _mediaType,
                marginPt: _marginPt,
                pageFrom: _pageFrom,
                pageTo: _pageTo,
                customWidth: _customWidth,
                customHeight: _customHeight,
                onPaperSize: (v) => setState(() => _paperSize = v),
                onOrientationDegrees: (v) =>
                    setState(() => _orientationDegrees = v),
                onQuality: (v) => setState(() => _quality = v),
                onColor: (v) => setState(() => _color = v),
                onDuplex: (v) => setState(() => _duplex = v),
                onCollate: (v) => setState(() => _collate = v),
                onFitToPage: (v) => setState(() => _fitToPage = v),
                onCopies: (v) => setState(() => _copies = v),
                onPagesPerSheet: (v) => setState(() => _pagesPerSheet = v),
                onMediaType: (v) => setState(() => _mediaType = v),
                onMarginPt: (v) => setState(() => _marginPt = v),
                onPageFrom: (v) => setState(() => _pageFrom = v),
                onPageTo: (v) => setState(() => _pageTo = v),
                onCustomWidth: (v) => setState(() => _customWidth = v),
                onCustomHeight: (v) => setState(() => _customHeight = v),
              ),
            ],
          );

          final contentColumn = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'DOCUMENT CONTENT',
                style: Theme.of(context).textTheme.labelLarge,
              ),
              const SizedBox(height: 12),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      SegmentedButton<bool>(
                        segments: const [
                          ButtonSegment(
                            value: false,
                            label: Text('Plain Text'),
                            icon: Icon(Icons.text_snippet_rounded, size: 16),
                          ),
                          ButtonSegment(
                            value: true,
                            label: Text('HTML'),
                            icon: Icon(Icons.code_rounded, size: 16),
                          ),
                        ],
                        selected: {_isHtml},
                        onSelectionChanged: (v) =>
                            setState(() => _isHtml = v.first),
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: _textCtrl,
                        maxLines: 5,
                        onChanged: (_) => setState(() {}),
                        decoration: InputDecoration(
                          labelText: _isHtml
                              ? 'HTML Body Content'
                              : 'Print Text Content',
                          hintText: _isHtml
                              ? '<h1>Invoice</h1><p>Hello <b>world</b></p>'
                              : 'Enter text here...',
                          alignLabelWithHint: true,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _headerCtrl,
                              onChanged: (_) => setState(() {}),
                              decoration: const InputDecoration(
                                labelText: 'Header Text',
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: TextField(
                              controller: _footerCtrl,
                              onChanged: (_) => setState(() {}),
                              decoration: const InputDecoration(
                                labelText: 'Footer Text',
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: _jobCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Job Identifier Name',
                          hintText: 'e.g. Invoice #2041',
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),

              widgets.DecorPanel(),
              const SizedBox(height: 24),

              Text(
                'PRINT ACTIONS',
                style: Theme.of(context).textTheme.labelLarge,
              ),
              const SizedBox(height: 12),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Dispatch standard layout files directly to system drivers or custom network targets.',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                      const SizedBox(height: 16),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          widgets.PrintButton(
                            label: _isHtml ? 'Print HTML' : 'Print Text',
                            icon: _isHtml
                                ? Icons.code_rounded
                                : Icons.text_snippet_rounded,
                            loading: loading,
                            onPressed: () async {
                              updatePrintSettings(_build());
                              await (_isHtml
                                  ? printHtmlAction(widget.repo, _textCtrl.text)
                                  : printTextAction(
                                      widget.repo, _textCtrl.text));
                            },
                          ),
                          widgets.PrintButton(
                            label: 'Print Image',
                            icon: Icons.image_rounded,
                            loading: loading,
                            onPressed: () async {
                              updatePrintSettings(_build());
                              await printImageAction(
                                widget.repo,
                                await _testImage(),
                              );
                            },
                          ),
                          widgets.PrintButton(
                            label: 'Print PDF',
                            icon: Icons.picture_as_pdf_rounded,
                            loading: loading,
                            onPressed: () async {
                              updatePrintSettings(_build());
                              await printPdfAction(widget.repo, _testPdf());
                            },
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),

              Text(
                'BATCH OPERATIONS',
                style: Theme.of(context).textTheme.labelLarge,
              ),
              const SizedBox(height: 12),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Print multiple documents sequentially. Stops on first failure if "Stop on Error" is enabled.',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                      const SizedBox(height: 16),
                      SizedBox(
                        width: double.infinity,
                        child: widgets.PrintButton(
                          label: 'Launch Batch Print (3 documents)',
                          icon: Icons.layers_rounded,
                          loading: loading,
                          highlight: true,
                          onPressed: () async {
                            updatePrintSettings(_build());
                            await runBatchPrintAction(widget.repo, _build());
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );

          final banners = <Widget>[
            if (result != null) widgets.ResultBanner(result: result),
            if (loading)
              const Padding(
                padding: EdgeInsets.only(bottom: 20),
                child: ClipRRect(
                  borderRadius: BorderRadius.all(Radius.circular(4)),
                  child: LinearProgressIndicator(
                    minHeight: 3,
                    backgroundColor: Color(0xFF1E293B),
                    color: Color(0xFF6366F1),
                  ),
                ),
              ),
            if (batch != null) ...[
              widgets.BatchResultsCard(results: batch),
              const SizedBox(height: 20),
            ],
          ];

          if (isWide) {
            // Configuration scrolls on the LEFT; the preview owns the full
            // RIGHT pane height and stays put while settings scroll.
            return Padding(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ...banners,
                  Expanded(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          flex: 11,
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.only(right: 8),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                settingsColumn,
                                const SizedBox(height: 24),
                                contentColumn,
                                const SizedBox(height: 24),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 24),
                        Expanded(
                          flex: 9,
                          child: widgets.PreviewPanel(
                            text: _textCtrl.text,
                            settings: _build(),
                            isHtml: _isHtml,
                            fillHeight: true,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          }

          return ListView(
            padding: const EdgeInsets.all(24),
            children: [
              ...banners,
              settingsColumn,
              const SizedBox(height: 24),
              contentColumn,

              // Live preview below the configuration on narrow layouts.
              const SizedBox(height: 32),
              widgets.PreviewPanel(
                text: _textCtrl.text,
                settings: _build(),
                isHtml: _isHtml,
              ),
              const SizedBox(height: 48),
            ],
          );
        },
      ),
    );
  }

  Future<Uint8List> _testImage() async {
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec, const Rect.fromLTWH(0, 0, 400, 300));
    canvas.drawRect(
      const Rect.fromLTWH(0, 0, 400, 300),
      Paint()..color = const Color(0xFF1E1E38),
    );

    // Paint a gorgeous glowing gradient circle
    final paint = Paint()
      ..shader = ui.Gradient.linear(
        const Offset(120, 70),
        const Offset(280, 230),
        const [Color(0xFF6366F1), Color(0xFF8B5CF6)],
      );
    canvas.drawCircle(const Offset(200, 150), 80, paint);

    // Draw text using paint
    final tp = TextPainter(
      text: const TextSpan(
        text: 'NitroPrinting',
        style: TextStyle(
          color: Colors.white,
          fontSize: 24,
          fontWeight: FontWeight.bold,
          fontFamily: 'monospace',
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(200 - tp.width / 2, 150 - tp.height / 2));
    final pic = rec.endRecording();
    final img = await pic.toImage(400, 300);
    final bd = await img.toByteData(format: ui.ImageByteFormat.png);
    return bd!.buffer.asUint8List();
  }

  Uint8List _testPdf() {
    const src =
        '%PDF-1.4\n'
        '1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n'
        '2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj\n'
        '3 0 obj<</Type/Page/MediaBox[0 0 595 842]/Parent 2 0 R'
        '/Resources<</Font<</F1<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>>>>>'
        '/Contents 4 0 R>>endobj\n'
        '4 0 obj<</Length 58>>\nstream\nBT /F1 24 Tf 100 750 Td (NitroPrinting Demo) Tj ET\nendstream\nendobj\n'
        'xref\n0 5\n0000000000 65535 f\n0000000009 00000 n\n'
        '0000000058 00000 n\n0000000115 00000 n\n0000000250 00000 n\n'
        'trailer<</Size 5/Root 1 0 R>>\nstartxref\n345\n%%EOF';
    return Uint8List.fromList(src.codeUnits);
  }
}
