import Foundation
import FluidAudio
import SpeechEngine

// engine-bench: runs the real engine pipeline on audio files and reports speed and glossary hits.
//
// Usage: engine-bench [--model ultra|v3|v2] [--no-boost] [--glossary glossary.md] [--clips clips.json] [--json out.json] file.wav...
//        engine-bench --history [--model …] [--glossary …] [--limit N]
//          Scores a model on your own speech: every recording Speech Key kept (the `keepAudio` setting)
//          is transcribed again and compared with what the app wrote that day.
// File names like "slack1__am_michael.wav" are matched to clips.json entries by the part before "__".

struct Clip: Decodable { let id: String; let ref: String; let terms: [String] }
struct ClipFile: Decodable { let clips: [Clip] }

var args = Array(CommandLine.arguments.dropFirst())
func take(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    let v = args[i + 1]; args.removeSubrange(i...(i + 1)); return v
}
func flag(_ name: String) -> Bool {
    guard let i = args.firstIndex(of: name) else { return false }
    args.remove(at: i); return true
}

let model = EngineModel(rawValue: take("--model") ?? "ultra") ?? .ultra
let boost = !flag("--no-boost")
let clipsPath = take("--clips")
let glossaryPath = take("--glossary")
let jsonPath = take("--json")
let concurrent = flag("--concurrent")
let stressRounds = take("--stress").flatMap(Int.init)
let history = flag("--history")
let historyLimit = take("--limit").flatMap(Int.init) ?? .max
let files = args

let clips: [String: Clip] = {
    guard let p = clipsPath, let d = FileManager.default.contents(atPath: p),
          let f = try? JSONDecoder().decode(ClipFile.self, from: d) else { return [:] }
    return Dictionary(uniqueKeysWithValues: f.clips.map { ($0.id, $0) })
}()

let glossary = glossaryPath.flatMap { try? Glossary.load(path: $0) } ?? .empty
let mem = { () -> Double in
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
    _ = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) } }
    return Double(info.resident_size) / 1e9
}

let t0 = Date()
let engine = try await SpeechEngine(model: model, boostNames: boost)
print(String(format: "loaded %@ (boost %@) in %.1fs, resident %.2f GB", model.rawValue, boost ? "on" : "off", Date().timeIntervalSince(t0), mem()))
let vocab = boost ? glossary.boostTerms : []
if boost { print("boosting \(vocab.count) terms: " + vocab.map(\.canonical).joined(separator: ", ")) }

let converter = AudioConverter()
struct Row: Encodable { let file: String; let seconds: Double; let audioSeconds: Double; let raw: String; let final: String; let hits: Int; let terms: Int; let missed: [String] }
var rows: [Row] = []

if history {
    // The app's own log and kept recordings. A recording's name is its dictation's time.
    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("SpeechKey")
    var logged: [String: String] = [:]     // time (with - for :) → raw words that day
    for line in ((try? String(contentsOf: dir.appendingPathComponent("dictations.jsonl"), encoding: .utf8)) ?? "").split(separator: "\n") {
        guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let t = o["time"] as? String, let raw = o["raw"] as? String else { continue }
        logged[t.replacingOccurrences(of: ":", with: "-")] = raw
    }
    let audio = ((try? FileManager.default.contentsOfDirectory(at: dir.appendingPathComponent("audio"), includingPropertiesForKeys: nil)) ?? [])
        .filter { $0.pathExtension == "m4a" }.sorted { $0.lastPathComponent > $1.lastPathComponent }.prefix(historyLimit)
    guard !audio.isEmpty else {
        print("No kept recordings in \(dir.path)/audio. Turn them on with:\n  defaults write ~/Library/Preferences/com.seanblundin.utter.plist keepAudio -int 200")
        exit(0)
    }
    func words(_ s: String) -> [String] {
        s.lowercased().split(whereSeparator: \.isWhitespace).map { $0.filter { $0.isLetter || $0.isNumber || $0 == "'" } }.filter { !$0.isEmpty }
    }
    var same = 0, total = 0, identical = 0, audioSecs = 0.0, workSecs = 0.0
    for (i, file) in audio.enumerated() {
        let name = file.deletingPathExtension().lastPathComponent
        guard let then = logged[name], let samples = try? converter.resampleAudioFile(file) else { continue }
        if i == 0 { _ = try await engine.text(samples: samples, vocabulary: vocab) }   // warm-up
        let start = Date()
        let now = try await engine.text(samples: samples, vocabulary: vocab)
        workSecs += Date().timeIntervalSince(start)
        audioSecs += Double(samples.count) / 16_000
        let a = words(then), b = words(now)
        let diff = b.difference(from: a)
        var gone: [String] = [], new: [String] = []
        for c in diff { switch c { case .remove(_, let w, _): gone.append(w); case .insert(_, let w, _): new.append(w) } }
        let changed = max(gone.count, new.count)
        same += max(0, a.count - changed); total += a.count
        if changed == 0 { identical += 1; continue }
        print("\(name)  \(a.count) words, \(changed) differ")
        print("   that day: \(gone.joined(separator: " "))")
        print("   \(model.rawValue):" + String(repeating: " ", count: max(1, 9 - model.rawValue.count)) + new.joined(separator: " "))
    }
    print(String(format: "\nHISTORY %@: %d recordings, %.1f min of speech in %.1fs (%.0fx real time)", model.rawValue, audio.count, audioSecs / 60, workSecs, audioSecs / max(workSecs, 0.001)))
    print(String(format: "Same words as that day: %.1f%% (%d of %d). Identical recordings: %d of %d.", total == 0 ? 0 : Double(same) / Double(total) * 100, same, total, identical, audio.count))
    print("The app cuts long dictations at pauses and this run doesn't, so a few differences at the seams are expected even for the same model. Read the differing words: a better model fixes names and odd words; a worse one breaks ordinary ones.")
    exit(0)
}

