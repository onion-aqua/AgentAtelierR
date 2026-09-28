package com.cosyvoice.app

import android.content.Context
import android.util.Log
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.job
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.json.JSONObject
import java.io.File
import java.util.concurrent.atomic.AtomicReference

internal object CosyVoiceLlmOutputQuality {

    private const val SPEECH_EOS = 158486

    // 【2026-09-18 NPU-R9】判据重新标定。
    //
    // 旧判据是「longestRun >= 8 就拒」。它在**短输出**上和真实退化对齐（当时的样本都在 250 token
    // 上下），但在更长的输出上误杀。同句 63 字（音色前缀 26 字 + 文本 37 字）的 7 次实测：
    //   • 正常终止（有 EOS）：370 / 387 / 357 / 369 token，longestRun = 10 / 20 / 8 / 9
    //   • 真正跑飞（无 EOS、撞满 maxTokens=500）：500 / 500 / 500 token，longestRun = 105 / 107 / 117
    // 「有 EOS、但内部夹着 8~20 的重复段」被旧判据全部拒掉 —— 7 次尝试无一通过，整条链直接报错。
    //
    // 新判据只保留**能证明退化**的三条：
    //   1. 没有 EOS。生成只可能在 EOS 或 maxTokens 处停下，没出 EOS 就是撞满上限（本次 3/7）；
    //   2. 整段几乎只有一个 token（unique <= 4 且长度 >= 20）；
    //   3. 单段连续重复 >= 64（约 2.5 秒全是同一个 token）。本次样本里"正常"最大 20、
    //      "跑飞"最小 105，64 落在两者之间。
    // `longestRun` 与各重复段位置继续写进拒因/尝试日志，作为诊断信息保留。
    const val SINGLE_RUN_LIMIT = 64

    fun collapseReason(rawTokens: List<Int>): String? {
        if (rawTokens.size < 2) return "原始 Token 为空"
        val hasEos = rawTokens.any { it == SPEECH_EOS }
        val speechTokens = rawTokens.dropLastWhile { it == SPEECH_EOS }
        val uniqueTokens = speechTokens.toSet().size
        var longestRun = 0
        var currentRun = 0
        var previousToken: Int? = null
        speechTokens.forEach { token ->
            currentRun = if (token == previousToken) currentRun + 1 else 1
            longestRun = maxOf(longestRun, currentRun)
            previousToken = token
        }
        // 【2026-09-18 NPU-R1b 观测】
        //
        // 原来只报 longestRun 的长度，不报它【出现在序列的什么位置】。而"坍缩集中在某处"与
        // "散布全程"对应完全不同的修法：前者可能支持「前段 NPU / 后段 CPU」或「CPU prefill +
        // NPU decode」，后者说明采样本身在长序列上不可靠。
        // 因此这里额外统计所有长度 >= 8 的连续段，给出 [起-止] 下标与"止位置占全程百分比"。
        fun longRunsOf(tokens: List<Int>): List<IntArray> {
            val runs = mutableListOf<IntArray>()
            var i = 0
            while (i < tokens.size) {
                var j = i
                while (j + 1 < tokens.size && tokens[j + 1] == tokens[i]) j++
                val len = j - i + 1
                if (len >= 8) runs.add(intArrayOf(i, j, len))
                i = j + 1
            }
            return runs
        }
        val total = speechTokens.size.coerceAtLeast(1)
        val runs = longRunsOf(speechTokens)
        val runDesc = runs.take(6).joinToString(", ") { r ->
            "len${r[2]}@[${r[0]}-${r[1]}]止于${r[1] * 100 / total}%"
        } + if (runs.size > 6) " …共${runs.size}段" else ""
        if (speechTokens.size >= 20 && uniqueTokens <= 4) {
            return "Token 坍缩：count=${speechTokens.size}, unique=$uniqueTokens, 重复段[$runDesc]"
        }
        if (!hasEos) {
            return "未生成 EOS：全程${speechTokens.size} token、" +
                "unique=$uniqueTokens、longestRun=$longestRun，重复段[$runDesc]"
        }
        if (longestRun >= SINGLE_RUN_LIMIT) {
            return "单段连续重复 ${longestRun} >= $SINGLE_RUN_LIMIT：全程${speechTokens.size}, " +
                "unique=$uniqueTokens, 重复段[$runDesc]"
        }
        return null
    }
}


// 【2026-09-18 NPU-R11】尾部空转修复。
//
// 现象（真机实测，均为同一形态）：模型其实已经说完，但 EOS 在 `cosyvoice_ras` 的候选集里要跟
// 6561 个语音 token 一起过 top-k(25) / top-p(0.8)，被滤掉之后就再也选不出来 —— 于是它把最后一个
// token 一路重复到 `maxTokens` 上限，报告里表现为「填满 500、没有 EOS、尾部一整段相同 token」。
//
// 实测样本（都是尾部重复一直顶到 499）：
//   CPU   500 token, len266@[234-499]
//   OpenCL 500 token, len105@[395-499] / len107@[393-499] / len117@[383-499]
//   hexagon 500 token, len130@[370-499] / len178@[322-499] / len140@[360-499]
//
// 这类输出**不需要重抽** —— 重复段之前的那一截就是模型真正想说的内容。把它切掉即可，
// 切点就是模型「已经说完」的位置。修复结果会写进 run dir 的 `llm-tail-repair.txt`，
// 并进入 `llm-attempts.txt`，不做静默处理。
//
// 触发条件刻意收紧：必须没有 EOS、重复段一直延伸到序列末尾、重复段 >= 32（约 1.3 秒）、
// 保留段 >= 32。任何一条不满足就返回 null，仍旧按原样拒绝。
internal object CosyVoiceLlmTailRepair {

