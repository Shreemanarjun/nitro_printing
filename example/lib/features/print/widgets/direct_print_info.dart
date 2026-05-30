import 'package:flutter/material.dart';

class DirectPrintInfo extends StatelessWidget {
  final TextEditingController controller;
  const DirectPrintInfo({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'ROUTING ADDRESS',
              style: Theme.of(
                context,
              ).textTheme.labelLarge?.copyWith(color: const Color(0xFF64748B)),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                labelText: 'Direct Destination Printer ID / URL',
                hintText: 'e.g. ipp://192.168.1.10/ipp/print or Office-Jet',
                prefixIcon: Icon(
                  Icons.router_rounded,
                  color: Color(0xFF64748B),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.info_outline_rounded,
                  size: 14,
                  color: Color(0xFF64748B),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'iOS expects an AirPrint ipp:// connection. macOS uses exact Printer System Names. Leaves blank to auto-fallback.',
                    style: TextStyle(
                      fontSize: 11,
                      color: const Color(0xFF64748B).withValues(alpha: 0.9),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
