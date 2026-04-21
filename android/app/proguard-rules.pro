# Keep flutter_webrtc internals needed for MediaProjection reflection
-keep class com.cloudwebrtc.webrtc.GetUserMediaImpl { *; }
-keep class com.cloudwebrtc.webrtc.GetUserMediaImpl$VideoCapturerInfoEx { *; }
-keep class com.cloudwebrtc.webrtc.FlutterWebRTCPlugin { *; }
-keep class com.cloudwebrtc.webrtc.MethodCallHandlerImpl { *; }
-keep class com.cloudwebrtc.webrtc.OrientationAwareScreenCapturer { *; }