    private const val SPEECH_EOS = 158486
    private const val SPEECH_OFFSET = 151924
    private const val SPEECH_TOKEN_MAX = SPEECH_OFFSET + 6560

    const val MIN_RUN = 32
    const val MIN_KEEP = 32

    data class Repair(val tokens: List<Int>, val trimmedRun: Int)

    fun repair(rawTokens: List<Int>): Repair? {
        if (rawTokens.any { it == SPEECH_EOS }) return null
        if (rawTokens.size < MIN_KEEP + MIN_RUN) return null
        val last = rawTokens.last()
        var start = rawTokens.size - 1
        while (start > 0 && rawTokens[start - 1] == last) start--
        val run = rawTokens.size - start
        if (run < MIN_RUN) return null
        if (start < MIN_KEEP) return null
        return Repair(rawTokens.subList(0, start), run)
    }

    /** 按 Native 的 `speech-tokens-N.csv` 约定重写（token - SPEECH_OFFSET，逗号分隔）。 */
    fun speechTokenLine(tokens: List<Int>): String =
        tokens.filter { it in SPEECH_OFFSET..SPEECH_TOKEN_MAX }
            .joinToString(",") { (it - SPEECH_OFFSET).toString() } + "\n"
}

// 【2026-09-18 NPU-R7】LLM 尝试计划（纯函数，便于单测）。
//
// 路由后端本身是 cpu 时没有更快的替代品，只再掷一次骰子（每次约 70 s）；
// 其余后端先把自己的骰子掷完（每次 2~20 s），最后才落到 CPU 兜底。
internal object CosyVoiceLlmAttemptPlan {

    const val ROUTED_ATTEMPTS = 5
    const val CPU_RESORT_ATTEMPTS = 2
    const val CPU_ROUTED_ATTEMPTS = 2

    fun backends(routedBackend: String): List<String> = buildList {
        if (routedBackend == "cpu") {
            repeat(CPU_ROUTED_ATTEMPTS) { add("cpu") }
        } else {
            repeat(ROUTED_ATTEMPTS) { add(routedBackend) }
            repeat(CPU_RESORT_ATTEMPTS) { add("cpu") }
        }
    }
}

data class CosyVoiceSynthesisOptions(
    val hardwarePlan: CosyVoiceHardwarePlan = CosyVoiceRuntime.recommendedHardwarePlan(),
    val flowBackend: String = hardwarePlan.flowBackend,
    val flowGpuMode: Int = hardwarePlan.flowGpuMode,
    val hiftCoreBackend: String = hardwarePlan.hiftCoreBackend,
    val hiftGpuMode: Int = hardwarePlan.hiftGpuMode,
    val voiceProfileId: String = CosyVoiceStore.DEFAULT_VOICE_PROFILE_ID,
    /**
     * Optional normalized reference text for zero-shot synthesis.
     *
     * The speech prompt tensors belong to the selected voice profile, while
     * the text prompt can be normalized by the Japanese frontend immediately
     * before synthesis. This lets legacy profiles use corrected katakana
     * without re-enrolling their audio features.
     */
    val voicePromptText: String? = null,
    val inferenceMode: CosyVoiceInferenceMode = CosyVoiceInferenceMode.ZERO_SHOT,
    val instruction: String = ""
) {
    val flowPrecision: String get() = if (flowBackend == "cpu") "normal" else "high"
    val flowThreads: Int get() = if (flowBackend == "cpu") hardwarePlan.cpuThreads else flowGpuMode

    init {
        require(flowBackend in setOf("cpu", "opencl"))
        require(flowGpuMode in setOf(4, 68, 132))
        require(hiftCoreBackend in setOf("cpu", "opencl"))
        require(hiftGpuMode in setOf(4, 68, 132))
        if (inferenceMode == CosyVoiceInferenceMode.INSTRUCT2) {
            require(instruction.isNotBlank())
        }
    }
}

data class CosyVoiceSynthesisReport(
    val output: File,
    val totalMs: Long,
    val llmMs: Long,
    val conditionerMs: Long,
    val flowResizeMs: Double,
    val flowInferenceMs: Double,
    val hiftMs: Double,
    val audioSeconds: Double,
    val targetTokens: Int,
    val flowBucket: Int,
    val pcmPeak: Double,
    val pcmRms: Double,
    val voiceProfile: CosyVoiceVoiceProfile,
    val options: CosyVoiceSynthesisOptions
) {
    val rtf: Double
        get() = totalMs / 1000.0 / audioSeconds.coerceAtLeast(0.001)

    fun displayText(): String = buildString {
        append("合成完成 · %.2f 秒音频 · 总耗时 %.2f 秒 · RTF %.2f".format(audioSeconds, totalMs / 1000.0, rtf))
        append("\nLLM %.2f 秒 · Flow %.2f 秒（首次/形状 %.2f 秒）· HiFT %.2f 秒".format(
            llmMs / 1000.0, flowInferenceMs / 1000.0, flowResizeMs / 1000.0, hiftMs / 1000.0
        ))
        append("\n音色 ${voiceProfile.displayName} · ${options.inferenceMode.displayName()} · ${options.hardwarePlan.summary()} · peak %.3f · rms %.3f".format(pcmPeak, pcmRms))
    }
}

