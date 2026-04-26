import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:video_player/video_player.dart';

typedef PCMCallback = void Function(Uint8List pcm);
typedef VoidAsyncCallback = Future<void> Function();

class VideoShareService {
  // ── Constants ───────────────────────────────────────────────────────────────
  static const _ch = MethodChannel('com.example.chat_mate/screen_share');

  /// flutter_webrtc's internal method channel — used to call addTrack by trackId.
  static const _webrtcCh = MethodChannel('FlutterWebRTC.Method');

  static const _videoTrackId = 'video_share_track';
  static const _fps = 15;

  // ── State ───────────────────────────────────────────────────────────────────
  VideoPlayerController? _player;
  RTCRtpSender? _videoSender;
  Timer? _framePumpTimer;

  bool _active = false;
  String? _filePath;

  // ── Callbacks ───────────────────────────────────────────────────────────────
  PCMCallback? onPCMData;
  VoidCallback? onAudioEnded;

  // ── Public getters ──────────────────────────────────────────────────────────
  bool get isActive => _active;
  VideoPlayerController? get playerController => _player;
  String? get filePath => _filePath;

  // ── Pick & start ─────────────────────────────────────────────────────────────

  Future<bool> pickAndStart(RTCPeerConnection pc) async {
    assert(!kIsWeb, 'VideoShareService is mobile-only');

    final res = await FilePicker.platform.pickFiles(
      type: FileType.video,
      allowMultiple: false,
    );
    if (res == null || res.files.isEmpty) return false;

    final path = res.files.single.path;
    if (path == null) return false;

    return startWithPath(path, pc);
  }

  Future<bool> startWithPath(String path, RTCPeerConnection pc) async {
    if (_active) await stop(pc);
    _filePath = path;

    try {
      // ── 1. video_player (MUTED — audio comes from native pipeline) ───────
      _player = VideoPlayerController.contentUri(Uri.parse('file://$path'));
      await _player!.initialize();
      await _player!.setVolume(0.0);
      await _player!.setLooping(false);

// ── 2. Native audio decode (speaker + PCM callbacks) ─────────────────
      _ch.setMethodCallHandler(_handleNativeCall);
      await _ch.invokeMethod('startVideoShareAudio', {'filePath': path});

      // ── 2b. Native video decode (frame capture pipeline) ──────────────────
      await _ch.invokeMethod('startVideoShareVideo', {'filePath': path});

      // ── 3. Create custom WebRTC video track (native) ──────────────────────
      await _webrtcCh.invokeMethod(
        'createCustomVideoTrack',
        {'trackId': _videoTrackId},
      );

      // ── 4. Add custom track to peer connection via flutter_webrtc channel ─
      final added = await _addCustomTrackToPeerConnection(pc);
      if (added) {
        debugPrint('✅ VideoShareService: video track added to PC');
      } else {
        debugPrint(
            '⚠️ VideoShareService: could not add video track — audio only');
      }

      // ── 5. Start playback ─────────────────────────────────────────────────
      await _player!.play();

      // ── 6. Frame pump ─────────────────────────────────────────────────────
      _startFramePump();

      _active = true;
      debugPrint('✅ VideoShareService started: $path');
      return true;
    } catch (e, st) {
      debugPrint('❌ VideoShareService.startWithPath: $e\n$st');
      await _cleanup(pc);
      return false;
    }
  }

  // ── Add track via flutter_webrtc internal channel ─────────────────────────
  //
  // After createCustomVideoTrack, the native patch registers the VideoTrack
  // in MethodCallHandlerImpl.localTracks[trackId]. We retrieve it by calling
  // the plugin's own addTrack handler with the trackId we registered.

