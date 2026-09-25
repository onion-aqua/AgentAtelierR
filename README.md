# AgentAtelierR

Current source version: **1.0.3-beta4+27**.

Local-first AI character companion for Android and Windows. It combines
streaming LLM chat, local memory, optional TTS, animated character interaction,
and scene-aware audio while keeping service credentials on the device.

## Implemented

- Spine 4.2 character rendering, idle animation, tap reaction, and tap voice
- Local chat demo with persistent history
- Automatic and manual scene time selection
- Drawer navigation
- World hierarchy, area artwork, stage selection, and NPC hints
- Welcome missions, progress tracking, rewards, and persistent state
- Voice, volume, scene, and local-data settings
- OpenAI-compatible `/chat/completions` SSE streaming
- Google Gemini through the official OpenAI-compatible endpoint
- Local long-term memory summary and character mood/relationship state
- Fish Audio `POST /v1/tts` reply playback
- DashScope Qwen-TTS playback and guided voice-cloning setup
- Versioned JSON backup import/export without API credentials
- Native Android exact alarms with lock-screen ringing and voice audio
- Stage-aware looping BGM, day/night ambience, and time-band Spine scene layers

## Run

```powershell
powershell -ExecutionPolicy Bypass -File .\tool\run_protected.ps1 -Device emulator-5554
```

Character outfits are encrypted before they enter an APK. Use
`tool/build_protected.ps1` for every Android or Windows package; a direct
`flutter build` does not inject the local decryption key. See
`docs/PROTECTED_CHARACTER_ASSETS.md` for source placement and build commands.

Optional chat-scene music belongs in `assets/audio/bgm/`. Name a track
`bgm_<stageId>.m4a`, for example `bgm_stage_01_002_01.m4a`. The exact stage
track is preferred, followed by its shared-background stage track and finally
`bgm_opening.m4a`. These local media files are excluded from source control.

The vendored `packages/spine_flutter` dependency stays on the 4.2 runtime because
the character skeleton was exported with Spine 4.2.43. Its Android compile SDK
has been raised to 36 for compatibility with the current Flutter toolchain.

## Scope

AI and speech services remain disabled until configured in Settings. API keys are
stored with the platform secure-storage implementation and are excluded from
JSON backups. There is no cloud synchronization; migration is file-based.

Release signing and store publication are intentionally not configured. Public
distribution requires the relevant character, artwork, audio, and Spine Runtime
licenses.