internal object CosyVoiceRuntime {
    private const val TAG = "CosyVoiceRuntime"
    private const val HIFT_CPU_THREADS = 6
    private const val FLOW_CPU_THREADS = 6
    private val mutex = Mutex()
    private val activeProcess = AtomicReference<Process?>(null)
    @Volatile
    private var appContext: Context? = null

    private val openClAvailable: Boolean by lazy {
        try {
            System.loadLibrary("OpenCL")
            true
        } catch (_: Throwable) {
            false
        }
    }

    fun initialize(context: Context) {
        appContext = context.applicationContext
        recommendedHardwarePlan()
    }

    /**
     * 幂等懒初始化。
     *
     * 背景：「文字设计音色」路径为了省约 1.45 GB 常驻内存，会在 onCreate 里跳过 initialize()。
     * 但合成（preview / createRealtimeVoiceProfile 等）需要 runtime 已初始化，
     * 所以那些入口在真正干活前调用本函数补上，而不是依赖 onCreate。
     */
    fun ensureInitialized(context: Context) {
        if (appContext == null) initialize(context)
    }

    fun detectBestFlowBackend(): String = recommendedHardwarePlan().flowBackend

    fun recommendedHardwarePlan(): CosyVoiceHardwarePlan {
        // 未 initialize 时返回安全的 CPU 计划，而不是抛异常。
        // 背景：「文字设计音色」路径为了省 ~1.45 GB 内存会跳过 initialize()，
        // 但界面仍会读这个值用于展示；原来直接 checkNotNull 会导致主线程崩溃
        // （实测 FATAL EXCEPTION: main / IllegalStateException）。
        val context = appContext ?: return CosyVoiceHardwarePolicy.recommend(
            CosyVoiceHardwarePolicy.current(openClAvailable = false, hexagonAvailable = false)
        )
        val hexagonStatus = CosyVoiceHexagonBootstrap.initialize(context)
        return CosyVoiceHardwarePolicy.recommend(
            CosyVoiceHardwarePolicy.current(
                openClAvailable = openClAvailable,
                hexagonAvailable = hexagonStatus.available
            )
        )
    }

