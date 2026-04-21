import 'dart:typed_data';

/// No-op stub for non-web platforms.
class WebAudioPlayer {
  static void init() {}
  static void resume() {}
  static void play(Uint8List data,
      {int sampleRate = 48000, int channels = 2}) {}
  static void dispose() {}
}
