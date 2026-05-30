import 'package:flutter/material.dart';

class HoverButton extends StatefulWidget {
  final VoidCallback? onPressed;
  final IconData icon;
  final String label;

  const HoverButton({
    super.key,
    required this.onPressed,
    required this.icon,
    required this.label,
  });

  @override
  State<HoverButton> createState() => _HoverButtonState();
}

class _HoverButtonState extends State<HoverButton> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: AnimatedScale(
        scale: _isHovered ? 1.02 : 1.0,
        duration: const Duration(milliseconds: 150),
        child: FilledButton.icon(
          onPressed: widget.onPressed,
          icon: Icon(widget.icon, size: 16),
          label: Text(
            widget.label,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
          ),
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFF6366F1),
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
            elevation: _isHovered ? 4 : 0,
            shadowColor: const Color(0xFF6366F1).withValues(alpha: 0.4),
          ),
        ),
      ),
    );
  }
}
