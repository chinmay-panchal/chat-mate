package com.example.chat_mate

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
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

    // ── Existing: screen share AudioTrack (viewer side) ───────────────────────
    private var audioTrack: AudioTrack? = null

    // ── Existing: screen share FGS ────────────────────────────────────────────
    private var screenServiceBound = false
    private var pendingFgsResult: MethodChannel.Result? = null

    private val screenServiceConnection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
            Log.d(TAG, "✅ ServiceConnection: onServiceConnected")
            screenServiceBound = true
            pendingFgsResult?.success(null)
            pendingFgsResult = null
        }
        override fun onServiceDisconnected(name: ComponentName?) {
            Log.w(TAG, "⚠️ ServiceConnection: onServiceDisconnected")
            screenServiceBound = false
        }
    }

    // ── NEW: video share audio decode pipeline ────────────────────────────────
    private var vsExtractor:  MediaExtractor? = null
    private var vsCodec:      MediaCodec?     = null
    private var vsSpeaker:    AudioTrack?     = null
    private var vsThread:     Thread?         = null
    @Volatile private var vsRunning = false
    private var vsChannel:    MethodChannel?  = null   // for PCM callback to Dart

    // ── Existing ──────────────────────────────────────────────────────────────
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: android.content.Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (resultCode == android.app.Activity.RESULT_OK && data != null) {
            Log.d(TAG, "✅ Captured projection Intent (requestCode=$requestCode)")
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val methodChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger, METHOD_CHANNEL
        )
        vsChannel = methodChannel

        // Existing: forward native audio capture bytes to Dart
        ScreenShareForegroundService.audioDataChannelCallback = { bytes ->
            runOnUiThread { methodChannel.invokeMethod("onAudioCaptured", bytes) }
        }

        methodChannel.setMethodCallHandler { call, result ->
            when (call.method) {

                // ── Existing: screen share FGS ────────────────────────────────

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
                        Log.d(TAG, "🔄 FGS start+bind sent")
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
                        }
                        val intent = Intent(this, ScreenShareForegroundService::class.java)
                            .setAction(ScreenShareForegroundService.ACTION_STOP)
                        startService(intent)
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("FGS_STOP_ERROR", e.message, null)
                    }
                }

                // ── Existing: viewer-side AudioTrack (screen share audio) ─────

                "startAudioPlayback" -> {
                    try {
                        val sr   = 48000
                        val ch   = AudioFormat.CHANNEL_OUT_STEREO
                        val fmt  = AudioFormat.ENCODING_PCM_16BIT
                        val min  = AudioTrack.getMinBufferSize(sr, ch, fmt)
                        audioTrack?.stop(); audioTrack?.release()
                        audioTrack = AudioTrack.Builder()
                            .setAudioAttributes(
                                AudioAttributes.Builder()
                                    .setUsage(AudioAttributes.USAGE_MEDIA)
                                    .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                                    .build()
                            )
                            .setAudioFormat(
                                AudioFormat.Builder()
                                    .setEncoding(fmt).setSampleRate(sr).setChannelMask(ch).build()
                            )
                            .setBufferSizeInBytes(min * 4)
                            .setTransferMode(AudioTrack.MODE_STREAM)
                            .setSessionId(AudioManager.AUDIO_SESSION_ID_GENERATE)
                            .build()
                        audioTrack?.play()
                        Log.d(TAG, "🔊 AudioTrack started (viewer)")
                        result.success(null)
                    } catch (e: Exception) {
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
                    audioTrack?.stop(); audioTrack?.release(); audioTrack = null
                    Log.d(TAG, "🔇 AudioTrack stopped (viewer)")
                    result.success(null)
                }

                // ── Existing: internal audio capture (screen share, Android 10+) ─

                "startInternalAudioCapture" -> {
                    try {
                        var projection: android.media.projection.MediaProjection? = null
                        runCatching {
                            val cls = Class.forName(
                                "com.cloudwebrtc.webrtc.OrientationAwareScreenCapturer"
                            )
                            projection = cls.getField("lastCreatedProjection").get(null)
                                as? android.media.projection.MediaProjection
                        }.onFailure { Log.e(TAG, "❌ Static field: ${it.message}") }

                        if (projection != null) {
                            ScreenShareForegroundService.pendingMediaProjection = projection
                            startService(
                                Intent(this, ScreenShareForegroundService::class.java)
                                    .setAction(ScreenShareForegroundService.ACTION_START_AUDIO)
                            )
                            result.success(null)
                        } else {
                            result.error("NO_MEDIA_PROJECTION", "Could not obtain MediaProjection", null)
                        }
                    } catch (e: Exception) {
                        result.error("AUDIO_CAPTURE_ERROR", e.message, null)
                    }
                }

                "stopInternalAudioCapture" -> {
                    try {
                        ScreenShareForegroundService.audioDataChannelCallback = null
                        startService(
                            Intent(this, ScreenShareForegroundService::class.java)
                                .setAction(ScreenShareForegroundService.ACTION_STOP_AUDIO)
                        )
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("AUDIO_CAPTURE_STOP_ERROR", e.message, null)
                    }
                }

                // ── NEW: video share audio decode ─────────────────────────────

                "startVideoShareAudio" -> {
                    val filePath = call.argument<String>("filePath")
                    if (filePath == null) {
                        result.error("NO_PATH", "filePath required", null)
                        return@setMethodCallHandler
                    }
                    try {
                        stopVideoShareAudioInternal()
                        startVideoShareAudioInternal(filePath)
                        result.success(null)
                    } catch (e: Exception) {
                        Log.e(TAG, "❌ startVideoShareAudio: ${e.message}", e)
                        result.error("DECODE_ERROR", e.message, null)
                    }
                }

                "stopVideoShareAudio" -> {
                    stopVideoShareAudioInternal()
                    result.success(null)
                }

                "pauseVideoShareAudio" -> {
                    vsRunning = false
                    vsSpeaker?.pause()
                    result.success(null)
                }

                "resumeVideoShareAudio" -> {
                    if (vsCodec != null) {
                        vsRunning = true
                        vsSpeaker?.play()
                        // Restart decode loop on a new thread
                        vsThread = buildDecodeThread()
                        vsThread?.start()
                    }
                    result.success(null)
                }

                "seekVideoShareAudio" -> {
                    val ms = call.argument<Int>("positionMs") ?: 0
                    vsExtractor?.seekTo(ms * 1000L, MediaExtractor.SEEK_TO_CLOSEST_SYNC)
                    result.success(null)
                }

                // ── NEW: custom video track stubs (video frame pipeline) ───────
                // These are acknowledged here so Dart doesn't throw
                // MissingPluginException. Real VideoTrackSource wiring lives in
                // the flutter_webrtc_local native patch. If that patch is not yet
                // implemented, video frames won't reach the remote peer but the
                // app will not crash.

                "createCustomVideoTrack" -> {
                    Log.d(TAG, "ℹ️ createCustomVideoTrack: acknowledged")
                    result.success(null)
                }

                "disposeCustomVideoTrack" -> {
                    Log.d(TAG, "ℹ️ disposeCustomVideoTrack: acknowledged")
                    result.success(null)
                }

                "pushLatestVideoFrame" -> {
                    // No-op until real VideoTrackSource is wired in the native patch
                    result.success(null)
                }

                else -> result.notImplemented()
            }
        }
    }

    // ── Video share audio internals ────────────────────────────────────────────

    private fun startVideoShareAudioInternal(filePath: String) {
        val extractor = MediaExtractor()
        extractor.setDataSource(filePath)

        // Find audio track
        var audioIdx   = -1
        var mime       = ""
        var sampleRate = 44100
        var channels   = 2

        for (i in 0 until extractor.trackCount) {
            val fmt = extractor.getTrackFormat(i)
            val m   = fmt.getString(MediaFormat.KEY_MIME) ?: ""
            if (m.startsWith("audio/")) {
                audioIdx   = i
                mime       = m
                sampleRate = fmt.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                channels   = fmt.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                Log.d(TAG, "🎵 Audio track: mime=$m sr=$sampleRate ch=$channels")
                break
            }
        }
        if (audioIdx == -1) throw Exception("No audio track in file")

        extractor.selectTrack(audioIdx)

        val codec = MediaCodec.createDecoderByType(mime)
        codec.configure(extractor.getTrackFormat(audioIdx), null, null, 0)
        codec.start()

        val chCfg = if (channels == 1) AudioFormat.CHANNEL_OUT_MONO
                    else AudioFormat.CHANNEL_OUT_STEREO
        val minBuf = AudioTrack.getMinBufferSize(
            sampleRate, chCfg, AudioFormat.ENCODING_PCM_16BIT
        )
        val speaker = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                    .build()
            )
            .setAudioFormat(
                AudioFormat.Builder()
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setSampleRate(sampleRate)
                    .setChannelMask(chCfg)
                    .build()
            )
            .setBufferSizeInBytes(minBuf * 4)
            .setTransferMode(AudioTrack.MODE_STREAM)
            .setSessionId(AudioManager.AUDIO_SESSION_ID_GENERATE)
            .build()
        speaker.play()

        vsExtractor = extractor
        vsCodec     = codec
        vsSpeaker   = speaker
        vsRunning   = true

        vsThread = buildDecodeThread()
        vsThread?.start()
        Log.d(TAG, "✅ Video share audio decode started: $filePath")
    }

    /** Builds (but does not start) the decode thread. Call .start() separately. */
    private fun buildDecodeThread(): Thread {
        val extractor = vsExtractor!!
        val codec     = vsCodec!!
        val speaker   = vsSpeaker!!

        return Thread {
            val info      = MediaCodec.BufferInfo()
            var inputDone = false
            var outDone   = false

            while (vsRunning && !outDone) {
                // Feed compressed data into codec
                if (!inputDone) {
                    val inIdx = codec.dequeueInputBuffer(10_000)
                    if (inIdx >= 0) {
                        val buf  = codec.getInputBuffer(inIdx)!!
                        val size = extractor.readSampleData(buf, 0)
                        if (size < 0) {
                            codec.queueInputBuffer(
                                inIdx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM
                            )
                            inputDone = true
                        } else {
                            codec.queueInputBuffer(inIdx, 0, size, extractor.sampleTime, 0)
                            extractor.advance()
                        }
                    }
                }

                // Drain decoded PCM
                val outIdx = codec.dequeueOutputBuffer(info, 10_000)
                if (outIdx >= 0) {
                    val buf   = codec.getOutputBuffer(outIdx)!!
                    val pcm   = ByteArray(info.size)
                    buf.get(pcm)
                    codec.releaseOutputBuffer(outIdx, false)

                    if (pcm.isNotEmpty()) {
                        // 1️⃣  Local speaker
                        if (speaker.playState == AudioTrack.PLAYSTATE_PLAYING) {
                            speaker.write(pcm, 0, pcm.size)
                        }
                        // 2️⃣  Send PCM to Dart → DataChannel → remote peer
                        runOnUiThread {
                            vsChannel?.invokeMethod("onVideoShareAudioPCM", pcm)
                        }
                    }

                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                        outDone = true
                        runOnUiThread {
                            vsChannel?.invokeMethod("onVideoShareAudioEnded", null)
                        }
                        Log.d(TAG, "🎵 Video share audio: EOS reached")
                    }
                }
            }
            Log.d(TAG, "🎵 Decode thread exiting (vsRunning=$vsRunning)")
        }.apply {
            name     = "VideoShareAudioDecode"
            isDaemon = true
        }
    }

    private fun stopVideoShareAudioInternal() {
        vsRunning = false
        val t = vsThread
        vsThread = null
        // Wait for decode thread to exit before releasing codec
        // to prevent IllegalStateException on queueInputBuffer
        try { t?.join(500) } catch (_: InterruptedException) {}
        runCatching { vsCodec?.stop();    vsCodec?.release() }
        runCatching { vsExtractor?.release() }
        runCatching { vsSpeaker?.stop();  vsSpeaker?.release() }
        vsCodec     = null
        vsExtractor = null
        vsSpeaker   = null
        Log.d(TAG, "🛑 Video share audio stopped")
    }

    // ── Lifecycle ─────────────────────────────────────────────────────────────

    override fun onDestroy() {
        super.onDestroy()
        ScreenShareForegroundService.audioDataChannelCallback = null
        stopVideoShareAudioInternal()
        if (screenServiceBound) {
            try { unbindService(screenServiceConnection) } catch (_: Exception) {}
            screenServiceBound = false
        }
    }
}