import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:google_fonts/google_fonts.dart';
import '../services/webrtc_service.dart';
import '../services/signaling_service.dart';
import '../services/web_audio_player.dart'
    if (dart.library.js) '../services/web_audio_player_web.dart';
import 'package:flutter/foundation.dart';

class CallScreen extends StatefulWidget {
  final String roomId;
  final bool isInitiator;
  final SignalingService signalingService;

  const CallScreen({
    super.key,
    required this.roomId,
    required this.isInitiator,
    required this.signalingService,
  });

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  final _mainRenderer = RTCVideoRenderer();
  final _pipRenderer = RTCVideoRenderer();
  final _audioRenderer = RTCVideoRenderer();

  late WebRTCService _webrtc;
  late SignalingService _signaling;

  static const _audioPlaybackChannel =
      MethodChannel('com.example.chat_mate/screen_share');

  bool _micOn = true;
  bool _cameraOn = false;
  bool _screenSharing = false;
  bool _connected = false;
  bool _initialized = false;
  bool _isBeingWatched = false;

  bool _remoteScreenActive = false;
  bool _remoteCameraActive = false;
  bool _expectingScreenStream = false;
  String? _screenStreamId;
  String? _cameraStreamId;
  String? _audioStreamId;
  String? _screenAudioStreamId;

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    // Initialise Web Audio API as early as possible (before user gesture
    // restriction kicks in on some browsers).
    if (kIsWeb) WebAudioPlayer.init();
    _init();
  }

  void _setupAudioCaptureHandler() {
    _audioPlaybackChannel.setMethodCallHandler((call) async {
      if (call.method == 'onAudioCaptured') {
        final bytes = call.arguments as Uint8List;
        _webrtc.relayAudioToViewer(bytes);
      }
    });
  }

  void _setConnected(bool value, String source) {
    debugPrint('🟢 CONNECTED CHANGE -> $value (from $source)');
    if (mounted) setState(() => _connected = value);
  }

  Future<void> _init() async {
    await _mainRenderer.initialize();
    await _pipRenderer.initialize();
    await _audioRenderer.initialize();

    _webrtc = WebRTCService();

    _setupAudioCaptureHandler();

    _webrtc.onNegotiationNeeded = () async {
      debugPrint('🔄 Renegotiating...');
      final offer = await _webrtc.createOffer();
      _signaling.sendOffer(offer.sdp!);
    };

    _webrtc.onRemoteStream = (stream, trackKind) {
      if (!mounted) return;
      final id = stream.id;

      if (trackKind == 'audio') {
        if (_expectingScreenStream) {
          if (_screenAudioStreamId == id) return;
          _screenAudioStreamId = id;
          setState(() => _audioRenderer.srcObject = stream);
          debugPrint('🔊 Screen audio → hidden renderer ($id)');
        } else {
          _audioStreamId = id;
          setState(() => _audioRenderer.srcObject = stream);
          debugPrint('🔊 Mic audio → hidden renderer ($id)');
        }
        return;
      }

      if (trackKind != 'video') return;

      if (widget.isInitiator) {
        if (_cameraStreamId == id) return;
        _cameraStreamId = id;
        setState(() {
          _pipRenderer.srcObject = stream;
          _remoteCameraActive = true;
        });
        debugPrint('📷 [Sharer] Remote camera → PiP ($id)');
        return;
      }

      if (_screenStreamId == id || _cameraStreamId == id) return;

      if (_expectingScreenStream) {
        _expectingScreenStream = false;
        _screenStreamId = id;
        setState(() {
          _mainRenderer.srcObject = stream;
          _remoteScreenActive = true;
        });
        _setConnected(true, 'screen_stream_received');
        debugPrint('🖥️ [Viewer] Screen share → main ($id)');
      } else {
        _cameraStreamId = id;
        setState(() {
          _pipRenderer.srcObject = stream;
          _remoteCameraActive = true;
        });
        debugPrint('📷 [Viewer] Sharer camera → PiP ($id)');
      }
    };

    _webrtc.onCameraOff = () => _signaling.sendCameraOff();

    _webrtc.onScreenShareStopped = () {
      if (mounted) setState(() => _screenSharing = false);
      _signaling.sendScreenOff();
    };

    // System-audio PCM arrives here from the sharer's DataChannel.
    // Route to the correct player depending on platform:
    //   Web viewer  → WebAudioPlayer (Web Audio API, no native code needed)
    //   Android viewer → native AudioTrack via MethodChannel
    //   Initiator (sharer) → ignore (this is our own echo, should not arrive
    //                         but guard anyway)
    _webrtc.onRemoteAudioData = (Uint8List data) async {
      if (widget.isInitiator) return; // sharer never plays back own audio
      if (kIsWeb) {
        // Resume AudioContext on first data packet — covers browsers that
        // require a user gesture before allowing audio output.
        WebAudioPlayer.resume();
        WebAudioPlayer.play(data);
      } else {
        await _webrtc.sendAudioBytesToNative(data);
      }
    };

    _webrtc.onConnectionState = (state) {
      debugPrint('🔗 Connection state: $state');
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        if (mounted) setState(() => _connected = true);
      } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
        _handleDisconnect();
      }
    };

    _webrtc.onIceCandidate = (candidate) {
      _signaling.sendCandidate({
        'candidate': candidate.candidate,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
      });
    };

    await _webrtc.initialize(isInitiator: widget.isInitiator);

    _signaling = widget.signalingService;

    _signaling.onPeerJoined = () {
      debugPrint('👤 SIGNAL: Peer joined');
      if (!mounted) return;
      setState(() => _isBeingWatched = true);
      _setConnected(true, 'onPeerJoined');
      if (widget.isInitiator) _createOffer();
    };

    _signaling.onPeerLeft = () => _handleDisconnect();

    _signaling.onError = (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Signal error: $e')));
      }
    };

    _signaling.onMessage = _handleSignalingMessage;

    if (mounted) setState(() => _initialized = true);
  }

  Future<void> _createOffer() async {
    final offer = await _webrtc.createOffer();
    _signaling.sendOffer(offer.sdp!);
  }

  Future<void> _handleSignalingMessage(Map<String, dynamic> msg) async {
    final type = msg['type'] as String;
    debugPrint('📩 CallScreen: $type');

    switch (type) {
      case 'peer_joined':
        _setConnected(true, 'peer_joined_message');
        break;

      case 'joined':
        _setConnected(true, 'viewer_joined');
        break;

      case 'offer':
        await _webrtc.setRemoteDescription(
          RTCSessionDescription(msg['sdp'] as String, 'offer'),
        );
        final answer = await _webrtc.createAnswer();
        _signaling.sendAnswer(answer.sdp!);
        if (mounted) _setConnected(true, 'offer_answered');
        break;

      case 'answer':
        final signalingState = await _webrtc.getSignalingState();
        if (signalingState ==
            RTCSignalingState.RTCSignalingStateHaveLocalOffer) {
          await _webrtc.setRemoteDescription(
            RTCSessionDescription(msg['sdp'] as String, 'answer'),
          );
          if (mounted) _setConnected(true, 'answer_received');
        } else {
          debugPrint('⚠️ Ignoring answer in wrong state: $signalingState');
        }
        break;

      case 'candidate':
        final c = msg['candidate'] as Map<String, dynamic>;
        await _webrtc.addIceCandidate(RTCIceCandidate(
          c['candidate'] as String,
          c['sdpMid'] as String?,
          c['sdpMLineIndex'] as int?,
        ));
        break;

      case 'screen_start':
        debugPrint('🖥️ screen_start — expecting screen stream');
        if (mounted) setState(() => _expectingScreenStream = true);
        // Only Android viewer needs to pre-start the native AudioTrack.
        // Web viewer plays via WebAudioPlayer on demand (no pre-start needed).
        if (!widget.isInitiator && !kIsWeb) {
          try {
            await _audioPlaybackChannel.invokeMethod('startAudioPlayback');
            debugPrint('🔊 Viewer AudioTrack started');
          } catch (e) {
            debugPrint('⚠️ startAudioPlayback error: $e');
          }
        }
        break;

      case 'camera_off':
        if (mounted) {
          setState(() {
            _pipRenderer.srcObject = null;
            _remoteCameraActive = false;
          });
          _cameraStreamId = null;
        }
        break;

      case 'screen_off':
        if (mounted && !widget.isInitiator) {
          setState(() {
            _mainRenderer.srcObject = null;
            _remoteScreenActive = false;
            _expectingScreenStream = false;
          });
          _screenStreamId = null;
          _screenAudioStreamId = null;
          _audioStreamId = null;
          // Stop native AudioTrack on Android; web just stops receiving data.
          if (!kIsWeb) {
            try {
              await _audioPlaybackChannel.invokeMethod('stopAudioPlayback');
              debugPrint('🔇 Viewer AudioTrack stopped');
            } catch (e) {
              debugPrint('⚠️ stopAudioPlayback error: $e');
            }
          }
        }
        break;
    }
  }

  bool _disconnectShown = false;
  void _handleDisconnect() {
    if (!mounted || _disconnectShown) return;
    _disconnectShown = true;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF141420),
        title: Text('Call Ended',
            style: GoogleFonts.spaceGrotesk(color: Colors.white)),
        content: Text('Your friend disconnected.',
            style: GoogleFonts.spaceGrotesk(color: Colors.white54)),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              Navigator.pushNamedAndRemoveUntil(context, '/home', (_) => false);
            },
            child: Text('Go Home',
                style:
                    GoogleFonts.spaceGrotesk(color: const Color(0xFF6C63FF))),
          ),
        ],
      ),
    );
  }

  Future<void> _toggleMic() async {
    await _webrtc.toggleMicrophone();
    setState(() => _micOn = _webrtc.micEnabled);
  }

  Future<void> _toggleCamera() async {
    await _webrtc.toggleCamera();
    setState(() => _cameraOn = _webrtc.cameraEnabled);
  }

  Future<void> _toggleScreenShare() async {
    debugPrint('🚀 _toggleScreenShare clicked');

    if (_screenSharing) {
      await _webrtc.stopScreenShare();
      setState(() => _screenSharing = false);
    } else {
      // Resume AudioContext on user gesture — satisfies browser autoplay policy
      if (kIsWeb) WebAudioPlayer.resume();

      _signaling.sendScreenStart();
      try {
        final success = await _webrtc.startScreenShare();
        if (!success) {
          _signaling.sendScreenOff();
          if (mounted) _showMobileScreenShareUnsupported();
          return;
        }
        setState(() => _screenSharing = _webrtc.screenSharing);
      } catch (e, stack) {
        debugPrint('💥 _toggleScreenShare crash: $e\n$stack');
        _signaling.sendScreenOff();
      }
    }
  }

  void _showMobileScreenShareUnsupported() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF141420),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(bottom: 28),
              decoration: BoxDecoration(
                color: Colors.white12,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFF6C63FF).withOpacity(0.1),
                border: Border.all(
                  color: const Color(0xFF6C63FF).withOpacity(0.3),
                  width: 1.5,
                ),
              ),
              child: const Icon(
                Icons.screen_share_rounded,
                color: Color(0xFF6C63FF),
                size: 28,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'Screen sharing unavailable',
              style: GoogleFonts.spaceGrotesk(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'Screen sharing is not supported here.\nTry opening the app on a desktop browser.',
              textAlign: TextAlign.center,
              style: GoogleFonts.spaceGrotesk(
                fontSize: 13,
                color: Colors.white38,
                height: 1.6,
              ),
            ),
            const SizedBox(height: 28),
            GestureDetector(
              onTap: () => Navigator.of(context).pop(),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 14),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  color: const Color(0xFF6C63FF).withOpacity(0.15),
                  border: Border.all(
                    color: const Color(0xFF6C63FF).withOpacity(0.3),
                    width: 1,
                  ),
                ),
                child: Text(
                  'Got it',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.spaceGrotesk(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: const Color(0xFF6C63FF),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _endCall() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF141420),
        title: Text('End Call?',
            style: GoogleFonts.spaceGrotesk(color: Colors.white)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text('Cancel',
                style: GoogleFonts.spaceGrotesk(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              Navigator.pushNamedAndRemoveUntil(context, '/home', (_) => false);
            },
            child: Text('End',
                style: GoogleFonts.spaceGrotesk(color: Colors.redAccent)),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    if (kIsWeb) WebAudioPlayer.dispose();
    _mainRenderer.dispose();
    _pipRenderer.dispose();
    _audioRenderer.dispose();
    if (_initialized) {
      _webrtc.dispose();
      _signaling.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final pipH = size.height * 0.18;
    final pipW = pipH * (9 / 16);

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(child: _buildMainContent()),
          Positioned(
            width: 0,
            height: 0,
            child: RTCVideoView(
              _audioRenderer,
              objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
            ),
          ),
          if (_remoteCameraActive)
            Positioned(
              bottom: 110,
              right: 16,
              child: _CameraPiP(
                renderer: _pipRenderer,
                width: pipW,
                height: pipH,
              ),
            ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    _RoomChip(roomId: widget.roomId),
                    Row(
                      children: [
                        if (widget.isInitiator &&
                            _isBeingWatched &&
                            _screenSharing)
                          const _LiveBadge(),
                        const SizedBox(width: 10),
                        _EndCallButton(onTap: _endCall),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: _BottomControls(
              micOn: _micOn,
              cameraOn: _cameraOn,
              screenSharing: _screenSharing,
              isInitiator: widget.isInitiator,
              onMic: _toggleMic,
              onCamera: _toggleCamera,
              onScreen: _toggleScreenShare,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMainContent() {
    if (!widget.isInitiator) {
      if (_remoteScreenActive) {
        return RTCVideoView(
          _mainRenderer,
          objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
          filterQuality: FilterQuality.low,
        );
      }
      if (_connected) {
        return _StatusView(
          icon: Icons.headset_rounded,
          iconColor: const Color(0xFF6C63FF),
          title: 'Connected',
          subtitle: 'Waiting for the sharer to start...',
          roomId: widget.roomId,
        );
      }
      return _StatusView(
        icon: null,
        iconColor: Colors.transparent,
        title: 'Connecting...',
        subtitle: '',
        roomId: widget.roomId,
        showSpinner: true,
      );
    }

    if (_screenSharing) {
      return _SharingView(
          isBeingWatched: _isBeingWatched, roomId: widget.roomId);
    }
    if (_connected) {
      return _StatusView(
        icon: Icons.headset_rounded,
        iconColor: const Color(0xFF6C63FF),
        title: 'Connected',
        subtitle: 'Start screen sharing for your friend to watch',
        roomId: widget.roomId,
      );
    }
    return _StatusView(
      icon: null,
      iconColor: Colors.transparent,
      title: 'Connecting...',
      subtitle: '',
      roomId: widget.roomId,
      showSpinner: true,
    );
  }
}

// ── Widgets ───────────────────────────────────────────────────────────────────

class _CameraPiP extends StatelessWidget {
  final RTCVideoRenderer renderer;
  final double width;
  final double height;
  const _CameraPiP(
      {required this.renderer, required this.width, required this.height});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: const Color(0xFF141420),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white10, width: 1),
          boxShadow: [
            BoxShadow(
                color: Colors.black.withOpacity(0.5),
                blurRadius: 12,
                offset: const Offset(0, 4))
          ],
        ),
        child: RTCVideoView(renderer,
            objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
            mirror: false),
      ),
    );
  }
}

class _SharingView extends StatelessWidget {
  final bool isBeingWatched;
  final String roomId;
  const _SharingView({required this.isBeingWatched, required this.roomId});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF0A0A0F),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFF0ECFCF).withOpacity(0.1),
                border: Border.all(
                    color: const Color(0xFF0ECFCF).withOpacity(0.35),
                    width: 1.5),
              ),
              child: const Icon(Icons.screen_share_rounded,
                  color: Color(0xFF0ECFCF), size: 30),
            ),
            const SizedBox(height: 20),
            Text('Sharing your screen',
                style: GoogleFonts.spaceGrotesk(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                    color: Colors.white)),
            const SizedBox(height: 8),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              child: Text(
                isBeingWatched
                    ? 'Your friend is watching  👀'
                    : 'Waiting for your friend...',
                key: ValueKey(isBeingWatched),
                style: GoogleFonts.spaceGrotesk(
                    fontSize: 13,
                    color: isBeingWatched
                        ? const Color(0xFF00E676)
                        : Colors.white38),
              ),
            ),
            const SizedBox(height: 28),
            Text(roomId,
                style: GoogleFonts.jetBrainsMono(
                    fontSize: 12, color: Colors.white12, letterSpacing: 3)),
          ],
        ),
      ),
    );
  }
}

