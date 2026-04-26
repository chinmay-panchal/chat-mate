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
    } catch (_) {}
  }

  static void resume() {
    try {
      _ctx?.callMethod('resume', []);
    } catch (_) {}
  }

  static void play(Uint8List pcmBytes,
      {int sampleRate = 48000, int channels = 2}) {
    if (_ctx == null) init();
    final ctx = _ctx;
    if (ctx == null) return;

    try {
      if (ctx['state'] != 'running') ctx.callMethod('resume', []);

      final totalSamples = pcmBytes.length ~/ 2;
      final frames = totalSamples ~/ channels;
      if (frames <= 0) return;

      final byteData = ByteData.sublistView(pcmBytes);
      final perChannel = List.generate(channels, (_) => Float32List(frames));
      for (int i = 0; i < frames; i++) {
        for (int ch = 0; ch < channels; ch++) {
          perChannel[ch][i] =
              byteData.getInt16((i * channels + ch) * 2, Endian.little) /
                  32768.0;
        }
      }

      final audioBuffer =
          ctx.callMethod('createBuffer', [channels, frames, sampleRate])
              as js.JsObject;

      for (int ch = 0; ch < channels; ch++) {
        final jsChannelData =
            audioBuffer.callMethod('getChannelData', [ch]) as js.JsObject;
        jsChannelData.callMethod('set', [js.JsArray.from(perChannel[ch])]);
      }

      final currentTime = (ctx['currentTime'] as num?)?.toDouble() ?? 0.0;
      if (_nextPlayTime < currentTime) _nextPlayTime = currentTime;

      final source = ctx.callMethod('createBufferSource', []) as js.JsObject;
      source['buffer'] = audioBuffer;
      source.callMethod('connect', [ctx['destination']]);
      source.callMethod('start', [_nextPlayTime]);
      _nextPlayTime += frames / sampleRate;
    } catch (_) {}
  }

  static void dispose() {
    try {
      _ctx?.callMethod('close', []);
    } catch (_) {}
    _ctx = null;
    _nextPlayTime = 0.0;
  }
}
