import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'audio_capture_stub.dart'
    if (dart.library.io) 'audio_capture_native.dart';
import 'video_share_service.dart';

typedef OnTrackCallback = void Function(MediaStream stream, String trackKind);
typedef OnIceCandidateCallback = void Function(RTCIceCandidate candidate);
typedef OnConnectionStateCallback = void Function(RTCPeerConnectionState state);
typedef OnAudioDataCallback = void Function(Uint8List data);

class WebRTCService {
  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream; // mic-only
  MediaStream? _cameraStream;
  // Screen share kept but only active on web:
  MediaStream? _screenStream;
  bool _isNegotiating = false;
  set isNegotiating(bool v) => _isNegotiating = v;

  bool _micEnabled = true;
  bool _cameraEnabled = false;
  bool _screenSharing = false; // web only
  bool _videoSharing = false; // mobile only

  OnTrackCallback? onRemoteStream;
  Future<void> Function()? onNegotiationNeeded;
  VoidCallback? onLocalCameraStopped;
  VoidCallback? onScreenShareStopped;
  VoidCallback? onCameraOff;
  VoidCallback? onVideoShareStopped;

  final _audioCaptureService = AudioCaptureService();

  OnAudioDataCallback? onRemoteAudioData;
  OnIceCandidateCallback? onIceCandidate;
  OnConnectionStateCallback? onConnectionState;

  // ── DataChannel (audio relay: sharer → viewer) ────────────────────────────
  RTCDataChannel? _audioDataChannel;

  static const _methodChannel =
      MethodChannel('com.example.chat_mate/screen_share');

  final List<RTCIceCandidate> _pendingCandidates = [];
  bool _remoteDescriptionSet = false;

  RTCRtpSender? _screenVideoSender;
  RTCRtpSender? _screenAudioSender;

  // ── Video share ───────────────────────────────────────────────────────────
  late final VideoShareService _videoShare;

  // ── ICE / TURN ────────────────────────────────────────────────────────────
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

  bool _isInitiator = false;

  // ── Initialize ────────────────────────────────────────────────────────────
  Future<void> initialize({bool isInitiator = false}) async {
    _isInitiator = isInitiator;
    _videoShare = VideoShareService();

    _peerConnection = await createPeerConnection(_iceConfig);

    _peerConnection!.onIceCandidate = (c) => onIceCandidate?.call(c);

    _peerConnection!.onTrack = (event) {
      if (event.streams.isEmpty) return;
      final kind = event.track.kind ?? '';
      debugPrint('📥 onTrack kind=$kind id=${event.streams.first.id}');
      onRemoteStream?.call(event.streams.first, kind);
    };

    _peerConnection!.onConnectionState = (s) => onConnectionState?.call(s);

    _peerConnection!.onRenegotiationNeeded = () async {
      if (_isNegotiating) {
        debugPrint('⏭️ Skipping renegotiation — already in progress');
        return;
      }
      // Don't fire during initial setup before peer has joined
      if (!_isInitiator) return;
      final sigState = await _peerConnection?.getSignalingState();
      if (sigState != RTCSignalingState.RTCSignalingStateStable) {
        debugPrint('⏭️ Skipping renegotiation — not stable ($sigState)');
        return;
      }
      _isNegotiating = true;
      debugPrint('🔄 renegotiation needed');
      try {
        await onNegotiationNeeded?.call();
      } catch (e) {
        debugPrint('❌ onNegotiationNeeded error: $e');
        _isNegotiating = false;
      }
    };

    _peerConnection!.onDataChannel = (RTCDataChannel channel) {
      if (channel.label == 'system_audio') {
        debugPrint('🎵 system_audio DataChannel received');
        _audioDataChannel = channel;
        channel.onMessage = (msg) {
          if (msg.isBinary) onRemoteAudioData?.call(msg.binary);
        };
      }
    };

    if (isInitiator) {
      _audioDataChannel = await _peerConnection!.createDataChannel(
        'system_audio',
        RTCDataChannelInit()
          ..ordered = false
          ..maxRetransmits = 0,
      );
      _audioDataChannel!.onDataChannelState =
          (s) => debugPrint('🎵 DataChannel state: $s');
      debugPrint('🎵 system_audio DataChannel created (initiator)');
    }

    // Wire video share PCM → DataChannel relay
    _videoShare.onPCMData = relayAudioToViewer;
    _videoShare.onAudioEnded = () {
      debugPrint('🎬 Video share audio ended');
      onVideoShareStopped?.call();
    };

    await _initLocalMedia();
  }

