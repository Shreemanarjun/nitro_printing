import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'info_chips.dart';
import 'hover_button.dart';

class RawPanel extends StatefulWidget {
  final bool loading;
  final Future<void> Function(Uint8List bytes) onSend;

  const RawPanel({super.key, required this.loading, required this.onSend});

  @override
  State<RawPanel> createState() => _RawPanelState();
}

class _RawPanelState extends State<RawPanel> {
  final _hexCtrl = TextEditingController(text: '1B 40 48 65 6C 6C 6F 0A');

  @override
  void dispose() {
    _hexCtrl.dispose();
    super.dispose();
  }

  Uint8List? _parseHex() {
    try {
      final parts = _hexCtrl.text.trim().split(RegExp(r'\s+'));
      if (parts.isEmpty || (parts.length == 1 && parts.first.isEmpty)) {
        return null;
      }
      return Uint8List.fromList(
        parts.map((h) => int.parse(h, radix: 16)).toList(),
      );
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(
              Icons.memory_rounded,
              color: Color(0xFF8B5CF6),
              size: 18,
            ),
            const SizedBox(width: 8),
            const Expanded(
              child: Text(
                'Direct Binary Byte Array Sequence',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
            ),
            const SizedBox(width: 8),
            const InfoChips(items: ['Octet Stream', 'Any Protocol']),
          ],
        ),
        const SizedBox(height: 10),
        const Text(
          'Inject arbitrary hexadecimal byte structures. Input values must consist of space-separated two-digit hex values (e.g. 1B 40 represents ESC @).',
          style: TextStyle(fontSize: 12, color: Color(0xFF64748B)),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _hexCtrl,
          maxLines: 4,
          style: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 13,
            color: Color(0xFF34D399),
          ),
          decoration: const InputDecoration(
            labelText: 'Hexadecimal Raw Stream',
            hintText: '1B 40 48 65 6C 6C 6F 0A',
            alignLabelWithHint: true,
          ),
        ),
        const SizedBox(height: 8),
        ListenableBuilder(
          listenable: _hexCtrl,
          builder: (ctx, _) {
            final bytes = _parseHex();
            return Row(
              children: [
                Icon(
                  bytes != null
                      ? Icons.check_circle_rounded
                      : Icons.info_outline_rounded,
                  size: 13,
                  color: bytes != null
                      ? const Color(0xFF10B981)
                      : const Color(0xFFEF4444),
                ),
                const SizedBox(width: 6),
                Text(
                  bytes != null
                      ? 'Parsed successfully: ${bytes.length} binary byte(s)'
                      : 'Malformed hex values detected',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: bytes != null
                        ? const Color(0xFF10B981)
                        : const Color(0xFFEF4444),
                  ),
                ),
              ],
            );
          },
        ),
        const SizedBox(height: 20),
        SizedBox(
          width: double.infinity,
          child: HoverButton(
            onPressed: widget.loading
                ? null
                : () {
                    final bytes = _parseHex();
                    if (bytes == null) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Invalid Hex sequence!')),
                      );
                      return;
                    }
                    widget.onSend(bytes);
                  },
            icon: Icons.send_rounded,
            label: 'Send Raw Byte Sequence',
          ),
        ),
      ],
    );
  }
}