class _StatusView extends StatelessWidget {
  final IconData? icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final String roomId;
  final bool showSpinner;

  const _StatusView({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.roomId,
    this.showSpinner = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF0A0A0F),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (showSpinner)
              const SizedBox(
                  width: 36,
                  height: 36,
                  child: CircularProgressIndicator(
                      color: Color(0xFF6C63FF), strokeWidth: 2))
            else if (icon != null)
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: iconColor.withOpacity(0.1),
                  border:
                      Border.all(color: iconColor.withOpacity(0.3), width: 1.5),
                ),
                child: Icon(icon, color: iconColor, size: 28),
              ),
            const SizedBox(height: 20),
            Text(title,
                style: GoogleFonts.spaceGrotesk(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: Colors.white)),
            if (subtitle.isNotEmpty) ...[
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 40),
                child: Text(subtitle,
                    textAlign: TextAlign.center,
                    style: GoogleFonts.spaceGrotesk(
                        fontSize: 13, color: Colors.white38)),
              ),
            ],
            const SizedBox(height: 24),
            Text(roomId,
                style: GoogleFonts.jetBrainsMono(
                    fontSize: 12, color: Colors.white12, letterSpacing: 3)),
          ],
        ),
      ),
    );
  }
}

class _RoomChip extends StatelessWidget {
  final String roomId;
  const _RoomChip({required this.roomId});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
          color: Colors.black45, borderRadius: BorderRadius.circular(20)),
      child: Text(roomId,
          style: GoogleFonts.jetBrainsMono(
              fontSize: 14, color: Colors.white60, letterSpacing: 2)),
    );
  }
}

