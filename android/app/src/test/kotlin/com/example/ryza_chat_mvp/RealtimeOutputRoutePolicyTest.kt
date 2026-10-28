package com.example.ryza_chat_mvp

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RealtimeOutputRoutePolicyTest {
    private val speaker = RealtimeOutputEndpoint(1, RealtimeOutputKind.SPEAKER)
    private val earpiece = RealtimeOutputEndpoint(2, RealtimeOutputKind.EARPIECE)
    private val wired = RealtimeOutputEndpoint(3, RealtimeOutputKind.WIRED)
    // Android adapters normalize A2DP and LE Audio to the same policy kind.
    private val a2dp = RealtimeOutputEndpoint(4, RealtimeOutputKind.BLUETOOTH)
    private val ble = RealtimeOutputEndpoint(5, RealtimeOutputKind.BLUETOOTH)

    @Test
    fun connectedBluetoothWinsOverWiredAndTheDefaultPhoneSpeaker() {
        assertEquals(
            a2dp,
            RealtimeOutputRoutePolicy.select(
                listOf(speaker, earpiece, wired, a2dp),
                RealtimeOutputPreference(),
                routedId = speaker.id,
            ),
        )
    }

    @Test
    fun bothNormalizedBluetoothKindsWinRegardlessOfEnumerationOrder() {
        for (headset in listOf(a2dp, ble)) {
            for (endpoints in listOf(
                listOf(speaker, wired, headset),
                listOf(headset, wired, speaker),
            )) {
                assertEquals(
                    headset,
                    RealtimeOutputRoutePolicy.select(endpoints, RealtimeOutputPreference()),
                )
            }
        }
    }

    @Test
    fun wiredHeadphonesWinWhenNoBluetoothOutputIsAvailable() {
        assertEquals(
            wired,
            RealtimeOutputRoutePolicy.select(
                listOf(speaker, earpiece, wired),
                RealtimeOutputPreference(),
                routedId = speaker.id,
            ),
        )
    }

    @Test
    fun anAlreadyRoutedBluetoothEndpointStaysStableAmongEqualCandidates() {
        val preference = RealtimeOutputPreference()
        assertEquals(
            ble,
            RealtimeOutputRoutePolicy.select(listOf(a2dp, ble, speaker), preference, ble.id),
        )
        assertEquals(
            ble,
            RealtimeOutputRoutePolicy.select(listOf(speaker, ble, a2dp), preference, ble.id),
        )
    }

    @Test
    fun anAlreadyRoutedWiredEndpointStaysStableAmongEqualCandidates() {
        val secondWired = RealtimeOutputEndpoint(6, RealtimeOutputKind.WIRED)
        assertEquals(
            secondWired,
            RealtimeOutputRoutePolicy.select(
                listOf(wired, secondWired, speaker),
                RealtimeOutputPreference(),
                secondWired.id,
            ),
        )
    }

    @Test
    fun aNewBluetoothConnectionWinsOverThePreviouslyRoutedBluetoothOutput() {
        val preference = RealtimeOutputPreference().withConnectedHeadset(ble.id)
        assertEquals(
            ble,
            RealtimeOutputRoutePolicy.select(listOf(a2dp, ble, speaker), preference, a2dp.id),
        )
    }

    @Test
    fun aNewWiredConnectionDoesNotDisplaceAnAvailableBluetoothOutput() {
        assertEquals(
            a2dp,
            RealtimeOutputRoutePolicy.select(
                listOf(wired, speaker, a2dp),
                RealtimeOutputPreference().withConnectedHeadset(wired.id),
                wired.id,
            ),
        )
    }

    @Test
    fun anExplicitSpeakerSelectionOverridesConnectedHeadphones() {
        val preference = RealtimeOutputPreference().withSpeaker(true)
        assertTrue(preference.forceSpeaker)
        assertEquals(
            speaker,
            RealtimeOutputRoutePolicy.select(
                listOf(a2dp, wired, speaker, earpiece),
                preference,
                a2dp.id,
            ),
        )
    }

    @Test
    fun connectingANewHeadsetClearsAnOldExplicitSpeakerOverride() {
        val before = RealtimeOutputPreference().withSpeaker(true)
        val after = before.withConnectedHeadset(ble.id)
        assertTrue(before.forceSpeaker)
        assertFalse(after.forceSpeaker)
        assertEquals(ble.id, after.headsetId)
        assertEquals(
            ble,
            RealtimeOutputRoutePolicy.select(listOf(speaker, ble), after, speaker.id),
        )
    }

    @Test
    fun disablingSpeakerAllowsHeadphonesAndUsesEarpieceAsThePhoneFallback() {
        val preference = RealtimeOutputPreference().withSpeaker(true).withSpeaker(false)
        assertFalse(preference.forceSpeaker)
        assertFalse(preference.speaker)
        assertEquals(
            a2dp,
            RealtimeOutputRoutePolicy.select(listOf(speaker, earpiece, a2dp), preference),
        )
        assertEquals(
            earpiece,
            RealtimeOutputRoutePolicy.select(listOf(speaker, earpiece), preference),
        )
    }

    @Test
    fun missingEarpieceDoesNotSilentlySelectSpeaker() {
        assertNull(
            RealtimeOutputRoutePolicy.select(
                listOf(speaker),
                RealtimeOutputPreference().withSpeaker(false),
                speaker.id,
            ),
        )
    }

    @Test
    fun aNewCallPreferenceResetsAnOldExplicitRoute() {
        val old = RealtimeOutputPreference().withConnectedHeadset(ble.id).withSpeaker(true)
        val fresh = RealtimeOutputPreference()
        assertTrue(old.forceSpeaker)
        assertTrue(fresh.speaker)
        assertFalse(fresh.forceSpeaker)
        assertNull(fresh.headsetId)
        assertEquals(
            a2dp,
            RealtimeOutputRoutePolicy.select(listOf(speaker, a2dp), fresh),
        )
    }

    @Test
    fun disconnectingHeadphonesFallsBackToTheRemainingHeadsetThenPhonePreference() {
        val preference = RealtimeOutputPreference().withConnectedHeadset(a2dp.id)
        assertEquals(
            wired,
            RealtimeOutputRoutePolicy.select(listOf(speaker, wired), preference, a2dp.id),
        )
        assertEquals(
            speaker,
            RealtimeOutputRoutePolicy.select(listOf(earpiece, speaker), preference, wired.id),
        )
        assertEquals(
            earpiece,
            RealtimeOutputRoutePolicy.select(
                listOf(speaker, earpiece),
                preference.withSpeaker(false),
                a2dp.id,
            ),
        )
    }

    @Test
    fun recreatingPlaybackPreservesTheSelectedHeadsetAndManualOverride() {
        val endpoints = listOf(a2dp, ble, wired, speaker, earpiece)
        val preference = RealtimeOutputPreference().withConnectedHeadset(ble.id)
        val first = RealtimeOutputRoutePolicy.select(endpoints, preference, a2dp.id)
        val recreated = RealtimeOutputRoutePolicy.select(endpoints, preference)
        assertEquals(ble, first)
        assertEquals(first, recreated)
        val manual = preference.withSpeaker(true)
        assertEquals(speaker, RealtimeOutputRoutePolicy.select(endpoints, manual, first?.id))
        assertEquals(speaker, RealtimeOutputRoutePolicy.select(endpoints, manual))
    }

    @Test
    fun noAvailableEndpointsReturnsNoForcedDevice() {
        assertNull(
            RealtimeOutputRoutePolicy.select(emptyList(), RealtimeOutputPreference()),
        )
        assertNull(
            RealtimeOutputRoutePolicy.select(
                listOf(a2dp),
                RealtimeOutputPreference().withSpeaker(true),
                a2dp.id,
            ),
        )
    }
}
