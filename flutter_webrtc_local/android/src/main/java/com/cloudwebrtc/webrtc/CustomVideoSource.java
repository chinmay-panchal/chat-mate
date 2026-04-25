package com.cloudwebrtc.webrtc;

import android.os.SystemClock;
import android.util.Log;

import org.webrtc.JavaI420Buffer;
import org.webrtc.VideoFrame;
import org.webrtc.VideoSource;
import org.webrtc.VideoTrack;
import org.webrtc.PeerConnectionFactory;

import java.nio.ByteBuffer;
import java.util.concurrent.TimeUnit;

/**
 * CustomVideoSource
 *
 * Wraps a WebRTC VideoSource + VideoTrack pair and accepts raw RGBA frames
 * pushed from Dart via MethodChannel ("pushVideoFrame"). Converts RGBA → I420
 * in software and feeds the WebRTC encoding pipeline.
 *
 * Lifecycle (driven from MethodCallHandlerImpl): createCustomVideoTrack → new
 * CustomVideoSource(factory, trackId) pushVideoFrame → pushRGBAFrame(rgba, w,
 * h) disposeCustomVideoTrack → dispose()
 */
public class CustomVideoSource {

    private static final String TAG = "CustomVideoSource";

    private final VideoSource videoSource;
    private final VideoTrack videoTrack;
    private final String trackId;

    // Scratch buffers — reallocated only on dimension change
    private ByteBuffer yBuf, uBuf, vBuf;
    private int lastW = 0, lastH = 0;

    public CustomVideoSource(PeerConnectionFactory factory, String trackId) {
        this.trackId = trackId;
        this.videoSource = factory.createVideoSource(false /* isScreencast */);
        this.videoTrack = factory.createVideoTrack(trackId, videoSource);
        this.videoTrack.setEnabled(true);
        Log.d(TAG, "✅ CustomVideoSource created: " + trackId);
    }

    // ── Public API ────────────────────────────────────────────────────────────
    public VideoTrack getTrack() {
        return videoTrack;
    }

    public VideoSource getSource() {
        return videoSource;
    }

    public String getTrackId() {
        return trackId;
    }

    /**
     * Push one RGBA frame into the WebRTC pipeline. Safe to call from any
     * thread.
     *
     * @param rgba raw RGBA bytes, length must == width * height * 4
     * @param width frame width in pixels
     * @param height frame height in pixels
     */
    public void pushRGBAFrame(byte[] rgba, int width, int height) {
        if (rgba == null || rgba.length != width * height * 4) {
            Log.w(TAG, "pushRGBAFrame: bad buffer, dropping frame");
            return;
        }
        if (width != lastW || height != lastH) {
            allocatePlanes(width, height);
            lastW = width;
            lastH = height;
        }

        rgbaToI420(rgba, width, height, yBuf, uBuf, vBuf);

        long tsNs = TimeUnit.MILLISECONDS.toNanos(SystemClock.elapsedRealtime());
        JavaI420Buffer i420 = JavaI420Buffer.allocate(width, height);

        int uvW = (width + 1) / 2;
        int uvH = (height + 1) / 2;
        copyInto(yBuf, i420.getDataY(), width * height);
        copyInto(uBuf, i420.getDataU(), uvW * uvH);
        copyInto(vBuf, i420.getDataV(), uvW * uvH);

        VideoFrame frame = new VideoFrame(i420, 0 /* rotation */, tsNs);
        try {
            videoSource.getCapturerObserver().onFrameCaptured(frame);
        } finally {
            frame.release();
        }
    }

    public void dispose() {
        videoTrack.setEnabled(false);
        videoTrack.dispose();
        videoSource.dispose();
        Log.d(TAG, "🗑️ CustomVideoSource disposed: " + trackId);
    }

    // ── Helpers ───────────────────────────────────────────────────────────────
    private void allocatePlanes(int w, int h) {
        int uvW = (w + 1) / 2;
        int uvH = (h + 1) / 2;
        yBuf = ByteBuffer.allocateDirect(w * h);
        uBuf = ByteBuffer.allocateDirect(uvW * uvH);
        vBuf = ByteBuffer.allocateDirect(uvW * uvH);
    }

    /**
     * BT.601 RGBA → I420. Fine for ≤720p @ 15 fps.
     */
    private static void rgbaToI420(byte[] rgba, int w, int h,
            ByteBuffer outY, ByteBuffer outU, ByteBuffer outV) {
        outY.clear();
        outU.clear();
        outV.clear();

        for (int row = 0; row < h; row++) {
            for (int col = 0; col < w; col++) {
                int i = (row * w + col) * 4;
                int r = rgba[i] & 0xFF;
                int g = rgba[i + 1] & 0xFF;
                int b = rgba[i + 2] & 0xFF;
                outY.put((byte) clamp(((66 * r + 129 * g + 25 * b + 128) >> 8) + 16));
            }
        }

        int uvW = (w + 1) / 2;
        int uvH = (h + 1) / 2;
        for (int row = 0; row < uvH; row++) {
            for (int col = 0; col < uvW; col++) {
                int r = 0, g = 0, b = 0, cnt = 0;
                for (int dy = 0; dy < 2; dy++) {
                    int sr = row * 2 + dy;
                    if (sr >= h) {
                        continue;
                    }
                    for (int dx = 0; dx < 2; dx++) {
                        int sc = col * 2 + dx;
                        if (sc >= w) {
                            continue;
                        }
                        int i = (sr * w + sc) * 4;
                        r += rgba[i] & 0xFF;
                        g += rgba[i + 1] & 0xFF;
                        b += rgba[i + 2] & 0xFF;
                        cnt++;
                    }
                }
                if (cnt == 0) {
                    cnt = 1;
                }
                r /= cnt;
                g /= cnt;
                b /= cnt;
                outU.put((byte) clamp(((-38 * r - 74 * g + 112 * b + 128) >> 8) + 128));
                outV.put((byte) clamp(((112 * r - 94 * g - 18 * b + 128) >> 8) + 128));
            }
        }
    }

    private static void copyInto(ByteBuffer src, ByteBuffer dst, int bytes) {
        src.rewind();
        int n = Math.min(bytes, Math.min(src.remaining(), dst.remaining()));
        byte[] tmp = new byte[n];
        src.get(tmp, 0, n);
        dst.put(tmp, 0, n);
    }

    private static int clamp(int v) {
        return Math.max(0, Math.min(255, v));
    }
}
