import 'package:flutter/material.dart';

class PrintButton extends StatefulWidget {
  final String label;
  final IconData icon;
  final bool loading;
  final VoidCallback onPressed;
  final bool highlight;

  const PrintButton({
    super.key,
    required this.label,
    required this.icon,
    required this.loading,
    required this.onPressed,
    this.highlight = false,
  });

  @override
  State<PrintButton> createState() => _PrintButtonState();
}

class _PrintButtonState extends State<PrintButton> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final primaryColor = widget.highlight ? const Color(0xFF8B5CF6) : const Color(0xFF6366F1);

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: AnimatedScale(
        scale: _isHovered ? 1.025 : 1.0,
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
        child: FilledButton.icon(
          onPressed: widget.loading ? null : widget.onPressed,
          icon: Icon(widget.icon, size: 16),
          label: Text(
            widget.label,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
          ),
          style: FilledButton.styleFrom(
            backgroundColor: primaryColor,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
            elevation: _isHovered ? 4 : 0,
            shadowColor: primaryColor.withValues(alpha: 0.4),
          ),
        ),
      ),
    );
  }
}