    suspend fun synthesize(
        store: CosyVoiceStore,
        text: String,
        output: File,
        options: CosyVoiceSynthesisOptions,
        onStage: suspend (String) -> Unit = {}
    ): CosyVoiceSynthesisReport = mutex.withLock {
        check(store.modelStatus().ready) { "MNN 模型不完整" }
        val cleanText = text.replace(Regex("[\\r\\n]+"), " ").trim()
        require(cleanText.isNotEmpty()) { "试听文字不能为空" }
        val voiceProfile = store.voiceProfile(options.voiceProfileId)
        check(voiceProfile.promptTokenCount <= CosyVoiceStore.MAX_REALTIME_PROMPT_TOKENS) {
            "音色提示过长（${voiceProfile.promptTokenCount} Token），请先点\"实时版\"生成朗读音色"
        }

        val startedAt = System.nanoTime()
        store.workDir.listFiles()
            .orEmpty()
            .filter { it.isDirectory && it.name.startsWith("run-") }
            .sortedByDescending(File::lastModified)
            .drop(2)
            .forEach(File::deleteRecursively)
        val runDir = File(store.workDir, "run-${System.currentTimeMillis()}").apply {
            deleteRecursively()
            mkdirs()
        }
        val llmOutput = File(runDir, "llm-output").apply { mkdirs() }
        val flowInput = File(runDir, "flow-input").apply { mkdirs() }
        val flowOutput = File(runDir, "flow-output").apply { mkdirs() }
        val hiftInput = File(runDir, "hift-input").apply { mkdirs() }
        val hiftOutput = File(runDir, "hift-output").apply { mkdirs() }
        val model = store.modelDir
        var effectiveOptions = options
        // 【2026-09-18 NPU-R4】受控对照开关：强制 LLM 以 CPU 计划起步。
        //
        // 目的：分离「长文本在 CPU 上本来就慢」与「fallback 这条路径本身低效」。
        // 正常 fallback 的顺序是：先跑一次 hexagon（含 NPU prefill）→ 质量门拒绝 →
        // reset() + 删目录 + 改用 cpu 配置重跑。本开关跳过那次失败尝试，直接以 cpu 起步，
        // 因此两者若速度不同，差异就出在 fallback 的重建流程上，而不是 CPU 执行本身。
        //
        // 用 <模型目录>/force_cpu_llm.txt 触发（沿用 vd_prec.txt 的模式），便于随时 A/B。
        // 【2026-09-18 NPU-R6】后端受控对照开关（推广 R4）。
        // <模型目录>/force_llm_backend.txt 内容为 cpu | opencl | hexagon 三者之一；
        // 旧的 force_cpu_llm.txt 仍然兼容（等价于内容 cpu）。
        //
        // 为什么需要 opencl：长句 CPU 只有 4~7 tok/s，而历史「OpenCL 不如 CPU」的结论
        // （68.38 vs 84.99）是在**短句**上得出的。若 CPU 在长序列上退化而 GPU 不受同样影响，
        // 长句上 OpenCL 完全可能反超 —— 必须在同长度下实测，不能沿用短句结论。
        val forcedBackend = runCatching {
            File(model, "force_llm_backend.txt").takeIf(File::isFile)?.readText()?.trim()
        }.getOrNull().takeUnless { it.isNullOrEmpty() }
            ?: if (File(model, "force_cpu_llm.txt").isFile) "cpu" else null
        // 【2026-09-18 NPU-R10】取消「按明文长度分流」。
        //
        // 原来：明文 <= 24 字 → hexagon，> 24 字 → opencl。依据是 ADR-053 R5 的
        // 「NPU 在长序列上约 3/4 概率退化」。但 R8 已查明当时据以判定 NPU 行为的字段
        // （continuousHexagon / npuFirstTokenValid）只是配置回显，R9 又查明判据
        // 「longestRun >= 8 即拒」会误杀正常输出 —— 于是"长句不能用 NPU"这个结论的两条腿
        // 都不成立。
        //
        // 用同一句 63 字（inputTokens=196）、R9 的新判据、本机实测：
        //   hexagon  3/3 首次尝试即通过；prefill 0.62~0.73 s、decode 9.1~11.7 s、
        //            37.6~38.8 tok/s、wall 10.3~13.1 s；三次都正常出 EOS
        //            （longestRun 23 / 18 / 9 —— 旧判据会把它们全部拒掉）
        //   opencl   6 次里 3 次撞满 maxTokens 且无 EOS；prefill 10.8~12.2 s、wall 18.7~22.4 s
        // 长句不但能用 NPU，而且比 OpenCL 更快也更稳。分流取消，一律用硬件策略给出的后端
        // （SM8850 即 hexagon）；重试与质量门保留作安全网。
        // 唯一还会改写后端的来源就是受控开关（<模型目录>/force_llm_backend.txt）；
        // 没有它时一律采用硬件策略给出的后端。
        if (forcedBackend != null &&
            effectiveOptions.hardwarePlan.llmBackend != forcedBackend
        ) {
            Log.i(TAG, "llm backend: " + effectiveOptions.hardwarePlan.llmBackend +
                " -> " + forcedBackend + " (forced)")
            effectiveOptions = effectiveOptions.copy(
                hardwarePlan = effectiveOptions.hardwarePlan.copy(
                    llmBackend = forcedBackend,
                    decision = "受控对照：强制 " + forcedBackend,
                    npuStatus = "受控对照：强制 " + forcedBackend
                )
            )
        }
        if (effectiveOptions.hardwarePlan.llmBackend == "hexagon") {
            File(model, "hexagon-stage-layers.txt").writeText("0", Charsets.US_ASCII)
            File(model, "hexagon-stage-ops.txt").writeText("conv", Charsets.US_ASCII)
            File(model, "hexagon-stage-name.txt").writeText("q_proj", Charsets.US_ASCII)
        }

        val promptFile = File(runDir, "prompts.txt").apply {
            val prefix = if (options.inferenceMode == CosyVoiceInferenceMode.INSTRUCT2) {
                CosyVoiceInstruction.promptPrefix(options.instruction)
            } else if (!options.voicePromptText.isNullOrBlank()) {
                CosyVoiceStore.SYSTEM_PROMPT_PREFIX + options.voicePromptText.trim()
            } else {
                voiceProfile.promptPrefix
            }
            writeText(prefix + cleanText, Charsets.UTF_8)
        }

        // 【2026-09-18 NPU-R12】`maxTokens` 不再是常量 500。
        //
        // 500 个 speech token ≈ **20 秒**语音（25 Hz）。而这条链的 LM 生成的是
        // 「音色前缀文本 + 正文」整段 —— 前缀里那 26 个字的参考文本同样要占 token。
        // 于是只要「前缀 + 正文」超过约 20 秒的语速，**必然撞满上限、永远出不了 EOS**，
        // 表现为"最后一句没读完"或尾部空转。
        //
        // 实测标定（同一台设备）：39 字 → 184 token；63 字 → 353~443 token；92 字 → 撞满 500。
        // 即约 6 token/字。这里按 8 token/字 + 128 余量估，并钳在 [500, 1024]。
        val promptPrefixForLength = if (effectiveOptions.inferenceMode == CosyVoiceInferenceMode.INSTRUCT2) {
            CosyVoiceInstruction.promptPrefix(effectiveOptions.instruction)
        } else if (!effectiveOptions.voicePromptText.isNullOrBlank()) {
            CosyVoiceStore.SYSTEM_PROMPT_PREFIX + effectiveOptions.voicePromptText.trim()
        } else {
            voiceProfile.promptPrefix
        }
        val promptTextChars = promptPrefixForLength.substringAfter("<|endofprompt|>", "").length
        val llmMaxTokens = ((promptTextChars + cleanText.length) * 8 + 128).coerceIn(500, 1024)
        onStage("LLM 正在生成语音 Token")
        val llmStartedAt = System.nanoTime()
        fun runLlm(candidate: CosyVoiceSynthesisOptions): Int = CosyVoiceLlmNative.run(
            configPath = store.llmRuntimeConfig(candidate.hardwarePlan.llmBackend).absolutePath,
            promptsPath = promptFile.absolutePath,
            maxTokens = llmMaxTokens,
            promptSpeechTokensPath = voiceProfile.promptSpeechTokensFile.absolutePath,
            outputDirectory = llmOutput.absolutePath,
            appendPromptSpeechTokens = candidate.inferenceMode == CosyVoiceInferenceMode.ZERO_SHOT
        )
        // 【2026-09-18】质量检查改为**后端无关**。
        //
        // 原来这里只在 llmBackend == "hexagon" 时才调用，于是 CPU / OpenCL 的 repetition
        // collapse 从未被检测 —— 实测 CPU 长句出现**连续 266 个相同 token 且无 EOS**，
        // 却因为不走这个检查而被当成"干净的兜底"直接交付。
        //
        // requireHexagon=true 时额外检查"连续 Hexagon 解码是否真的启用"。
        fun llmOutputFailureReason(requireHexagon: Boolean): String? {
            val reportFile = File(llmOutput, "llm-persistent.jsonl")
            if (!reportFile.isFile) return "缺少 LLM 报告"
            val report = runCatching { reportFile.firstJson() }
                .getOrElse { return "LLM 报告无法解析" }
            // 【2026-09-18 NPU-R8 更正】这里查的是「连续 Hexagon 解码」这个**配置**是否启用，
            // 不是「NPU 实际算没算」—— Native 侧这两个字段都是从配置回显出来的：
            //   continuousHexagon = (configPath 含 "hexagon") && (!hexagon-stage-layers.txt 为空)
            //   npuFirstTokenValid = hybridNpuPrefill = (configPath 含 "hexagon") && (!continuousHexagon)
            // 依据：mnn-jni/CosyVoiceLlmPersistentBenchmark.cpp（465 行；2026-09-18 从构建机取回，
            // 此前仓库里的 327 行副本不含 hybrid 分支）。所以 npuFirstTokenValid=false 只说明
            // 「走的是 hybrid 那条分支」，不能读成「第一个解码 token 不是 NPU 产出」。
            //
            // 实测失败报告（npuPrefillMs=1078、cpuPrefillMs=0、continuousHexagon=false、
            // decodeMs=56493、tokensPerSecond=4.09）对应的正是 hybrid 分支：NPU 做 prefill + 1 个
            // token，随后**另起一个 CPU 配置的 LLM 实例**把整句重跑一遍，decode 于是落到 CPU 的
            // 4.09 tok/s，比直接回退 CPU 还慢（56.5 s vs 46.7 s）—— 这才是要拦住的失败模式。
            // App 对 hexagon 后端总会先写 hexagon-stage-*.txt，因此产品路径上不会走到 hybrid。
            Log.i(TAG, "Hexagon report: continuous=${report.optBoolean("continuousHexagon", false)}" +
                " npuFirstTokenValid=${report.optBoolean("npuFirstTokenValid", false)}" +
                " npuPrefillMs=${report.optDouble("npuPrefillMs", 0.0)}" +
                " cpuPrefillMs=${report.optDouble("cpuPrefillMs", 0.0)}" +
                " decodeMs=${report.optDouble("decodeMs", 0.0)}" +
                " tokensPerSecond=${report.optDouble("tokensPerSecond", 0.0)}" +
                " invalidOutputs=${report.optInt("invalidOutputs", -1)}" +
                " speechTokens=${report.optInt("speechTokens", -1)}" +
                " layers=${report.optString("stagedHexagonLayers")}")
            if (requireHexagon &&
                (!report.optBoolean("continuousHexagon", false) ||
                    report.optString("stagedHexagonLayers").isBlank())
            ) {
                return "Native 未进入受限 q_proj Hexagon（prefill=${report.optDouble("npuPrefillMs", 0.0)}ms, npuFirstTokenValid=${report.optBoolean("npuFirstTokenValid", false)}）"
            }
            if (report.optInt("invalidOutputs", -1) != 0) {
                return "LLM 存在非法输出"
            }
            val rawFile = File(llmOutput, "raw-output-ids-0.csv")
            if (!rawFile.isFile) return "缺少原始 Token 报告"
            return CosyVoiceLlmOutputQuality.collapseReason(
                rawFile.readText().split(',').mapNotNull { it.trim().toIntOrNull() }
            )
        }
        // 【2026-09-18 NPU-R7】把「重试 + 兜底」改成一张显式的尝试计划表，并让**每一次**尝试
        // —— 包括最后那次 CPU 兜底 —— 都过同一道质量门。
        //
        // 原实现有两个洞：
        //   1) CPU 兜底那一次跑完直接交付，从不过门。而实测 CPU 恰是长句上退化率最高的后端：
        //      同句 40 字，voice-ab/dev/cpu-tokens.csv 是 500 个 token、unique=158、**无 EOS**，
        //      唯一长度 >= 8 的连续段是 len266@[234-499]（234+266=500，正好撞满 maxTokens）。
        //      也就是说"兜底"这条路最容易把退化音频悄悄交付出去。
        //   2) 入口后端本来就是 cpu 时，兜底块会拿同一份 CPU 配置再跑一遍（约 70 秒），
        //      既没换后端也没提高质量。
        //
        // 尝试预算的依据：坍缩是每次采样独立的间歇事件（同句三次 token 轨迹各异），
        // 重试 = 重新抽样，成功概率按几何分布累积。退化率 OpenCL 约 1/3、NPU 约 3/4，
        // 5 次尝试把"全部失败"压到 0.33^5 ≈ 0.4%，而期望尝试次数只从 1.44 升到 1.49 ——
        // 平均墙钟几乎不变。CPU 每次约 70 秒，只在最末端留 2 次。
        val routedBackend = effectiveOptions.hardwarePlan.llmBackend
        val attemptBackends = CosyVoiceLlmAttemptPlan.backends(routedBackend)
        val attemptLog = StringBuilder()
        attemptLog.appendLine("maxTokens=" + llmMaxTokens + " promptTextChars=" + promptTextChars)
        var llmExitCode = -900
        var llmFailure: String? = null
        for ((index, backend) in attemptBackends.withIndex()) {
            if (index > 0) {
                CosyVoiceLlmNative.reset()
                llmOutput.deleteRecursively()
                llmOutput.mkdirs()
                if (backend != effectiveOptions.hardwarePlan.llmBackend) {
                    effectiveOptions = effectiveOptions.copy(
                        hardwarePlan = effectiveOptions.hardwarePlan.cpuFallback(
                            "LLM 输出被质量门拒绝，已回退 CPU"
                        )
                    )
                }
            }
            attemptLog.appendLine("attempt" + (index + 1) + ".backend=" + backend)
            llmExitCode = runCatching { runLlm(effectiveOptions) }.getOrDefault(-900)
            attemptLog.appendLine("attempt" + (index + 1) + ".llmExitCode=" + llmExitCode)
            // 无论退出码是否为 0 都要看报告：设备上的 .so 在「没能启用连续 Hexagon 解码」时
            // 会返回非 0，而那时仍需区分「真的坏了」与「只是没能启用连续解码」。
            llmFailure = llmOutputFailureReason(requireHexagon = backend == "hexagon")
            if (llmFailure == null) {
                attemptLog.appendLine("attempt" + (index + 1) + ".result=accepted")
                break
            }
            val reason = if (llmExitCode != 0) llmFailure + "（JNI 退出码 " + llmExitCode + "）" else llmFailure
            attemptLog.appendLine("attempt" + (index + 1) + ".rejectedReason=" + reason)
            // 【2026-09-18 NPU-R11】先试「尾部空转修复」，再考虑重抽。
            //
            // 尾部空转（模型已说完但 EOS 被 top-k/top-p 滤掉，于是把最后一个 token 重复到上限）
            // 不需要重新采样：重复段之前那一截就是模型想说的内容，切掉即可。这一步在重试之前做，
            // 因为它是确定性的 —— 同样的文本再抽一次往往还是同样的空转（实测同一句 3/3 次都是）。
            val repaired = runCatching {
                val raw = File(llmOutput, "raw-output-ids-0.csv")
                if (!raw.isFile) null else CosyVoiceLlmTailRepair.repair(
                    raw.readText().split(',').mapNotNull { it.trim().toIntOrNull() }
                )
            }.getOrNull()
            if (repaired != null) {
                val tokenFile = File(llmOutput, "speech-tokens-0.csv")
                if (tokenFile.isFile) {
                    tokenFile.writeText(
                        CosyVoiceLlmTailRepair.speechTokenLine(repaired.tokens), Charsets.US_ASCII
                    )
                    attemptLog.appendLine(
                        "attempt" + (index + 1) + ".tailRepair=kept " + repaired.tokens.size +
                            " tokens, trimmed trailing run of " + repaired.trimmedRun
                    )
                    runCatching {
                        File(runDir, "llm-tail-repair.txt").writeText(
                            buildString {
                                appendLine("backend=" + backend)
                                appendLine("originalTokens=" + (repaired.tokens.size + repaired.trimmedRun))
                                appendLine("keptTokens=" + repaired.tokens.size)
                                appendLine("trimmedRun=" + repaired.trimmedRun)
                                appendLine("originalReason=" + reason)
                            },
                            Charsets.UTF_8
                        )
                    }
                    Log.w(TAG, "LLM attempt " + (index + 1) + " tail-runaway repaired: kept " +
                        repaired.tokens.size + ", trimmed " + repaired.trimmedRun)
                    onStage("LLM 结尾空转已修正：裁掉 " + repaired.trimmedRun + " 个重复 Token")
                    llmFailure = null
                    break
                }
            }
            // 被拒的报告与原始 token 都留一份到 runDir（父目录）—— 下一次尝试会删掉 llmOutput。
            runCatching {
                val report = File(llmOutput, "llm-persistent.jsonl")
                if (report.isFile) {
                    report.copyTo(File(runDir, "llm-persistent-attempt" + (index + 1) + ".jsonl"), overwrite = true)
                }
                val raw = File(llmOutput, "raw-output-ids-0.csv")
                if (raw.isFile) {
                    raw.copyTo(File(runDir, "raw-output-ids-attempt" + (index + 1) + ".csv"), overwrite = true)
                }
            }
            Log.w(TAG, "LLM attempt " + (index + 1) + "/" + attemptBackends.size + " (" + backend + ") rejected: " + reason)
            if (index < attemptBackends.lastIndex) {
                onStage("LLM 输出校验未通过，正在重试（第 " + (index + 2) + "/" + attemptBackends.size + " 次）")
            }
        }
        runCatching { File(runDir, "llm-attempts.txt").writeText(attemptLog.toString()) }
        val llmFail = llmFailure
        if (llmFail != null) {
            val detail = if (llmExitCode != 0) llmFail + "（JNI 退出码 " + llmExitCode + "）" else llmFail
            error("LLM 输出质量门未通过（已尝试 " + attemptBackends.size + " 次）：" + detail)
        }
        val llmStage = (System.nanoTime() - llmStartedAt) / 1_000_000L
        check(llmExitCode == 0) { "LLM JNI 执行失败($llmExitCode)" }
        currentCoroutineContext().ensureActive()
        val tokenFile = File(llmOutput, "speech-tokens-0.csv")
        val targetTokens = tokenFile.readText().split(',').count { it.trim().isNotEmpty() }
        check(targetTokens > 0) { "LLM 没有生成语音 Token" }
        val sequenceLength = 2 * (voiceProfile.promptTokenCount + targetTokens)
        val targetFrames = 2 * targetTokens
        val flowBucket = flowBucket(sequenceLength)

        onStage("正在生成 Flow 输入")
        val conditionerStage = runCommand(
            stage = "conditioner",
            command = listOf(
                store.executable("libcosy_conditioner_exec.so").absolutePath,
                File(model, "flow-conditioner.fp32.mnn").absolutePath,
                voiceProfile.directory.absolutePath,
                tokenFile.absolutePath,
                flowInput.absolutePath,
                voiceProfile.promptTokenCount.toString(),
                voiceProfile.promptFrameCount.toString()
            ),
            directory = runDir,
            logFile = File(runDir, "conditioner.log")
        )
        currentCoroutineContext().ensureActive()

        onStage(if (options.flowBackend == "opencl") "Flow 正在使用 GPU 合成 Mel" else "Flow 正在使用 CPU 合成 Mel")
        val flowManifest = File(runDir, "flow-manifest.txt").apply {
            writeText(
                "${flowInput.absolutePath} ${flowOutput.absolutePath} $sequenceLength ${voiceProfile.promptFrameCount} $flowBucket\n",
                Charsets.US_ASCII
            )
        }
        val flowReportFile = File(runDir, "flow-report.jsonl")
        val flowCache = File(store.gpuCacheDir, "flow-fp16-${options.flowBackend}-${options.flowPrecision}-mode${options.flowGpuMode}.cache")
        val flowExitCode = CosyVoiceFlowNative.run(
            modelPath = File(model, "flow.cfg-student-2step.batch1.fp16.mnn").absolutePath,
            manifestPath = flowManifest.absolutePath,
            backend = options.flowBackend,
            precision = options.flowPrecision,
            threads = options.flowThreads,
            reportPath = flowReportFile.absolutePath,
            cachePath = flowCache.absolutePath
        )
        check(flowExitCode == 0) { "Flow JNI 执行失败($flowExitCode)" }
        currentCoroutineContext().ensureActive()

        File(flowOutput, "student_target_mel_android.bin").copyTo(
            File(hiftInput, "mel.bin"), overwrite = true
        )
        listOf("source-linear-weight.bin", "source-linear-bias.bin").forEach { name ->
            File(model, name).copyTo(File(hiftInput, name), overwrite = true)
        }
        val hiftManifest = File(runDir, "hift-manifest.txt").apply {
            writeText("${hiftInput.absolutePath} ${hiftOutput.absolutePath} $targetFrames\n", Charsets.US_ASCII)
        }
        val hiftReportFile = File(runDir, "hift-report.jsonl")
        val hiftCache = File(store.gpuCacheDir, "hift-core-${options.hiftCoreBackend}-high-mode${options.hiftGpuMode}.cache")
        onStage(
            if (options.hiftCoreBackend == "opencl") "HiFT core 正在使用 GPU 生成音频"
            else "HiFT 正在使用 CPU 生成音频"
        )
        val hiftExitCode = CosyVoiceHiFTNative.run(
            f0ModelPath = File(model, "hift-f0.fp32.mnn").absolutePath,
            coreModelPath = File(model, "hift-core.fp32.mnn").absolutePath,
            manifestPath = hiftManifest.absolutePath,
            threads = HIFT_CPU_THREADS,
            reportPath = hiftReportFile.absolutePath,
            coreBackend = options.hiftCoreBackend,
            corePrecision = "low",
            coreCachePath = hiftCache.absolutePath,
            coreGpuMode = if (options.hiftCoreBackend == "cpu") HIFT_CPU_THREADS else options.hiftGpuMode
        )
        check(hiftExitCode == 0) {
            val health = runCatching { hiftReportFile.firstJson() }.getOrNull()
            if (health == null) "HiFT JNI 执行失败($hiftExitCode)"
            else "HiFT JNI 执行失败($hiftExitCode)：finite=${health.optBoolean("pcmFinite")} peak=${
                "%.3f".format(health.optDouble("pcmPeak"))
            } rms=${"%.3f".format(health.optDouble("pcmRms"))} write=${health.optBoolean("waveWritten")}"
        }
        currentCoroutineContext().ensureActive()

