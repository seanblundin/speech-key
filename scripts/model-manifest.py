#!/usr/bin/env python3
"""Regenerates Sources/SpeechEngine/ModelManifest.swift from the speech models on this Mac.

Run after updating FluidAudio or when FluidInference updates a model, and only once the files on
this Mac are known good: compare them with HuggingFace first (each file's LFS sha256 or git blob
sha1 from https://huggingface.co/api/models/<repo>/tree/main)."""
import hashlib, pathlib
root = pathlib.Path.home() / "Library/Application Support/FluidAudio/Models"
lines = []
for folder in ["parakeet-ultra", "parakeet-ctc-110m-coreml", "silero-vad"]:
    for p in sorted((root / folder).rglob("*")):
        if p.is_file() and not p.name.startswith("."):
            h = hashlib.sha256()
            with open(p, "rb") as f:
                for b in iter(lambda: f.read(1 << 20), b""):
                    h.update(b)
            lines.append(f'        "{p.relative_to(root)}": "{h.hexdigest()}",')
out = pathlib.Path(__file__).resolve().parent.parent / "Sources/SpeechEngine/ModelManifest.swift"
text = out.read_text()
start = text.index("    static let files: [String: String] = [\n") + len("    static let files: [String: String] = [\n")
end = text.index("    ]\n}", start)
out.write_text(text[:start] + "\n".join(lines) + "\n" + text[end:])
print(f"{len(lines)} files fingerprinted into {out}")
