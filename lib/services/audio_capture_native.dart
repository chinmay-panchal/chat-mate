// Native (mobile) implementation of AudioCaptureService.
// Mirrors the stub interface exactly so the conditional import works.

import 'dart:typed_data';
import 'package:flutter/services.dart';

class AudioCaptureService {
  static const _ch = MethodChannel('com.example.chat_mate/screen_share');

  Future<void> start(void Function(Uint8List) onData) async {
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'onAudioPCM') {
        onData(call.arguments as Uint8List);
      }
    });
    try {
      await _ch.invokeMethod('startAudioCapture');
    } catch (e) {
      // Native method may not be implemented yet — fail silently.
    }
  }

  Future<void> stop() async {
    try {
      await _ch.invokeMethod('stopAudioCapture');
    } catch (_) {}
  }
}
