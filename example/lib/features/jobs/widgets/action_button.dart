import 'package:flutter/material.dart';

class ActionButton extends StatefulWidget {
  final String label;
  final IconData icon;
  final bool disabled;
  final VoidCallback onPressed;

  const ActionButton({
    super.key,
    required this.label,
    required this.icon,
    required this.disabled,
    required this.onPressed,
  });

  @override
  State<ActionButton> createState() => _ActionButtonState();
}

class _ActionButtonState extends State<ActionButton> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: AnimatedScale(
        scale: _isHovered ? 1.03 : 1.0,
        duration: const Duration(milliseconds: 150),
        child: FilledButton.tonalIcon(
          onPressed: widget.disabled ? null : widget.onPressed,
          icon: Icon(widget.icon, size: 14),
          label: Text(widget.label),
          style: FilledButton.styleFrom(
            backgroundColor: _isHovered
                ? const Color(0xFF6366F1).withValues(alpha: 0.2)
                : const Color(0xFF1E293B),
            foregroundColor: _isHovered
                ? Colors.white
                : const Color(0xFFCBD5E1),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
              side: BorderSide(
                color: _isHovered
                    ? const Color(0xFF6366F1).withValues(alpha: 0.4)
                    : const Color(0xFF334155).withValues(alpha: 0.3),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
