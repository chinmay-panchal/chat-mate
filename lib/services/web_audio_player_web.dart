import 'dart:typed_data';
import 'package:flutter/foundation.dart';

// ignore: avoid_web_libraries_in_flutter
import 'dart:js' as js;

class WebAudioPlayer {
  static js.JsObject? _ctx;
  static double _nextPlayTime = 0.0;

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
      if (state != 'running') {
        ctx.callMethod('resume', []);
      }

      final totalSamples = pcmBytes.length ~/ 2;
      final frames = totalSamples ~/ channels;
      if (frames <= 0) return;

      // Decode PCM16LE → Float32, deinterleaved per channel
      final byteData = ByteData.sublistView(pcmBytes);
      final float32PerChannel =
          List.generate(channels, (_) => Float32List(frames));

      for (int i = 0; i < frames; i++) {
        for (int ch = 0; ch < channels; ch++) {
          final raw = byteData.getInt16((i * channels + ch) * 2, Endian.little);
          float32PerChannel[ch][i] = raw / 32768.0;
        }
      }

      final audioBuffer =
          ctx.callMethod('createBuffer', [channels, frames, sampleRate])
              as js.JsObject;

      for (int ch = 0; ch < channels; ch++) {
        // getChannelData() returns a JS Float32Array.
        // Convert Dart Float32List → JS Array, then call .set() on the
        // Float32Array to bulk-copy — avoids the index-assign type error.
        final jsChannelData =
            audioBuffer.callMethod('getChannelData', [ch]) as js.JsObject;
        final jsArray = js.JsArray.from(float32PerChannel[ch]);
        jsChannelData.callMethod('set', [jsArray]);
      }

      final currentTime = (ctx['currentTime'] as num?)?.toDouble() ?? 0.0;
      if (_nextPlayTime < currentTime) _nextPlayTime = currentTime;

      final source = ctx.callMethod('createBufferSource', []) as js.JsObject;
      source['buffer'] = audioBuffer;
      source.callMethod('connect', [ctx['destination']]);
      source.callMethod('start', [_nextPlayTime]);

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