// Warm-up so the first timing isn't paying for Neural Engine compilation.
if let first = files.first {
    _ = try await engine.text(samples: try converter.resampleAudioFile(URL(fileURLWithPath: first)), vocabulary: vocab)
}

if let rounds = stressRounds {
    // Meeting-shaped stress: two streams through PauseChunker at full speed, background chunks plus
    // interactive "snapshot" flushes at random moments, silence gaps like StreamClock padding.
    let a = try converter.resampleAudioFile(URL(fileURLWithPath: files[0]))
    let b = try converter.resampleAudioFile(URL(fileURLWithPath: files.count > 1 ? files[1] : files[0]))
    var calls = 0, chars = 0
    let t0 = Date()
    for round in 1...rounds {
        try await withThrowingTaskGroup(of: (Int, Int).self) { group in
            for (i, source) in [a, b].enumerated() {
                group.addTask {
                    let chunker = try await PauseChunker.make()
                    var n = 0, c = 0
                    var audio = source
                    if (round + i) % 3 == 0 { audio = [Float](repeating: 0, count: Int.random(in: 1000...80000)) + audio }
                    var pos = 0
                    var pending: [Task<String, Error>] = []
                    while pos < audio.count {
                        let step = Int.random(in: 300...6000)
                        let piece = Array(audio[pos..<min(pos + step, audio.count)])
                        pos += step
                        for chunk in try await chunker.append(piece) where chunk.hasSpeech {
                            pending.append(Task { try await engine.text(samples: chunk.samples, vocabulary: vocab, priority: .background) })
                        }
                        if Int.random(in: 0..<400) == 0, let tail = await chunker.flush(), tail.samples.count >= SpeechEngine.minimumSamples {
                            pending.append(Task { try await engine.text(samples: tail.samples, vocabulary: vocab, priority: .interactive) })
                        }
                    }
                    if let tail = await chunker.flush(), tail.samples.count >= SpeechEngine.minimumSamples {
                        pending.append(Task { try await engine.text(samples: tail.samples, vocabulary: vocab, priority: .interactive) })
                    }
                    for p in pending { let t = try await p.value; n += 1; c += t.count }
                    return (n, c)
                }
            }
            for try await (n, c) in group { calls += n; chars += c }
        }
        print("round \(round): \(calls) calls so far, \(chars) chars, \(Int(Date().timeIntervalSince(t0)))s")
    }
    print("STRESS OK: \(calls) transcriptions, no crash")
    exit(0)
}

if concurrent {
    // Every file at once, alternating priorities, like two meeting streams plus a dictation.
    let inputs = try files.map { try converter.resampleAudioFile(URL(fileURLWithPath: $0)) }
    let start = Date()
    let results = try await withThrowingTaskGroup(of: (Int, String, Double).self) { group in
        for (i, samples) in inputs.enumerated() {
            group.addTask {
                let t = Date()
                let text = try await engine.text(samples: samples, vocabulary: vocab, priority: i % 3 == 0 ? .interactive : .background)
                return (i, text, Date().timeIntervalSince(t))
            }
        }
        var out: [(Int, String, Double)] = []
        for try await r in group { out.append(r) }
        return out
    }
    let wall = Date().timeIntervalSince(start)
    let audio = inputs.reduce(0) { $0 + Double($1.count) } / 16_000
    let empty = results.filter { $0.1.isEmpty }.count
    print(String(format: "concurrent: %d requests, %.1fs audio, all done in %.2fs (%.0fx real time), %d empty results",
                 results.count, audio, wall, audio / wall, empty))
    let interactive = results.filter { $0.0 % 3 == 0 }.map(\.2), background = results.filter { $0.0 % 3 != 0 }.map(\.2)
    print(String(format: "  mean wait: interactive %.2fs, background %.2fs", interactive.reduce(0, +) / Double(max(1, interactive.count)),
                 background.reduce(0, +) / Double(max(1, background.count))))
    exit(0)
}

var totalHits = 0, totalTerms = 0
for path in files {
    let samples = try converter.resampleAudioFile(URL(fileURLWithPath: path))
    let start = Date()
    let raw = try await engine.text(samples: samples, vocabulary: vocab)
    let secs = Date().timeIntervalSince(start)
    let final = CleanVerbatim.apply(glossary.apply(raw))
    let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    let clip = clips[String(name.split(separator: "_").first ?? "")] ?? clips[name.components(separatedBy: "__").first ?? ""]
    let terms = clip?.terms ?? []
    let missed = terms.filter { !final.contains($0) }
    totalHits += terms.count - missed.count; totalTerms += terms.count
    let audioSecs = Double(samples.count) / 16_000
    rows.append(Row(file: name, seconds: secs, audioSeconds: audioSecs, raw: raw, final: final, hits: terms.count - missed.count, terms: terms.count, missed: missed))
    print(String(format: "%-26@ %5.2fs for %4.1fs audio  terms %d/%d  missed %@", name, secs, audioSecs, terms.count - missed.count, terms.count, missed.description))
    print("   raw:   \(raw)")
    print("   final: \(final)")
}
print(String(format: "TOTAL terms %d/%d  resident %.2f GB", totalHits, totalTerms, mem()))
if let jsonPath {
    let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted]
    try enc.encode(rows).write(to: URL(fileURLWithPath: jsonPath))
}
