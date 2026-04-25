import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:video_player/video_player.dart';
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
  bool _screenSharing = false; // web only
  bool _videoSharing = false; // mobile only
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

  // ── Init ──────────────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    if (kIsWeb) WebAudioPlayer.init();
    _init();
  }

  void _setupAudioCaptureHandler() {
    _audioPlaybackChannel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onAudioCaptured':
          // Existing: screen share audio from native FGS
          final bytes = call.arguments as Uint8List;
          _webrtc.relayAudioToViewer(bytes);
          break;
        // onVideoShareAudioPCM is handled inside VideoShareService itself —
        // no action needed here.
      }
    });
  }

  void _setConnected(bool value, String source) {
    debugPrint('🟢 CONNECTED -> $value ($source)');
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
          debugPrint('🔊 Mic/video audio → hidden renderer ($id)');
        }
        return;
      }

      if (trackKind != 'video') return;

      // Initiator sees remote camera in PiP
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
        debugPrint('🖥️ [Viewer] Screen/video → main ($id)');
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
    _webrtc.onVideoShareStopped = () {
      if (mounted) setState(() => _videoSharing = false);
      _signaling.sendScreenOff(); // reuse screen_off signal for viewer cleanup
    };

    // Remote audio data (DataChannel PCM) → speaker
    _webrtc.onRemoteAudioData = (Uint8List data) async {
      if (widget.isInitiator) return; // sharer never plays back own audio
      if (kIsWeb) {
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

    _webrtc.onIceCandidate = (c) {
      _signaling.sendCandidate({
        'candidate': c.candidate,
        'sdpMid': c.sdpMid,
        'sdpMLineIndex': c.sdpMLineIndex,
      });
    };

    await _webrtc.initialize(isInitiator: widget.isInitiator);

    _signaling = widget.signalingService;

    _signaling.onPeerJoined = () {
      debugPrint('👤 Peer joined');
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

  // ── Signaling ─────────────────────────────────────────────────────────────
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
        _setConnected(true, 'offer_answered');
        break;

      case 'answer':
        final st = await _webrtc.getSignalingState();
        if (st == RTCSignalingState.RTCSignalingStateHaveLocalOffer) {
          await _webrtc.setRemoteDescription(
            RTCSessionDescription(msg['sdp'] as String, 'answer'),
          );
          _setConnected(true, 'answer_received');
        } else {
          debugPrint('⚠️ Ignoring answer in state: $st');
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
        // Viewer: next incoming video stream is from sharer (screen or video)
        if (mounted) setState(() => _expectingScreenStream = true);
        if (!widget.isInitiator && !kIsWeb) {
          try {
            await _audioPlaybackChannel.invokeMethod('startAudioPlayback');
            debugPrint('🔊 Viewer AudioTrack started');
          } catch (e) {
            debugPrint('⚠️ startAudioPlayback: $e');
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
          if (!kIsWeb) {
            try {
              await _audioPlaybackChannel.invokeMethod('stopAudioPlayback');
            } catch (e) {
              debugPrint('⚠️ stopAudioPlayback: $e');
            }
          }
        }
        break;
    }
  }

  // ── Disconnect ────────────────────────────────────────────────────────────
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

  // ── Controls ──────────────────────────────────────────────────────────────
  Future<void> _toggleMic() async {
    await _webrtc.toggleMicrophone();
    setState(() => _micOn = _webrtc.micEnabled);
  }

  Future<void> _toggleCamera() async {
    await _webrtc.toggleCamera();
    setState(() => _cameraOn = _webrtc.cameraEnabled);
  }

  // Web: screen share (unchanged)
  Future<void> _toggleScreenShare() async {
    debugPrint('🚀 _toggleScreenShare (web)');
    if (_screenSharing) {
      await _webrtc.stopScreenShare();
      setState(() => _screenSharing = false);
    } else {
      WebAudioPlayer.resume();
      _signaling.sendScreenStart();
      try {
        final ok = await _webrtc.startScreenShare();
        if (!ok) {
          _signaling.sendScreenOff();
          return;
        }
        final offer = await _webrtc.createOffer();
        _signaling.sendOffer(offer.sdp!);
        setState(() => _screenSharing = _webrtc.screenSharing);
      } catch (e) {
        debugPrint('💥 _toggleScreenShare: $e');
        _signaling.sendScreenOff();
      }
    }
  }

  // Mobile: video share (replaces screen share)
  Future<void> _toggleVideoShare() async {
    debugPrint('🎬 _toggleVideoShare');
    if (_videoSharing) {
      await _webrtc.stopVideoShare();
      setState(() => _videoSharing = false);
      _signaling.sendScreenOff();
    } else {
      _signaling
          .sendScreenStart(); // reuse signal — viewer expects a new stream
      final ok = await _webrtc.startVideoShare();
      if (!ok) {
        _signaling.sendScreenOff();
        if (mounted) _showVideoPickCancelled();
        return;
      }
      // Force renegotiation so the new video track reaches the remote peer
      final offer = await _webrtc.createOffer();
      _signaling.sendOffer(offer.sdp!);
      setState(() => _videoSharing = _webrtc.videoSharing);
    }
  }

  void _showVideoPickCancelled() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('No video selected')),
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

  // ── Dispose ───────────────────────────────────────────────────────────────
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

  // ── Build ─────────────────────────────────────────────────────────────────
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

          // Hidden audio renderer
          Positioned(
            width: 0,
            height: 0,
            child: RTCVideoView(_audioRenderer,
                objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain),
          ),

          // PiP: remote camera
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
                            (_screenSharing || _videoSharing))
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

          // Video player overlay (mobile sharer, when video share is active)
          if (!kIsWeb && _videoSharing && widget.isInitiator)
            _buildVideoPlayerOverlay(),

          // Bottom controls
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: _BottomControls(
              micOn: _micOn,
              cameraOn: _cameraOn,
              screenSharing: _screenSharing,
              videoSharing: _videoSharing,
              isInitiator: widget.isInitiator,
              onMic: _toggleMic,
              onCamera: _toggleCamera,
              onScreen: kIsWeb ? _toggleScreenShare : null,
              onVideo: !kIsWeb && widget.isInitiator ? _toggleVideoShare : null,
            ),
          ),
        ],
      ),
    );
  }

  // ── Main content ──────────────────────────────────────────────────────────
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

    // Initiator
    if (_screenSharing) {
      return _SharingView(
          isBeingWatched: _isBeingWatched, roomId: widget.roomId);
    }
    if (_videoSharing) {
      // The video player overlay is rendered in the Stack above this layer.
      // Show a transparent background here so it shines through.
      return Container(color: Colors.black);
    }
    if (_connected) {
      return _StatusView(
        icon: Icons.headset_rounded,
        iconColor: const Color(0xFF6C63FF),
        title: 'Connected',
        subtitle: kIsWeb
            ? 'Start screen sharing for your friend to watch'
            : 'Pick a video to share with your friend',
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

  // ── Video player overlay (mobile sharer) ──────────────────────────────────
  Widget _buildVideoPlayerOverlay() {
    final ctrl = _webrtc.videoShare.playerController;
    if (ctrl == null || !ctrl.value.isInitialized) {
      return const SizedBox.shrink();
    }
    return Positioned.fill(
      child: Stack(
        children: [
          // Black background
          Container(color: Colors.black),

          // Video
          Center(
            child: AspectRatio(
              aspectRatio: ctrl.value.aspectRatio,
              child: VideoPlayer(ctrl),
            ),
          ),

          // Progress bar + pause/resume
          Positioned(
            bottom: 100,
            left: 20,
            right: 20,
            child: _VideoControls(
              controller: ctrl,
              onPause: _webrtc.videoShare.pause,
              onResume: _webrtc.videoShare.resume,
              onSeek: _webrtc.videoShare.seek,
            ),
          ),

          // "LIVE" chip top-left
          Positioned(
            top: 60,
            left: 20,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Container(
                  width: 7,
                  height: 7,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: Color(0xFF00E676),
                  ),
                ),
                const SizedBox(width: 6),
                Text('SHARING',
                    style: GoogleFonts.spaceGrotesk(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: const Color(0xFF00E676),
                      letterSpacing: 1.5,
                    )),
              ]),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Video player controls ─────────────────────────────────────────────────────

class _VideoControls extends StatefulWidget {
  final VideoPlayerController controller;
  final Future<void> Function() onPause;
  final Future<void> Function() onResume;
  final Future<void> Function(Duration) onSeek;

  const _VideoControls({
    required this.controller,
    required this.onPause,
    required this.onResume,
    required this.onSeek,
  });

  @override
  State<_VideoControls> createState() => _VideoControlsState();
}

class _VideoControlsState extends State<_VideoControls> {
  bool _paused = false;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: widget.controller,
      builder: (_, value, __) {
        final pos = value.position;
        final dur = value.duration;
        final progress = dur.inMilliseconds > 0
            ? pos.inMilliseconds / dur.inMilliseconds
            : 0.0;

        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Seek bar
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                activeTrackColor: const Color(0xFF6C63FF),
                inactiveTrackColor: Colors.white24,
                thumbColor: const Color(0xFF6C63FF),
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                overlayShape: SliderComponentShape.noOverlay,
              ),
              child: Slider(
                value: progress.clamp(0.0, 1.0),
                onChanged: (v) {
                  final target = Duration(
                    milliseconds: (v * dur.inMilliseconds).round(),
                  );
                  widget.onSeek(target);
                },
              ),
            ),

            // Time + play/pause
            Row(
              children: [
                Text(
                  '${_fmt(pos)} / ${_fmt(dur)}',
                  style: GoogleFonts.jetBrainsMono(
                    fontSize: 11,
                    color: Colors.white54,
                  ),
                ),
                const Spacer(),
                GestureDetector(
                  onTap: () async {
                    if (_paused) {
                      await widget.onResume();
                    } else {
                      await widget.onPause();
                    }
                    setState(() => _paused = !_paused);
                  },
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white.withOpacity(0.15),
                    ),
                    child: Icon(
                      _paused ? Icons.play_arrow_rounded : Icons.pause_rounded,
                      color: Colors.white,
                      size: 22,
                    ),
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}

// ── Reusable widgets (unchanged from original) ────────────────────────────────

class _CameraPiP extends StatelessWidget {
  final RTCVideoRenderer renderer;
  final double width, height;
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
              offset: const Offset(0, 4),
            )
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
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(0xFF0ECFCF).withOpacity(0.1),
              border: Border.all(
                  color: const Color(0xFF0ECFCF).withOpacity(0.35), width: 1.5),
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
                color:
                    isBeingWatched ? const Color(0xFF00E676) : Colors.white38,
              ),
            ),
          ),
          const SizedBox(height: 28),
          Text(roomId,
              style: GoogleFonts.jetBrainsMono(
                  fontSize: 12, color: Colors.white12, letterSpacing: 3)),
        ]),
      ),
    );
  }
}

