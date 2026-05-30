import 'package:flutter/material.dart';

class ModeSwitcher extends StatelessWidget {
  final bool showDialog;
  final ValueChanged<bool> onChanged;
  const ModeSwitcher({
    super.key,
    required this.showDialog,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'INTERACTION ROUTE',
              style: Theme.of(
                context,
              ).textTheme.labelLarge?.copyWith(color: const Color(0xFF64748B)),
            ),
            const SizedBox(height: 12),
            LayoutBuilder(
              builder: (context, constraints) {
                return ToggleButtons(
                  direction: Axis.horizontal,
                  onPressed: (index) => onChanged(index == 0),
                  isSelected: [showDialog, !showDialog],
                  borderRadius: BorderRadius.circular(10),
                  selectedColor: Colors.white,
                  fillColor: const Color(0xFF6366F1),
                  color: const Color(0xFF94A3B8),
                  constraints: BoxConstraints(
                    minWidth: (constraints.maxWidth - 4) / 2,
                    minHeight: 48,
                  ),
                  children: const [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.open_in_new_rounded, size: 16),
                        SizedBox(width: 8),
                        Text(
                          'System Dialog',
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.flash_on_rounded, size: 16),
                        SizedBox(width: 8),
                        Text(
                          'Direct Dispatch',
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ],
                );
              },
            ),
            const SizedBox(height: 12),
            Text(
              showDialog
                  ? 'Delegates to the OS-native UI print dialogue window. Presets are loaded pre-filled.'
                  : 'Bypasses visual prompts. Forwards document payloads instantly to the targeted network ID.',
              style: const TextStyle(fontSize: 12, color: Color(0xFF64748B)),
            ),
          ],
        ),
      ),
    );
  }
}
