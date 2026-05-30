import 'package:flutter/material.dart';
import 'package:nitro_printing/nitro_printing.dart' as p;

class PrinterStatusDetailCard extends StatelessWidget {
  final p.PrinterStatusDetail detail;
  const PrinterStatusDetailCard({super.key, required this.detail});

  @override
  Widget build(BuildContext context) {
    final stateColor = detail.printerState == 'idle'
        ? const Color(0xFF10B981) // Green
        : detail.printerState == 'processing'
        ? const Color(0xFFF59E0B) // Amber
        : const Color(0xFFEF4444); // Red

    return Card(
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: LinearGradient(
            colors: [
              const Color(0xFF1E293B).withValues(alpha: 0.2),
              const Color(0xFF0F172A).withValues(alpha: 0.0),
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Status Header Row
            Row(
              children: [
                PulsingIndicator(isOnline: detail.isOnline),
                const SizedBox(width: 10),
                Text(
                  detail.isOnline ? 'ONLINE' : 'OFFLINE',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.0,
                    color: detail.isOnline
                        ? const Color(0xFF10B981)
                        : const Color(0xFFEF4444),
                  ),
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: stateColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: stateColor.withValues(alpha: 0.3),
                      width: 1,
                    ),
                  ),
                  child: Text(
                    (detail.printerState.isEmpty
                            ? 'unknown'
                            : detail.printerState)
                        .toUpperCase(),
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.5,
                      color: stateColor,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),

            // Alert indicators Wrap
            if (detail.hasPaperJam ||
                detail.isOutOfPaper ||
                detail.isOutOfInk ||
                detail.isWarmingUp) ...[
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (detail.hasPaperJam)
                    const Alert('PAPER JAM', Color(0xFFEF4444)),
                  if (detail.isOutOfPaper)
                    const Alert('OUT OF PAPER', Color(0xFFF59E0B)),
                  if (detail.isOutOfInk)
                    const Alert('LOW TONER/INK', Color(0xFFF59E0B)),
                  if (detail.isWarmingUp)
                    const Alert('WARMING UP', Color(0xFF3B82F6)),
                ],
              ),
              const SizedBox(height: 16),
            ],

            // Stats in rounded rows
            StatRow(
              'Jobs in queue',
              '${detail.jobsInQueue}',
              icon: Icons.queue_rounded,
            ),
            if (detail.stateReasons.isNotEmpty)
              StatRow(
                'State reasons',
                detail.stateReasons,
                icon: Icons.troubleshoot_rounded,
                mono: true,
              ),
            if (detail.statusMessage.isNotEmpty)
              StatRow(
                'Status message',
                detail.statusMessage,
                icon: Icons.messenger_outline_rounded,
              ),
            if (detail.errorCode.isNotEmpty)
              StatRow(
                'Error code',
                detail.errorCode,
                icon: Icons.bug_report_rounded,
                mono: true,
              ),

            const SizedBox(height: 20),
            const Divider(color: Color(0xFF1E293B)),
            const SizedBox(height: 10),

            // Ink/toner levels
            if (detail.inkLevelBlack >= 0 ||
                detail.inkLevelCyan >= 0 ||
                detail.inkLevelMagenta >= 0 ||
                detail.inkLevelYellow >= 0 ||
                detail.tonerLevel >= 0) ...[
              Text(
                'CONSUMABLES LEVEL',
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: const Color(0xFF64748B),
                ),
              ),
              const SizedBox(height: 14),
              if (detail.tonerLevel >= 0)
                InkBar(
                  'Toner',
                  detail.tonerLevel,
                  const Color(0xFF60A5FA),
                  Colors.blueGrey,
                ),
              if (detail.inkLevelBlack >= 0)
                InkBar(
                  'Black Ink',
                  detail.inkLevelBlack,
                  const Color(0xFF475569),
                  const Color(0xFF1E293B),
                ),
              if (detail.inkLevelCyan >= 0)
                InkBar(
                  'Cyan Ink',
                  detail.inkLevelCyan,
                  const Color(0xFF06B6D4),
                  const Color(0xFF0891B2),
                ),
              if (detail.inkLevelMagenta >= 0)
                InkBar(
                  'Magenta Ink',
                  detail.inkLevelMagenta,
                  const Color(0xFFEC4899),
                  const Color(0xFFDB2777),
                ),
              if (detail.inkLevelYellow >= 0)
                InkBar(
                  'Yellow Ink',
                  detail.inkLevelYellow,
                  const Color(0xFFFBBF24),
                  const Color(0xFFD97706),
                ),
              const SizedBox(height: 14),
            ],

            // Capabilities row
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (detail.isColorSupported)
                  const ChipWidget('COLOR SUPPORTED', Color(0xFF8B5CF6)),
                if (detail.isDuplexSupported)
                  const ChipWidget('DUPLEX SUPPORTED', Color(0xFF06B6D4)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class PulsingIndicator extends StatefulWidget {
  final bool isOnline;
  const PulsingIndicator({super.key, required this.isOnline});
  @override
  State<PulsingIndicator> createState() => _PulsingIndicatorState();
}

class _PulsingIndicatorState extends State<PulsingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.isOnline
        ? const Color(0xFF10B981)
        : const Color(0xFFEF4444);
    return ScaleTransition(
      scale: Tween<double>(
        begin: 0.85,
        end: 1.15,
      ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut)),
      child: Container(
        width: 12,
        height: 12,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: color.withValues(alpha: 0.6),
              blurRadius: 8,
              spreadRadius: 2,
            ),
          ],
        ),
      ),
    );
  }
}

