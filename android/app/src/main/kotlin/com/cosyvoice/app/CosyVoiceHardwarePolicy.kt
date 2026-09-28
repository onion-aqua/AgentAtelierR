package com.cosyvoice.app

import android.os.Build

internal data class CosyVoiceDeviceCapabilities(
    val manufacturer: String,
    val socManufacturer: String,
    val socModel: String,
    val hardware: String,
    val model: String,
    val cpuCores: Int,
    val openClAvailable: Boolean,
    val hexagonAvailable: Boolean
)

data class CosyVoiceHardwarePlan(
    val flowBackend: String,
    val flowGpuMode: Int,
    val llmBackend: String,
    val hiftCoreBackend: String,
    val hiftGpuMode: Int,
    val cpuThreads: Int,
    val decision: String,
    val npuStatus: String
) {
    fun summary(): String {
        val llm = if (llmBackend == "hexagon") {
            "LLM NPU q_proj + CPU 解码"
        } else {
            "LLM CPU"
        }
        val flow = if (flowBackend == "opencl") "Flow GPU/OpenCL" else "Flow CPU"
        return "$llm · $flow · HiFT CPU/$cpuThreads 线程 · $decision"
    }

    fun cpuFallback(reason: String): CosyVoiceHardwarePlan = copy(
        llmBackend = "cpu",
        decision = reason,
        npuStatus = reason
    )
}

internal object CosyVoiceHardwarePolicy {

    private val verifiedHexagonSocModels = setOf("SM8850")

    fun current(
        openClAvailable: Boolean,
        hexagonAvailable: Boolean
    ): CosyVoiceDeviceCapabilities {
        val socManufacturer = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            Build.SOC_MANUFACTURER.orEmpty()
        } else {
            ""
        }
        val socModel = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            Build.SOC_MODEL.orEmpty()
        } else {
            ""
        }
        return CosyVoiceDeviceCapabilities(
            manufacturer = Build.MANUFACTURER.orEmpty(),
            socManufacturer = socManufacturer,
            socModel = socModel,
            hardware = Build.HARDWARE.orEmpty(),
            model = Build.MODEL.orEmpty(),
            cpuCores = Runtime.getRuntime().availableProcessors().coerceAtLeast(1),
            openClAvailable = openClAvailable,
            hexagonAvailable = hexagonAvailable
        )
    }

    fun recommend(capabilities: CosyVoiceDeviceCapabilities): CosyVoiceHardwarePlan {
        val identity = listOf(
            capabilities.manufacturer,
            capabilities.socManufacturer,
            capabilities.socModel,
            capabilities.hardware,
            capabilities.model
        ).joinToString(" ").lowercase()
        val isQualcomm = listOf("qualcomm", "qcom", "snapdragon").any(identity::contains) ||
            Regex("\\bsm\\d{4}\\b", RegexOption.IGNORE_CASE).containsMatchIn(identity)
        val cpuThreads = when {
            capabilities.cpuCores >= 8 -> 6
            capabilities.cpuCores >= 6 -> 4
            capabilities.cpuCores >= 4 -> 3
            else -> 2
        }
        val verifiedSoc = capabilities.socModel.uppercase() in verifiedHexagonSocModels
        val llmBackend =
            if (verifiedSoc && capabilities.hexagonAvailable) "hexagon" else "cpu"
        val flowBackend = if (capabilities.openClAvailable) "opencl" else "cpu"
        val decision = when {
            llmBackend == "hexagon" -> "SM8850 已验证自动加速"
            verifiedSoc -> "SM8850 NPU 运行库不可用，自动回退"
            isQualcomm -> "高通兼容模式，NPU 尚未验证"
            capabilities.openClAvailable -> "跨厂商 GPU 兼容模式"
            else -> "CPU 兼容模式"
        }
        val npuStatus = when {
            llmBackend == "hexagon" ->
                "Hexagon 仅执行第 0 层 q_proj；其余 LLM 算子使用 CPU"
            capabilities.hexagonAvailable ->
                "Hexagon 运行库可用，但当前 SoC 未通过音频正确性验证"
            isQualcomm -> "Hexagon Stub/Skeleton 初始化失败"
            else -> "非高通设备不启用 Hexagon"
        }
        return CosyVoiceHardwarePlan(
            flowBackend = flowBackend,
            flowGpuMode = if (flowBackend == "opencl" && isQualcomm) 68 else 4,
            llmBackend = llmBackend,
            hiftCoreBackend = "cpu",
            hiftGpuMode = 4,
            cpuThreads = cpuThreads,
            decision = decision,
            npuStatus = npuStatus
        )
    }
}
