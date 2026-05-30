import 'package:flutter/material.dart';
import 'info_chips.dart';
import 'hover_button.dart';

class EscPosPanel extends StatelessWidget {
  final TextEditingController textCtrl;
  final bool loading;
  final VoidCallback onSend;

  const EscPosPanel({
    super.key,
    required this.textCtrl,
    required this.loading,
    required this.onSend,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.bolt_rounded, color: Color(0xFF8B5CF6), size: 18),
            const SizedBox(width: 8),
            const Expanded(
              child: Text(
                'ESC/POS Thermal Receipt Payload',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
            ),
            const SizedBox(width: 8),
            const InfoChips(items: ['Port 9100', 'Direct Socket']),
          ],
        ),
        const SizedBox(height: 10),
        const Text(
          'Encodes textual strings into raw ESC/POS byte values. Injects custom header centering commands, bold highlight sequences, and a cutter feed code.',
          style: TextStyle(fontSize: 12, color: Color(0xFF64748B)),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: textCtrl,
          maxLines: 4,
          decoration: const InputDecoration(
            labelText: 'Receipt Body Text Lines',
            hintText: 'Enter text here...',
          ),
        ),
        const SizedBox(height: 16),
        EscPosPreview(text: textCtrl),
        const SizedBox(height: 20),
        SizedBox(
          width: double.infinity,
          child: HoverButton(
            onPressed: loading ? null : onSend,
            icon: Icons.send_rounded,
            label: 'Dispatch ESC/POS Payload',
          ),
        ),
      ],
    );
  }
}

class EscPosPreview extends StatefulWidget {
  final TextEditingController text;
  const EscPosPreview({super.key, required this.text});

  @override
  State<EscPosPreview> createState() => _EscPosPreviewState();
}

class _EscPosPreviewState extends State<EscPosPreview> {
  @override
  void initState() {
    super.initState();
    widget.text.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    widget.text.removeListener(_onTextChanged);
    super.dispose();
  }

  void _onTextChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: const Color(0xFF070A13), // Ultra dark console
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF1E293B)),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.terminal_rounded, color: Color(0xFF64748B), size: 14),
              SizedBox(width: 6),
              Text(
                'LIVE ESC/POS RECEIPT EMULATOR PREVIEW',
                style: TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.5,
                  color: Color(0xFF64748B),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Center(
            child: Container(
              color: Colors.white,
              padding: const EdgeInsets.all(16),
              width: 260,
              child: Column(
                children: [
                  const Text(
                    '━━━━━━━━━━━━━━━━━━━━',
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      color: Colors.black,
                      height: 1.0,
                    ),
                  ),
                  const Text(
                    'NitroPrinting',
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: Colors.black,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    widget.text.text,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      color: Colors.black,
                    ),
                    textAlign: TextAlign.left,
                  ),
                  const SizedBox(height: 12),
                  const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.content_cut, color: Colors.grey, size: 10),
                      Text(
                        ' - - - - - [CUT] - - - - -',
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 8,
                          color: Colors.grey,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
