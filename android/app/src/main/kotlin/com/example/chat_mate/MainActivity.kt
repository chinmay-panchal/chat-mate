package com.example.chat_mate

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.graphics.Bitmap
import android.graphics.ImageFormat
import android.graphics.PixelFormat
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.media.ImageReader
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.os.Build
import android.os.IBinder
import android.util.Log
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer

class MainActivity : FlutterFragmentActivity() {

    companion object {
        private const val TAG = "MainActivity"
        private const val METHOD_CHANNEL = "com.example.chat_mate/screen_share"
    }

    // ── Screen share AudioTrack (viewer side) ─────────────────────────────────
    private var audioTrack: AudioTrack? = null

    // ── Screen share FGS ──────────────────────────────────────────────────────
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

    // ── Video share: audio decode pipeline ───────────────────────────────────
    private var vsExtractor:  MediaExtractor? = null
    private var vsCodec:      MediaCodec?     = null
    private var vsSpeaker:    AudioTrack?     = null
    private var vsThread:     Thread?         = null
    @Volatile private var vsRunning = false
    private var vsChannel:    MethodChannel?  = null

    // ── Video share: video decode pipeline ───────────────────────────────────
    private var vvExtractor:  MediaExtractor? = null
    private var vvCodec:      MediaCodec?     = null
    private var vvImageReader: ImageReader?   = null
    private var vvThread:     Thread?         = null
    @Volatile private var vvRunning = false
    @Volatile private var currentVideoBitmap: Bitmap? = null
    private var vvWidth  = 0
    private var vvHeight = 0

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

        ScreenShareForegroundService.audioDataChannelCallback = { bytes ->
            runOnUiThread { methodChannel.invokeMethod("onAudioCaptured", bytes) }
        }

