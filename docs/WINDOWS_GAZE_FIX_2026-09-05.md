# Windows crash and gaze fixes

## Verified causes

- Windows Application Error events report `0xc0000005` in
  `flutter_windows.dll`. Symbol resolution maps Release offset `0x3c16a`
  and Debug offset `0x3c18a` to
  `AccessibilityBridge::CreateRemoveReparentedNodesUpdate`, line 229.
- The debug client emitted invalid AXTree updates at startup before crashing.
  Replacing Windows Material sliders with non-OverlayPortal Cupertino sliders
  removed those startup errors in the observed run. This is an application-level
  workaround, not a patched Flutter engine. Accessibility remains enabled.
- Reference: https://github.com/flutter/flutter/issues/190357
- A separate audio plugin non-platform-thread warning was observed in an earlier
  run. It was not the symbolized fault above and remains a separate risk.

## Gaze

- Pointer down/move now use camera-inverse coordinates. Pointer up/cancel and
  application focus loss end tracking. Release fades over 700 ms even when the
  tracking setting remains enabled.
- Original iris meshes are weighted to `eyeball_L_offset` and
  `eyeball_R_offset`. Highlight meshes use `eyehilight_L` and `eyehilight_R`,
  whose parents are the non-offset pupil bones. The offset constraint therefore
  moved the iris without its highlight.
- Each frame preserves the highlight position in the effective iris bone's
  local space, then reapplies it after procedural gaze/head motion. Procedural
  local values are restored before the next animation update to avoid drift.
- Native lip-sync references are invalidated before facial tracks are cleared
  or the character skeleton changes.

## Validation scope

- Windows Debug: startup, background drag/release, drawer navigation, settings
  and settings scrolling. Temporary instrumentation confirmed release completion
  and no highlight-position mismatch above 0.1 skeleton units in the tested pose.
  Diagnostic prints were removed before delivery.
- Unit/widget coverage includes down/move/up/cancel, pinch suppression,
  inverse camera coordinates, release decay and Windows/Android slider selection.
- All costumes, prolonged TTS playback and all possible desktop interactions
  are not covered by this check. Android hardware was not retested in this turn.

## Build

From the Flutter project directory, with Visual Studio C++ tools and NuGet on PATH:

For a fresh source-only checkout, follow
[resource and platform setup](RESOURCE_SETUP_AND_BUILD.md) first. The generated
Windows runner is intentionally not tracked; create it locally with
`flutter create --platforms=windows .` and apply the documented MSVC compatibility
definition if required.

```powershell
flutter analyze
flutter test
flutter build windows --release
```

Run `build/windows/x64/runner/Release/ryza_chat_mvp.exe` in place. Distribution
requires the entire Release directory, not the executable alone. This local build
contains private assets; do not upload it to the source-only public repository.
