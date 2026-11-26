# Speech Key

Hold **🌐 (fn)** and talk. Let go, and your words paste wherever your cursor is, with your names spelled right. Everything runs on your Mac: no account, no cloud, no audio saved.

Download the signed app at **[speechkeyapp.com](https://speechkeyapp.com)**. It needs macOS 26 on Apple silicon. The speech model (about 0.5 GB) downloads on first launch.

## What it does

- **Hold fn:** talk, let go to paste.
- **Double-tap fn:** hands-free for long dictations. Tap fn again to finish.
- **Hold ⇧ fn:** talk to the agent instead of typing: "Jammy should be Jimmy", "remove Jimmy", "start a meeting", "take a snapshot", "undo that". Apple's on-device model reads the command, so it stays on the Mac.
- **Esc** cancels.
- **In the Dock and the menu bar.** The Dock icon and its dot show that Speech Key is running; clicking it opens the panel, and it never comes to the front on its own, so dictation keeps landing in the app you're using. The menu-bar icon is the quick way in. If the menu bar is too full to show it (macOS hides extra icons behind the notch without saying so), Speech Key tells you.
- **The panel** has three tabs:
  - **History:** every dictation, newest first. Click to copy, double-click to fix a word and teach the glossary. When the cleanup changed anything, **View Raw** flips a row to the words exactly as heard (what was cut is tinted) and a click copies those instead.
  - **Meetings:** past meetings with titles and one-line summaries written on the Mac.
  - **Glossary:** an editable table of names Speech Key should spell your way.
- **Say a name and spell it in the same sentence** ("Sara S-A-R-A-H", or "my friend Sara is coming, S-A-R-A-H") and Speech Key writes it that way from then on. The pill says "Learned Sarah"; History has the undo.
- Don't want it pasted? Settings › "After you release 🌐" switches to **Copy** or **Save**.

### Meeting mode

- **⌃⌥ fn** starts and ends a meeting. **⌃ fn** saves a snapshot of everything so far and copies the file's path.
- Two streams are transcribed: **Me** (the mic) and **Them** (whatever the Mac plays: Zoom, Meet, Teams, FaceTime).
- Files are written only when you take a snapshot or end the meeting, to `~/Documents/Speech Key Meetings/2026-10-22_1547_x7bm3z/`. Every file ends with that folder name (`full_2026-10-22_1547_x7bm3z.md` holds everything; each `part-…` overlaps the previous one by 10 seconds), and the six-character code is unique to the meeting, so searching Finder for it finds them all. The Meetings tab shows each meeting's code; click it to copy.
- **Who is speaking.** The transcript is written for an AI to read, and a good one follows a raw transcript well; what it can't do is hear. So the one thing Speech Key adds is who said each line, the same way for every kind of meeting: a call with many people, a room with many people, both at once, or a phone on speaker. Each stream is split by voice. The saved files say **Me** for your voice, **Them** when the call is one other voice, and otherwise **Speaker 1**, **Speaker 2**… in the order people first spoke; one line under the heading says who is on your mic and who is on the computer's audio. Real names are left to whoever reads the file ("Speaker 2 is Daniel" is easy for a reader with the context). The names are written into the files a few seconds after each snapshot (a one-hour meeting takes about 15 s per stream on an M2 Air).
  - It runs on your Mac: FluidAudio's batch pipeline (pyannote segmentation, WeSpeaker voice fingerprints, VBx clustering; a 34 MB download the first time). On a real four-person meeting it gave about 84% of the words to the right person; most misses are people talking over each other.
  - **Me** is the mic voice that matches your own. Your voice is learned from kept dictation recordings (`keepAudio`, below) as 256 numbers in `voiceprint.json`, which never leaves the Mac. Without it, a mic with a single voice is you, and a mic with several voices is numbered.
- Many places require everyone's consent to record a call. Tell people when you start.

## How it works

1. **Recognizer:** NVIDIA Parakeet TDT 0.6B (Moondream's "Ultra" fine-tune) on the Neural Engine, through [FluidAudio](https://github.com/FluidInference/FluidAudio). Long dictations are cut at pauses and transcribed while you talk, so letting go leaves only the last few seconds to do.
2. **Name boosting:** a small second model (Parakeet CTC 110M) listens for glossary names. A suggested swap is kept only when it replaces something that isn't an ordinary word or a common first name.
3. **Glossary:** a Markdown table (`Heard as | Write as | Notes`) in `~/Library/Application Support/SpeechKey/glossary.md`, or any file you pick in Settings. Plain rows are replaced as whole words. Rows whose notes set a condition ("only in book club talk") are decided by Apple's on-device model, and left alone when it's unsure.
4. **Clean verbatim:** removes um and uh, small connecting words said twice in a row ("the the", "should should"; nouns, adjectives and verbs stay, since "final final take" is said on purpose), back-to-back repeats of a phrase, "like" when it's set off by commas, and the cut-off start of a word ("w white paper"). Rules only, no language model, so it adds no wait and does the same thing every time. Nothing is rewritten: every word left is one you said, in your order. Each cut is logged by kind.
5. **Paste:** the clipboard holds a promise, so your old clipboard comes back only after the app has read the new text, and "Pasted" shows only when it did.

Dictations are logged as text to `~/Library/Application Support/SpeechKey/` so the panel can show them. Audio is not kept unless you turn it on (below). Nothing is sent anywhere.

**Is the cleanup working?** `SpeechKey --cleanup-report 7` prints the last 7 days: what was cut, by kind, with the words around each cut, plus the signs it got something wrong (raw text copied instead of the cleaned text, fixes made by hand). It is plain text, written to be read by you or pasted to an AI.

**Trying another speech model.** `defaults write ~/Library/Preferences/com.seanblundin.utter.plist keepAudio -int 200` keeps the sound of your last 200 dictations on your Mac (lossless, about 1 MB a minute, never more than 300 MB). `engine-bench --history --model v3` then transcribes them again with another model and lists every word that came out differently, so a new model is judged on your own speech.

On a MacBook Air M2: about 0.3 s to transcribe a 6-second clip, and 0.35–0.85 s from letting go to pasted at the end of a one-minute dictation.

## Build

Needs Swift 6 and a macOS 15+ SDK (`scripts/swift.sh` picks a toolchain).

```bash
scripts/build-app.sh          # build, sign, install to ~/Applications/Speech Key.app
scripts/swift.sh test         # glossary, clean-verbatim, hotkey and correction tests
```

`SPEECHKEY_APPSTORE=1 scripts/build-app.sh` builds a sandboxed version (no Sparkle, Input Monitoring instead of Accessibility, folders kept as security-scoped bookmarks). Apple rejected it for the Mac App Store in November 2026: the Store allows neither watching a key in other apps nor pasting into them. The Mac app ships from the website only; the build flag stays for reference.

`build-app.sh` signs with the certificate named in `UTTER_IDENTITY` (default "Local Dictation Dev") and falls back to ad-hoc signing. A stable self-signed certificate keeps macOS permissions across rebuilds. `scripts/release.sh` builds a notarized DMG with a Developer ID certificate.

Test modes (no permission prompts):

```bash
SK="dist/Speech Key.app/Contents/MacOS/SpeechKey"
"$SK" --simulate clip.wav                            # full pipeline, fed at real-time speed
"$SK" --simulate-keys "d0 s150Hello_there. u4000"    # fn presses (ms) through the real rules; s<ms> speaks with `say`
"$SK" --test-paste                                   # the paste confirmation, without touching the keyboard
"$SK" --render-pill /tmp/pill                        # PNG of every pill state and panel page, light and dark
"$SK" --cleanup-replay fragment,repeat               # rerun today's cleanup rules over your logged dictations and list every cut
"$SK" --test-voices mic.wav --call call.wav          # treat recordings as a meeting's two streams (--call is optional): transcribe, name the voices, print the transcript
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

## Security

See [SECURITY.md](SECURITY.md): how Speech Key keeps your voice and keystrokes on your Mac, how models and updates are verified, and how to report a problem privately.

## License

MIT. See [LICENSE](LICENSE).
