# Security

Speech Key can hear your microphone, notice your keystrokes (to catch the globe key) and paste into
other apps, so it has to be trustworthy. If you find a way it isn't, please tell us privately.

## Reporting a problem

Use **[Report a vulnerability](https://github.com/seanblundin/speech-key/security/advisories/new)**
on this repository (GitHub's private reporting). Please don't open a public issue for security
problems. You'll get an answer within a few days, and fixes ship to everyone through the app's
automatic updates.

Only the latest version is supported.

## How Speech Key is built to be safe

- **Everything stays on the Mac.** Speech is turned into text on the Neural Engine. Audio is never
  saved or sent. There's no account, no server, no analytics and no open network port.
- **It goes online for two things only:** downloading the speech models once, and checking
  `speechkeyapp.com/appcast.xml` for updates (the version from the website; the App Store version
  is updated by the App Store).
- **Models are fingerprinted.** Every model file is checked against SHA-256 fingerprints built
  into the app (`Sources/SpeechEngine/ModelManifest.swift`) before it's used, so a model changed
  on its download site is refused, not loaded.
- **Updates are signed three ways.** Each update is signed with the project's EdDSA key, the feed
  itself is signed, and the app inside is signed with the developer's Apple Developer ID and
  notarized by Apple. Sparkle checks the update's signature before it even unpacks it.
- **Keystrokes aren't kept.** The key watcher reads key codes only to recognize the globe key and
  the keys pressed with it. Nothing about other keys is stored or logged.
- **No remote control by default.** A developer-only setting lets local tools end or snapshot a
  meeting; it's off unless turned on with `defaults write`, and absent from the App Store build.
- **Dependencies are pinned** to exact versions and commits (`Package.resolved`).
