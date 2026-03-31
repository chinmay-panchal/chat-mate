import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';

typedef VoidCallback = void Function();
typedef ErrorCallback = void Function(String error);
typedef MessageCallback = void Function(Map<String, dynamic> message);

class SignalingService {
  WebSocketChannel? _channel;
  String? _roomId;
  bool _disposed = false;

  VoidCallback? onPeerJoined;
  VoidCallback? onPeerLeft;
  ErrorCallback? onError;

  // Queue messages that arrive before the handler is set (race condition fix).
  MessageCallback? _onMessage;
  final List<Map<String, dynamic>> _pendingMessages = [];

  MessageCallback? get onMessage => _onMessage;
  set onMessage(MessageCallback? callback) {
    _onMessage = callback;
    if (callback != null && _pendingMessages.isNotEmpty) {
      final queued = List.of(_pendingMessages);
      _pendingMessages.clear();
      for (final msg in queued) {
        callback(msg);
      }
    }
  }

  // static const String _serverUrl = 'ws://localhost:8080/ws/signaling';
  // static const String _serverUrl = 'ws://192.168.43.188:8080/ws/signaling';
  // static const String _serverUrl =
  //     'wss://watchtogether-server.onrender.com/ws/signaling';
  // static const String _serverUrl =
  //     'wss://watchtogether-server-ku71.onrender.com/ws/signaling';
  static const String _serverUrl =
      'wss://watchtogether-server-1.onrender.com/ws/signaling';

  void connect({
    required String roomId,
    required bool isInitiator,
    VoidCallback? onPeerJoined,
    ErrorCallback? onError,
    MessageCallback? onMessage,
  }) {
    _roomId = roomId;
    this.onPeerJoined = onPeerJoined;
    if (onMessage != null) {
      print("on mesasge is null");
      this.onMessage = onMessage;
    }
    this.onError = onError;

    print('📡 Connecting to $_serverUrl');
    print('📡 Room: $roomId | Initiator: $isInitiator');

    try {
      _channel = WebSocketChannel.connect(Uri.parse(_serverUrl));

      _channel!.stream.listen(
        (data) {
          if (_disposed) return;
          _handleMessage(data);
        },
        onError: (e) {
          print('❌ WebSocket error: $e');
          if (!_disposed) onError?.call(e.toString());
        },
        onDone: () {
          print('🔌 WebSocket closed');
          if (!_disposed) onPeerLeft?.call();
        },
      );

      _channel!.ready.then((_) {
        print('✅ WebSocket ready, sending ${isInitiator ? "create" : "join"}');
        _send({'type': isInitiator ? 'create' : 'join', 'roomId': roomId});
      }).catchError((e) {
        print('❌ WebSocket ready failed: $e');
        onError?.call('WebSocket connection failed: $e');
      });
    } catch (e) {
      print('❌ Connect exception: $e');
      onError?.call('Failed to connect to server: $e');
    }
  }

  void _handleMessage(dynamic data) {
    try {
      final msg = jsonDecode(data as String) as Map<String, dynamic>;
      final type = msg['type'] as String?;
      print('🔔 Handling message type: $type');

      switch (type) {
        case 'peer_left':
          onPeerLeft?.call();
          break;
        case 'created':
        case 'joined':
          print('✅ Room acknowledged: $type');

          _pendingMessages.add(msg); // ALWAYS queue

          if (_onMessage != null) {
            _onMessage!(msg);
          }

          break;

        case 'peer_joined':
          print('👥 Peer joined!');

          if (onPeerJoined != null) {
            onPeerJoined!();
          } else {
            print('⏳ Queuing peer_joined event');
            _pendingMessages.add({'type': 'peer_joined'});
          }

          // ALSO forward it through the normal message queue
          if (_onMessage != null) {
            _onMessage!({'type': 'peer_joined'});
          } else {
            _pendingMessages.add({'type': 'peer_joined'});
          }

          break;
        case 'offer':
        case 'answer':
        case 'candidate':
        case 'screen_start':
        case 'camera_off':
        case 'screen_off':
          if (_onMessage != null) {
            _onMessage!(msg);
          } else {
            print('⏳ Queuing message: $type');
            _pendingMessages.add(msg);
          }
          break;
        case 'error':
          print('❌ Server error: ${msg['message']}');
          onError?.call(msg['message'] as String? ?? 'Unknown error');
          break;
        default:
          print('❓ Unknown message type: $type');
      }
    } catch (e) {
      print('❌ Parse error: $e');
    }
  }

  void sendOffer(String sdp) =>
      _send({'type': 'offer', 'sdp': sdp, 'roomId': _roomId});
  void sendAnswer(String sdp) =>
      _send({'type': 'answer', 'sdp': sdp, 'roomId': _roomId});
  void sendCandidate(Map<String, dynamic> candidate) =>
      _send({'type': 'candidate', 'candidate': candidate, 'roomId': _roomId});

  /// Sent just before screen share starts so the viewer knows the next
  /// incoming video stream is a screen share, not a camera.
  void sendScreenStart() => _send({'type': 'screen_start', 'roomId': _roomId});

  /// Sent when local camera stops — peer clears its PiP.
  void sendCameraOff() => _send({'type': 'camera_off', 'roomId': _roomId});

  /// Sent when screen share stops — viewer clears main view.
  void sendScreenOff() => _send({'type': 'screen_off', 'roomId': _roomId});

  void _send(Map<String, dynamic> data) {
    if (_channel != null && !_disposed) {
      _channel!.sink.add(jsonEncode(data));
    }
  }

  void dispose() {
    _disposed = true;
    _channel?.sink.close();
    _channel = null;
  }
}