class _LiveBadge extends StatelessWidget {
  const _LiveBadge();
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
          color: Colors.black45, borderRadius: BorderRadius.circular(20)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
            width: 7,
            height: 7,
            decoration: const BoxDecoration(
                shape: BoxShape.circle, color: Color(0xFF00E676))),
        const SizedBox(width: 6),
        Text('LIVE',
            style: GoogleFonts.spaceGrotesk(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: const Color(0xFF00E676),
                letterSpacing: 1.5)),
      ]),
    );
  }
}

class _EndCallButton extends StatelessWidget {
  final VoidCallback onTap;
  const _EndCallButton({required this.onTap});
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
            shape: BoxShape.circle, color: Colors.red.withOpacity(0.85)),
        child:
            const Icon(Icons.call_end_rounded, color: Colors.white, size: 20),
      ),
    );
  }
}

class _BottomControls extends StatelessWidget {
  final bool micOn, cameraOn, screenSharing, isInitiator;
  final VoidCallback onMic, onCamera, onScreen;

  const _BottomControls({
    required this.micOn,
    required this.cameraOn,
    required this.screenSharing,
    required this.isInitiator,
    required this.onMic,
    required this.onCamera,
    required this.onScreen,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 36),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _ControlButton(
                icon: micOn ? Icons.mic_rounded : Icons.mic_off_rounded,
                active: micOn,
                onTap: onMic),
            const SizedBox(width: 20),
            if (isInitiator) ...[
              _ControlButton(
                icon: screenSharing
                    ? Icons.stop_screen_share_rounded
                    : Icons.screen_share_rounded,
                active: screenSharing,
                activeColor: const Color(0xFF0ECFCF),
                onTap: onScreen,
              ),
              const SizedBox(width: 20),
            ],
            _ControlButton(
                icon: cameraOn
                    ? Icons.videocam_rounded
                    : Icons.videocam_off_rounded,
                active: cameraOn,
                onTap: onCamera),
          ],
        ),
      ),
    );
  }
}

class _ControlButton extends StatelessWidget {
  final IconData icon;
  final bool active;
  final Color activeColor;
  final VoidCallback onTap;

  const _ControlButton({
    required this.icon,
    required this.active,
    this.activeColor = const Color(0xFF6C63FF),
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 60,
        height: 60,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: active
              ? activeColor.withOpacity(0.9)
              : Colors.white.withOpacity(0.12),
          boxShadow: active
              ? [
                  BoxShadow(
                      color: activeColor.withOpacity(0.4),
                      blurRadius: 20,
                      spreadRadius: 2)
                ]
              : null,
        ),
        child: Icon(icon, color: Colors.white, size: 26),
      ),
    );
  }
}
