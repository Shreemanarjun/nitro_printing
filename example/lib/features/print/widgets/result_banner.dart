import 'package:flutter/material.dart';

class ResultBanner extends StatelessWidget {
  final String result;
  const ResultBanner({super.key, required this.result});

  @override
  Widget build(BuildContext context) {
    final ok = result.startsWith('OK') || result.startsWith('Batch:');
    final color = ok ? const Color(0xFF10B981) : const Color(0xFFEF4444);

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(ok ? Icons.check_circle_outline_rounded : Icons.error_outline_rounded, size: 20, color: color),
          const SizedBox(width: 12),
          Expanded(
            child: SelectableText(
              result,
              style: TextStyle(
                fontSize: 13,
                color: color,
                fontWeight: FontWeight.w600,
                fontFamily: 'monospace',
              ),
            ),
          ),
        ],
      ),
    );
  }
}
