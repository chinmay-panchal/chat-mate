/// Central config — change the server IP here and it applies everywhere.
///
/// For local development:
///   Android emulator → 10.0.2.2  (maps to host machine localhost)
///   iOS simulator    → 127.0.0.1
///   Physical device  → your Mac's LAN IP (e.g. 192.168.1.5)
///
/// For production: replace with your deployed server domain.
class AppConfig {
  AppConfig._();

  /// WebSocket signaling server URL.
  /// Spring Boot default port is 8080, path is /ws.
  static const signalingUrl = 'ws://10.0.2.2:8080/ws';

  /// iOS simulator / physical device on same LAN — uncomment as needed:
  // static const signalingUrl = 'ws://127.0.0.1:8080/ws';
  // static const signalingUrl = 'ws://192.168.1.5:8080/ws';
}
