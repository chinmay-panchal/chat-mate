import 'dart:typed_data';
import 'package:flutter/foundation.dart';

// ignore: avoid_web_libraries_in_flutter
import 'dart:js' as js;

class WebAudioPlayer {
  static js.JsObject? _ctx;
  static double _nextPlayTime = 0.0;

  static void init() {
    if (!kIsWeb) return;
    try {
      final ctor =
          js.context['AudioContext'] ?? js.context['webkitAudioContext'];
      if (ctor == null) return;
      _ctx = js.JsObject(ctor as js.JsFunction, []);
      _nextPlayTime = 0.0;
      debugPrint('🔊 WebAudioPlayer: AudioContext created');
    } catch (e) {
      debugPrint('⚠️ WebAudioPlayer init failed: $e');
    }
  }

  static void resume() {
    if (_ctx == null) return;
    try {
      _ctx!.callMethod('resume', []);
    } catch (_) {}
  }

  static void play(Uint8List pcmBytes,
      {int sampleRate = 48000, int channels = 2}) {
    _ensureCtx();
    final ctx = _ctx;
    if (ctx == null) return;

    // ADD THIS:
    final state = ctx['state'];
    debugPrint('🔊 WebAudioPlayer.play: state=$state bytes=${pcmBytes.length}');
    if (state != 'running') {
      ctx.callMethod('resume', []);
      return; // drop this packet, next one will play after resume
    }
    try {
      final totalSamples = pcmBytes.length ~/ 2;
      final frames = totalSamples ~/ channels;
      if (frames <= 0) return;

      final buffer =
          ctx.callMethod('createBuffer', [channels, frames, sampleRate]);
      if (buffer == null) return;
      final audioBuffer = buffer as js.JsObject;

      final byteData = ByteData.sublistView(pcmBytes);
      final data = Int16List(pcmBytes.length ~/ 2);
      for (int i = 0; i < data.length; i++) {
        data[i] = byteData.getInt16(i * 2, Endian.little);
      }

      for (int ch = 0; ch < channels; ch++) {
        final float32Ctor = js.context['Float32Array'];
        if (float32Ctor == null) return;
        final float32 = js.JsObject(float32Ctor as js.JsFunction, [frames]);

        for (int i = 0; i < frames; i++) {
          float32[i] = data[i * channels + ch] / 32768.0;
        }

        final channelData = audioBuffer.callMethod('getChannelData', [ch]);
        if (channelData == null) return;
        (channelData as js.JsObject).callMethod('set', [float32]);
      }

      final currentTimeRaw = ctx['currentTime'];
      final currentTime =
          currentTimeRaw != null ? (currentTimeRaw as num).toDouble() : 0.0;

      if (_nextPlayTime < currentTime) {
        _nextPlayTime = currentTime + 0.05;
      }

      final source = ctx.callMethod('createBufferSource', []);
      if (source == null) return;
      final sourceNode = source as js.JsObject;

      sourceNode['buffer'] = audioBuffer;
      sourceNode.callMethod('connect', [ctx['destination']]);
      sourceNode.callMethod('start', [_nextPlayTime]);

      _nextPlayTime += frames / sampleRate;
    } catch (e) {
      debugPrint('⚠️ WebAudioPlayer.play error: $e');
    }
  }

  static void _ensureCtx() {
    if (_ctx != null) return;
    init();
  }

  static void dispose() {
    try {
      _ctx?.callMethod('close', []);
    } catch (_) {}
    _ctx = null;
    _nextPlayTime = 0.0;
  }
}
