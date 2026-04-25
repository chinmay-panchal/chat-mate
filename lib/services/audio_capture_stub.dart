// Stub implementation — used on web and as the default import.
// The real implementation is in audio_capture_native.dart (mobile only).

typedef PCMCallback = void Function(List<int> pcm);

class AudioCaptureService {
  Future<void> start(void Function(dynamic) onData) async {}
  Future<void> stop() async {}
}
