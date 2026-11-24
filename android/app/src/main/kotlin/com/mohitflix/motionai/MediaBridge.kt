package com.mohitflix.motionai

import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.segmentation.subject.SubjectSegmentation
import com.google.mlkit.vision.segmentation.subject.SubjectSegmenterOptions
import java.io.FileOutputStream
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.media.MediaMuxer
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileInputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.Executors
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * Native media helpers for MotionAI:
 *  - exact video frames (export) and JPEG thumbnails (AI)
 *  - audio-track extraction (captions)
 *  - H.264 encoding of rendered frames + audio mixing + MP4 muxing (export)
 *  - saving to the gallery and sharing
 */
class MediaBridge(private val context: Context, messenger: BinaryMessenger) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, "motionai/media")
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private val retrievers = HashMap<String, MediaMetadataRetriever>()
    private var encoder: VideoEncoder? = null
    private val readers = HashMap<String, FrameReader>()

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        worker.execute {
            try {
                val value: Any? = when (call.method) {
                    "frameAt" -> frameAt(call.argument<String>("path")!!, call.long("timeUs"), call.argument<Int>("maxSize") ?: 1280)
                    "readerFrame" -> {
                        val key = call.argument<String>("key")!!
                        val path = call.argument<String>("path")!!
                        val reader = readers[key]?.takeIf { it.path == path }
                            ?: FrameReader(path).also { readers.put(key, it)?.release() }
                        reader.frameAt(call.long("timeUs"), call.argument<Int>("maxSize") ?: 1920)
                    }
                    "readerReleaseAll" -> {
                        readers.values.forEach { it.release() }
                        readers.clear()
                        null
                    }
                    "cutout" -> cutout(
                        call.argument<String>("path")!!,
                        call.argument<String>("fg")!!,
                        call.argument<String>("bg")!!,
                    )
                    "normalizeImage" -> normalizeImage(call.argument<String>("path")!!, call.argument<String>("out")!!)
                    "thumbnailJpeg" -> thumbnail(call.argument<String>("path")!!, call.long("timeUs"), call.argument<Int>("maxSize") ?: 512)
                    "extractAudio" -> extractAudio(call.argument<String>("path")!!, call.argument<String>("out")!!)
                    "encoderStart" -> {
                        encoder?.cancel()
                        encoder = VideoEncoder(
                            call.argument<String>("out")!!,
                            call.argument<Int>("width")!!,
                            call.argument<Int>("height")!!,
                            call.argument<Double>("fps")!!,
                            call.argument<Int>("bitrate")!!,
                        )
                        null
                    }
                    "encoderFrame" -> {
                        val enc = encoder ?: throw IllegalStateException("Encoder not started")
                        enc.addFrame(call.argument<ByteArray>("rgba")!!)
                        null
                    }
                    "encoderFinish" -> {
                        val enc = encoder ?: throw IllegalStateException("Encoder not started")
                        encoder = null
                        enc.finish()
                        @Suppress("UNCHECKED_CAST")
                        val audio = (call.argument<List<Map<String, Any?>>>("audio") ?: emptyList())
                        val duration = call.argument<Double>("duration")!!
                        val finalPath = call.argument<String>("final")!!
                        AudioMixer.muxWithAudio(enc.outPath, finalPath, duration, audio)
                        File(enc.outPath).delete()
                        null
                    }
                    "encoderCancel" -> {
                        encoder?.cancel()
                        encoder = null
                        null
                    }
                    "saveToGallery" -> saveToGallery(call.argument<String>("path")!!, call.argument<String>("name")!!)
                    "share" -> {
                        share(call.argument<String>("path")!!)
                        null
                    }
                    else -> {
                        main.post { result.notImplemented() }
                        return@execute
                    }
                }
                main.post { result.success(value) }
            } catch (e: Throwable) {
                main.post { result.error("media", e.message ?: e.toString(), null) }
            }
        }
    }

    private fun MethodCall.long(key: String): Long = (argument<Any>(key) as Number).toLong()

    // ------------------------------------------------------------ frames

    private fun retriever(path: String): MediaMetadataRetriever =
        retrievers.getOrPut(path) { MediaMetadataRetriever().apply { setDataSource(path) } }

    private fun grab(path: String, timeUs: Long, maxSize: Int): Bitmap? {
        val r = retriever(path)
        val w = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull() ?: 0
        val h = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull() ?: 0
        val rot = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull() ?: 0
        val (dw, dh) = if (rot == 90 || rot == 270) Pair(h, w) else Pair(w, h)
        val scale = if (dw > 0 && dh > 0) min(1.0, maxSize.toDouble() / max(dw, dh)) else 1.0
        val tw = max(2, (dw * scale).roundToInt())
        val th = max(2, (dh * scale).roundToInt())
        val bmp = if (Build.VERSION.SDK_INT >= 27 && dw > 0) {
            r.getScaledFrameAtTime(timeUs, MediaMetadataRetriever.OPTION_CLOSEST, tw, th)
        } else {
            r.getFrameAtTime(timeUs, MediaMetadataRetriever.OPTION_CLOSEST)?.let { Bitmap.createScaledBitmap(it, tw, th, true) }
        } ?: return null
        return if (bmp.config != Bitmap.Config.ARGB_8888) bmp.copy(Bitmap.Config.ARGB_8888, false) else bmp
    }

    private fun frameAt(path: String, timeUs: Long, maxSize: Int): Map<String, Any>? {
        val bmp = grab(path, timeUs, maxSize) ?: return null
        val buf = ByteBuffer.allocate(bmp.byteCount)
        bmp.copyPixelsToBuffer(buf)
        return mapOf("width" to bmp.width, "height" to bmp.height, "rgba" to buf.array())
    }

    private fun thumbnail(path: String, timeUs: Long, maxSize: Int): ByteArray? {
        val bmp = grab(path, timeUs, maxSize) ?: return null
        val out = ByteArrayOutputStream()
        bmp.compress(Bitmap.CompressFormat.JPEG, 80, out)
        return out.toByteArray()
    }

    // ------------------------------------------------------ image import

    /**
     * Decodes any photo Android can read (JPEG, PNG, WebP, HEIC/HEIF...),
     * applies EXIF rotation, limits size to 4096 px and writes a JPEG
     * (or PNG when the image has transparency).
     */
    private fun normalizeImage(path: String, outBase: String): Map<String, Any> {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(path, bounds)
        var sample = 1
        while (max(bounds.outWidth, bounds.outHeight) / sample > 4096) sample *= 2
        val opts = BitmapFactory.Options().apply {
            inSampleSize = sample
            inPreferredConfig = Bitmap.Config.ARGB_8888
        }
        var bmp = BitmapFactory.decodeFile(path, opts) ?: throw IllegalStateException("This image format can't be read")
        val rotation = try {
            when (android.media.ExifInterface(path).getAttributeInt(android.media.ExifInterface.TAG_ORIENTATION, 1)) {
                android.media.ExifInterface.ORIENTATION_ROTATE_90 -> 90f
                android.media.ExifInterface.ORIENTATION_ROTATE_180 -> 180f
                android.media.ExifInterface.ORIENTATION_ROTATE_270 -> 270f
                else -> 0f
            }
        } catch (_: Throwable) { 0f }
        if (rotation != 0f) {
            val m = android.graphics.Matrix().apply { postRotate(rotation) }
            bmp = Bitmap.createBitmap(bmp, 0, 0, bmp.width, bmp.height, m, true)
        }
        val png = bmp.hasAlpha() && path.lowercase().endsWith(".png")
        val out = outBase + if (png) ".png" else ".jpg"
        FileOutputStream(out).use {
            bmp.compress(if (png) Bitmap.CompressFormat.PNG else Bitmap.CompressFormat.JPEG, if (png) 100 else 92, it)
        }
        return mapOf("width" to bmp.width, "height" to bmp.height, "path" to out)
    }

    // ----------------------------------------------------- subject cut-out

    /** Splits a photo into a transparent foreground subject and a background plate. */
    private fun cutout(path: String, fgPath: String, bgPath: String): Map<String, Any> {
        val opts = BitmapFactory.Options().apply { inPreferredConfig = Bitmap.Config.ARGB_8888 }
        var src = BitmapFactory.decodeFile(path, opts) ?: throw IllegalStateException("Cannot read image")
        val maxSide = 2048
        if (max(src.width, src.height) > maxSide) {
            val k = maxSide.toDouble() / max(src.width, src.height)
            src = Bitmap.createScaledBitmap(src, (src.width * k).roundToInt(), (src.height * k).roundToInt(), true)
        }
        val segmenter = SubjectSegmentation.getClient(
            SubjectSegmenterOptions.Builder().enableForegroundBitmap().build()
        )
        val result = Tasks.await(segmenter.process(InputImage.fromBitmap(src, 0)))
        val fg = result.foregroundBitmap ?: throw IllegalStateException("No subject found in this photo")
        segmenter.close()
        FileOutputStream(fgPath).use { fg.compress(Bitmap.CompressFormat.PNG, 100, it) }

        // Background plate: subject area filled with a heavy blur of the photo,
        // so parallax doesn't reveal a sharp duplicate of the subject.
        val w = src.width
        val h = src.height
        val small = Bitmap.createScaledBitmap(src, max(1, w / 24), max(1, h / 24), true)
        val blurred = Bitmap.createScaledBitmap(small, w, h, true)
        val srcPx = IntArray(w * h).also { src.getPixels(it, 0, w, 0, 0, w, h) }
        val blurPx = IntArray(w * h).also { blurred.getPixels(it, 0, w, 0, 0, w, h) }
        val fgScaled = if (fg.width != w || fg.height != h) Bitmap.createScaledBitmap(fg, w, h, true) else fg
        val fgPx = IntArray(w * h).also { fgScaled.getPixels(it, 0, w, 0, 0, w, h) }
        // Dilate the subject mask a little (cheap: 3 passes of 4-neighbour max on a coarse grid).
        val mask = BooleanArray(w * h) { (fgPx[it] ushr 24) > 20 }
        val r = max(2, max(w, h) / 120)
        val grown = BooleanArray(w * h)
        for (y in 0 until h) {
            for (x in 0 until w) {
                if (!mask[y * w + x]) continue
                for (dy in -r..r step max(1, r / 2)) {
                    val yy = y + dy
                    if (yy < 0 || yy >= h) continue
                    for (dx in -r..r step max(1, r / 2)) {
                        val xx = x + dx
                        if (xx in 0 until w) grown[yy * w + xx] = true
                    }
                }
            }
        }
        for (i in 0 until w * h) if (grown[i]) srcPx[i] = blurPx[i]
        val bg = Bitmap.createBitmap(srcPx, w, h, Bitmap.Config.ARGB_8888)
        FileOutputStream(bgPath).use { bg.compress(Bitmap.CompressFormat.JPEG, 92, it) }
        return mapOf("width" to w, "height" to h)
    }

    // ------------------------------------------------------------- audio

    private fun extractAudio(path: String, outPath: String): Boolean {
        val ex = MediaExtractor()
        ex.setDataSource(path)
        var track = -1
        for (i in 0 until ex.trackCount) {
            if (ex.getTrackFormat(i).getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true) {
                track = i
                break
            }
        }
        if (track < 0) {
            ex.release()
            return false
        }
        ex.selectTrack(track)
        val muxer = MediaMuxer(outPath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        val out = muxer.addTrack(ex.getTrackFormat(track))
        muxer.start()
        val buf = ByteBuffer.allocate(1 shl 20)
        val info = MediaCodec.BufferInfo()
        while (true) {
            val size = ex.readSampleData(buf, 0)
            if (size < 0) break
            info.set(0, size, ex.sampleTime, if ((ex.sampleFlags and MediaExtractor.SAMPLE_FLAG_SYNC) != 0) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0)
            muxer.writeSampleData(out, buf, info)
            ex.advance()
        }
        muxer.stop()
        muxer.release()
        ex.release()
        return true
    }

    // ----------------------------------------------------- gallery/share

    private fun saveToGallery(path: String, name: String): String {
        val src = File(path)
        if (Build.VERSION.SDK_INT >= 29) {
            val values = ContentValues().apply {
                put(MediaStore.Video.Media.DISPLAY_NAME, name)
                put(MediaStore.Video.Media.MIME_TYPE, "video/mp4")
                put(MediaStore.Video.Media.RELATIVE_PATH, Environment.DIRECTORY_MOVIES + "/MotionAI")
                put(MediaStore.Video.Media.IS_PENDING, 1)
            }
            val resolver = context.contentResolver
            val uri = resolver.insert(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, values)
                ?: throw IllegalStateException("Could not create gallery entry")
            resolver.openOutputStream(uri)!!.use { out -> FileInputStream(src).use { it.copyTo(out) } }
            values.clear()
            values.put(MediaStore.Video.Media.IS_PENDING, 0)
            resolver.update(uri, values, null, null)
            return uri.toString()
        }
        val dir = File(context.getExternalFilesDir(Environment.DIRECTORY_MOVIES), "MotionAI").apply { mkdirs() }
        val dest = File(dir, name)
        src.copyTo(dest, overwrite = true)
        return dest.absolutePath
    }

    private fun share(uriString: String) {
        val uri = Uri.parse(uriString)
        val send = Intent(Intent.ACTION_SEND).apply {
            type = "video/mp4"
            putExtra(Intent.EXTRA_STREAM, uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        val chooser = Intent.createChooser(send, "Share video").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        main.post { context.startActivity(chooser) }
    }
}

/**
 * Sequential frame-exact video decoder for export. Decodes forward from the
 * nearest keyframe and only seeks when time jumps, so exporting a clip
 * decodes each frame once. Output is RGBA, rotated upright, downscaled to
 * at most maxSize on the long side.
 */
class FrameReader(val path: String) {
    private val ex = MediaExtractor()
    private val dec: MediaCodec
    private val rotation: Int
    private val info = MediaCodec.BufferInfo()
    private var lastPts = Long.MIN_VALUE
    private var last: Map<String, Any>? = null
    private var inputDone = false
    private var outputDone = false

    init {
        ex.setDataSource(path)
        var track = -1
        for (i in 0 until ex.trackCount) {
            if (ex.getTrackFormat(i).getString(MediaFormat.KEY_MIME)?.startsWith("video/") == true) {
                track = i
                break
            }
        }
        if (track < 0) throw IllegalStateException("No video track in $path")
        ex.selectTrack(track)
        val fmt = ex.getTrackFormat(track)
        rotation = if (fmt.containsKey("rotation-degrees")) fmt.getInteger("rotation-degrees") else 0
        fmt.setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible)
        dec = MediaCodec.createDecoderByType(fmt.getString(MediaFormat.KEY_MIME)!!)
        dec.configure(fmt, null, null, 0)
        dec.start()
    }

    fun frameAt(timeUs: Long, maxSize: Int): Map<String, Any>? {
        val l = last
        if (l != null && timeUs in lastPts until lastPts + 1) return l
        // Seek when going backwards or jumping far ahead.
        if (timeUs < lastPts || timeUs > lastPts + 1_500_000 || outputDone) {
            ex.seekTo(timeUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
            dec.flush()
            inputDone = false
            outputDone = false
            lastPts = Long.MIN_VALUE
        }
        var guard = 0
        while (!outputDone && guard++ < 20_000) {
            if (!inputDone) {
                val ii = dec.dequeueInputBuffer(5_000)
                if (ii >= 0) {
                    val size = ex.readSampleData(dec.getInputBuffer(ii)!!, 0)
                    if (size < 0) {
                        dec.queueInputBuffer(ii, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                        inputDone = true
                    } else {
                        dec.queueInputBuffer(ii, 0, size, ex.sampleTime, 0)
                        ex.advance()
                    }
                }
            }
            val oi = dec.dequeueOutputBuffer(info, 5_000)
            if (oi >= 0) {
                val eos = (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0
                if (eos) outputDone = true
                // Convert only the first frame at/after the requested time.
                val reached = info.presentationTimeUs >= timeUs - 1_000
                if (info.size > 0 && (reached || (eos && last == null))) {
                    val image = dec.getOutputImage(oi)
                    if (image != null) {
                        last = convert(image, maxSize)
                        image.close()
                    }
                }
                if (info.size > 0) lastPts = info.presentationTimeUs
                dec.releaseOutputBuffer(oi, false)
                if (reached || eos) break
            }
        }
        return last
    }

    private fun convert(image: android.media.Image, maxSize: Int): Map<String, Any> {
        val crop = image.cropRect
        val w = crop.width()
        val h = crop.height()
        val rot = ((rotation % 360) + 360) % 360
        val dw = if (rot == 90 || rot == 270) h else w
        val dh = if (rot == 90 || rot == 270) w else h
        val step = max(1, kotlin.math.ceil(max(dw, dh).toDouble() / maxSize).toInt())
        val ow = dw / step
        val oh = dh / step
        val out = ByteArray(ow * oh * 4)
        val p = image.planes
        val yB = p[0].buffer
        val uB = p[1].buffer
        val vB = p[2].buffer
        val yRow = p[0].rowStride
        val yPix = p[0].pixelStride
        val uvRow = p[1].rowStride
        val uvPix = p[1].pixelStride
        var o = 0
        for (oy in 0 until oh) {
            for (ox in 0 until ow) {
                val dx = ox * step
                val dy = oy * step
                val sx: Int
                val sy: Int
                when (rot) {
                    90 -> { sx = dy; sy = h - 1 - dx }
                    180 -> { sx = w - 1 - dx; sy = h - 1 - dy }
                    270 -> { sx = w - 1 - dy; sy = dx }
                    else -> { sx = dx; sy = dy }
                }
                val px = sx + crop.left
                val py = sy + crop.top
                val y = (yB.get(py * yRow + px * yPix).toInt() and 0xFF) - 16
                val uvi = (py shr 1) * uvRow + (px shr 1) * uvPix
                val u = (uB.get(uvi).toInt() and 0xFF) - 128
                val v = (vB.get(uvi).toInt() and 0xFF) - 128
                val c = 298 * y
                out[o] = clamp((c + 409 * v + 128) shr 8)
                out[o + 1] = clamp((c - 100 * u - 208 * v + 128) shr 8)
                out[o + 2] = clamp((c + 516 * u + 128) shr 8)
                out[o + 3] = 0xFF.toByte()
                o += 4
            }
        }
        return mapOf("width" to ow, "height" to oh, "rgba" to out)
    }

    private fun clamp(v: Int): Byte = (if (v < 0) 0 else if (v > 255) 255 else v).toByte()

    fun release() {
        try { dec.stop() } catch (_: Throwable) {}
        try { dec.release() } catch (_: Throwable) {}
        try { ex.release() } catch (_: Throwable) {}
    }
}

/** Encodes RGBA frames to an H.264 MP4 (video only) with exact timestamps. */
class VideoEncoder(val outPath: String, private val width: Int, private val height: Int, fps: Double, bitrate: Int) {
    private val codec: MediaCodec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
    private val muxer = MediaMuxer(outPath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
    private val frameUs = 1_000_000.0 / fps
    private var frame = 0L
    private var track = -1
    private var muxing = false
    private val info = MediaCodec.BufferInfo()

    init {
        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible)
            setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
            setFloat(MediaFormat.KEY_FRAME_RATE, fps.toFloat())
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
        }
        codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        codec.start()
    }

    fun addFrame(rgba: ByteArray) {
        var index: Int
        while (true) {
            index = codec.dequeueInputBuffer(10_000)
            if (index >= 0) break
            drain(false)
        }
        val image = codec.getInputImage(index) ?: throw IllegalStateException("No encoder input image")
        fillYuv(image, rgba)
        val pts = (frame * frameUs).toLong()
        codec.queueInputBuffer(index, 0, width * height * 3 / 2, pts, 0)
        frame++
        drain(false)
    }

    private fun fillYuv(image: android.media.Image, rgba: ByteArray) {
        val planes = image.planes
        val yBuf = planes[0].buffer
        val yRow = planes[0].rowStride
        val yPix = planes[0].pixelStride
        val uBuf = planes[1].buffer
        val vBuf = planes[2].buffer
        val uvRow = planes[1].rowStride
        val uvPix = planes[1].pixelStride
        for (y in 0 until height) {
            val rowIn = y * width * 4
            val rowY = y * yRow
            val evenRow = (y and 1) == 0
            val rowUv = (y shr 1) * uvRow
            for (x in 0 until width) {
                val i = rowIn + x * 4
                val r = rgba[i].toInt() and 0xFF
                val g = rgba[i + 1].toInt() and 0xFF
                val b = rgba[i + 2].toInt() and 0xFF
                yBuf.put(rowY + x * yPix, (((66 * r + 129 * g + 25 * b + 128) shr 8) + 16).toByte())
                if (evenRow && (x and 1) == 0) {
                    val o = rowUv + (x shr 1) * uvPix
                    uBuf.put(o, (((-38 * r - 74 * g + 112 * b + 128) shr 8) + 128).toByte())
                    vBuf.put(o, (((112 * r - 94 * g - 18 * b + 128) shr 8) + 128).toByte())
                }
            }
        }
    }

    private fun drain(endOfStream: Boolean) {
        while (true) {
            val index = codec.dequeueOutputBuffer(info, 10_000)
            when {
                index == MediaCodec.INFO_TRY_AGAIN_LATER -> if (!endOfStream) return
                index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    track = muxer.addTrack(codec.outputFormat)
                    muxer.start()
                    muxing = true
                }
                index >= 0 -> {
                    val buf = codec.getOutputBuffer(index)!!
                    if ((info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0) info.size = 0
                    if (info.size > 0 && muxing) {
                        buf.position(info.offset)
                        buf.limit(info.offset + info.size)
                        muxer.writeSampleData(track, buf, info)
                    }
                    codec.releaseOutputBuffer(index, false)
                    if ((info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) return
                }
            }
        }
    }

    fun finish() {
        var index: Int
        while (true) {
            index = codec.dequeueInputBuffer(10_000)
            if (index >= 0) break
            drain(false)
        }
        codec.queueInputBuffer(index, 0, 0, (frame * frameUs).toLong(), MediaCodec.BUFFER_FLAG_END_OF_STREAM)
        drain(true)
        codec.stop()
        codec.release()
        if (muxing) muxer.stop()
        muxer.release()
    }

    fun cancel() {
        try { codec.stop() } catch (_: Throwable) {}
        try { codec.release() } catch (_: Throwable) {}
        try { if (muxing) muxer.stop() } catch (_: Throwable) {}
        try { muxer.release() } catch (_: Throwable) {}
        File(outPath).delete()
    }
}

/** Decodes, resamples and mixes audio clips, encodes AAC and muxes it with the video. */
object AudioMixer {
    private const val SR = 44100
    private const val CH = 2

    fun muxWithAudio(videoPath: String, finalPath: String, duration: Double, clips: List<Map<String, Any?>>) {
        val total = (duration * SR).toInt() + 1
        val mix = FloatArray(total * CH)
        var any = false
        for (c in clips) {
            try {
                if (decodeInto(mix, total, c)) any = true
            } catch (_: Throwable) {
                // Skip clips whose audio can't be decoded.
            }
        }
        val vEx = MediaExtractor().apply { setDataSource(videoPath) }
        vEx.selectTrack(0)
        val muxer = MediaMuxer(finalPath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        val vTrack = muxer.addTrack(vEx.getTrackFormat(0))
        if (any) {
            encodeAac(mix, total, muxer, vTrack, vEx)
        } else {
            muxer.start()
            copyVideo(vEx, muxer, vTrack)
        }
        muxer.stop()
        muxer.release()
        vEx.release()
    }

    private fun num(v: Any?, d: Double): Double = (v as? Number)?.toDouble() ?: d

    private fun decodeInto(mix: FloatArray, total: Int, clip: Map<String, Any?>): Boolean {
        val path = clip["path"] as? String ?: return false
        val start = num(clip["start"], 0.0)
        val sourceIn = num(clip["sourceIn"], 0.0)
        val dur = num(clip["duration"], 0.0)
        val speed = num(clip["speed"], 1.0).coerceIn(0.05, 16.0)
        val volume = num(clip["volume"], 1.0).toFloat()
        if (volume <= 0f || dur <= 0) return false

        val ex = MediaExtractor()
        ex.setDataSource(path)
        var track = -1
        for (i in 0 until ex.trackCount) {
            if (ex.getTrackFormat(i).getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true) {
                track = i
                break
            }
        }
        if (track < 0) {
            ex.release()
            return false
        }
        ex.selectTrack(track)
        val inFormat = ex.getTrackFormat(track)
        ex.seekTo((sourceIn * 1e6).toLong(), MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
        val dec = MediaCodec.createDecoderByType(inFormat.getString(MediaFormat.KEY_MIME)!!)
        dec.configure(inFormat, null, null, 0)
        dec.start()

        var sr = inFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE)
        var ch = inFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
        val info = MediaCodec.BufferInfo()
        var inputDone = false
        var prevT = Double.NaN
        var prevL = 0f
        var prevR = 0f
        val endSource = sourceIn + dur * speed
        var wrote = false
        loop@ while (true) {
            if (!inputDone) {
                val ii = dec.dequeueInputBuffer(5_000)
                if (ii >= 0) {
                    val b = dec.getInputBuffer(ii)!!
                    val size = ex.readSampleData(b, 0)
                    if (size < 0 || ex.sampleTime / 1e6 > endSource + 0.5) {
                        dec.queueInputBuffer(ii, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                        inputDone = true
                    } else {
                        dec.queueInputBuffer(ii, 0, size, ex.sampleTime, 0)
                        ex.advance()
                    }
                }
            }
            val oi = dec.dequeueOutputBuffer(info, 5_000)
            when {
                oi == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    sr = dec.outputFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                    ch = dec.outputFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                }
                oi >= 0 -> {
                    val out = dec.getOutputBuffer(oi)!!.order(ByteOrder.LITTLE_ENDIAN)
                    out.position(info.offset)
                    out.limit(info.offset + info.size)
                    val shorts = out.asShortBuffer()
                    val frames = shorts.remaining() / ch
                    val t0 = info.presentationTimeUs / 1e6
                    for (f in 0 until frames) {
                        val ts = t0 + f.toDouble() / sr
                        val l = shorts.get(f * ch) / 32768f
                        val r = if (ch > 1) shorts.get(f * ch + 1) / 32768f else l
                        if (ts < sourceIn || ts >= endSource) {
                            prevT = Double.NaN
                            continue
                        }
                        val compT = start + (ts - sourceIn) / speed
                        if (!prevT.isNaN()) {
                            // Linear resampling between the previous and this input frame.
                            var j = kotlin.math.ceil(prevT * SR).toInt()
                            val jEnd = kotlin.math.floor(compT * SR).toInt()
                            val span = compT - prevT
                            while (j <= jEnd) {
                                if (j in 0 until total) {
                                    val k = if (span <= 0) 1f else ((j.toDouble() / SR - prevT) / span).toFloat()
                                    mix[j * CH] += (prevL + (l - prevL) * k) * volume
                                    mix[j * CH + 1] += (prevR + (r - prevR) * k) * volume
                                    wrote = true
                                }
                                j++
                            }
                        }
                        prevT = compT + 1e-9
                        prevL = l
                        prevR = r
                    }
                    dec.releaseOutputBuffer(oi, false)
                    if ((info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) break@loop
                }
            }
        }
        dec.stop()
        dec.release()
        ex.release()
        return wrote
    }

    private fun encodeAac(mix: FloatArray, total: Int, muxer: MediaMuxer, vTrack: Int, vEx: MediaExtractor) {
        val fmt = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, SR, CH).apply {
            setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
            setInteger(MediaFormat.KEY_BIT_RATE, 192_000)
            setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 1 shl 16)
        }
        val enc = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
        enc.configure(fmt, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        enc.start()
        val info = MediaCodec.BufferInfo()
        var aTrack = -1
        var started = false
        var pos = 0 // frames written
        var inputDone = false
        val chunk = 1024
        while (true) {
            if (!inputDone) {
                val ii = enc.dequeueInputBuffer(5_000)
                if (ii >= 0) {
                    val b = enc.getInputBuffer(ii)!!.order(ByteOrder.LITTLE_ENDIAN)
                    b.clear()
                    val n = min(chunk, total - pos)
                    if (n <= 0) {
                        enc.queueInputBuffer(ii, 0, 0, pos * 1_000_000L / SR, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                        inputDone = true
                    } else {
                        for (k in 0 until n * CH) {
                            val v = mix[pos * CH + k].coerceIn(-1f, 1f)
                            b.putShort((v * 32767f).toInt().toShort())
                        }
                        enc.queueInputBuffer(ii, 0, n * CH * 2, pos * 1_000_000L / SR, 0)
                        pos += n
                    }
                }
            }
            val oi = enc.dequeueOutputBuffer(info, 5_000)
            if (oi == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                aTrack = muxer.addTrack(enc.outputFormat)
                muxer.start()
                started = true
            } else if (oi >= 0) {
                val buf = enc.getOutputBuffer(oi)!!
                if ((info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0) info.size = 0
                if (info.size > 0 && started) {
                    buf.position(info.offset)
                    buf.limit(info.offset + info.size)
                    muxer.writeSampleData(aTrack, buf, info)
                }
                enc.releaseOutputBuffer(oi, false)
                if ((info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) break
            }
        }
        enc.stop()
        enc.release()
        if (!started) muxer.start()
        copyVideo(vEx, muxer, vTrack)
    }

    private fun copyVideo(vEx: MediaExtractor, muxer: MediaMuxer, vTrack: Int) {
        val buf = ByteBuffer.allocate(4 shl 20)
        val info = MediaCodec.BufferInfo()
        while (true) {
            val size = vEx.readSampleData(buf, 0)
            if (size < 0) break
            info.set(0, size, vEx.sampleTime, if ((vEx.sampleFlags and MediaExtractor.SAMPLE_FLAG_SYNC) != 0) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0)
            muxer.writeSampleData(vTrack, buf, info)
            vEx.advance()
        }
    }
}
