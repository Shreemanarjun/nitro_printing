import 'package:flutter/material.dart';

class ListeningToggle extends StatefulWidget {
  final bool listening;
  final VoidCallback onPressed;

  const ListeningToggle({
    super.key,
    required this.listening,
    required this.onPressed,
  });

  @override
  State<ListeningToggle> createState() => _ListeningToggleState();
}

class _ListeningToggleState extends State<ListeningToggle> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final activeColor = widget.listening ? const Color(0xFFEF4444) : const Color(0xFF6366F1);

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: AnimatedScale(
        scale: _isHovered ? 1.025 : 1.0,
        duration: const Duration(milliseconds: 150),
        child: FilledButton.icon(
          onPressed: widget.onPressed,
          icon: Icon(widget.listening ? Icons.portable_wifi_off_rounded : Icons.wifi_tethering_rounded, size: 16),
          label: Text(widget.listening ? 'Kill Feed' : 'Launch Feed', style: const TextStyle(fontWeight: FontWeight.bold)),
          style: FilledButton.styleFrom(
            backgroundColor: activeColor,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            elevation: _isHovered ? 4 : 0,
            shadowColor: activeColor.withValues(alpha: 0.4),
          ),
        ),
      ),
    );
  }
}
