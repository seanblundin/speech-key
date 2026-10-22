import Foundation
import FluidAudio
import SpeechEngine

// engine-bench: runs the real engine pipeline on audio files and reports speed and glossary hits.
//
// Usage: engine-bench [--model ultra|v3|v2] [--no-boost] [--glossary glossary.md] [--clips clips.json] [--json out.json] file.wav...
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
                        if Int.random(in: 0..<400) == 0, let tail = chunker.flush(), tail.samples.count >= SpeechEngine.minimumSamples {
                            pending.append(Task { try await engine.text(samples: tail.samples, vocabulary: vocab, priority: .interactive) })
                        }
                    }
                    if let tail = chunker.flush(), tail.samples.count >= SpeechEngine.minimumSamples {
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
