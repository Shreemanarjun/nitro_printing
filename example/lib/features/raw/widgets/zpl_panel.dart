import 'package:flutter/material.dart';
import 'info_chips.dart';
import 'hover_button.dart';

class ZplPanel extends StatelessWidget {
  final TextEditingController zplCtrl;
  final bool loading;
  final VoidCallback onSend;
  final VoidCallback onPreview;

  const ZplPanel({
    super.key,
    required this.zplCtrl,
    required this.loading,
    required this.onSend,
    required this.onPreview,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.label_rounded, color: Color(0xFF8B5CF6), size: 18),
            const SizedBox(width: 8),
            const Expanded(
              child: Text(
                'ZPL II Programming Language',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.white),
              ),
            ),
            const SizedBox(width: 8),
            const InfoChips(items: ['Zebra', 'TCP Direct']),
          ],
        ),
        const SizedBox(height: 10),
        const Text(
          'Forwards raw Zebra Programming Language scripts to label printer sockets. Standard layout commands must start with ^XA and end with ^XZ tags.',
          style: TextStyle(fontSize: 12, color: Color(0xFF64748B)),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: zplCtrl,
          maxLines: 8,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12, color: Color(0xFF38BDF8)),
          decoration: const InputDecoration(
            labelText: 'ZPL Label Document Stream',
            alignLabelWithHint: true,
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: onPreview,
                icon: const Icon(Icons.code_rounded, size: 16),
                label: const Text('View Raw Code', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: HoverButton(
                onPressed: loading ? null : onSend,
                icon: Icons.send_rounded,
                label: 'Transmit ZPL Label',
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class ZplPreviewDialog extends StatelessWidget {
  final String zpl;
  const ZplPreviewDialog({super.key, required this.zpl});

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF0F172A),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: Color(0xFF1E293B)),
      ),
      child: Container(
        padding: const EdgeInsets.all(24),
        constraints: const BoxConstraints(maxWidth: 500),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.code_rounded, color: Color(0xFF6366F1), size: 20),
                SizedBox(width: 8),
                Text(
                  'ZPL Byte Layout Output',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFF070A13),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFF1E293B)),
              ),
              height: 240,
              child: SingleChildScrollView(
                child: SelectableText(
                  zpl,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12, color: Color(0xFF38BDF8)),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Align(
              alignment: Alignment.bottomRight,
              child: FilledButton(
                style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1E293B)),
                onPressed: () => Navigator.pop(context),
                child: const Text('Close Workspace'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
