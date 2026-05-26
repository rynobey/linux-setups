# Disabled Android packages

Tracking which Android system packages have been disabled (`pm disable-user`)
to free memory for the Podroid VM. Disabling leaves the package on disk;
state persists across reboots; re-enable with one command.

## Currently disabled

| Package | Why | Memory freed | Re-enable command |
|---|---|---|---|
| `com.google.android.aicore` | Holds 3.8 GB Tensor model weights when active. Idle ~130 MB. Inference is what triggered LMK kills of Podroid. | ~3.5 GB available, ~3 GB free | `adb shell pm enable com.google.android.aicore` |
| `com.google.android.tts` | Google Text-to-Speech engine. Not used in our setup. | ~135 MB available | `adb shell pm enable com.google.android.tts` |

## What you lose with each disabled

### AiCore (`com.google.android.aicore`)

- **Magic Compose** suggestions in Gboard
- **Smart Reply** in Messages (falls back to cloud-based or none)
- **Now Brief** — Pixel's daily AI-generated summary
- **Pixel Recorder** Summarize feature
- Other apps that call the framework's `OnDeviceSandboxedInferenceService` interface

### TTS (`com.google.android.tts`)

- Voice playback for accessibility (Select-to-Speak, TalkBack readout)
- Google Maps voice navigation prompts (some routes fall back to system TTS or silence)
- Any app calling Android's `TextToSpeech` API for output

What's kept regardless:
- Google Assistant (cloud-based, separate from AiCore)
- Voice typing (Gboard's separate speech engine)
- Camera AI features (Best Take, Magic Eraser, Audio Magic Eraser — different engines)
- All non-AI Android functionality

## Helper script

Toggle the tracked packages via [`android-pkg-state.sh`](android-pkg-state.sh):

```sh
./android-pkg-state.sh status         # show enable/disable state + memory snapshot
./android-pkg-state.sh disable        # disable everything in TRACKED
./android-pkg-state.sh enable         # re-enable everything in TRACKED
./android-pkg-state.sh disable aicore # just one (suffix match works)
./android-pkg-state.sh enable  tts
./android-pkg-state.sh list           # show tracked packages + descriptions
```

Memory deltas print before/after each disable/enable so you can see the impact.
Edit the `TRACKED=(...)` array near the top of the script to add more packages.

Raw `adb` equivalents if you'd rather skip the script:

```sh
adb shell pm enable               com.google.android.aicore
adb shell pm disable-user --user 0 com.google.android.aicore

adb shell pm enable               com.google.android.tts
adb shell pm disable-user --user 0 com.google.android.tts
```

After re-enabling AiCore, Android may take a minute to repopulate the binding service;
the model loads lazily on first inference call.

## Check current state (raw)

```sh
adb shell pm list packages -d        # all disabled packages on the device
```

## Notes on the discovery

The reason AiCore looked like the worst offender in earlier kill logs (3.8 GB
`dmabuf_pss`) is that the kill happened *during active inference* — model
weights were loaded into Tensor memory at that moment. At idle, AiCore is
only ~130 MB PSS. But the LMK threshold can be crossed when:

1. The VM is doing a memory-heavy operation (backup, scan)
2. Some background trigger (notification, smart-reply, suggestion) wakes AiCore
3. AiCore loads the model → 3.8 GB Tensor allocation
4. Combined pressure breaches the watermark → LMK fires → Podroid dies

So disabling AiCore eliminates the *probabilistic* part of the kill risk —
not because AiCore-at-rest is heavy, but because AiCore-during-inference is
a 3.8 GB spike that can land at any time.

Apply `pm disable-user` when you need consistent headroom (during long
backup/restore operations, big builds, etc.). Re-enable when you want the
AI features back.

For automation, see [`disable-for-heavy-ops.sh`](disable-for-heavy-ops.sh)
if/when we add it — wraps disable + restore-with-cleanup.
