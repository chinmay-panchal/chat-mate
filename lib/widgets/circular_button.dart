import 'package:flutter/material.dart';

/// A large circular tappable button used throughout the app.
///
/// Supports two visual variants:
///  - [CircularButtonVariant.primary] — filled with the primary green color.
///  - [CircularButtonVariant.ghost]   — transparent with a subtle border.
///  - [CircularButtonVariant.danger]  — filled with a red/destructive color.
enum CircularButtonVariant { primary, ghost, danger }

class CircularButton extends StatelessWidget {
  const CircularButton({
    super.key,
    required this.onTap,
    this.icon,
    this.label,
    this.size = 80,
    this.variant = CircularButtonVariant.primary,
    this.tooltip,
  });

  final VoidCallback? onTap;
  final IconData? icon;
  final String? label;
  final double size;
  final CircularButtonVariant variant;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    Color backgroundColor;
    Color foregroundColor;
    Color? borderColor;

    switch (variant) {
      case CircularButtonVariant.primary:
        backgroundColor = colorScheme.primary;
        foregroundColor = Colors.white;
        borderColor = null;
        break;
      case CircularButtonVariant.ghost:
        backgroundColor = Colors.white.withOpacity(0.08);
        foregroundColor = Colors.white;
        borderColor = Colors.white.withOpacity(0.18);
        break;
      case CircularButtonVariant.danger:
        backgroundColor = const Color(0xFFE53935);
        foregroundColor = Colors.white;
        borderColor = null;
        break;
    }

    Widget button = GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: backgroundColor,
          shape: BoxShape.circle,
          border: borderColor != null
              ? Border.all(color: borderColor, width: 1.5)
              : null,
          boxShadow: variant == CircularButtonVariant.primary
              ? [
                  BoxShadow(
                    color: colorScheme.primary.withOpacity(0.35),
                    blurRadius: 20,
                    offset: const Offset(0, 6),
                  ),
                ]
              : variant == CircularButtonVariant.danger
              ? [
                  BoxShadow(
                    color: const Color(0xFFE53935).withOpacity(0.35),
                    blurRadius: 20,
                    offset: const Offset(0, 6),
                  ),
                ]
              : null,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (icon != null)
              Icon(icon, color: foregroundColor, size: size * 0.38),
            if (label != null && icon == null)
              Text(
                label!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: foregroundColor,
                  fontWeight: FontWeight.w700,
                  fontSize: size * 0.16,
                  letterSpacing: 1.0,
                ),
              ),
          ],
        ),
      ),
    );

    if (tooltip != null) {
      return Tooltip(message: tooltip!, child: button);
    }
    return button;
  }
}

/// A smaller, square-ish icon button used in the call overlay controls.
class CallControlButton extends StatelessWidget {
  const CallControlButton({
    super.key,
    required this.onTap,
    required this.icon,
    required this.isActive,
    this.size = 64,
    this.activeColor,
    this.inactiveColor,
    this.tooltip,
  });

  final VoidCallback onTap;
  final IconData icon;
  final bool isActive;
  final double size;
  final Color? activeColor;
  final Color? inactiveColor;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final active = activeColor ?? Colors.white.withOpacity(0.12);
    final inactive = inactiveColor ?? const Color(0xFFE53935).withOpacity(0.85);

    Widget button = GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: isActive ? active : inactive,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white.withOpacity(0.10), width: 1),
        ),
        child: Icon(icon, color: Colors.white, size: size * 0.42),
      ),
    );

    if (tooltip != null) {
      return Tooltip(message: tooltip!, child: button);
    }
    return button;
  }
}
