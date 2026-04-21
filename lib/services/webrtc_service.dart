import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

typedef OnTrackCallback = void Function(MediaStream stream, String trackKind);
typedef OnIceCandidateCallback = void Function(RTCIceCandidate candidate);
typedef OnConnectionStateCallback = void Function(RTCPeerConnectionState state);
typedef OnAudioDataCallback = void Function(Uint8List data);

class WebRTCService {
  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;
  MediaStream? _cameraStream;
  MediaStream? _screenStream;

  bool _micEnabled = true;
  bool _cameraEnabled = false;
  bool _screenSharing = false;

  OnTrackCallback? onRemoteStream;
  VoidCallback? onNegotiationNeeded;
  VoidCallback? onLocalCameraStopped;
  VoidCallback? onScreenShareStopped;
  VoidCallback? onCameraOff;

  /// PCM audio bytes from the sharer's system audio, delivered via DataChannel.
  /// CallScreen decides whether to play via Web Audio API (web) or
  /// native AudioTrack (Android).
  OnAudioDataCallback? onRemoteAudioData;

  OnIceCandidateCallback? onIceCandidate;
  OnConnectionStateCallback? onConnectionState;

  // ── Audio DataChannel ──────────────────────────────────────────────────────
  // Relays system-audio PCM: sharer (Android) → viewer (web or Android).
  RTCDataChannel? _audioDataChannel;

  // MethodChannel — Android-only, used for native AudioTrack playback on
  // the viewer side and FGS control on the sharer side.
  static const _methodChannel =
      MethodChannel('com.example.chat_mate/screen_share');

  final List<RTCIceCandidate> _pendingCandidates = [];
  bool _remoteDescriptionSet = false;

  RTCRtpSender? _screenVideoSender;
  RTCRtpSender? _screenAudioSender;

