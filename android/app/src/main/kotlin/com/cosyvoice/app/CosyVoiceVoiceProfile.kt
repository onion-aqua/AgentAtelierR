package com.cosyvoice.app

import org.json.JSONObject
import java.io.File

data class CosyVoiceVoiceProfile(
    val schemaVersion: Int,
    val id: String,
    val displayName: String,
    val modelId: String,
    val promptPrefix: String,
    val promptTokenCount: Int,
    val promptFrameCount: Int,
    val profileHash: String,
    val builtIn: Boolean,
    val createdAt: Long,
    val directory: File
) {
    val promptSpeechTokensFile: File
        get() = File(directory, PROMPT_SPEECH_TOKENS_FILE)

    val promptConditionFile: File
        get() = File(directory, PROMPT_CONDITION_FILE)

    val flowSpeakerFile: File
        get() = File(directory, FLOW_SPEAKER_FILE)

    val sharedNoiseFile: File
        get() = File(directory, SHARED_NOISE_FILE)

    fun toJson(): JSONObject = JSONObject()
        .put("schemaVersion", schemaVersion)
        .put("id", id)
        .put("displayName", displayName)
        .put("modelId", modelId)
        .put("promptPrefix", promptPrefix)
        .put("promptTokenCount", promptTokenCount)
        .put("promptFrameCount", promptFrameCount)
        .put("profileHash", profileHash)
        .put("builtIn", builtIn)
        .put("createdAt", createdAt)

    companion object {
        const val METADATA_FILE = "profile.json"
        const val PROMPT_SPEECH_TOKENS_FILE = "prompt-speech-tokens.csv"
        const val PROMPT_CONDITION_FILE = "prompt-cond.bin"
        const val FLOW_SPEAKER_FILE = "spks.bin"
        const val SHARED_NOISE_FILE = "rand-noise.bin"
        const val SOURCE_AUDIO_FILE = "source.wav"

        fun fromJson(json: JSONObject, directory: File): CosyVoiceVoiceProfile =
            CosyVoiceVoiceProfile(
                schemaVersion = json.getInt("schemaVersion"),
                id = json.getString("id"),
                displayName = json.getString("displayName"),
                modelId = json.getString("modelId"),
                promptPrefix = json.getString("promptPrefix"),
                promptTokenCount = json.getInt("promptTokenCount"),
                promptFrameCount = json.getInt("promptFrameCount"),
                profileHash = json.getString("profileHash"),
                builtIn = json.optBoolean("builtIn", false),
                createdAt = json.optLong("createdAt", 0L),
                directory = directory
            )
    }
}
