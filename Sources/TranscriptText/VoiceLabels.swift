import Foundation

/// Turns "voice S2 spoke from 12.0 to 19.5" into names on transcript lines: "Me" for the user's
/// own voice, "Speaker 1", "Speaker 2"… for everyone else, in the room or on the call.
public enum VoiceLabels {
    public static let me = "Me"
    public static let them = "Them"
    /// A voice is "Me" only when it matches the user's fingerprint this well, and clearly better
    /// than any other voice in the room. Measured 2026-11-26: Sean against Sean scored 0.98 in the
    /// same setting and 0.65 in another room; against four strangers, 0.17 at most.
    public static let mineAtLeast: Float = 0.5
    public static let mineMargin: Float = 0.15
    /// A voice keeps the name it had at the last snapshot when its fingerprint matches this well.
    public static let sameVoiceAtLeast: Float = 0.6

    /// For each line, the voice that overlaps it longest; nil where nobody was found speaking.
    public static func assign(lines: [(start: TimeInterval, end: TimeInterval)],
                              turns: [(voice: String, start: TimeInterval, end: TimeInterval)]) -> [String?] {
        lines.map { line in
            var overlap: [String: TimeInterval] = [:]
            for t in turns where t.end > line.start && t.start < line.end {
                overlap[t.voice, default: 0] += min(t.end, line.end) - max(t.start, line.start)
            }
            if let best = overlap.max(by: { $0.value < $1.value }) { return best.key }
            // Nobody found speaking during the line itself: the nearest voice within two seconds.
            let near = turns.map { (voice: $0.voice, gap: max($0.start - line.end, line.start - $0.end)) }.min { $0.gap < $1.gap }
            return near.flatMap { $0.gap <= 2 ? $0.voice : nil }
        }
    }

    /// One voice found in one of a meeting's two streams.
    public struct Voice: Sendable {
        public let id: String
        public let print: [Float]?
        /// From the mic (the room) rather than the computer's audio (the call).
        public let onMic: Bool
        public init(id: String, print: [Float]?, onMic: Bool) { self.id = id; self.print = print; self.onMic = onMic }
    }

    /// A name for every voice, the same way for every kind of meeting (Sean, 2026-11-26: "many
    /// voices via computer audio, many via in person"). `voices` are in the order they first spoke.
    ///
    /// - **Me** is the mic voice that clearly matches `mine`, the user's own fingerprint. With no
    ///   fingerprint, a mic with a single voice is the user.
    /// - A call with a single voice stays **Them**.
    /// - Everyone else is **Speaker 1, 2…** in the order they first spoke, whichever stream they
    ///   are on. A voice keeps its number from one snapshot to the next (`previous`: names already
    ///   given, with fingerprints), and a call voice the mic also picked up through the speakers
    ///   gets the same name on both.
    public static func names(voices: [Voice], mine: [Float]?, previous: [String: [Float]] = [:]) -> [String: String] {
        var names: [String: String] = [:]
        let mic = voices.filter(\.onMic), call = voices.filter { !$0.onMic }

        if let mine {
            let scored = mic.compactMap { v in v.print.map { (v.id, similarity($0, mine)) } }.sorted { $0.1 > $1.1 }
            if let best = scored.first, best.1 >= mineAtLeast, scored.count < 2 || best.1 - scored[1].1 >= mineMargin {
                names[best.0] = me
            }
        } else if mic.count == 1 {
            names[mic[0].id] = me
        }
        if call.count == 1 { names[call[0].id] = them }

        // A mic voice that is really a call voice coming out of the speakers takes that voice's name.
        var echoOf: [String: String] = [:]
        for v in mic where names[v.id] == nil {
            guard let p = v.print else { continue }
            let best = call.compactMap { c in c.print.map { (c.id, similarity(p, $0)) } }.max { $0.1 < $1.1 }
            if let best, best.1 >= sameVoiceAtLeast { echoOf[v.id] = best.0 }
        }

        // Voices heard before keep their numbers: best matches first.
        var pairs: [(voice: String, name: String, score: Float)] = []
        for v in voices where names[v.id] == nil && echoOf[v.id] == nil {
            guard let p = v.print else { continue }
            for (name, old) in previous where name.hasPrefix("Speaker ") { pairs.append((v.id, name, similarity(p, old))) }
        }
        var taken = Set(names.values)
        for pair in pairs.sorted(by: { $0.score > $1.score }) where pair.score >= sameVoiceAtLeast {
            if names[pair.voice] == nil, !taken.contains(pair.name) { names[pair.voice] = pair.name; taken.insert(pair.name) }
        }
        // Everyone else gets the next free number, in the order they first spoke.
        var n = 1
        for v in voices where names[v.id] == nil && echoOf[v.id] == nil {
            while taken.contains("Speaker \(n)") { n += 1 }
            names[v.id] = "Speaker \(n)"
            taken.insert("Speaker \(n)")
        }
        for (echo, source) in echoOf { names[echo] = names[source] }
        return names
    }

    /// Cosine similarity of two fingerprints: 1 is the same voice, around 0 is unrelated.
    public static func similarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in a.indices { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        let d = (na * nb).squareRoot()
        return d > 0 ? dot / d : 0
    }

    /// The same direction at length 1.
    public static func unit(_ v: [Float]) -> [Float] {
        let n = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return n > 0 ? v.map { $0 / n } : v
    }
}
