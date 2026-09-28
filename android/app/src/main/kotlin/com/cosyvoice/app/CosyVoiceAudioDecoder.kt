package com.cosyvoice.app

import android.content.Context
import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.net.Uri
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.ceil
import kotlin.math.roundToInt

data class CosyVoiceDecodedSegment(
    val sampleRate: Int,
    val samples: Int,
    val sourceDurationSeconds: Double
) {
    val durationSeconds: Double
        get() = samples.toDouble() / sampleRate
}

internal object CosyVoiceAudioDecoder {
    private const val TIMEOUT_US = 10_000L

    fun decodeSegmentToWav(
        context: Context,
        uri: Uri,
        startSeconds: Double,
        endSeconds: Double,
        output: File
    ): CosyVoiceDecodedSegment {
        require(startSeconds >= 0.0 && endSeconds > startSeconds) { "音频截取时间不正确" }
        val extractor = MediaExtractor()
        var codec: MediaCodec? = null
        try {
            extractor.setDataSource(context, uri, null)
            val trackIndex = (0 until extractor.trackCount).firstOrNull { index ->
                extractor.getTrackFormat(index).getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true
            } ?: error("文件中没有可解码的音频轨道")
            val sourceFormat = extractor.getTrackFormat(trackIndex)
            val mime = sourceFormat.getString(MediaFormat.KEY_MIME) ?: error("音频格式缺少 MIME")
            val durationUs = sourceFormat.getLongOrDefault(MediaFormat.KEY_DURATION, 0L)
            if (durationUs > 0L) {
                require(startSeconds * 1_000_000.0 < durationUs) { "截取起点超过音频长度" }
            }
            val startUs = (startSeconds * 1_000_000.0).toLong()
            val requestedEndUs = (endSeconds * 1_000_000.0).toLong()
            val endUs = if (durationUs > 0L) minOf(requestedEndUs, durationUs) else requestedEndUs
            require(endUs - startUs in 3_000_000L..15_000_000L) { "请选择 3-15 秒参考人声" }

            extractor.selectTrack(trackIndex)
            extractor.seekTo(startUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
            val decoder = MediaCodec.createDecoderByType(mime).apply {
                configure(sourceFormat, null, null, 0)
                start()
            }
            codec = decoder

            var sampleRate = sourceFormat.getIntegerOrDefault(MediaFormat.KEY_SAMPLE_RATE, 0)
            var channels = sourceFormat.getIntegerOrDefault(MediaFormat.KEY_CHANNEL_COUNT, 1)
            var pcmEncoding = AudioFormat.ENCODING_PCM_16BIT
            val samples = FloatBufferBuilder(((endUs - startUs) * sampleRate / 1_000_000L).toInt())
            val info = MediaCodec.BufferInfo()
            var inputEnded = false
            var outputEnded = false
            var idleCount = 0
            while (!outputEnded) {
                var progressed = false
                if (!inputEnded) {
                    val inputIndex = decoder.dequeueInputBuffer(TIMEOUT_US)
                    if (inputIndex >= 0) {
                        val inputBuffer = decoder.getInputBuffer(inputIndex) ?: error("音频解码输入缓冲区不可用")
                        val sampleTime = extractor.sampleTime
                        if (sampleTime < 0L || sampleTime > endUs) {
                            decoder.queueInputBuffer(inputIndex, 0, 0, maxOf(sampleTime, 0L), MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputEnded = true
                        } else {
                            val size = extractor.readSampleData(inputBuffer, 0)
                            if (size < 0) {
                                decoder.queueInputBuffer(inputIndex, 0, 0, 0L, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                                inputEnded = true
                            } else {
                                decoder.queueInputBuffer(inputIndex, 0, size, sampleTime, extractor.sampleFlags)
                                extractor.advance()
                            }
                        }
                        progressed = true
                    }
                }

                when (val outputIndex = decoder.dequeueOutputBuffer(info, TIMEOUT_US)) {
                    MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        val format = decoder.outputFormat
                        sampleRate = format.getIntegerOrDefault(MediaFormat.KEY_SAMPLE_RATE, sampleRate)
                        channels = format.getIntegerOrDefault(MediaFormat.KEY_CHANNEL_COUNT, channels)
                        pcmEncoding = format.getIntegerOrDefault(MediaFormat.KEY_PCM_ENCODING, AudioFormat.ENCODING_PCM_16BIT)
                        progressed = true
                    }
                    MediaCodec.INFO_TRY_AGAIN_LATER -> Unit
                    else -> if (outputIndex >= 0) {
                        val buffer = decoder.getOutputBuffer(outputIndex)
                        if (buffer != null && info.size > 0) {
                            appendPcmRange(
                                buffer, info, sampleRate, channels, pcmEncoding,
                                startUs, endUs, samples
                            )
                        }
                        outputEnded = info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                        decoder.releaseOutputBuffer(outputIndex, false)
                        progressed = true
                    }
                }
                idleCount = if (progressed) 0 else idleCount + 1
                check(idleCount < 500) { "音频解码长时间无响应" }
            }
            val pcm = samples.toArray()
            require(sampleRate >= 16_000 && pcm.size >= sampleRate * 3) { "有效人声不足 3 秒" }
            writePcm16Wav(output, pcm, sampleRate)
            return CosyVoiceDecodedSegment(sampleRate, pcm.size, durationUs.coerceAtLeast(0L) / 1_000_000.0)
        } finally {
            runCatching { codec?.stop() }
            runCatching { codec?.release() }
            extractor.release()
        }
    }

    private fun appendPcmRange(
        buffer: ByteBuffer, info: MediaCodec.BufferInfo,
        sampleRate: Int, channels: Int, pcmEncoding: Int,
        startUs: Long, endUs: Long, output: FloatBufferBuilder
    ) {
        require(sampleRate > 0 && channels > 0) { "解码器返回了无效音频格式" }
        val bytesPerSample = when (pcmEncoding) {
            AudioFormat.ENCODING_PCM_FLOAT -> 4
            AudioFormat.ENCODING_PCM_16BIT -> 2
            else -> error("不支持的 PCM 编码：$pcmEncoding")
        }
        val frameBytes = bytesPerSample * channels
        val frameCount = info.size / frameBytes
        if (frameCount <= 0) return
        val firstFrame = ceil((startUs - info.presentationTimeUs) * sampleRate / 1_000_000.0)
            .toInt().coerceIn(0, frameCount)
        val lastFrame = ceil((endUs - info.presentationTimeUs) * sampleRate / 1_000_000.0)
            .toInt().coerceIn(0, frameCount)
        if (lastFrame <= firstFrame) return
        val pcm = buffer.duplicate().order(ByteOrder.LITTLE_ENDIAN)
        pcm.position(info.offset + firstFrame * frameBytes)
        pcm.limit(info.offset + lastFrame * frameBytes)
        repeat(lastFrame - firstFrame) {
            var mono = 0f
            repeat(channels) {
                mono += when (pcmEncoding) {
                    AudioFormat.ENCODING_PCM_FLOAT -> pcm.float
                    else -> pcm.short / 32768f
                }
            }
            output.add((mono / channels).coerceIn(-1f, 1f))
        }
    }

    private fun writePcm16Wav(file: File, samples: FloatArray, sampleRate: Int) {
        file.parentFile?.mkdirs()
        val dataBytes = samples.size * 2
        FileOutputStream(file).buffered().use { output ->
            output.write("RIFF".toByteArray(Charsets.US_ASCII))
            output.writeLittleEndianInt(36 + dataBytes)
            output.write("WAVEfmt ".toByteArray(Charsets.US_ASCII))
            output.writeLittleEndianInt(16)
            output.writeLittleEndianShort(1)
            output.writeLittleEndianShort(1)
            output.writeLittleEndianInt(sampleRate)
            output.writeLittleEndianInt(sampleRate * 2)
            output.writeLittleEndianShort(2)
            output.writeLittleEndianShort(16)
            output.write("data".toByteArray(Charsets.US_ASCII))
            output.writeLittleEndianInt(dataBytes)
            samples.forEach { sample ->
                output.writeLittleEndianShort((sample.coerceIn(-1f, 1f) * 32767f).roundToInt())
            }
        }
    }

    private fun java.io.OutputStream.writeLittleEndianInt(value: Int) {
        write(value and 0xFF)
        write(value ushr 8 and 0xFF)
        write(value ushr 16 and 0xFF)
        write(value ushr 24 and 0xFF)
    }

    private fun java.io.OutputStream.writeLittleEndianShort(value: Int) {
        write(value and 0xFF)
        write(value ushr 8 and 0xFF)
    }

    private fun MediaFormat.getIntegerOrDefault(key: String, default: Int): Int =
        if (containsKey(key)) getInteger(key) else default

    private fun MediaFormat.getLongOrDefault(key: String, default: Long): Long =
        if (containsKey(key)) getLong(key) else default

    private class FloatBufferBuilder(initialCapacity: Int) {
        private var values = FloatArray(initialCapacity.coerceAtLeast(1024))
        private var size = 0

        fun add(value: Float) {
            if (size == values.size) values = values.copyOf(values.size * 2)
            values[size++] = value
        }

        fun toArray(): FloatArray = values.copyOf(size)
    }
}
