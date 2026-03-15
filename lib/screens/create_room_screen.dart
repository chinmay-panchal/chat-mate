import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'dart:math';
import '../services/signaling_service.dart';

class CreateRoomScreen extends StatefulWidget {
  const CreateRoomScreen({super.key});

  @override
  State<CreateRoomScreen> createState() => _CreateRoomScreenState();
}

class _CreateRoomScreenState extends State<CreateRoomScreen>
    with SingleTickerProviderStateMixin {
  late String _roomId;
  late SignalingService _signaling;
  late AnimationController _pulseCtrl;
  late Animation<double> _pulse;

  @override
  void initState() {
    super.initState();
    _roomId = _generateRoomId();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);
    _pulse = Tween<double>(begin: 0.7, end: 1.0).animate(
      CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut),
    );

    _signaling = SignalingService();
    _connectAndWait();
  }

  String _generateRoomId() {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final rng = Random.secure();
    return List.generate(6, (_) => chars[rng.nextInt(chars.length)]).join();
  }

  void _connectAndWait() {
    _signaling.connect(
      roomId: _roomId,
      isInitiator: true,
      onPeerJoined: () {
        if (mounted) {
          Navigator.pushReplacementNamed(context, '/call', arguments: {
            'roomId': _roomId,
            'isInitiator': true,
            'signalingService': _signaling, // pass instance, do NOT dispose
          });
        }
      },
      onError: (e) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('Connection error: $e')));
        }
      },
    );
  }

  void _copyToClipboard() {
    Clipboard.setData(ClipboardData(text: _roomId));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Room ID copied!', style: GoogleFonts.spaceGrotesk()),
        backgroundColor: const Color(0xFF141420),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    // DO NOT dispose _signaling here — call_screen takes ownership
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0F),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded,
              color: Colors.white54),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const SizedBox(height: 32),
              Text(
                'Your Room ID',
                style: GoogleFonts.spaceGrotesk(
                  fontSize: 14,
                  color: Colors.white38,
                  letterSpacing: 2,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 20),
              GestureDetector(
                onTap: _copyToClipboard,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 32, vertical: 20),
                  decoration: BoxDecoration(
                    color: const Color(0xFF141420),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: const Color(0xFF6C63FF).withOpacity(0.3),
                      width: 1.5,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _roomId,
                        style: GoogleFonts.jetBrainsMono(
                          fontSize: 42,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                          letterSpacing: 6,
                        ),
                      ),
                      const SizedBox(width: 12),
                      const Icon(Icons.copy_rounded,
                          color: Colors.white24, size: 20),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                'Send this code to your friend',
                style: GoogleFonts.spaceGrotesk(
                    fontSize: 14, color: Colors.white38),
              ),
              const Spacer(),
              AnimatedBuilder(
                animation: _pulse,
                builder: (ctx, _) => Opacity(
                  opacity: _pulse.value,
                  child: Column(
                    children: [
                      Container(
                        width: 12,
                        height: 12,
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          color: Color(0xFF6C63FF),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'Waiting for friend to join...',
                        style: GoogleFonts.spaceGrotesk(
                            fontSize: 15, color: Colors.white54),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 60),
            ],
          ),
        ),
      ),
    );
  }
}
