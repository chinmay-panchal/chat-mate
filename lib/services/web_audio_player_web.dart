import 'dart:typed_data';
import 'package:flutter/foundation.dart';

// ignore: avoid_web_libraries_in_flutter
import 'dart:js' as js;

class WebAudioPlayer {
  static js.JsObject? _ctx;
  static double _nextPlayTime = 0.0;

  /// 🔊 Unified logger (Flutter + Chrome DevTools)
  static void _log(String msg) {
    debugPrint(msg);
    try {
      js.context.callMethod('console.log', ['🎧 $msg']);
    } catch (_) {}
  }

  static void init() {
    if (!kIsWeb) return;
    try {
      final ctor =
          js.context['AudioContext'] ?? js.context['webkitAudioContext'];
      if (ctor == null) {
        _log('❌ AudioContext not supported');
        return;
      }

      _ctx = js.JsObject(ctor as js.JsFunction, []);
      _nextPlayTime = 0.0;

      _log('🔊 AudioContext created');
    } catch (e) {
      _log('⚠️ init failed: $e');
    }
  }

  static void resume() {
    if (_ctx == null) return;
    try {
      _ctx!.callMethod('resume', []);
      _log('▶️ AudioContext resumed');
    } catch (e) {
      _log('⚠️ resume failed: $e');
    }
  }

  static void play(Uint8List pcmBytes,
      {int sampleRate = 48000, int channels = 2}) {
    _ensureCtx();
    final ctx = _ctx;
    if (ctx == null) return;

    try {
      final state = ctx['state'];
      _log('🔊 play() state=$state bytes=${pcmBytes.length}');

      // ✅ DO NOT drop packet
      if (state != 'running') {
        ctx.callMethod('resume', []);
      }

      final totalSamples = pcmBytes.length ~/ 2;
      final frames = totalSamples ~/ channels;

      if (frames <= 0) {
        _log('⚠️ No frames');
        return;
      }

      final buffer =
          ctx.callMethod('createBuffer', [channels, frames, sampleRate]);
      if (buffer == null) return;

      final audioBuffer = buffer as js.JsObject;

      final byteData = ByteData.sublistView(pcmBytes);
      final data = Int16List(totalSamples);

      for (int i = 0; i < totalSamples; i++) {
        data[i] = byteData.getInt16(i * 2, Endian.little);
      }

      // 🔍 DEBUG: check audio presence
      int nonZero = 0;
      for (int i = 0; i < data.length && i < 200; i++) {
        if (data[i] != 0) nonZero++;
      }
      _log('📊 samples=${data.length}, nonZero=$nonZero');
      _log('🎵 first10=${data.take(10).toList()}');

      // ✅ FIXED: direct write (NO Float32Array, NO set())
      for (int ch = 0; ch < channels; ch++) {
        final channelData = audioBuffer.callMethod('getChannelData', [ch]);
        if (channelData == null) return;

        final jsArray = channelData as js.JsObject;

        for (int i = 0; i < frames; i++) {
          jsArray[i] = data[i * channels + ch] / 32768.0;
        }
      }

      final currentTimeRaw = ctx['currentTime'];
      final currentTime =
          currentTimeRaw != null ? (currentTimeRaw as num).toDouble() : 0.0;

      _log('⏱ currentTime=$currentTime next=$_nextPlayTime frames=$frames');

      if (_nextPlayTime < currentTime) {
        _nextPlayTime = currentTime;
      }

      final source = ctx.callMethod('createBufferSource', []);
      if (source == null) return;

      final sourceNode = source as js.JsObject;

      sourceNode['buffer'] = audioBuffer;
      sourceNode.callMethod('connect', [ctx['destination']]);
      sourceNode.callMethod('start', [_nextPlayTime]);

      _nextPlayTime += frames / sampleRate;
    } catch (e) {
      _log('⚠️ play error: $e');
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
