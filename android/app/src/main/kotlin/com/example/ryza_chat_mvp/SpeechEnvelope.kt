package com.example.ryza_chat_mvp

import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.os.SystemClock
import java.nio.ByteOrder
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import kotlin.math.sqrt

/** Decode off the main thread. Return RMS windows or write standard PCM16 WAV. */
object SpeechEnvelope {
    fun decode(path: String, pcmPath: String? = null): List<Double> {
        val extractor = MediaExtractor()
        var codec: MediaCodec? = null
        var pcm: RandomAccessFile? = null
        var pcmSize = 0
        try {
            pcm = pcmPath?.let { RandomAccessFile(it, "rw").apply { setLength(0); seek(44) } }
            extractor.setDataSource(path)
            val track = (0 until extractor.trackCount).firstOrNull {
                extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true
            } ?: error("No audio track")
            extractor.selectTrack(track)
            val format = extractor.getTrackFormat(track)
            val decoder = MediaCodec.createDecoderByType(format.getString(MediaFormat.KEY_MIME)!!)
            codec = decoder
            decoder.configure(format, null, null, 0)
            decoder.start()
            var rate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            var channels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
            var encoding = AudioFormat.ENCODING_PCM_16BIT
            var inputDone = false
            var outputDone = false
            val info = MediaCodec.BufferInfo()
            val sums = ArrayList<Double>()
            val counts = ArrayList<Int>()
            val deadline = SystemClock.elapsedRealtime() + 20000
            while (!outputDone) {
                check(SystemClock.elapsedRealtime() < deadline) { "Audio decode timed out" }
                if (!inputDone) {
                    val index = decoder.dequeueInputBuffer(1000)
                    if (index >= 0) {
                        val buffer = decoder.getInputBuffer(index)!!
                        val size = extractor.readSampleData(buffer, 0)
                        if (size < 0) {
                            decoder.queueInputBuffer(index, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputDone = true
                        } else {
                            decoder.queueInputBuffer(index, 0, size, extractor.sampleTime, 0)
                            extractor.advance()
                        }
                    }
                }
                val index = decoder.dequeueOutputBuffer(info, 1000)
                if (index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    val output = decoder.outputFormat
                    rate = output.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                    channels = output.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                    encoding = if (output.containsKey(MediaFormat.KEY_PCM_ENCODING)) output.getInteger(MediaFormat.KEY_PCM_ENCODING) else AudioFormat.ENCODING_PCM_16BIT
                } else if (index >= 0) {
                    try {
                        check(rate > 0 && channels > 0)
                        check(encoding == AudioFormat.ENCODING_PCM_16BIT || encoding == AudioFormat.ENCODING_PCM_FLOAT) { "Unsupported decoded PCM" }
                        val buffer = decoder.getOutputBuffer(index)!!.order(ByteOrder.LITTLE_ENDIAN)
                        buffer.position(info.offset)
                        buffer.limit(info.offset + info.size)
                        val bytes = if (encoding == AudioFormat.ENCODING_PCM_FLOAT) 4 else 2
                        val converted = if (pcm != null) ByteBuffer.allocate(info.size / bytes * 2).order(ByteOrder.LITTLE_ENDIAN) else null
                        var frame = 0L
                        while (buffer.remaining() >= bytes * channels) {
                            val micros = info.presentationTimeUs + frame * 1000000L / rate
                            check(micros < 600000000L) { "Audio exceeds ten minutes" }
                            val window = (micros.coerceAtLeast(0) / 20000).toInt()
                            while (sums.size <= window) { sums.add(0.0); counts.add(0) }
                            repeat(channels) {
                                val sample = if (bytes == 4) buffer.float.toDouble() else buffer.short / 32768.0
                                converted?.putShort((if (sample.isFinite()) (sample * 32768).toInt().coerceIn(-32768, 32767) else 0).toShort())
                                if (sample.isFinite()) { sums[window] = sums[window] + sample * sample; counts[window] = counts[window] + 1 }
                            }
                            frame++
                        }
                        if (converted != null) {
                            pcmSize += converted.position()
                            check(pcmSize <= 64 * 1024 * 1024) { "Decoded audio too large" }
                            pcm?.write(converted.array(), 0, converted.position())
                        }
                    } finally { decoder.releaseOutputBuffer(index, false) }
                    outputDone = info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                }
            }
            if (pcm != null) {
                check(pcmSize > 0) { "Empty decoded audio" }
                val header = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN)
                header.put("RIFF".toByteArray()).putInt(36 + pcmSize).put("WAVEfmt ".toByteArray())
                header.putInt(16).putShort(1.toShort()).putShort(channels.toShort()).putInt(rate)
                header.putInt(rate * channels * 2).putShort((channels * 2).toShort()).putShort(16.toShort())
                header.put("data".toByteArray()).putInt(pcmSize)
                pcm.seek(0)
                pcm.write(header.array())
            }
            return sums.indices.map { if (counts[it] == 0) 0.0 else sqrt(sums[it] / counts[it]) }
        } finally {
            pcm?.close()
            try { codec?.stop() } catch (_: Exception) { }
            codec?.release()
            extractor.release()
        }
    }
}
