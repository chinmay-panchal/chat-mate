import 'dart:typed_data';

// Stub implementation — used on web and as the default import.
// The real implementation is in audio_capture_native.dart (mobile only).

class AudioCaptureService {
  Future<void> start(void Function(Uint8List) onData) async {}
  Future<void> stop() async {}
}