  // ── ICE / TURN config ─────────────────────────────────────────────────────
  // TURN servers ensure the connection works even when both peers are behind
  // strict NAT (mobile data, corporate WiFi).  Replace the openrelay entries
  // with your own TURN credentials before shipping to production.
  static const Map<String, dynamic> _iceConfig = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
      {'urls': 'stun:stun1.l.google.com:19302'},
      {
        'urls': 'turn:openrelay.metered.ca:80',
        'username': 'openrelayproject',
        'credential': 'openrelayproject',
      },
      {
        'urls': 'turn:openrelay.metered.ca:443',
        'username': 'openrelayproject',
        'credential': 'openrelayproject',
      },
      {
        'urls': 'turn:openrelay.metered.ca:443?transport=tcp',
        'username': 'openrelayproject',
        'credential': 'openrelayproject',
      },
    ],
    'sdpSemantics': 'unified-plan',
    'iceTransportPolicy': 'all',
    'bundlePolicy': 'max-bundle',
    'rtcpMuxPolicy': 'require',
  };

  static const Map<String, dynamic> _offerSdpConstraints = {
    'mandatory': {'OfferToReceiveAudio': true, 'OfferToReceiveVideo': true},
    'optional': [],
  };

  // ── Initialize ────────────────────────────────────────────────────────────
  Future<void> initialize({bool isInitiator = false}) async {
    _peerConnection = await createPeerConnection(_iceConfig);

    _peerConnection!.onIceCandidate = (candidate) {
      onIceCandidate?.call(candidate);
    };

    _peerConnection!.onTrack = (event) {
      if (event.streams.isEmpty) return;
      final kind = event.track.kind ?? '';
      debugPrint('📥 onTrack kind=$kind streamId=${event.streams.first.id}');
      onRemoteStream?.call(event.streams.first, kind);
    };

    _peerConnection!.onConnectionState = (state) {
      onConnectionState?.call(state);
    };

    _peerConnection!.onRenegotiationNeeded = () {
      debugPrint('🔄 Native renegotiation needed');
      onNegotiationNeeded?.call();
    };

    // Viewer side: receive system-audio PCM via DataChannel.
    // CallScreen.onRemoteAudioData decides how to play it (web vs Android).
    _peerConnection!.onDataChannel = (RTCDataChannel channel) {
      if (channel.label == 'system_audio') {
        debugPrint('🎵 Received system_audio DataChannel from sharer');
        _audioDataChannel = channel;
        channel.onMessage = (RTCDataChannelMessage msg) {
          if (msg.isBinary) {
            onRemoteAudioData?.call(msg.binary);
          }
        };
      }
    };

    // Sharer side: create DataChannel upfront so it appears in the SDP offer.
    if (isInitiator) {
      _audioDataChannel = await _peerConnection!.createDataChannel(
        'system_audio',
        RTCDataChannelInit()
          ..ordered = false
          ..maxRetransmits = 0, // UDP-like — drop stale audio frames
      );
      debugPrint('🎵 system_audio DataChannel created (Initiator)');
    }

    await _initLocalMedia();
  }

  // ── Local mic ─────────────────────────────────────────────────────────────
  Future<void> _initLocalMedia() async {
    try {
      _localStream = await navigator.mediaDevices.getUserMedia({
        'audio': true,
        'video': false,
      });
      for (final track in _localStream!.getTracks()) {
        track.enabled = true;
        await _peerConnection!.addTrack(track, _localStream!);
      }
      debugPrint('✅ Mic track added');
    } catch (e) {
      debugPrint('❌ Media init error: $e');
    }
  }

  // ── Offer / Answer ────────────────────────────────────────────────────────
  Future<RTCSessionDescription> createOffer() async {
    final offer = await _peerConnection!.createOffer(_offerSdpConstraints);
    final sdp = _preferH264(_setVideoBandwidth(offer.sdp!, 4000));
    final desc = RTCSessionDescription(sdp, 'offer');
    await _peerConnection!.setLocalDescription(desc);
    return desc;
  }

  Future<RTCSessionDescription> createAnswer() async {
    final answer = await _peerConnection!.createAnswer(_offerSdpConstraints);
    final sdp = _preferH264(_setVideoBandwidth(answer.sdp!, 4000));
    final desc = RTCSessionDescription(sdp, 'answer');
    await _peerConnection!.setLocalDescription(desc);
    return desc;
  }

  // ── SDP helpers ───────────────────────────────────────────────────────────

  /// Reorders the m=video payload list so H264 is negotiated first.
  /// Android hardware encoders support H264 natively — using it instead of
  /// VP8 (which is software-only on most Android devices) cuts CPU usage
  /// dramatically and removes the main source of encode-side stuttering.
  String _preferH264(String sdp) {
    final lines = sdp.split('\r\n');
    final h264Payloads = <String>[];

    for (final line in lines) {
      if (line.contains('a=rtpmap') && line.toLowerCase().contains('h264')) {
        final match = RegExp(r'a=rtpmap:(\d+)').firstMatch(line);
        if (match != null) h264Payloads.add(match.group(1)!);
      }
    }

    if (h264Payloads.isEmpty) return sdp;

    final result = <String>[];
    for (final line in lines) {
      if (line.startsWith('m=video')) {
        final parts = line.split(' ');
        final header = parts.sublist(0, 3);
        final payloads = parts.sublist(3);
        final reordered = [
          ...h264Payloads.where((p) => payloads.contains(p)),
          ...payloads.where((p) => !h264Payloads.contains(p)),
        ];
        result.add([...header, ...reordered].join(' '));
      } else {
        result.add(line);
      }
    }
    return result.join('\r\n');
  }

  /// Inserts b=AS:<kbps> after m=video.  Respected by desktop browsers;
  /// Android ignores it — real bitrate control is via setParameters() below.
  String _setVideoBandwidth(String sdp, int kbps) {
    final lines = sdp.split('\r\n');
    final result = <String>[];
    for (final line in lines) {
      result.add(line);
      if (line.startsWith('m=video')) {
        result.add('b=AS:$kbps');
      }
    }
    return result.join('\r\n');
  }

  // ── Remote description / ICE ──────────────────────────────────────────────
  Future<void> setRemoteDescription(RTCSessionDescription desc) async {
    await _peerConnection!.setRemoteDescription(desc);
    _remoteDescriptionSet = true;
    for (final c in List.of(_pendingCandidates)) {
      try {
        await _peerConnection!.addCandidate(c);
      } catch (e) {
        debugPrint('❌ queued candidate error: $e');
      }
    }
    _pendingCandidates.clear();
  }

  Future<RTCSignalingState?> getSignalingState() async {
    return await _peerConnection?.getSignalingState();
  }

  Future<void> addIceCandidate(RTCIceCandidate candidate) async {
    if (!_remoteDescriptionSet) {
      _pendingCandidates.add(candidate);
      return;
    }
    try {
      await _peerConnection!.addCandidate(candidate);
    } catch (e) {
      debugPrint('❌ addIceCandidate error: $e');
    }
  }

  // ── Mic toggle ────────────────────────────────────────────────────────────
  Future<void> toggleMicrophone() async {
    _micEnabled = !_micEnabled;
    final tracks = _localStream?.getAudioTracks() ?? [];
    if (tracks.isEmpty) {
      debugPrint('⚠️ No audio tracks to toggle');
      return;
    }
    for (final track in tracks) {
      track.enabled = _micEnabled;
    }
    debugPrint('🎤 Mic ${_micEnabled ? "ON" : "OFF"}');
  }

  // ── Camera ────────────────────────────────────────────────────────────────
  Future<void> toggleCamera() async {
    _cameraEnabled = !_cameraEnabled;
    if (_cameraEnabled) {
      await _startCamera();
    } else {
      await _stopCamera();
    }
  }

  Future<void> _startCamera() async {
    try {
      _cameraStream = await navigator.mediaDevices.getUserMedia({
        'video': {
          'facingMode': 'user',
          'width': {'ideal': 640},
          'height': {'ideal': 480},
          'frameRate': {'max': 15},
        },
        'audio': false,
      });

      final videoTrack = _cameraStream!.getVideoTracks().first;

      videoTrack.onEnded = () {
        debugPrint('📷 Camera track ended externally');
        _cameraEnabled = false;
        _cameraStream?.getTracks().forEach((t) => t.stop());
        _cameraStream?.dispose();
        _cameraStream = null;
        onCameraOff?.call();
        onNegotiationNeeded?.call();
      };

      final senders = await _peerConnection!.getSenders();
      final videoSenders =
          senders.where((s) => s.track?.kind == 'video').toList();

      if (_screenSharing) {
        await _peerConnection!.addTrack(videoTrack, _cameraStream!);
      } else if (videoSenders.isNotEmpty) {
        await videoSenders.first.replaceTrack(videoTrack);
      } else {
        await _peerConnection!.addTrack(videoTrack, _cameraStream!);
      }

      _cameraEnabled = true;
    } catch (e) {
      debugPrint('❌ Camera error: $e');
      _cameraEnabled = false;
    }
  }

  Future<void> _stopCamera() async {
    if (_screenSharing && _cameraStream != null) {
      final cameraTrackId = _cameraStream!.getVideoTracks().firstOrNull?.id;
      final senders = await _peerConnection!.getSenders();
      for (final sender in senders) {
        if (sender.track?.id == cameraTrackId) {
          await _peerConnection!.removeTrack(sender);
          break;
        }
      }
    } else {
      final senders = await _peerConnection!.getSenders();
      for (final sender in senders) {
        if (sender.track?.kind == 'video') {
          await sender.replaceTrack(null);
        }
      }
    }

    _cameraStream?.getTracks().forEach((t) => t.stop());
    _cameraStream?.dispose();
    _cameraStream = null;
    _cameraEnabled = false;

    onCameraOff?.call();
    onLocalCameraStopped?.call();
  }

  // ── Screen share ──────────────────────────────────────────────────────────
  Future<bool> startScreenShare() async {
    debugPrint('🚀 startScreenShare: called');
    try {
      if (!kIsWeb) {
        // Step 1 — request system permission (stores token in plugin).
        final granted = await Helper.requestCapturePermission();
        if (!granted) {
          debugPrint('❌ Screen capture permission denied');
          return false;
        }
        debugPrint('✅ Permission granted, token stored in plugin');

        // Step 2 — start & bind FGS; await resolves only after
        // onServiceConnected fires, guaranteeing startForeground() ran.
        try {
          await _methodChannel.invokeMethod('startScreenCaptureFgs');
          debugPrint('✅ FGS started and bound');
        } catch (e) {
          debugPrint('❌ FGS start failed: $e');
          return false;
        }

        // Step 3 — getDisplayMedia; plugin reuses stored token, no 2nd dialog.
        try {
          _screenStream = await navigator.mediaDevices.getDisplayMedia({
            'video': {
              'width': {'ideal': 1280, 'max': 1280},
              'height': {'ideal': 720, 'max': 720},
              'frameRate': {'ideal': 30, 'max': 30},
            },
            'audio': {
              'suppressLocalAudioPlayback': false,
              'echoCancellation': false,
              'noiseSuppression': false,
              'sampleRate': 48000,
            },
          });
          debugPrint('✅ getDisplayMedia succeeded');
        } catch (e) {
          debugPrint('❌ getDisplayMedia failed: $e');
          await _methodChannel.invokeMethod('stopScreenCaptureFgs');
          return false;
        }
      } else {
        // Web — no FGS needed.
        _screenStream = await navigator.mediaDevices.getDisplayMedia({
          'video': {
            'width': {'ideal': 1280, 'max': 1280},
            'height': {'ideal': 720, 'max': 720},
            'frameRate': {'ideal': 30, 'max': 30},
          },
          'audio': {
            'suppressLocalAudioPlayback': false,
            'echoCancellation': false,
            'noiseSuppression': false,
            'sampleRate': 48000,
          },
        });
      }

      final screenVideoTrack = _screenStream!.getVideoTracks().firstOrNull;
      if (screenVideoTrack == null) {
        debugPrint('❌ No video track from getDisplayMedia');
        _screenStream?.dispose();
        _screenStream = null;
        return false;
      }

      // Guard against accidentally getting a camera track on mobile web.
      final label = (screenVideoTrack.label ?? '').toLowerCase();
      final looksLikeCamera = label.contains('camera') ||
          label.contains('facetime') ||
          label.contains('front') ||
          label.contains('back') ||
          label.contains('webcam');
      final looksLikeScreen = label.contains('screen') ||
          label.contains('window') ||
          label.contains('tab') ||
          label.contains('display') ||
          label.contains('monitor');

      if (kIsWeb && looksLikeCamera && !looksLikeScreen) {
        _screenStream!.getTracks().forEach((t) => t.stop());
        _screenStream!.dispose();
        _screenStream = null;
        debugPrint('❌ Aborting: got camera track on mobile web');
        return false;
      }

      // Add video track and immediately tune encoder params.
      _screenVideoSender =
          await _peerConnection!.addTrack(screenVideoTrack, _screenStream!);
      debugPrint('🖥️ Screen video sender added');
      await _applyScreenShareEncoderParams(_screenVideoSender!);

      // Add audio track if the platform delivered one (web typically does,
      // Android typically does not — we use the DataChannel instead).
      final screenAudioTracks = _screenStream!.getAudioTracks();
      if (screenAudioTracks.isNotEmpty) {
        _screenAudioSender = await _peerConnection!
            .addTrack(screenAudioTracks.first, _screenStream!);
        debugPrint('🔊 Screen audio sender added');
      } else {
        _screenAudioSender = null;
        debugPrint('ℹ️ No native screen audio track (expected on Android)');
        if (!kIsWeb) {
          try {
            await _methodChannel.invokeMethod('startInternalAudioCapture');
            debugPrint('🎵 Internal audio capture requested');
          } catch (e) {
            debugPrint('⚠️ startInternalAudioCapture error: $e');
          }
        }
      }

      _screenSharing = true;

      screenVideoTrack.onEnded = () {
        debugPrint('🖥️ Screen track ended externally');
        _screenSharing = false;
        _clearScreenTrack();
        onScreenShareStopped?.call();
      };

      debugPrint('🚀 startScreenShare: success');
      return true;
    } catch (e, stack) {
      debugPrint('❌ startScreenShare error: $e\n$stack');
      _screenSharing = false;
      _screenStream?.getTracks().forEach((t) => t.stop());
      _screenStream?.dispose();
      _screenStream = null;
      return false;
    }
  }

  /// Tunes the screen-share video sender for quality over latency:
  /// - MAINTAIN_RESOLUTION: under congestion drop FPS, never resolution.
  ///   Text/UI content is unreadable when pixelated; choppy is tolerable.
  /// - Explicit bitrate floor/ceiling via setParameters() because Android
  ///   hardware encoders completely ignore the b=AS line in SDP.
  Future<void> _applyScreenShareEncoderParams(RTCRtpSender sender) async {
    try {
      final params = sender.parameters;

      params.degradationPreference =
          RTCDegradationPreference.MAINTAIN_RESOLUTION;

      final encodings = params.encodings;
      if (encodings != null && encodings.isNotEmpty) {
        encodings[0].maxBitrate = 4000 * 1000; // 4 Mbps ceiling
        encodings[0].minBitrate = 500 * 1000; // 500 Kbps floor
        encodings[0].maxFramerate = 30;
        encodings[0].scaleResolutionDownBy = 1.0;
        params.encodings = encodings; // reassign after mutation
      }

      await sender.setParameters(params);
      debugPrint('✅ Screen share encoder params applied');
    } catch (e) {
      debugPrint('⚠️ setParameters failed (non-fatal): $e');
    }
  }

  Future<void> stopScreenShare() async {
    await _clearScreenTrack();
    _stopDataChannelAudio();
    if (!kIsWeb) {
      try {
        await _methodChannel.invokeMethod('stopInternalAudioCapture');
        await _methodChannel.invokeMethod('stopScreenCaptureFgs');
      } catch (_) {}
    }
    onScreenShareStopped?.call();
  }

  // ── Audio helpers ─────────────────────────────────────────────────────────

  /// Android viewer: write PCM bytes to native AudioTrack via MethodChannel.
  Future<void> sendAudioBytesToNative(Uint8List bytes) async {
    try {
      await _methodChannel.invokeMethod('playAudioBytes', bytes);
    } catch (_) {
      // Silently drop — audio glitch beats a crash.
    }
  }

  /// Android sharer: push PCM bytes to the viewer over the DataChannel.
  void relayAudioToViewer(Uint8List bytes) {
    final state = _audioDataChannel?.state;
    debugPrint('🔊 relay: state=$state bytes=${bytes.length}');
    if (state == RTCDataChannelState.RTCDataChannelOpen) {
      _audioDataChannel!.send(RTCDataChannelMessage.fromBinary(bytes));
    }
  }

  void _stopDataChannelAudio() {
    _audioDataChannel?.close();
    _audioDataChannel = null;
  }

  Future<void> _clearScreenTrack() async {
    _screenStream?.getTracks().forEach((t) => t.stop());
    _screenStream?.dispose();
    _screenStream = null;

    if (_screenVideoSender != null) {
      try {
        await _peerConnection!.removeTrack(_screenVideoSender!);
        debugPrint('🖥️ Screen video sender removed');
      } catch (e) {
        debugPrint('⚠️ removeTrack screenVideo: $e');
      }
      _screenVideoSender = null;
    }

    if (_screenAudioSender != null) {
      try {
        await _peerConnection!.removeTrack(_screenAudioSender!);
        debugPrint('🔇 Screen audio sender removed');
      } catch (e) {
        debugPrint('⚠️ removeTrack screenAudio: $e');
      }
      _screenAudioSender = null;
    }

    _screenSharing = false;
  }

  // ── Getters ───────────────────────────────────────────────────────────────
  bool get micEnabled => _micEnabled;
  bool get cameraEnabled => _cameraEnabled;
  bool get screenSharing => _screenSharing;

  // ── Dispose ───────────────────────────────────────────────────────────────
  Future<void> dispose() async {
    _stopDataChannelAudio();
    _localStream?.getTracks().forEach((t) => t.stop());
    _cameraStream?.getTracks().forEach((t) => t.stop());
    _screenStream?.getTracks().forEach((t) => t.stop());
    await _peerConnection?.close();
    _localStream?.dispose();
    _cameraStream?.dispose();
    _screenStream?.dispose();
    _peerConnection = null;
  }
}