        val generated = File(hiftOutput, "hift-android.wav")
        check(generated.length() > 44L) { "HiFT 没有生成有效 WAV" }
        output.parentFile?.mkdirs()
        val tempOutput = File(output.parentFile, "${output.name}.writing")
        generated.copyTo(tempOutput, overwrite = true)
        output.delete()
        check(tempOutput.renameTo(output)) { "试听音频无法保存" }

        val llm = File(llmOutput, "llm-persistent.jsonl").firstJson()
        val flow = flowReportFile.firstJson()
        val hift = hiftReportFile.firstJson()
        val totalMs = (System.nanoTime() - startedAt) / 1_000_000L
        val report = CosyVoiceSynthesisReport(
            output = output, totalMs = totalMs,
            llmMs = llmStage, conditionerMs = conditionerStage,
            flowResizeMs = flow.optDouble("resizeMs", 0.0),
            flowInferenceMs = flow.optDouble("inferenceMs", 0.0),
            hiftMs = hift.optDouble("requestMs", 0.0),
            audioSeconds = hift.optDouble("audioSeconds", targetFrames * 0.02),
            targetTokens = targetTokens, flowBucket = flowBucket,
            pcmPeak = hift.optDouble("pcmPeak", 0.0),
            pcmRms = hift.optDouble("pcmRms", 0.0),
            voiceProfile = voiceProfile, options = effectiveOptions
        )
        Log.d(TAG, report.displayText().replace('\n', ' '))
        onStage("合成完成，正在播放")
        if (!runDir.deleteRecursively()) {
            Log.w(TAG, "无法清理合成中间目录：${runDir.absolutePath}")
        }
        report
    }

    suspend fun close() = mutex.withLock {
        activeProcess.getAndSet(null)?.destroyForcibly()
        CosyVoiceLlmNative.reset()
        CosyVoiceFlowNative.reset()
        CosyVoiceHiFTNative.reset()
    }

    private suspend fun runCommand(
        stage: String, command: List<String>, directory: File, logFile: File
    ): Long {
        currentCoroutineContext().ensureActive()
        val startedAt = System.nanoTime()
        // 这些 *_exec.so 是被当可执行文件 exec 的，它们 NEEDED libMNN.so 等库。
        // 子进程的动态链接器默认不会搜 App 的 nativeLibraryDir，
        // 于是报 "CANNOT LINK EXECUTABLE ... cannot locate symbol MNN::Interpreter::destroy"。
        // 显式把 nativeLibraryDir 加进 LD_LIBRARY_PATH。
        val builder = ProcessBuilder(command)
            .directory(directory)
            .redirectErrorStream(true)
        appContext?.applicationInfo?.nativeLibraryDir?.let { nativeDir ->
            val env = builder.environment()
            val old = env["LD_LIBRARY_PATH"].orEmpty()
            env["LD_LIBRARY_PATH"] = if (old.isBlank()) nativeDir else nativeDir + ":" + old
        }
        val process = builder.start()
        activeProcess.set(process)
        val cancellation = currentCoroutineContext().job.invokeOnCompletion {
            if (process.isAlive) process.destroyForcibly()
        }
        val console = try {
            process.inputStream.bufferedReader().use { it.readText() }
        } finally {
            cancellation.dispose()
        }
        val exitCode = process.waitFor()
        activeProcess.compareAndSet(process, null)
        logFile.writeText(console, Charsets.UTF_8)
        val elapsedMs = (System.nanoTime() - startedAt) / 1_000_000L
        Log.d(TAG, "stage=$stage exit=$exitCode elapsed=${elapsedMs}ms log=${logFile.absolutePath}")
        check(exitCode == 0) { "$stage 执行失败($exitCode)：${console.takeLast(1200)}" }
        return elapsedMs
    }

    private fun flowBucket(sequenceLength: Int): Int =
        listOf(512, 768, 1024, 1280, 1536, 2048).firstOrNull { sequenceLength <= it }
            ?: error("文本过长：Flow sequence=$sequenceLength")

    private fun File.firstJson(): JSONObject {
        check(isFile) { "缺少报告文件：$absolutePath" }
        val line = useLines { lines -> lines.firstOrNull { it.isNotBlank() } }
            ?: error("报告为空：$absolutePath")
        return JSONObject(line)
    }
}

private fun CosyVoiceInferenceMode.displayName(): String = when (this) {
    CosyVoiceInferenceMode.ZERO_SHOT -> "普通复刻"
    CosyVoiceInferenceMode.INSTRUCT2 -> "指令演绎"
}
