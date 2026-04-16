import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

// Now carries trackKind ('audio' | 'video') so CallScreen routes correctly
// without inspecting stream contents (which can be unreliable mid-negotiation).
typedef OnTrackCallback = void Function(MediaStream stream, String trackKind);
typedef OnIceCandidateCallback = void Function(RTCIceCandidate candidate);
typedef OnConnectionStateCallback = void Function(RTCPeerConnectionState state);

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

  OnIceCandidateCallback? onIceCandidate;
  OnConnectionStateCallback? onConnectionState;

  final List<RTCIceCandidate> _pendingCandidates = [];
  bool _remoteDescriptionSet = false;

  // Stored so _clearScreenTrack() removes exactly the screen video/audio
  // senders and never accidentally removes the local mic sender.
  RTCRtpSender? _screenVideoSender; // BUG 2 FIX: store screen video sender ref
  RTCRtpSender? _screenAudioSender;

  String? _localMicTrackId;

  static const Map<String, dynamic> _iceConfig = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
      {'urls': 'stun:stun1.l.google.com:19302'},
    ],
    'sdpSemantics': 'unified-plan',
  };

  static const Map<String, dynamic> _offerSdpConstraints = {
    'mandatory': {'OfferToReceiveAudio': true, 'OfferToReceiveVideo': true},
    'optional': [],
  };

  Future<void> initialize() async {
    _peerConnection = await createPeerConnection(_iceConfig);

    _peerConnection!.onIceCandidate = (candidate) {
      onIceCandidate?.call(candidate);
    };

    // Pass track.kind explicitly — far more reliable than inspecting stream
    // track lists, which can be in flux during renegotiation.
    _peerConnection!.onTrack = (event) {
      if (event.streams.isEmpty) return;
      final kind = event.track.kind ?? '';
      debugPrint('📥 onTrack kind=$kind streamId=${event.streams.first.id}');
      onRemoteStream?.call(event.streams.first, kind);
    };

    _peerConnection!.onConnectionState = (state) {
      onConnectionState?.call(state);
    };

    // BUG 3 FIX: wire native negotiation needed event so renegotiation fires
    // automatically when tracks are added/removed (e.g. camera, screen share).
    // Previously this was only triggered manually, so the mic track added
    // during initialize() was never properly renegotiated after offer/answer.
    _peerConnection!.onRenegotiationNeeded = () {
      debugPrint('🔄 Native renegotiation needed');
      onNegotiationNeeded?.call();
    };

    await _initLocalMedia();
  }

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
      _localMicTrackId = _localStream!.getAudioTracks().firstOrNull?.id;
      debugPrint(
          '✅ Audio tracks added: ${_localStream!.getAudioTracks().length}');
    } catch (e) {
      debugPrint('❌ Media init error: $e');
    }
  }

  Future<RTCSessionDescription> createOffer() async {
    final offer = await _peerConnection!.createOffer(_offerSdpConstraints);
    await _peerConnection!.setLocalDescription(offer);
    return offer;
  }

  Future<RTCSessionDescription> createAnswer() async {
    final answer = await _peerConnection!.createAnswer(_offerSdpConstraints);
    await _peerConnection!.setLocalDescription(answer);
    return answer;
  }

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

  // ── Mic ──────────────────────────────────────────────────────────────────
  Future<void> toggleMicrophone() async {
    _micEnabled = !_micEnabled;
    // BUG 3 FIX: guard against empty track list
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

  // ── Camera ───────────────────────────────────────────────────────────────
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

      // BUG 1 FIX: listen for external track-end (e.g. browser/OS kills camera)
      // so we always send camera_off to the peer and clean up state.
      videoTrack.onEnded = () {
        debugPrint('📷 Camera track ended externally');
        _cameraEnabled = false;
        _cameraStream?.getTracks().forEach((t) => t.stop());
        _cameraStream?.dispose();
        _cameraStream = null;
        onCameraOff?.call(); // → CallScreen sends camera_off to peer
        onNegotiationNeeded?.call(); // renegotiate to remove the dead sender
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
      onNegotiationNeeded?.call();
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
    onNegotiationNeeded?.call();
    onLocalCameraStopped?.call();
  }

  // ── Screen share ─────────────────────────────────────────────────────────
  Future<void> startScreenShare() async {
    try {
      // BUG 4 FIX: pass proper audio constraints so Chrome captures tab audio.
      // suppressLocalAudioPlayback:false prevents Chrome from muting the tab
      // for the sharer while sharing — without this the audio track exists but
      // carries silence. echoCancellation/noiseSuppression must be false for
      // system audio (they are designed for mic input, not loopback).
      _screenStream = await navigator.mediaDevices.getDisplayMedia({
        'video': {
          'width': {'max': 1920},
          'height': {'max': 1080},
          'frameRate': {'max': 15},
        },
        'audio': {
          'suppressLocalAudioPlayback': false,
          'echoCancellation': false,
          'noiseSuppression': false,
          'sampleRate': 44100,
        },
      });

      final screenVideoTrack = _screenStream!.getVideoTracks().first;

      // BUG 2 FIX: always add screen share as a NEW sender — never reuse the
      // camera sender via replaceTrack(). When replaceTrack is used the viewer
      // receives the same stream ID as the camera stream, so the dedup guard
      // in CallScreen routes it to _pipRenderer instead of _mainRenderer.
      // A new addTrack() call gives a new stream ID, which combined with the
      // screen_start signal correctly routes to _mainRenderer.
      _screenVideoSender =
          await _peerConnection!.addTrack(screenVideoTrack, _screenStream!);
      debugPrint('🖥️ Screen video sender stored');

      // Store screen audio sender reference for precise removal on stop.
      final screenAudioTracks = _screenStream!.getAudioTracks();
      if (screenAudioTracks.isNotEmpty) {
        _screenAudioSender = await _peerConnection!
            .addTrack(screenAudioTracks.first, _screenStream!);
        debugPrint('🔊 Screen audio sender stored');
      } else {
        _screenAudioSender = null;
        debugPrint('ℹ️ No screen audio from platform');
      }

      _screenSharing = true;
      onNegotiationNeeded?.call();

      // BUG 1 FIX (screen): also handle track-end for screen share so the
      // sharer's UI updates and screen_off is sent if user stops via browser UI.
      screenVideoTrack.onEnded = () {
        _screenSharing = false;
        _clearScreenTrack();
        onScreenShareStopped?.call();
      };
    } catch (e) {
      debugPrint('❌ Screen share error: $e');
      _screenSharing = false;
    }
  }

  Future<void> stopScreenShare() async {
    await _clearScreenTrack();
    onNegotiationNeeded?.call();
    onScreenShareStopped?.call();
  }

  Future<void> _clearScreenTrack() async {
    _screenStream?.getTracks().forEach((t) => t.stop());
    _screenStream?.dispose();
    _screenStream = null;

    // BUG 2 FIX: remove screen video sender by stored reference, not by
    // iterating all video senders — that could accidentally remove the camera
    // sender if camera was also active during screen share.
    if (_screenVideoSender != null) {
      try {
        await _peerConnection!.removeTrack(_screenVideoSender!);
        debugPrint('🖥️ Screen video sender removed');
      } catch (e) {
        debugPrint('⚠️ removeTrack screenVideo: $e');
      }
      _screenVideoSender = null;
    }

    // Remove screen audio sender by stored reference — never touches mic.
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

  bool get micEnabled => _micEnabled;
  bool get cameraEnabled => _cameraEnabled;
  bool get screenSharing => _screenSharing;

  Future<void> dispose() async {
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
