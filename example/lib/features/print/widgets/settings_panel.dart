import 'package:flutter/material.dart';
import 'package:nitro_printing/nitro_printing.dart' as p;

class SettingsPanel extends StatelessWidget {
  final p.PaperSize paperSize;
  final double orientationDegrees;
  final p.PrintQuality quality;
  final bool color;
  final bool duplex;
  final int copies;
  final int pagesPerSheet;
  final ValueChanged<p.PaperSize> onPaperSize;
  final ValueChanged<double> onOrientationDegrees;
  final ValueChanged<p.PrintQuality> onQuality;
  final ValueChanged<bool> onColor;
  final ValueChanged<bool> onDuplex;
  final ValueChanged<int> onCopies;
  final ValueChanged<int> onPagesPerSheet;

  const SettingsPanel({
    super.key,
    required this.paperSize,
    required this.orientationDegrees,
    required this.quality,
    required this.color,
    required this.duplex,
    required this.copies,
    required this.pagesPerSheet,
    required this.onPaperSize,
    required this.onOrientationDegrees,
    required this.onQuality,
    required this.onColor,
    required this.onDuplex,
    required this.onCopies,
    required this.onPagesPerSheet,
  });

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
                Expanded(
                  child: DropdownTile<p.PaperSize>(
                    label: 'Paper Size',
                    value: paperSize,
                    items: p.PaperSize.values,
                    labelOf: (v) => v.name.toUpperCase(),
                    onChanged: onPaperSize,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownTile<double>(
                    label: 'Orientation',
                    value: orientationDegrees,
                    items: const [0.0, 90.0, 180.0, 270.0],
                    labelOf: _orientationLabel,
                    onChanged: onOrientationDegrees,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            DropdownTile<p.PrintQuality>(
              label: 'Print Quality',
              value: quality,
              items: p.PrintQuality.values,
              labelOf: (v) => v.name[0].toUpperCase() + v.name.substring(1),
              onChanged: onQuality,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: DropdownTile<int>(
                    label: 'Print Copies',
                    value: copies,
                    items: const [1, 2, 3, 4, 5],
                    labelOf: (v) => '$v copies',
                    onChanged: onCopies,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownTile<int>(
                    label: 'Layout Page Count',
                    value: pagesPerSheet,
                    items: const [1, 2, 4, 6, 8],
                    labelOf: (v) => v == 1 ? '1 page/sheet' : '$v pages/sheet',
                    onChanged: onPagesPerSheet,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            const Divider(color: Color(0xFF1E293B)),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: ToggleWidget(
                    label: 'Full Color Output',
                    value: color,
                    onChanged: onColor,
                  ),
                ),
                Expanded(
                  child: ToggleWidget(
                    label: '2-Sided Duplex',
                    value: duplex,
                    onChanged: onDuplex,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _orientationLabel(double deg) => switch (deg) {
    0.0 => 'Portrait',
    90.0 => 'Landscape',
    180.0 => 'Reverse Portrait',
    270.0 => 'Reverse Landscape',
    _ => '${deg.toStringAsFixed(0)}°',
  };
}

class DropdownTile<T> extends StatelessWidget {
  final String label;
  final T value;
  final List<T> items;
  final String Function(T) labelOf;
  final ValueChanged<T> onChanged;

  const DropdownTile({
    super.key,
    required this.label,
    required this.value,
    required this.items,
    required this.labelOf,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return InputDecorator(
      decoration: InputDecoration(
        labelText: label,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
        isDense: true,
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          isDense: true,
          isExpanded: true,
          icon: const Icon(
            Icons.keyboard_arrow_down_rounded,
            color: Color(0xFF64748B),
          ),
          items: items
              .map(
                (v) => DropdownMenuItem(
                  value: v,
                  child: Text(
                    labelOf(v),
                    style: const TextStyle(
                      fontSize: 13,
                      color: Color(0xFFE2E8F0),
                    ),
                  ),
                ),
              )
              .toList(),
          onChanged: (v) {
            if (v != null) onChanged(v);
          },
        ),
      ),
    );
  }
}

class ToggleWidget extends StatelessWidget {
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;
  const ToggleWidget({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Switch.adaptive(
          value: value,
          onChanged: onChanged,
          activeThumbColor: const Color(0xFF6366F1),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: Color(0xFFCBD5E1),
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}
