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
import com.cloudwebrtc.webrtc.CustomVideoSource
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer

class MainActivity : FlutterFragmentActivity() {

    companion object {
        private const val TAG = "MainActivity"
        private const val METHOD_CHANNEL = "com.example.chat_mate/screen_share"
        private const val VIDEO_TRACK_ID = "video_share_track"
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
    private var vsExtractor: MediaExtractor? = null
    private var vsCodec: MediaCodec? = null
    private var vsSpeaker: AudioTrack? = null
    private var vsThread: Thread? = null
    @Volatile private var vsRunning = false
    private var vsChannel: MethodChannel? = null

    // ── Video share: video decode pipeline ───────────────────────────────────
    private var vvExtractor: MediaExtractor? = null
    private var vvCodec: MediaCodec? = null
    private var vvThread: Thread? = null
    @Volatile private var vvRunning = false

    // Frame push stats for debugging
    @Volatile private var framesPushed = 0
    @Volatile private var framesDropped = 0
    @Volatile private var lastFrameLogTime = 0L

    private fun clamp(v: Int): Int = maxOf(0, minOf(255, v))

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

                // ── Video share: video ─────────────────────────────────────────
                // NOTE: captureVideoFrame is now REMOVED — frames are pushed
                // directly from the decode thread into CustomVideoSource.
                // Dart's frame pump is also disabled (see VideoShareService.dart).

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

                // captureVideoFrame intentionally removed — no longer used

                else -> result.notImplemented()
            }
        }
    }

    // ── Video share: VIDEO decode internals ───────────────────────────────────

    private fun startVideoShareVideoInternal(filePath: String) {
        val extractor = MediaExtractor()
        extractor.setDataSource(filePath)

        var videoIdx = -1
        var mime = ""
        var trackFormat: MediaFormat? = null
        var width = 0
        var height = 0

        for (i in 0 until extractor.trackCount) {
            val fmt = extractor.getTrackFormat(i)
            val m = fmt.getString(MediaFormat.KEY_MIME) ?: ""
            if (m.startsWith("video/")) {
                videoIdx = i
                mime = m
                trackFormat = fmt
                width = fmt.getInteger(MediaFormat.KEY_WIDTH)
                height = fmt.getInteger(MediaFormat.KEY_HEIGHT)
                Log.d(TAG, "🎬 Video track found: mime=$m ${width}x${height}")
                break
            }
        }
        if (videoIdx == -1 || trackFormat == null) {
            throw Exception("No video track found in file: $filePath")
        }

        extractor.selectTrack(videoIdx)
        Log.d(TAG, "🎬 Video track selected: index=$videoIdx")

        // Software decode (null surface) so we can read output buffers directly
        val codec = MediaCodec.createDecoderByType(mime)
        Log.d(TAG, "🎬 Codec created for mime=$mime")
        codec.configure(trackFormat, null, null, 0)
        codec.start()
        Log.d(TAG, "🎬 Codec started")

        vvExtractor = extractor
        vvCodec = codec
        vvRunning = true
        framesPushed = 0
        framesDropped = 0
        lastFrameLogTime = System.currentTimeMillis()

        // Check if CustomVideoSource is already registered
        val cvs = CustomVideoSource.activeInstances[VIDEO_TRACK_ID]
        Log.d(TAG, "🎬 CustomVideoSource at decode start: ${if (cvs != null) "FOUND ✅" else "NOT FOUND ⚠️ — frames will be dropped until track is added"}")

        vvThread = buildVideoDecodeThread()
        vvThread?.start()
        Log.d(TAG, "✅ Video decode thread started for: $filePath")
    }

    private fun buildVideoDecodeThread(): Thread {
        val extractor = vvExtractor!!
        val codec = vvCodec!!

        return Thread {
            Log.d(TAG, "🎬 [DecodeThread] Started")
            val info = MediaCodec.BufferInfo()
            var inputDone = false
            var outDone = false
            var outputFormat: MediaFormat? = null
            var frameCount = 0

            while (vvRunning && !outDone) {
                // ── Feed input ──────────────────────────────────────────────
                if (!inputDone) {
                    val inIdx = codec.dequeueInputBuffer(10_000)
                    if (inIdx >= 0) {
                        val buf = codec.getInputBuffer(inIdx)!!
                        val size = extractor.readSampleData(buf, 0)
                        if (size < 0) {
                            Log.d(TAG, "🎬 [DecodeThread] Input EOS at frame $frameCount")
                            codec.queueInputBuffer(inIdx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputDone = true
                        } else {
                            codec.queueInputBuffer(inIdx, 0, size, extractor.sampleTime, 0)
                            extractor.advance()
                        }
                    }
                }

                // ── Drain output ────────────────────────────────────────────
                val outIdx = codec.dequeueOutputBuffer(info, 10_000)
                when {
                    outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        outputFormat = codec.outputFormat
                        Log.d(TAG, "🎬 [DecodeThread] Output format changed: $outputFormat")
                    }
                    outIdx >= 0 -> {
                        val buf = codec.getOutputBuffer(outIdx)
                        if (buf != null && info.size > 0) {
                            val fmt = outputFormat ?: codec.outputFormat
                            val w = fmt.getInteger(MediaFormat.KEY_WIDTH)
                            val h = fmt.getInteger(MediaFormat.KEY_HEIGHT)
                            val stride = runCatching { fmt.getInteger("stride") }.getOrDefault(w)
                            val sliceH = runCatching { fmt.getInteger("slice-height") }.getOrDefault(h)

                            if (frameCount == 0) {
                                Log.d(TAG, "🎬 [DecodeThread] First frame: ${w}x${h} stride=$stride sliceH=$sliceH bufSize=${buf.remaining()} infoSize=${info.size}")
                            }

                            // ── YUV NV12 → RGBA bytes ────────────────────────
                            // NV12: Y plane [stride * sliceH], UV interleaved [stride * sliceH/2]
                            val rgbaBytes = ByteArray(w * h * 4)
                            val uvOff = stride * sliceH

                            // Sanity check buffer is large enough
                            val requiredBufSize = uvOff + (stride * (sliceH / 2))
                            if (buf.capacity() < requiredBufSize) {
                                Log.w(TAG, "⚠️ [DecodeThread] Buffer too small: capacity=${buf.capacity()} required=$requiredBufSize, dropping frame")
                                codec.releaseOutputBuffer(outIdx, false)
                                framesDropped++
                            } else {
                                buf.rewind()
                                // Copy buffer to byte array for safe indexed access
                                val raw = ByteArray(buf.remaining())
                                buf.get(raw)

                                for (row in 0 until h) {
                                    for (col in 0 until w) {
                                        val yIdx = row * stride + col
                                        val uvIdx = uvOff + (row / 2) * stride + (col and 1.inv())

                                        val y = (raw[yIdx].toInt() and 0xFF) - 16
                                        val u = (raw[uvIdx].toInt() and 0xFF) - 128
                                        val v = (raw[uvIdx + 1].toInt() and 0xFF) - 128

                                        val r = clamp((298 * y + 409 * v + 128) shr 8)
                                        val g = clamp((298 * y - 100 * u - 208 * v + 128) shr 8)
                                        val b = clamp((298 * y + 516 * u + 128) shr 8)

                                        val i = (row * w + col) * 4
                                        rgbaBytes[i]     = r.toByte()
                                        rgbaBytes[i + 1] = g.toByte()
                                        rgbaBytes[i + 2] = b.toByte()
                                        rgbaBytes[i + 3] = 0xFF.toByte()
                                    }
                                }

                                codec.releaseOutputBuffer(outIdx, false)

                                // ── Push directly into WebRTC pipeline ──────────
                                val cvs = CustomVideoSource.activeInstances[VIDEO_TRACK_ID]
                                if (cvs != null) {
                                    cvs.pushRGBAFrame(rgbaBytes, w, h)
                                    framesPushed++
                                } else {
                                    framesDropped++
                                    if (frameCount < 5 || frameCount % 30 == 0) {
                                        Log.w(TAG, "⚠️ [DecodeThread] CustomVideoSource not ready, frame $frameCount dropped (total dropped=$framesDropped)")
                                    }
                                }

                                frameCount++

                                // Log stats every 3 seconds
                                val now = System.currentTimeMillis()
                                if (now - lastFrameLogTime >= 3000) {
                                    Log.d(TAG, "📊 [DecodeThread] Stats: pushed=$framesPushed dropped=$framesDropped total=$frameCount")
                                    lastFrameLogTime = now
                                }
                            }
                        } else {
                            codec.releaseOutputBuffer(outIdx, false)
                        }

                        if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                            Log.d(TAG, "🎬 [DecodeThread] Output EOS reached, total frames decoded=$frameCount pushed=$framesPushed dropped=$framesDropped")
                            outDone = true
                        }
                    }
                }
            }
            Log.d(TAG, "🎬 [DecodeThread] Exiting (vvRunning=$vvRunning, outDone=$outDone)")
        }.apply {
            name = "VideoShareVideoDecode"
            isDaemon = true
        }
    }

    private fun stopVideoShareVideoInternal() {
        Log.d(TAG, "🛑 stopVideoShareVideoInternal: stopping decode thread")
        vvRunning = false
        val t = vvThread
        vvThread = null
        try { t?.join(500) } catch (_: InterruptedException) {}
        Log.d(TAG, "🛑 Decode thread joined, releasing codec")
        runCatching { vvCodec?.stop(); vvCodec?.release() }
        runCatching { vvExtractor?.release() }
        vvCodec = null
        vvExtractor = null
        Log.d(TAG, "🛑 Video share video decode stopped. Final stats: pushed=$framesPushed dropped=$framesDropped")
    }

    // ── Video share: AUDIO decode internals ──────────────────────────────────

    private fun startVideoShareAudioInternal(filePath: String) {
        val extractor = MediaExtractor()
        extractor.setDataSource(filePath)

        var audioIdx = -1
        var mime = ""
        var sampleRate = 44100
        var channels = 2

        for (i in 0 until extractor.trackCount) {
            val fmt = extractor.getTrackFormat(i)
            val m = fmt.getString(MediaFormat.KEY_MIME) ?: ""
            if (m.startsWith("audio/")) {
                audioIdx = i
                mime = m
                sampleRate = fmt.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                channels = fmt.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                Log.d(TAG, "🎵 Audio track: mime=$m sr=$sampleRate ch=$channels")
                break
            }
        }
        if (audioIdx == -1) throw Exception("No audio track in file")

        extractor.selectTrack(audioIdx)

        val codec = MediaCodec.createDecoderByType(mime)
        codec.configure(extractor.getTrackFormat(audioIdx), null, null, 0)
        codec.start()

        val chCfg = if (channels == 1) AudioFormat.CHANNEL_OUT_MONO else AudioFormat.CHANNEL_OUT_STEREO
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
        vsCodec = codec
        vsSpeaker = speaker
        vsRunning = true

        vsThread = buildAudioDecodeThread()
        vsThread?.start()
        Log.d(TAG, "✅ Video share audio decode started: $filePath")
    }

    private fun buildAudioDecodeThread(): Thread {
        val extractor = vsExtractor!!
        val codec = vsCodec!!
        val speaker = vsSpeaker!!

        return Thread {
            val info = MediaCodec.BufferInfo()
            var inputDone = false
            var outDone = false

            while (vsRunning && !outDone) {
                if (!inputDone) {
                    val inIdx = codec.dequeueInputBuffer(10_000)
                    if (inIdx >= 0) {
                        val buf = codec.getInputBuffer(inIdx)!!
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
            Log.d(TAG, "🎵 Audio decode thread exiting (vsRunning=$vsRunning)")
        }.apply {
            name = "VideoShareAudioDecode"
            isDaemon = true
        }
    }

    private fun stopVideoShareAudioInternal() {
        vsRunning = false
        val t = vsThread
        vsThread = null
        try { t?.join(500) } catch (_: InterruptedException) {}
        runCatching { vsCodec?.stop(); vsCodec?.release() }
        runCatching { vsExtractor?.release() }
        runCatching { vsSpeaker?.stop(); vsSpeaker?.release() }
        vsCodec = null
        vsExtractor = null
        vsSpeaker = null
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