class InkBar extends StatelessWidget {
  final String label;
  final int level;
  final Color startColor;
  final Color endColor;

  const InkBar(
    this.label,
    this.level,
    this.startColor,
    this.endColor, {
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final pct = (level.clamp(0, 100) / 100.0);
    final low = pct < 0.2;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(
            Icons.water_drop_rounded,
            color: low ? const Color(0xFFEF4444) : startColor,
            size: 18,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      label,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFFE2E8F0),
                      ),
                    ),
                    Text(
                      '$level%',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: low
                            ? const Color(0xFFEF4444)
                            : const Color(0xFF94A3B8),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: SizedBox(
                    height: 8,
                    child: LinearProgressIndicator(
                      value: pct,
                      color: low ? const Color(0xFFEF4444) : startColor,
                      backgroundColor: const Color(0xFF1E293B),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class Alert extends StatelessWidget {
  final String label;
  final Color color;
  const Alert(this.label, this.color, {super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.25), width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.warning_amber_rounded, size: 14, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.5,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

class ChipWidget extends StatelessWidget {
  final String label;
  final Color color;
  const ChipWidget(this.label, this.color, {super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.2), width: 1),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.5,
          color: color,
        ),
      ),
    );
  }
}

class CapabilitiesSection extends StatelessWidget {
  final p.PrinterCapabilities caps;
  const CapabilitiesSection({super.key, required this.caps});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        Text(
          'CAPABILITIES',
          style: Theme.of(
            context,
          ).textTheme.labelLarge?.copyWith(color: const Color(0xFF64748B)),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (caps.supportsColor) const BadgeWidget('Color Mode'),
            if (caps.supportsDuplex) const BadgeWidget('2-Sided Duplex'),
            if (caps.supportsCopy) const BadgeWidget('Multi-Copies'),
            if (caps.supportsBorderless) const BadgeWidget('Borderless'),
            if (caps.supportsCustomPaper) const BadgeWidget('Custom Sizes'),
            BadgeWidget('Max Copies: ${caps.maxCopies}'),
            BadgeWidget('${caps.maxResolutionDpi} DPI'),
          ],
        ),
        if (caps.inputTrays.isNotEmpty) ...[
          const SizedBox(height: 12),
          Row(
            children: [
              const Icon(
                Icons.inbox_rounded,
                size: 14,
                color: Color(0xFF64748B),
              ),
              const SizedBox(width: 6),
              Text(
                'Paper Trays: ${caps.inputTrays}', // printed directly, as it's a String
                style: const TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

class BadgeWidget extends StatelessWidget {
  final String label;
  const BadgeWidget(this.label, {super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: const Color(0xFF334155).withValues(alpha: 0.5),
        ),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: Color(0xFFCBD5E1),
        ),
      ),
    );
  }
}

class StatRow extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final bool mono;
  final bool highlight;
  final Color? successColor;

  const StatRow(
    this.label,
    this.value, {
    super.key,
    required this.icon,
    this.mono = false,
    this.highlight = false,
    this.successColor,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: (successColor ?? cs.primary).withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              icon,
              size: 16,
              color:
                  successColor ??
                  (highlight ? const Color(0xFF8B5CF6) : cs.primary),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label.toUpperCase(),
                  style: const TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.5,
                    color: Color(0xFF64748B),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: highlight ? FontWeight.bold : FontWeight.w500,
                    color: highlight
                        ? Colors.white
                        : successColor ?? const Color(0xFFE2E8F0),
                    fontFamily: mono ? 'monospace' : null,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
