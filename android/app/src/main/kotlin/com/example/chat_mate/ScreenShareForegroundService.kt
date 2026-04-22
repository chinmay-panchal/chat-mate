package com.example.chat_mate

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioPlaybackCaptureConfiguration
import android.media.AudioRecord
import android.media.projection.MediaProjection
import android.os.Binder
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import androidx.annotation.RequiresApi
import androidx.core.app.NotificationCompat
import io.flutter.plugin.common.EventChannel

class ScreenShareForegroundService : Service() {

    // ── Binder ────────────────────────────────────────────────────────────────
    // Returned from onBind() so MainActivity can detect the moment the service
    // is fully started (onServiceConnected fires only after startForeground()
    // has been called on Android 14+).
    inner class LocalBinder : Binder() {
        fun getService(): ScreenShareForegroundService = this@ScreenShareForegroundService
    }

    private val binder = LocalBinder()

    companion object {
        const val CHANNEL_ID = "screen_share_channel"
        const val NOTIFICATION_ID = 1001
        const val ACTION_START = "ACTION_START_SCREEN_SHARE"
        const val ACTION_STOP = "ACTION_STOP_SCREEN_SHARE"
        const val ACTION_START_AUDIO = "ACTION_START_AUDIO"
        const val ACTION_STOP_AUDIO = "ACTION_STOP_AUDIO"
        private const val TAG = "ScreenShareService"
        var audioDataChannelCallback: ((ByteArray) -> Unit)? = null


        const val SAMPLE_RATE = 48000
        const val CHANNEL_CONFIG = AudioFormat.CHANNEL_IN_STEREO
        const val AUDIO_FORMAT = AudioFormat.ENCODING_PCM_16BIT

        var pendingMediaProjection: MediaProjection? = null
        var audioEventSink: EventChannel.EventSink? = null
    }

    private var audioRecord: AudioRecord? = null
    private var audioCapturingThread: Thread? = null
    private var isCapturing = false

    // ── Binding ───────────────────────────────────────────────────────────────
    // Returning a non-null IBinder allows MainActivity to use bindService().
    // onServiceConnected() on the MainActivity side fires only after this
    // service is fully initialised — which on Android 14 means after
    // startForeground(…, FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION) has run.
    override fun onBind(intent: Intent?): IBinder = binder

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                val notification = buildNotification()
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    startForeground(
                        NOTIFICATION_ID,
                        notification,
                        android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
                    )
                } else {
                    startForeground(NOTIFICATION_ID, notification)
                }
                Log.d(TAG, "✅ Foreground service started with mediaProjection type")
            }

            ACTION_START_AUDIO -> {
                // No MediaProjection needed for mic-based capture
                startInternalAudioCapture()
            }

            ACTION_STOP_AUDIO -> stopInternalAudioCapture()

            ACTION_STOP -> {
                stopInternalAudioCapture()
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
            }
        }
        return START_NOT_STICKY
    }

    // Removed @RequiresApi — mic capture works on all API levels
    private fun startInternalAudioCapture() {
        if (isCapturing) {
            Log.w(TAG, "⚠️ Already capturing audio")
            return
        }

        val minBufferSize = AudioRecord.getMinBufferSize(SAMPLE_RATE, CHANNEL_CONFIG, AUDIO_FORMAT)
        if (minBufferSize <= 0) {
            Log.e(TAG, "❌ Invalid minBufferSize: $minBufferSize")
            return
        }
        val bufferSize = minBufferSize * 2

        try {
            val source = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                android.media.MediaRecorder.AudioSource.UNPROCESSED
            } else {
                android.media.MediaRecorder.AudioSource.VOICE_RECOGNITION
            }

            audioRecord = AudioRecord(
                source,
                SAMPLE_RATE,
                CHANNEL_CONFIG,
                AUDIO_FORMAT,
                bufferSize
            )

            if (audioRecord?.state != AudioRecord.STATE_INITIALIZED) {
                Log.e(TAG, "❌ AudioRecord failed to initialize")
                audioRecord?.release()
                audioRecord = null
                return
            }

            isCapturing = true
            audioRecord?.startRecording()
            Log.d(TAG, "🎵 Mic audio capture started")

            audioCapturingThread = Thread {
                val buffer = ShortArray(bufferSize / 2)
                while (isCapturing) {
                    val read = audioRecord?.read(buffer, 0, buffer.size) ?: -1
                    if (read > 0) {
                        val bytes = ByteArray(read * 2)
                        for (i in 0 until read) {
                            bytes[i * 2] = (buffer[i].toInt() and 0xFF).toByte()
                            bytes[i * 2 + 1] = (buffer[i].toInt() shr 8 and 0xFF).toByte()
                        }
                        audioDataChannelCallback?.invoke(bytes)
                        Handler(Looper.getMainLooper()).post {
                            audioEventSink?.success(bytes)
                        }
                    }
                }
                Log.d(TAG, "🛑 Audio capture thread stopped")
            }.apply {
                name = "InternalAudioCapture"
                isDaemon = true
                start()
            }

        } catch (e: Exception) {
            Log.e(TAG, "❌ Error starting audio capture: ${e.message}")
            isCapturing = false
        }
    }

    private fun stopInternalAudioCapture() {
        isCapturing = false
        audioCapturingThread?.interrupt()
        audioCapturingThread = null
        audioRecord?.stop()
        audioRecord?.release()
        audioRecord = null
        Log.d(TAG, "🛑 Internal audio capture stopped")
    }

    private fun buildNotification(): Notification {
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Screen Sharing")
            .setContentText("Your screen is being shared")
            .setSmallIcon(android.R.drawable.ic_menu_share)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setSilent(true)
            .build()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Screen Sharing",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Used while screen sharing is active"
                setShowBadge(false)
            }
            getSystemService(NotificationManager::class.java)
                .createNotificationChannel(channel)
        }
    }
}