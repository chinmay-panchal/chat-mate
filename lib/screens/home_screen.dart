import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0F),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Column(
            children: [
              const SizedBox(height: 60),
              // Header
              Text(
                'WatchTogether',
                style: GoogleFonts.spaceGrotesk(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                  letterSpacing: -0.5,
                ),
              ),
              const Spacer(),
              // Buttons
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _RoundActionButton(
                    label: 'SHARE',
                    icon: Icons.screen_share_outlined,
                    gradient: const LinearGradient(
                      colors: [Color(0xFF6C63FF), Color(0xFF8B5CF6)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    glowColor: const Color(0xFF6C63FF),
                    onTap: () => Navigator.pushNamed(context, '/create'),
                  ),
                  const SizedBox(width: 36),
                  _RoundActionButton(
                    label: 'WATCH',
                    icon: Icons.play_arrow_rounded,
                    gradient: const LinearGradient(
                      colors: [Color(0xFF0ECFCF), Color(0xFF06B6B6)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    glowColor: const Color(0xFF0ECFCF),
                    onTap: () => Navigator.pushNamed(context, '/join'),
                  ),
                ],
              ),
              const SizedBox(height: 28),
              Text(
                'Create or join a room to start watching',
                style: GoogleFonts.spaceGrotesk(
                  fontSize: 13,
                  color: Colors.white24,
                ),
              ),
              const Spacer(),
              const SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );
  }
}

class _RoundActionButton extends StatefulWidget {
  final String label;
  final IconData icon;
  final LinearGradient gradient;
  final Color glowColor;
  final VoidCallback onTap;

  const _RoundActionButton({
    required this.label,
    required this.icon,
    required this.gradient,
    required this.glowColor,
    required this.onTap,
  });

  @override
  State<_RoundActionButton> createState() => _RoundActionButtonState();
}

class _RoundActionButtonState extends State<_RoundActionButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 120),
      lowerBound: 0.0,
      upperBound: 0.08,
    );
    _scale = Tween<double>(begin: 1.0, end: 0.94).animate(_ctrl);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => _ctrl.forward(),
      onTapUp: (_) {
        _ctrl.reverse();
        widget.onTap();
      },
      onTapCancel: () => _ctrl.reverse(),
      child: AnimatedBuilder(
        animation: _scale,
        builder: (ctx, child) =>
            Transform.scale(scale: _scale.value, child: child),
        child: Column(
          children: [
            Container(
              width: 120,
              height: 120,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: widget.gradient,
                boxShadow: [
                  BoxShadow(
                    color: widget.glowColor.withOpacity(0.35),
                    blurRadius: 40,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: Icon(widget.icon, size: 48, color: Colors.white),
            ),
            const SizedBox(height: 14),
            Text(
              widget.label,
              style: GoogleFonts.spaceGrotesk(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Colors.white60,
                letterSpacing: 2,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
