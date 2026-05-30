import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:nitro_printing/nitro_printing.dart' as p;
import '../../core/repositories/printer_repository.dart';
import '../../core/signals.dart';
import 'print_signals.dart';
import 'widgets/batch_results_card.dart' as widgets;
import 'widgets/direct_print_info.dart' as widgets;
import 'widgets/mode_switcher.dart' as widgets;
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

  p.PaperSize _paperSize = p.PaperSize.a4;
  double _orientationDegrees = 0.0;
  p.PrintQuality _quality = p.PrintQuality.normal;
  bool _color = true;
  bool _duplex = false;
  int _copies = 1;
  int _pagesPerSheet = 1;
  bool _showDialog = true;

  @override
  void dispose() {
    _textCtrl.dispose();
    _jobCtrl.dispose();
    _printerIdCtrl.dispose();
    super.dispose();
  }

  p.PrintSettings _build() => p.PrintSettings(
    jobName: _jobCtrl.text,
    printerId: _printerIdCtrl.text.trim(),
    paperSize: _paperSize,
    orientationDegrees: _orientationDegrees,
    quality: _quality,
    color: _color,
    duplex: _duplex,
    copies: _copies,
    pagesPerSheet: _pagesPerSheet,
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
                copies: _copies,
                pagesPerSheet: _pagesPerSheet,
                onPaperSize: (v) => setState(() => _paperSize = v),
                onOrientationDegrees: (v) =>
                    setState(() => _orientationDegrees = v),
                onQuality: (v) => setState(() => _quality = v),
                onColor: (v) => setState(() => _color = v),
                onDuplex: (v) => setState(() => _duplex = v),
                onCopies: (v) => setState(() => _copies = v),
                onPagesPerSheet: (v) => setState(() => _pagesPerSheet = v),
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
                      TextField(
                        controller: _textCtrl,
                        maxLines: 5,
                        decoration: const InputDecoration(
                          labelText: 'Print Text Content',
                          hintText: 'Enter text here...',
                          alignLabelWithHint: true,
                        ),
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
                            label: 'Print Text',
                            icon: Icons.text_snippet_rounded,
                            loading: loading,
                            onPressed: () async {
                              updatePrintSettings(_build());
                              await printTextAction(
                                widget.repo,
                                _textCtrl.text,
                              );
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

          return ListView(
            padding: const EdgeInsets.all(24),
            children: [
              // Result and loading indicators
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

              if (isWide)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: settingsColumn),
                    const SizedBox(width: 24),
                    Expanded(child: contentColumn),
                  ],
                )
              else ...[
                settingsColumn,
                const SizedBox(height: 24),
                contentColumn,
              ],
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
