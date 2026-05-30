import 'package:flutter/material.dart';
import 'package:nitro_printing/nitro_printing.dart' as p;

class SpoolDetailCard extends StatelessWidget {
  final p.PrintJob job;
  const SpoolDetailCard({super.key, required this.job});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.assignment_rounded, color: Color(0xFF8B5CF6), size: 18),
                const SizedBox(width: 8),
                Text(
                  'SPOOL QUERY RESULT',
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(color: const Color(0xFF8B5CF6)),
                ),
              ],
            ),
            const SizedBox(height: 12),
            DetailRow('Spool Job ID', job.id, mono: true),
            DetailRow('Document Title', job.documentTitle),
            DetailRow('Target Printer', job.printerId, mono: true),
            DetailRow('Spool State', job.state.name.toUpperCase(), highlight: true),
            DetailRow('Queue Progress', '${job.progress}%'),
          ],
        ),
      ),
    );
  }
}

class DetailRow extends StatelessWidget {
  final String label;
  final String value;
  final bool mono;
  final bool highlight;

  const DetailRow(
    this.label,
    this.value, {
    super.key,
    this.mono = false,
    this.highlight = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(fontSize: 12, color: Color(0xFF64748B), fontWeight: FontWeight.w500)),
          Text(
            value,
            style: TextStyle(
              fontSize: 12,
              fontFamily: mono ? 'monospace' : null,
              fontWeight: highlight ? FontWeight.bold : FontWeight.w600,
              color: highlight ? const Color(0xFF8B5CF6) : Colors.white,
            ),
          ),
        ],
      ),
    );
  }
}
