import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:google_fonts/google_fonts.dart';
import '../services/webrtc_service.dart';
import '../services/signaling_service.dart';

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
  // ── Renderers ─────────────────────────────────────────────────────────────
  //
  // _mainRenderer  → screen share video (viewer only, full screen)
  // _pipRenderer   → remote camera (small corner overlay)
  // _audioRenderer → HIDDEN 0×0 renderer required by Flutter Web to play
  //                  remote audio. On mobile audio auto-plays; this is a no-op.
  final _mainRenderer = RTCVideoRenderer();
  final _pipRenderer = RTCVideoRenderer();
  final _audioRenderer = RTCVideoRenderer();

  late WebRTCService _webrtc;
  late SignalingService _signaling;

  bool _micOn = true;
  bool _cameraOn = false;
  bool _screenSharing = false;
  bool _connected = false;
  bool _initialized = false;
  bool _isBeingWatched = false;

  bool _remoteScreenActive = false;
  bool _remoteCameraActive = false;

  // Set to true ONLY when a screen_start signal arrives from the sharer.
  // The next incoming VIDEO track is then routed to _mainRenderer.
  // Without this guard a camera stream could fill the main view.
  bool _expectingScreenStream = false;

  // Stream IDs already routed — prevents duplicate onTrack fires from
  // renegotiation from re-routing to the wrong renderer.
  String? _screenStreamId;
  String? _cameraStreamId;

  // ── Ghost-audio fix ───────────────────────────────────────────────────────
  // We track whether the audio renderer currently has a live stream attached.
  // When the peer's mic is muted the stream still exists but track.enabled is
  // false — that is fine and handled by WebRTC itself.
  // The ghost audio bug was caused by routing EVERY onTrack audio event to
  // _audioRenderer regardless of whether it was the mic or screen-share audio,
  // AND by re-routing the same stream on renegotiation.
  // Fix: use a single _audioStreamId guard AND only attach audio when it is
  // a genuinely new stream ID.
  String? _audioStreamId;

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _init();
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

    _webrtc.onNegotiationNeeded = () async {
      debugPrint('🔄 Renegotiating...');
      final offer = await _webrtc.createOffer();
      _signaling.sendOffer(offer.sdp!);
    };

    // ── Remote stream routing ─────────────────────────────────────────────
    //
    // WebRTCService now passes (stream, trackKind) so we never have to
    // inspect stream.getVideoTracks() / getAudioTracks() here, which is
    // unreliable mid-negotiation.
    //
    // trackKind == 'audio':
    //   Always goes to _audioRenderer (hidden). Only routed once per unique
    //   stream ID to prevent ghost audio from duplicate onTrack events.
    //
    // trackKind == 'video', isInitiator:
    //   Always → _pipRenderer (viewer's camera).
    //
    // trackKind == 'video', viewer, _expectingScreenStream == true:
    //   → _mainRenderer (screen share). Flag cleared immediately.
    //
    // trackKind == 'video', viewer, _expectingScreenStream == false:
    //   → _pipRenderer (sharer's camera).
    _webrtc.onRemoteStream = (stream, trackKind) {
      if (!mounted) return;
      final id = stream.id;

      // ── Audio ────────────────────────────────────────────────────────────
      if (trackKind == 'audio') {
        // Ghost-audio fix: only attach if this is a new audio stream.
        // Re-attaching the same stream on renegotiation caused phantom audio
        // because the renderer kept playing a stale/ended stream object.
        if (_audioStreamId == id) {
          debugPrint('🔇 Audio stream already routed, skipping duplicate');
          return;
        }
        _audioStreamId = id;
        setState(() => _audioRenderer.srcObject = stream);
        debugPrint('🔊 Audio stream → hidden renderer ($id)');
        return;
      }

      // ── Video ─────────────────────────────────────────────────────────────
      if (trackKind != 'video') return;

      // ── Initiator (sharer) ────────────────────────────────────────────────
      // Only ever receives the viewer's camera → always PiP.
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

      // ── Viewer ────────────────────────────────────────────────────────────
      // Deduplicate: skip if this stream ID is already routed anywhere.
      if (_screenStreamId == id || _cameraStreamId == id) {
        debugPrint('📺 Video stream already routed, skipping ($id)');
        return;
      }

      if (_expectingScreenStream) {
        // screen_start signal arrived before this track → it's the screen share.
        _expectingScreenStream = false;
        _screenStreamId = id;
        setState(() {
          _mainRenderer.srcObject = stream;
          _remoteScreenActive = true;
        });
        _setConnected(true, 'screen_stream_received');
        debugPrint('🖥️ [Viewer] Screen share → main ($id)');
      } else {
        // No screen_start received → this is the sharer's camera → PiP only.
        // This also handles the rare timing case where onTrack fires before
        // screen_start arrives: the stream is PiP now and will NOT be
        // re-routed to main because _screenStreamId guards against that.
        _cameraStreamId = id;
        setState(() {
          _pipRenderer.srcObject = stream;
          _remoteCameraActive = true;
        });
        debugPrint('📷 [Viewer] Sharer camera → PiP ($id)');
      }
    };

    // Local camera off → tell peer to clear PiP.
    _webrtc.onCameraOff = () => _signaling.sendCameraOff();

    // Local screen share stopped → tell viewer to clear main view.
    _webrtc.onScreenShareStopped = () {
      if (mounted) setState(() => _screenSharing = false);
      _signaling.sendScreenOff();
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

    // Fully initialise WebRTC before wiring signaling to avoid the race
    // where an offer arrives before the local audio track is ready.
    await _webrtc.initialize();

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
    // Set onMessage last — flushes any queued messages immediately.
    _signaling.onMessage = _handleSignalingMessage;

    if (mounted) setState(() => _initialized = true);

    if (widget.isInitiator) {
      debugPrint('📤 Initiator creating offer...');
      _createOffer();
    }
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
        debugPrint('👤 CallScreen received peer_joined');
        _setConnected(true, 'peer_joined_message');
        break;

      case 'joined':
        debugPrint('👤 Viewer joined room');
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
        await _webrtc.setRemoteDescription(
          RTCSessionDescription(msg['sdp'] as String, 'answer'),
        );
        if (mounted) _setConnected(true, 'answer_received');
        break;

      case 'candidate':
        final c = msg['candidate'] as Map<String, dynamic>;
        await _webrtc.addIceCandidate(RTCIceCandidate(
          c['candidate'] as String,
          c['sdpMid'] as String?,
          c['sdpMLineIndex'] as int?,
        ));
        break;

      // Sharer is about to start a screen share stream.
      // Set the flag BEFORE the renegotiation offer arrives so the next
      // incoming video track is correctly routed to _mainRenderer.
      case 'screen_start':
        debugPrint('🖥️ screen_start received — expecting screen stream');
        if (mounted) setState(() => _expectingScreenStream = true);
        break;

      // Peer turned off camera → clear PiP and reset stream ID.
      case 'camera_off':
        if (mounted) {
          setState(() {
            _pipRenderer.srcObject = null;
            _remoteCameraActive = false;
          });
          _cameraStreamId = null;
        }
        break;

      // Sharer stopped screen share → clear main view on viewer.
      // Also reset _expectingScreenStream in case screen_start was sent but
      // share was cancelled before the stream arrived (avoids stale flag).
      case 'screen_off':
        if (mounted && !widget.isInitiator) {
          setState(() {
            _mainRenderer.srcObject = null;
            _remoteScreenActive = false;
            _expectingScreenStream = false; // ← stale-flag cleanup
          });
          _screenStreamId = null;

          // Also clear audio renderer to stop screen share audio on viewer.
          // The screen audio sender is removed on the sharer side; we clear
          // the renderer here so Web stops playing it immediately.
          setState(() {
            _audioRenderer.srcObject = null;
          });
          _audioStreamId = null;
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
    if (_screenSharing) {
      await _webrtc.stopScreenShare();
      setState(() => _screenSharing = false);
    } else {
      // Send screen_start BEFORE renegotiation so viewer sets the flag first.
      _signaling.sendScreenStart();
      await _webrtc.startScreenShare();
      setState(() => _screenSharing = _webrtc.screenSharing);
    }
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

          // Hidden 0×0 audio renderer — required by Flutter Web to play
          // remote audio streams. Invisible to the user; harmless on mobile.
          Positioned(
            width: 0,
            height: 0,
            child: RTCVideoView(
              _audioRenderer,
              objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
            ),
          ),

          // PiP: remote camera in a small fixed corner box.
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

          // Top bar
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

          // Bottom controls
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
          filterQuality: FilterQuality.medium,
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

    // Initiator (sharer)
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
