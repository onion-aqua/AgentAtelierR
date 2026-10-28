package com.example.ryza_chat_mvp

/** Selection only: Android's actual routedDevice remains the source of truth. */
internal enum class RealtimeOutputKind(val wireName: String) {
    BLUETOOTH("bluetooth"), WIRED("wired"), SPEAKER("speaker"), EARPIECE("earpiece"), SYSTEM("system"),
}

internal data class RealtimeOutputEndpoint(val id: Int, val kind: RealtimeOutputKind)

internal data class RealtimeOutputPreference(
    val speaker: Boolean = true,
    val forceSpeaker: Boolean = false,
    val headsetId: Int? = null,
) {
    fun withSpeaker(enabled: Boolean) = copy(speaker = enabled, forceSpeaker = enabled)

    // A new headset should win even if the user previously selected speaker.
    fun withConnectedHeadset(id: Int) = copy(forceSpeaker = false, headsetId = id)
}

internal object RealtimeOutputRoutePolicy {
    fun select(
        endpoints: List<RealtimeOutputEndpoint>,
        preference: RealtimeOutputPreference,
        routedId: Int? = null,
    ): RealtimeOutputEndpoint? {
        if (!preference.forceSpeaker) {
            for (kind in listOf(RealtimeOutputKind.BLUETOOTH, RealtimeOutputKind.WIRED)) {
                val candidates = endpoints.filter { it.kind == kind }
                if (candidates.isNotEmpty()) {
                    return candidates.firstOrNull { it.id == preference.headsetId }
                        ?: candidates.firstOrNull { it.id == routedId }
                        ?: candidates.first()
                }
            }
        }
        val fallback = if (preference.speaker) RealtimeOutputKind.SPEAKER else RealtimeOutputKind.EARPIECE
        // No earpiece (e.g. tablets) is not permission to silently force speaker.
        return endpoints.firstOrNull { it.kind == fallback }
    }
}
