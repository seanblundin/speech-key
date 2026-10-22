# Speech Key

Hold **🌐 (fn)** and talk. Let go, and your words paste wherever your cursor is, with your names spelled right. Everything runs on your Mac: no account, no cloud, no audio saved.

Download the signed app at **[speechkeyapp.com](https://speechkeyapp.com)**. It needs macOS 26 on Apple silicon. The speech model (about 0.5 GB) downloads on first launch.

## What it does

- **Hold fn:** talk, let go to paste.
- **Double-tap fn:** hands-free for long dictations. Tap fn again to finish.
- **Hold ⇧ fn:** talk to the agent instead of typing: "Jammy should be Jimmy", "remove Jimmy", "start a meeting", "take a snapshot", "undo that". Apple's on-device model reads the command, so it stays on the Mac.
- **Esc** cancels.
- **The menu-bar panel** has three tabs:
  - **History:** every dictation, newest first. Click to copy, double-click to fix a word and teach the glossary.
  - **Meetings:** past meetings with titles and one-line summaries written on the Mac.
  - **Glossary:** an editable table of names Speech Key should spell your way.
- Don't want it pasted? Settings › "After you release 🌐" switches to **Copy** or **Save**.

### Meeting mode

- **⌃⌥ fn** starts and ends a meeting. **⌃ fn** saves a snapshot of everything so far and copies the file's path.
- Two streams are transcribed: **Me** (the mic) and **Them** (whatever the Mac plays: Zoom, Meet, Teams, FaceTime).
- Files are written only when you take a snapshot or end the meeting, to `~/Documents/Speech Key Meetings/<date>_<time>/`. Each part overlaps the previous one by 10 seconds, and `full.md` holds everything.
- Many places require everyone's consent to record a call. Tell people when you start.

## How it works

1. **Recognizer:** NVIDIA Parakeet TDT 0.6B (Moondream's "Ultra" fine-tune) on the Neural Engine, through [FluidAudio](https://github.com/FluidInference/FluidAudio). Long dictations are cut at pauses and transcribed while you talk, so letting go leaves only the last few seconds to do.
2. **Name boosting:** a small second model (Parakeet CTC 110M) listens for glossary names. A suggested swap is kept only when it replaces something that isn't an ordinary word or a common first name.
3. **Glossary:** a Markdown table (`Heard as | Write as | Notes`) in `~/Library/Application Support/SpeechKey/glossary.md`, or any file you pick in Settings. Plain rows are replaced as whole words. Rows whose notes set a condition ("only in book club talk") are decided by Apple's on-device model, and left alone when it's unsure.
4. **Clean verbatim:** removes um and uh, stutters, back-to-back repeats, and "like" when it's set off by commas. Nothing else is rewritten.
5. **Paste:** the clipboard holds a promise, so your old clipboard comes back only after the app has read the new text, and "Pasted" shows only when it did.

Dictations are logged as text (never audio) to `~/Library/Application Support/SpeechKey/` so the panel can show them. Nothing is sent anywhere.

On a MacBook Air M2: about 0.3 s to transcribe a 6-second clip, and 0.35–0.85 s from letting go to pasted at the end of a one-minute dictation.

## Build

Needs Swift 6 and a macOS 15+ SDK (`scripts/swift.sh` picks a toolchain).

```bash
scripts/build-app.sh          # build, sign, install to ~/Applications/Speech Key.app
scripts/swift.sh test         # glossary, clean-verbatim, hotkey and correction tests
```

`SPEECHKEY_APPSTORE=1 scripts/build-app.sh` builds the sandboxed Mac App Store version instead (no Sparkle, Input Monitoring instead of Accessibility, folders kept as security-scoped bookmarks); `scripts/asc.py setup` and `scripts/release-appstore.sh` sign and upload it.

`build-app.sh` signs with the certificate named in `UTTER_IDENTITY` (default "Local Dictation Dev") and falls back to ad-hoc signing. A stable self-signed certificate keeps macOS permissions across rebuilds. `scripts/release.sh` builds a notarized DMG with a Developer ID certificate.

Test modes (no permission prompts):

```bash
SK="dist/Speech Key.app/Contents/MacOS/SpeechKey"
"$SK" --simulate clip.wav                            # full pipeline, fed at real-time speed
"$SK" --simulate-keys "d0 s150Hello_there. u4000"    # fn presses (ms) through the real rules; s<ms> speaks with `say`
"$SK" --test-paste                                   # the paste confirmation, without touching the keyboard
"$SK" --render-pill /tmp/pill                        # PNG of every pill state and panel page, light and dark
.build/release/engine-bench --glossary g.md --clips clips.json clips/*.wav   # engine speed and accuracy
```

## Layout

```
Sources/TranscriptText/   Glossary, CleanVerbatim, ChunkJoiner, CorrectionDiff (pure Swift, no dependencies)
Sources/Hotkeys/          FnChordMachine: what each fn chord means
Sources/SpeechEngine/     SpeechEngine actor, PauseChunker (Silero VAD)
Sources/Utter/            the menu-bar app (the folder keeps the app's first name)
Sources/EngineBench/      benchmark CLI
```

### Using the engine from another package

```swift
import SpeechEngine

let engine = try await SpeechEngine(model: .ultra)                  // downloads ~0.5 GB on first run
let glossary = try Glossary.load(path: "glossary.md")
let chunker = try await PauseChunker.make()                         // ≤14.5 s chunks at pauses

for chunk in try await chunker.append(samples16kMono) where chunk.hasSpeech {
    let segments = try await engine.transcribe(samples: chunk.samples, vocabulary: glossary.boostTerms,
                                               priority: .background)
    for s in segments { print(chunk.start + s.start, glossary.apply(s.text)) }
}
```

## Credits

- Speech models: NVIDIA Parakeet TDT 0.6B in Moondream's "Ultra" fine-tune, and Parakeet CTC 110M for name boosting, both CC-BY-4.0, converted to Core ML by [FluidInference](https://huggingface.co/FluidInference).
- [FluidAudio](https://github.com/FluidInference/FluidAudio) (Apache-2.0) runs them on the Neural Engine.
- [Silero VAD](https://github.com/snakers4/silero-vad) (MIT) finds the pauses.

## License

MIT. See [LICENSE](LICENSE).
