import 'package:flutter/material.dart';

class InfoChips extends StatelessWidget {
  final List<String> items;
  const InfoChips({super.key, required this.items});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: items
          .map(
            (t) => Container(
              margin: const EdgeInsets.only(left: 6),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xFF1E293B),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: const Color(0xFF334155).withValues(alpha: 0.4)),
              ),
              child: Text(
                t,
                style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Color(0xFF94A3B8)),
              ),
            ),
          )
          .toList(),
    );
  }
}
