package com.cosyvoice.app

/*
 * 注意：真正的 external 声明在 io.legado.app.cosy.CosyVoiceJniBridge.kt ——
 * 因为预编译的 .so 导出的是 Java_io_legado_app_cosy_* 符号（见 bridge 文件里的说明）。
 * 本对象只做转发，保持 app 内既有调用点不变。
 */
internal object CosyVoiceEnrollmentNative {
    fun enroll(
        tokenizerModelPath: String,
        campPlusModelPath: String,
        affineWeightPath: String,
        affineBiasPath: String,
        sourceWavPath: String,
        outputDirectory: String,
        threads: Int
    ): Int = io.legado.app.cosy.CosyVoiceEnrollmentNative.enroll(
        tokenizerModelPath, campPlusModelPath, affineWeightPath, affineBiasPath,
        sourceWavPath, outputDirectory, threads)

    fun errorMessage(code: Int): String = when (code) {
        0 -> "成功"
        10 -> "参考 WAV 无法读取"
        11 -> "参考人声长度不在 3-15 秒"
        12 -> "参考音频特征提取失败"
        20 -> "语音 Tokenizer 模型无法打开"
        21 -> "语音 Tokenizer Session 创建失败"
        22 -> "语音 Tokenizer 输入节点不匹配"
        24 -> "语音 Tokenizer 输入尺寸不匹配"
        25 -> "语音 Tokenizer 推理失败"
        26 -> "语音 Tokenizer 输出节点不匹配"
        27 -> "语音 Tokenizer 没有生成 Token"
        28 -> "语音 Tokenizer 输出无效，请重新导入新版音色创建扩展"
        30 -> "说话人模型无法打开"
        31 -> "说话人模型 Session 创建失败"
        32 -> "说话人模型输入节点不匹配"
        34 -> "说话人模型输入尺寸不匹配"
        35 -> "说话人特征推理失败"
        36 -> "说话人模型输出节点不匹配"
        37 -> "说话人特征无效"
        40 -> "参考音频生成的 Token 数量超出限制"
        41 -> "说话人特征投影失败"
        42 -> "音色档案文件写入失败"
        else -> "未知原生错误"
    }
}