  // ── Mic ───────────────────────────────────────────────────────────────────
  Future<void> _initLocalMedia() async {
    try {
      _localStream = await navigator.mediaDevices.getUserMedia({
        'audio': true,
        'video': false,
      });
      for (final t in _localStream!.getTracks()) {
        t.enabled = true;
        await _peerConnection!.addTrack(t, _localStream!);
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
  String _preferH264(String sdp) {
    final lines = sdp.split('\r\n');
    final h264Payloads = <String>[];
    for (final l in lines) {
      if (l.contains('a=rtpmap') && l.toLowerCase().contains('h264')) {
        final m = RegExp(r'a=rtpmap:(\d+)').firstMatch(l);
        if (m != null) h264Payloads.add(m.group(1)!);
      }
    }
    if (h264Payloads.isEmpty) return sdp;
    final result = <String>[];
    for (final l in lines) {
      if (l.startsWith('m=video')) {
        final parts = l.split(' ');
        final header = parts.sublist(0, 3);
        final payloads = parts.sublist(3);
        final reordered = [
          ...h264Payloads.where((p) => payloads.contains(p)),
          ...payloads.where((p) => !h264Payloads.contains(p)),
        ];
        result.add([...header, ...reordered].join(' '));
      } else {
        result.add(l);
      }
    }
    return result.join('\r\n');
  }

  String _setVideoBandwidth(String sdp, int kbps) {
    final lines = sdp.split('\r\n');
    final result = <String>[];
    for (final l in lines) {
      result.add(l);
      if (l.startsWith('m=video')) result.add('b=AS:$kbps');
    }
    return result.join('\r\n');
  }

  // ── Remote desc / ICE ────────────────────────────────────────────────────
  Future<void> setRemoteDescription(RTCSessionDescription desc) async {
    await _peerConnection!.setRemoteDescription(desc);
    _remoteDescriptionSet = true;
    _isNegotiating = false; // ← add this line here too
    for (final c in List.of(_pendingCandidates)) {
      try {
        await _peerConnection!.addCandidate(c);
      } catch (e) {
        debugPrint('❌ queued candidate: $e');
      }
    }
    _pendingCandidates.clear();
  }

  Future<RTCSignalingState?> getSignalingState() =>
      _peerConnection?.getSignalingState() ?? Future.value(null);

  Future<void> addIceCandidate(RTCIceCandidate c) async {
    if (!_remoteDescriptionSet) {
      _pendingCandidates.add(c);
      return;
    }
    try {
      await _peerConnection!.addCandidate(c);
    } catch (e) {
      debugPrint('❌ addIceCandidate: $e');
    }
  }

  // ── Mic toggle ────────────────────────────────────────────────────────────
  Future<void> toggleMicrophone() async {
    _micEnabled = !_micEnabled;
    for (final t in _localStream?.getAudioTracks() ?? []) {
      t.enabled = _micEnabled;
    }
    debugPrint('🎤 Mic ${_micEnabled ? "ON" : "OFF"}');
  }

  // ── Camera ────────────────────────────────────────────────────────────────
  Future<void> toggleCamera() async {
    _cameraEnabled = !_cameraEnabled;
    if (_cameraEnabled)
      await _startCamera();
    else
      await _stopCamera();
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

      final vt = _cameraStream!.getVideoTracks().first;
      vt.onEnded = () {
        debugPrint('📷 Camera track ended externally');
        _cameraEnabled = false;
        _cameraStream?.getTracks().forEach((t) => t.stop());
        _cameraStream?.dispose();
        _cameraStream = null;
        onCameraOff?.call();
        onNegotiationNeeded?.call();
      };

      final senders = await _peerConnection!.getSenders();
      final vidSenders =
          senders.where((s) => s.track?.kind == 'video').toList();

      if (_screenSharing) {
        await _peerConnection!.addTrack(vt, _cameraStream!);
      } else if (vidSenders.isNotEmpty) {
        await vidSenders.first.replaceTrack(vt);
      } else {
        await _peerConnection!.addTrack(vt, _cameraStream!);
      }
      _cameraEnabled = true;
    } catch (e) {
      debugPrint('❌ Camera error: $e');
      _cameraEnabled = false;
    }
  }

  Future<void> _stopCamera() async {
    if (_screenSharing && _cameraStream != null) {
      final camId = _cameraStream!.getVideoTracks().firstOrNull?.id;
      final senders = await _peerConnection!.getSenders();
      for (final s in senders) {
        if (s.track?.id == camId) {
          await _peerConnection!.removeTrack(s);
          break;
        }
      }
    } else {
      final senders = await _peerConnection!.getSenders();
      for (final s in senders) {
        if (s.track?.kind == 'video') await s.replaceTrack(null);
      }
    }
    _cameraStream?.getTracks().forEach((t) => t.stop());
    _cameraStream?.dispose();
    _cameraStream = null;
    _cameraEnabled = false;
    onCameraOff?.call();
    onLocalCameraStopped?.call();
  }

  // ── Video share (mobile) ─────────────────────────────────────────────────

  /// Called by CallScreen when the initiator taps the video share button.
  /// Returns true on success.
  Future<bool> startVideoShare() async {
    if (kIsWeb) return false;
    if (_videoSharing) return false;
    if (_peerConnection == null) return false;

    final ok = await _videoShare.pickAndStart(_peerConnection!);
    if (ok) {
      _videoSharing = true;
      debugPrint('🎬 Video share started');
    }
    return ok;
  }

  Future<void> stopVideoShare() async {
    if (!_videoSharing || _peerConnection == null) return;
    await _videoShare.stop(_peerConnection!);
    _videoSharing = false;
    onVideoShareStopped?.call();
    debugPrint('🛑 Video share stopped');
  }

  // ── Screen share (WEB ONLY — kept intact, disabled on mobile) ────────────

  Future<bool> startScreenShare() async {
    // On mobile this feature is replaced by video share.
    if (!kIsWeb) {
      debugPrint(
          'ℹ️ Screen share is web-only; use startVideoShare() on mobile');
      return false;
    }
    debugPrint('🚀 startScreenShare (web)');
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

      final screenVideo = _screenStream!.getVideoTracks().firstOrNull;
      if (screenVideo == null) {
        _screenStream?.dispose();
        _screenStream = null;
        return false;
      }

      // Guard against getting a camera track on mobile web
      final label = (screenVideo.label ?? '').toLowerCase();
      final likeCamera = label.contains('camera') ||
          label.contains('facetime') ||
          label.contains('front') ||
          label.contains('back') ||
          label.contains('webcam');
      final likeScreen = label.contains('screen') ||
          label.contains('window') ||
          label.contains('tab') ||
          label.contains('display') ||
          label.contains('monitor');
      if (kIsWeb && likeCamera && !likeScreen) {
        _screenStream!.getTracks().forEach((t) => t.stop());
        _screenStream!.dispose();
        _screenStream = null;
        debugPrint('❌ Got camera track on mobile web — aborting');
        return false;
      }

      _screenVideoSender =
          await _peerConnection!.addTrack(screenVideo, _screenStream!);
      await _applyScreenShareEncoderParams(_screenVideoSender!);

      final screenAudio = _screenStream!.getAudioTracks();
      if (screenAudio.isNotEmpty) {
        _screenAudioSender =
            await _peerConnection!.addTrack(screenAudio.first, _screenStream!);
      } else {
        _screenAudioSender = null;
        // Android screen audio via DataChannel (existing FGS path)
        if (!kIsWeb) {
          try {
            await _audioCaptureService.start(relayAudioToViewer);
          } catch (e) {
            debugPrint('⚠️ PlaybackCapture: $e');
          }
        }
      }

      _screenSharing = true;
      screenVideo.onEnded = () {
        _screenSharing = false;
        _clearScreenTrack();
        onScreenShareStopped?.call();
      };
      return true;
    } catch (e, st) {
      debugPrint('❌ startScreenShare: $e\n$st');
      _screenSharing = false;
      _screenStream?.getTracks().forEach((t) => t.stop());
      _screenStream?.dispose();
      _screenStream = null;
      return false;
    }
  }

  Future<void> _applyScreenShareEncoderParams(RTCRtpSender sender) async {
    try {
      final params = sender.parameters;
      params.degradationPreference =
          RTCDegradationPreference.MAINTAIN_RESOLUTION;
      final encodings = params.encodings;
      if (encodings != null && encodings.isNotEmpty) {
        encodings[0].maxBitrate = 4000 * 1000;
        encodings[0].minBitrate = 500 * 1000;
        encodings[0].maxFramerate = 30;
        encodings[0].scaleResolutionDownBy = 1.0;
        params.encodings = encodings;
      }
      await sender.setParameters(params);
    } catch (e) {
      debugPrint('⚠️ setParameters: $e');
    }
  }

  Future<void> stopScreenShare() async {
    await _clearScreenTrack();
    _stopDataChannelAudio();
    if (!kIsWeb) {
      try {
        await _audioCaptureService.stop();
        await _methodChannel.invokeMethod('stopScreenCaptureFgs');
      } catch (_) {}
    }
    onScreenShareStopped?.call();
  }

  // ── Audio helpers ─────────────────────────────────────────────────────────

  Future<void> sendAudioBytesToNative(Uint8List bytes) async {
    try {
      await _methodChannel.invokeMethod('playAudioBytes', bytes);
    } catch (_) {}
  }

  /// Relay PCM bytes to the remote peer via DataChannel.
  /// Used by both screen share (existing) and video share (new).
  void relayAudioToViewer(Uint8List bytes) {
    if (_audioDataChannel?.state == RTCDataChannelState.RTCDataChannelOpen) {
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
      } catch (e) {
        debugPrint('⚠️ removeTrack screenVideo: $e');
      }
      _screenVideoSender = null;
    }
    if (_screenAudioSender != null) {
      try {
        await _peerConnection!.removeTrack(_screenAudioSender!);
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
  bool get videoSharing => _videoSharing;
  VideoShareService get videoShare => _videoShare;

  // ── Dispose ───────────────────────────────────────────────────────────────
  Future<void> dispose() async {
    _stopDataChannelAudio();
    await _audioCaptureService.stop();
    if (_videoSharing && _peerConnection != null) {
      await _videoShare.stop(_peerConnection!);
    }
    _videoShare.dispose();
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