  Future<bool> _addCustomTrackToPeerConnection(RTCPeerConnection pc) async {
    try {
      final stream = await createLocalMediaStream('video_share_stream');

      // Get the peer connection's internal ID used by flutter_webrtc
      final pcId = _getPeerConnectionId(pc);
      if (pcId == null) {
        debugPrint('❌ peerConnectionId not accessible');
        return false;
      }

      final result = await _webrtcCh.invokeMethod('addTrack', {
        'peerConnectionId': pcId,
        'trackId': _videoTrackId,
        'streamIds': [stream.id],
      });

      debugPrint('✅ addTrack result: $result');
      return true;
    } catch (e) {
      debugPrint('❌ _addCustomTrackToPeerConnection: $e');
      return false;
    }
  }

  String? _getPeerConnectionId(RTCPeerConnection pc) {
    try {
      return (pc as dynamic).peerConnectionId as String?;
    } catch (e) {
      debugPrint('⚠️ _getPeerConnectionId: $e');
      return null;
    }
  }

  // ── Controls ─────────────────────────────────────────────────────────────────

  Future<void> pause() async {
    await _player?.pause();
    await _ch.invokeMethod('pauseVideoShareAudio');
  }

  Future<void> resume() async {
    await _player?.play();
    await _ch.invokeMethod('resumeVideoShareAudio');
  }

  Future<void> seek(Duration position) async {
    await _player?.seekTo(position);
    await _ch.invokeMethod('seekVideoShareAudio', {
      'positionMs': position.inMilliseconds,
    });
  }

  // ── Stop ─────────────────────────────────────────────────────────────────────

  Future<void> stop(RTCPeerConnection pc) async {
    if (!_active) return;
    _active = false;
    await _cleanup(pc);
  }

  Future<void> _cleanup(RTCPeerConnection pc) async {
    _framePumpTimer?.cancel();
    _framePumpTimer = null;

    try {
      await _ch.invokeMethod('stopVideoShareAudio');
    } catch (_) {}

    try {
      await _ch.invokeMethod('stopVideoShareVideo');
    } catch (_) {}

    try {
      await _webrtcCh
          .invokeMethod('disposeCustomVideoTrack', {'trackId': _videoTrackId});
    } catch (_) {}

    if (_videoSender != null) {
      try {
        await pc.removeTrack(_videoSender!);
      } catch (_) {}
      _videoSender = null;
    }

    await _player?.dispose();
    _player = null;
    _filePath = null;
    debugPrint('🛑 VideoShareService stopped');
  }

  void dispose() {
    _framePumpTimer?.cancel();
    _player?.dispose();
  }

  // ── Frame pump ────────────────────────────────────────────────────────────────

  void _startFramePump() {
    final interval = Duration(milliseconds: (1000 / _fps).round());
    _framePumpTimer = Timer.periodic(interval, (_) async {
      if (!_active) return;
      if (_player?.value.isPlaying != true) return;
      try {
        // Capture current frame from video player as RGBA bytes
        final bytes = await _captureVideoFrame();
        if (bytes == null) return;
        final width = _player!.value.size.width.toInt();
        final height = _player!.value.size.height.toInt();
        await _webrtcCh.invokeMethod('pushVideoFrame', {
          'trackId': _videoTrackId,
          'rgba': bytes,
          'width': width,
          'height': height,
        });
      } catch (e) {
        debugPrint('⚠️ framePump error: $e');
      }
    });
  }

  Future<Uint8List?> _captureVideoFrame() async {
    try {
      // Use the native channel to grab the latest decoded frame from ExoPlayer
      final result = await _ch.invokeMethod<Uint8List>('captureVideoFrame', {
        'trackId': _videoTrackId,
      });
      return result;
    } catch (e) {
      debugPrint('⚠️ captureVideoFrame error: $e');
      return null;
    }
  }
  // ── Native callbacks ──────────────────────────────────────────────────────────

  Future<dynamic> _handleNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'onVideoShareAudioPCM':
        final bytes = call.arguments as Uint8List;
        onPCMData?.call(bytes);
        break;

      case 'onVideoShareAudioEnded':
        debugPrint('🎵 VideoShare audio ended');
        onAudioEnded?.call();
        break;
    }
  }
}
