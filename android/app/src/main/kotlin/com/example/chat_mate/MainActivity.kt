package com.example.chat_mate

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.os.Build
import android.os.IBinder
import android.util.Log
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {

    companion object {
        private const val TAG = "MainActivity"
        private const val METHOD_CHANNEL = "com.example.chat_mate/screen_share"
    }

    private var audioTrack: AudioTrack? = null
    private var capturedProjectionIntent: android.content.Intent? = null

    private var screenServiceBound = false
    private var pendingFgsResult: MethodChannel.Result? = null

    private val screenServiceConnection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
            Log.d(TAG, "✅ ServiceConnection: onServiceConnected — FGS is fully started")
            screenServiceBound = true
            pendingFgsResult?.success(null)
            pendingFgsResult = null
        }

        override fun onServiceDisconnected(name: ComponentName?) {
            Log.w(TAG, "⚠️ ServiceConnection: onServiceDisconnected")
            screenServiceBound = false
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: android.content.Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (resultCode == android.app.Activity.RESULT_OK && data != null) {
            capturedProjectionIntent = data
            Log.d(TAG, "✅ Captured projection Intent in onActivityResult (requestCode=$requestCode)")
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD_CHANNEL)

        ScreenShareForegroundService.audioDataChannelCallback = { bytes ->
            runOnUiThread {
                methodChannel.invokeMethod("onAudioCaptured", bytes)
            }
        }

        methodChannel.setMethodCallHandler { call, result ->
            when (call.method) {

                "startScreenCaptureFgs" -> {
                    try {
                        pendingFgsResult = result

                        val intent = Intent(this, ScreenShareForegroundService::class.java)
                            .setAction(ScreenShareForegroundService.ACTION_START)

                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startForegroundService(intent)
                        } else {
                            startService(intent)
                        }

                        val bindIntent = Intent(this, ScreenShareForegroundService::class.java)
                        bindService(bindIntent, screenServiceConnection, Context.BIND_AUTO_CREATE)

                        Log.d(TAG, "🔄 startForegroundService + bindService sent; awaiting onServiceConnected")

                    } catch (e: Exception) {
                        Log.e(TAG, "❌ startScreenCaptureFgs: ${e.message}")
                        pendingFgsResult = null
                        result.error("FGS_ERROR", e.message, null)
                    }
                }

                "stopScreenCaptureFgs" -> {
                    try {
                        if (screenServiceBound) {
                            unbindService(screenServiceConnection)
                            screenServiceBound = false
                            Log.d(TAG, "🔌 Unbound from ScreenShareForegroundService")
                        }
                        val intent = Intent(this, ScreenShareForegroundService::class.java)
                            .setAction(ScreenShareForegroundService.ACTION_STOP)
                        startService(intent)
                        result.success(null)
                    } catch (e: Exception) {
                        Log.e(TAG, "❌ stopScreenCaptureFgs: ${e.message}")
                        result.error("FGS_STOP_ERROR", e.message, null)
                    }
                }

                "startAudioPlayback" -> {
                    try {
                        val sampleRate = 48000
                        val channelConfig = AudioFormat.CHANNEL_OUT_STEREO
                        val audioFormat = AudioFormat.ENCODING_PCM_16BIT
                        val minBuf = AudioTrack.getMinBufferSize(sampleRate, channelConfig, audioFormat)
                        audioTrack?.stop()
                        audioTrack?.release()
                        audioTrack = AudioTrack.Builder()
                            .setAudioAttributes(
                                AudioAttributes.Builder()
                                    .setUsage(AudioAttributes.USAGE_MEDIA)
                                    .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                                    .build()
                            )
                            .setAudioFormat(
                                AudioFormat.Builder()
                                    .setEncoding(audioFormat)
                                    .setSampleRate(sampleRate)
                                    .setChannelMask(channelConfig)
                                    .build()
                            )
                            .setBufferSizeInBytes(minBuf * 4)
                            .setTransferMode(AudioTrack.MODE_STREAM)
                            .setSessionId(AudioManager.AUDIO_SESSION_ID_GENERATE)
                            .build()
                        audioTrack?.play()
                        Log.d(TAG, "🔊 AudioTrack started")
                        result.success(null)
                    } catch (e: Exception) {
                        Log.e(TAG, "❌ startAudioPlayback: ${e.message}")
                        result.error("AUDIO_TRACK_ERROR", e.message, null)
                    }
                }

                "playAudioBytes" -> {
                    val bytes = call.arguments as? ByteArray
                    if (bytes != null && audioTrack?.playState == AudioTrack.PLAYSTATE_PLAYING) {
                        audioTrack?.write(bytes, 0, bytes.size)
                    }
                    result.success(null)
                }

                "stopAudioPlayback" -> {
                    audioTrack?.stop()
                    audioTrack?.release()
                    audioTrack = null
                    Log.d(TAG, "🔇 AudioTrack stopped")
                    result.success(null)
                }

                "startInternalAudioCapture" -> {
                    try {
                        // No MediaProjection needed — mic capture works directly
                        startService(Intent(this, ScreenShareForegroundService::class.java)
                            .setAction(ScreenShareForegroundService.ACTION_START_AUDIO))
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("AUDIO_CAPTURE_ERROR", e.message, null)
                    }
                }

                "stopInternalAudioCapture" -> {
                    try {
                        ScreenShareForegroundService.audioDataChannelCallback = null
                        val intent = Intent(this, ScreenShareForegroundService::class.java)
                            .setAction(ScreenShareForegroundService.ACTION_STOP_AUDIO)
                        startService(intent)
                        result.success(null)
                    } catch (e: Exception) {
                        Log.e(TAG, "❌ stopInternalAudioCapture: ${e.message}")
                        result.error("AUDIO_CAPTURE_STOP_ERROR", e.message, null)
                    }
                }

                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        ScreenShareForegroundService.audioDataChannelCallback = null
        if (screenServiceBound) {
            try {
                unbindService(screenServiceConnection)
            } catch (_: Exception) {}
            screenServiceBound = false
        }
    }
}