class _StatusView extends StatelessWidget {
  final IconData? icon;
  final Color iconColor;
  final String title, subtitle, roomId;
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
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (showSpinner)
            const SizedBox(
              width: 36,
              height: 36,
              child: CircularProgressIndicator(
                  color: Color(0xFF6C63FF), strokeWidth: 2),
            )
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
        ]),
      ),
    );
  }
}

class _RoomChip extends StatelessWidget {
  final String roomId;
  const _RoomChip({required this.roomId});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
            color: Colors.black45, borderRadius: BorderRadius.circular(20)),
        child: Text(roomId,
            style: GoogleFonts.jetBrainsMono(
                fontSize: 14, color: Colors.white60, letterSpacing: 2)),
      );
}

class _LiveBadge extends StatelessWidget {
  const _LiveBadge();
  @override
  Widget build(BuildContext context) => Container(
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

class _EndCallButton extends StatelessWidget {
  final VoidCallback onTap;
  const _EndCallButton({required this.onTap});
  @override
  Widget build(BuildContext context) => GestureDetector(
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

class _BottomControls extends StatelessWidget {
  final bool micOn, cameraOn, screenSharing, videoSharing, isInitiator;
  final VoidCallback onMic, onCamera;
  final VoidCallback? onScreen; // web only — null on mobile
  final VoidCallback? onVideo; // mobile only — null on web / viewer

  const _BottomControls({
    required this.micOn,
    required this.cameraOn,
    required this.screenSharing,
    required this.videoSharing,
    required this.isInitiator,
    required this.onMic,
    required this.onCamera,
    this.onScreen,
    this.onVideo,
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
              onTap: onMic,
            ),
            const SizedBox(width: 20),

            // Web: screen share button
            if (onScreen != null) ...[
              _ControlButton(
                icon: screenSharing
                    ? Icons.stop_screen_share_rounded
                    : Icons.screen_share_rounded,
                active: screenSharing,
                activeColor: const Color(0xFF0ECFCF),
                onTap: onScreen!,
              ),
              const SizedBox(width: 20),
            ],

            // Mobile initiator: video share button
            if (onVideo != null) ...[
              _ControlButton(
                icon: videoSharing
                    ? Icons.stop_circle_outlined
                    : Icons.video_library_rounded,
                active: videoSharing,
                activeColor: const Color(0xFF0ECFCF),
                onTap: onVideo!,
              ),
              const SizedBox(width: 20),
            ],

            _ControlButton(
              icon: cameraOn
                  ? Icons.videocam_rounded
                  : Icons.videocam_off_rounded,
              active: cameraOn,
              onTap: onCamera,
            ),
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
  Widget build(BuildContext context) => GestureDetector(
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
