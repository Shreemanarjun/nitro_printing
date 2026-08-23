import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:nitro_printing/nitro_printing.dart';

/// Page decoration controls (web): background graphic / watermark plus rich
/// HTML header & footer, applied live through [WebPrintDecor].
class DecorPanel extends StatefulWidget {
  const DecorPanel({super.key});

  @override
  State<DecorPanel> createState() => _DecorPanelState();
}

class _DecorPanelState extends State<DecorPanel> {
  final _background = TextEditingController(
    text:
        '<div style="font-size:96px;color:#6366f1;opacity:.06;'
        'transform:rotate(-30deg);margin-top:40%">DRAFT</div>',
  );
  final _header = TextEditingController();
  final _footer = TextEditingController();
  bool _applied = false;

  @override
  void dispose() {
    _background.dispose();
    _header.dispose();
    _footer.dispose();
    super.dispose();
  }

  void _apply() {
    WebPrintDecor.configure(
      backgroundHtml: _background.text,
      headerHtml: _header.text,
      footerHtml: _footer.text,
    );
    setState(() => _applied = true);
  }

  void _clear() {
    WebPrintDecor.clear();
    setState(() => _applied = false);
  }

  @override
  Widget build(BuildContext context) {
    if (!kIsWeb) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            'Page decoration (background graphics, HTML header/footer) is a '
            'web feature — run this example with flutter run -d chrome.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      );
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.branding_watermark_rounded,
                    size: 18, color: Color(0xFF6366F1)),
                const SizedBox(width: 8),
                Text('PAGE DECORATION',
                    style: Theme.of(context).textTheme.labelLarge),
                const Spacer(),
                if (_applied)
                  const Chip(
                    label: Text('applied'),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _background,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: 'Background HTML (watermark / letterhead)',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _header,
              decoration: const InputDecoration(
                labelText: 'Header HTML (overrides headerText)',
                hintText: '<b>ACME Corp</b>',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _footer,
              decoration: const InputDecoration(
                labelText: 'Footer HTML (overrides footerText)',
                hintText: '<i>confidential</i>',
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                FilledButton.tonal(onPressed: _apply, child: const Text('Apply')),
                const SizedBox(width: 8),
                TextButton(onPressed: _clear, child: const Text('Clear')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
