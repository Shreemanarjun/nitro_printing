import 'package:flutter/material.dart';
import 'package:nitro_printing/nitro_printing.dart' as p;

class BatchResultsCard extends StatelessWidget {
  final List<p.PrintResult> results;
  const BatchResultsCard({super.key, required this.results});

  @override
  Widget build(BuildContext context) {
    final successes = results.where((r) => r.success).length;
    final isSuccessAll = successes == results.length;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.layers_outlined, size: 20, color: Color(0xFF6366F1)),
                const SizedBox(width: 8),
                Text('BATCH DISPATCH STATUS', style: Theme.of(context).textTheme.labelLarge),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: (isSuccessAll ? const Color(0xFF10B981) : const Color(0xFFEF4444)).withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: (isSuccessAll ? const Color(0xFF10B981) : const Color(0xFFEF4444)).withValues(alpha: 0.3)),
                  ),
                  child: Text(
                    '$successes OF ${results.length} SUCCESS',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: isSuccessAll ? const Color(0xFF10B981) : const Color(0xFFEF4444),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ...results.asMap().entries.map((e) {
              final i = e.key;
              final r = e.value;
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Icon(
                      r.success ? Icons.check_circle_outline_rounded : Icons.cancel_outlined,
                      size: 16,
                      color: r.success ? const Color(0xFF10B981) : const Color(0xFFEF4444),
                    ),
                    const SizedBox(width: 10),
                    Text('Document #${i + 1}: ', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFFCBD5E1))),
                    Expanded(
                      child: Text(
                        r.success ? 'Success (jobId: ${r.jobId})' : '${r.errorCode}: ${r.errorMessage}',
                        style: TextStyle(
                          fontSize: 12,
                          color: r.success ? const Color(0xFF10B981) : const Color(0xFFEF4444),
                          fontFamily: 'monospace',
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              );
            }),
          ],
        ),
      ),
    );
  }
}