        methodChannel.setMethodCallHandler { call, result ->
            when (call.method) {

                // ── Screen share FGS ──────────────────────────────────────────

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

                // ── Viewer-side AudioTrack ─────────────────────────────────────

                "startAudioPlayback" -> {
                    try {
                        val sr  = 48000
                        val ch  = AudioFormat.CHANNEL_OUT_STEREO
                        val fmt = AudioFormat.ENCODING_PCM_16BIT
                        val min = AudioTrack.getMinBufferSize(sr, ch, fmt)
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

                // ── Internal audio capture (screen share) ─────────────────────

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

                // ── Video share: audio ─────────────────────────────────────────

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
                        vsThread = buildAudioDecodeThread()
                        vsThread?.start()
                    }
                    result.success(null)
                }

                "seekVideoShareAudio" -> {
                    val ms = call.argument<Int>("positionMs") ?: 0
                    vsExtractor?.seekTo(ms * 1000L, MediaExtractor.SEEK_TO_CLOSEST_SYNC)
                    result.success(null)
                }

                // ── Video share: video frame capture ──────────────────────────

                "startVideoShareVideo" -> {
                    val filePath = call.argument<String>("filePath")
                    if (filePath == null) {
                        result.error("NO_PATH", "filePath required", null)
                        return@setMethodCallHandler
                    }
                    try {
                        stopVideoShareVideoInternal()
                        startVideoShareVideoInternal(filePath)
                        result.success(null)
                    } catch (e: Exception) {
                        Log.e(TAG, "❌ startVideoShareVideo: ${e.message}", e)
                        result.error("VIDEO_DECODE_ERROR", e.message, null)
                    }
                }

                "stopVideoShareVideo" -> {
                    stopVideoShareVideoInternal()
                    result.success(null)
                }

                "captureVideoFrame" -> {
                    val bmp = currentVideoBitmap
                    if (bmp != null && !bmp.isRecycled) {
                        try {
                            val buf = ByteArray(bmp.width * bmp.height * 4)
                            val wrapped = ByteBuffer.wrap(buf)
                            bmp.copyPixelsToBuffer(wrapped)
                            result.success(buf)
                        } catch (e: Exception) {
                            Log.e(TAG, "❌ captureVideoFrame copy: ${e.message}")
                            result.success(null)
                        }
                    } else {
                        result.success(null)
                    }
                }

                else -> result.notImplemented()
            }
        }
    }

    // ── Video share: VIDEO decode internals ───────────────────────────────────

    private fun startVideoShareVideoInternal(filePath: String) {
        val extractor = MediaExtractor()
        extractor.setDataSource(filePath)

        var videoIdx = -1
        var mime     = ""
        var width    = 0
        var height   = 0

        for (i in 0 until extractor.trackCount) {
            val fmt = extractor.getTrackFormat(i)
            val m   = fmt.getString(MediaFormat.KEY_MIME) ?: ""
            if (m.startsWith("video/")) {
                videoIdx = i
                mime     = m
                width    = fmt.getInteger(MediaFormat.KEY_WIDTH)
                height   = fmt.getInteger(MediaFormat.KEY_HEIGHT)
                Log.d(TAG, "🎬 Video track: mime=$m ${width}x${height}")
                break
            }
        }
        if (videoIdx == -1) throw Exception("No video track in file")

        extractor.selectTrack(videoIdx)

        // ImageReader in RGBA_8888 so we can copy pixels directly to Bitmap
        val imageReader = ImageReader.newInstance(width, height, PixelFormat.RGBA_8888, 4)

        val codec = MediaCodec.createDecoderByType(mime)
        codec.configure(extractor.getTrackFormat(videoIdx), imageReader.surface, null, 0)
        codec.start()

        vvExtractor  = extractor
        vvCodec      = codec
        vvImageReader = imageReader
        vvWidth      = width
        vvHeight     = height
        vvRunning    = true

        // ImageReader listener: grab latest frame as Bitmap
        imageReader.setOnImageAvailableListener({ reader ->
            val image = reader.acquireLatestImage() ?: return@setOnImageAvailableListener
            try {
                val plane  = image.planes[0]
                val buffer = plane.buffer
                val rowStride   = plane.rowStride
                val pixelStride = plane.pixelStride
                val w = image.width
                val h = image.height

                val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
                // Copy row by row accounting for padding
                val rowData = ByteArray(rowStride)
                val bmpBuf  = ByteBuffer.allocate(w * h * 4)
                for (row in 0 until h) {
                    buffer.position(row * rowStride)
                    buffer.get(rowData, 0, minOf(rowStride, buffer.remaining()))
                    if (pixelStride == 4) {
                        bmpBuf.put(rowData, 0, w * 4)
                    } else {
                        // pixelStride == 1 shouldn't happen for RGBA but handle gracefully
                        for (col in 0 until w) {
                            bmpBuf.put(rowData, col * pixelStride, 4)
                        }
                    }
                }
                bmpBuf.rewind()
                bmp.copyPixelsFromBuffer(bmpBuf)

                val old = currentVideoBitmap
                currentVideoBitmap = bmp
                old?.recycle()
            } catch (e: Exception) {
                Log.w(TAG, "⚠️ ImageReader frame error: ${e.message}")
            } finally {
                image.close()
            }
        }, null)

        vvThread = buildVideoDecodeThread()
        vvThread?.start()
        Log.d(TAG, "✅ Video share video decode started: $filePath")
    }

    private fun buildVideoDecodeThread(): Thread {
        val extractor = vvExtractor!!
        val codec     = vvCodec!!

        return Thread {
            val info      = MediaCodec.BufferInfo()
            var inputDone = false
            var outDone   = false

            while (vvRunning && !outDone) {
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

                val outIdx = codec.dequeueOutputBuffer(info, 10_000)
                if (outIdx >= 0) {
                    // render=true pushes frame to ImageReader surface
                    codec.releaseOutputBuffer(outIdx, true)
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                        outDone = true
                    }
                }
            }
            Log.d(TAG, "🎬 Video decode thread exiting (vvRunning=$vvRunning)")
        }.apply {
            name     = "VideoShareVideoDecode"
            isDaemon = true
        }
    }

    private fun stopVideoShareVideoInternal() {
        vvRunning = false
        val t = vvThread
        vvThread = null
        try { t?.join(500) } catch (_: InterruptedException) {}
        runCatching { vvCodec?.stop();    vvCodec?.release() }
        runCatching { vvExtractor?.release() }
        runCatching { vvImageReader?.close() }
        vvCodec      = null
        vvExtractor  = null
        vvImageReader = null
        currentVideoBitmap?.recycle()
        currentVideoBitmap = null
        Log.d(TAG, "🛑 Video share video decode stopped")
    }

    // ── Video share: AUDIO decode internals ──────────────────────────────────

    private fun startVideoShareAudioInternal(filePath: String) {
        val extractor = MediaExtractor()
        extractor.setDataSource(filePath)

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

        val chCfg  = if (channels == 1) AudioFormat.CHANNEL_OUT_MONO else AudioFormat.CHANNEL_OUT_STEREO
        val minBuf = AudioTrack.getMinBufferSize(sampleRate, chCfg, AudioFormat.ENCODING_PCM_16BIT)
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

        vsThread = buildAudioDecodeThread()
        vsThread?.start()
        Log.d(TAG, "✅ Video share audio decode started: $filePath")
    }

    private fun buildAudioDecodeThread(): Thread {
        val extractor = vsExtractor!!
        val codec     = vsCodec!!
        val speaker   = vsSpeaker!!

        return Thread {
            val info      = MediaCodec.BufferInfo()
            var inputDone = false
            var outDone   = false

            while (vsRunning && !outDone) {
                if (!inputDone) {
                    val inIdx = codec.dequeueInputBuffer(10_000)
                    if (inIdx >= 0) {
                        val buf  = codec.getInputBuffer(inIdx)!!
                        val size = extractor.readSampleData(buf, 0)
                        if (size < 0) {
                            codec.queueInputBuffer(inIdx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputDone = true
                        } else {
                            codec.queueInputBuffer(inIdx, 0, size, extractor.sampleTime, 0)
                            extractor.advance()
                        }
                    }
                }

                val outIdx = codec.dequeueOutputBuffer(info, 10_000)
                if (outIdx >= 0) {
                    val buf = codec.getOutputBuffer(outIdx)!!
                    val pcm = ByteArray(info.size)
                    buf.get(pcm)
                    codec.releaseOutputBuffer(outIdx, false)

                    if (pcm.isNotEmpty()) {
                        if (speaker.playState == AudioTrack.PLAYSTATE_PLAYING) {
                            speaker.write(pcm, 0, pcm.size)
                        }
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
        stopVideoShareVideoInternal()
        if (screenServiceBound) {
            try { unbindService(screenServiceConnection) } catch (_: Exception) {}
            screenServiceBound = false
        }
    }
}