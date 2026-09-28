package com.cosyvoice.app

enum class CosyVoiceInferenceMode {
    ZERO_SHOT,
    INSTRUCT2
}

data class CosyVoiceInstructionPreset(
    val label: String,
    val instruction: String
)

object CosyVoiceInstruction {
    const val DEFAULT_INSTRUCTION = "请用四川话表达。"

    val presets = listOf(
        CosyVoiceInstructionPreset("四川话", "请用四川话表达。"),
        CosyVoiceInstructionPreset("广东话", "请用广东话表达。"),
        CosyVoiceInstructionPreset("东北话", "请用东北话表达。"),
        CosyVoiceInstructionPreset("开心", "请非常开心地说一句话。"),
        CosyVoiceInstructionPreset("伤心", "请非常伤心地说一句话。"),
        CosyVoiceInstructionPreset("生气", "请非常生气地说一句话。"),
        CosyVoiceInstructionPreset("快速", "请用尽可能快地语速说一句话。"),
        CosyVoiceInstructionPreset("慢速", "请用尽可能慢地语速说一句话。"),
        CosyVoiceInstructionPreset("响亮", "Please say a sentence as loudly as possible."),
        CosyVoiceInstructionPreset("轻声", "Please say a sentence in a very soft voice."),
        CosyVoiceInstructionPreset("机器人", "你可以尝试用机器人的方式解答吗？")
    )

    fun promptPrefix(instruction: String): String {
        val clean = instruction
            .replace("<|endofprompt|>", "")
            .replace(Regex("[\\r\\n]+"), " ")
            .trim()
        require(clean.isNotEmpty()) { "指令内容不能为空" }
        return "You are a helpful assistant. $clean<|endofprompt|>"
    }
}
