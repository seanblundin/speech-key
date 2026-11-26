import Foundation

/// Turns "voice S2 spoke from 12.0 to 19.5" into names on transcript lines: "Me" for the voice
/// that matches the user's own voice, "Speaker 1", "Speaker 2"… for the rest.
public enum VoiceLabels {
    public static let me = "Me"
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

    /// A name for every voice. `order` is the voices as they first appear. `mine` is the user's own
    /// fingerprint, if known. `previous` is the names already given in this meeting with each one's
    /// fingerprint, so a voice keeps its number from one snapshot to the next.
    public static func names(order: [String], prints: [String: [Float]], mine: [Float]?,
                             previous: [String: [Float]] = [:]) -> [String: String] {
        var names: [String: String] = [:]
        // Me: the single clear match.
        if let mine {
            let scored = order.compactMap { v in prints[v].map { (v, similarity($0, mine)) } }.sorted { $0.1 > $1.1 }
            if let best = scored.first, best.1 >= mineAtLeast, scored.count < 2 || best.1 - scored[1].1 >= mineMargin {
                names[best.0] = me
            }
        }
        // Voices heard before keep their names: best matches first.
        var pairs: [(voice: String, name: String, score: Float)] = []
        for v in order where names[v] == nil {
            guard let p = prints[v] else { continue }
            for (name, old) in previous where name != me { pairs.append((v, name, similarity(p, old))) }
        }
        var taken = Set(names.values)
        for pair in pairs.sorted(by: { $0.score > $1.score }) where pair.score >= sameVoiceAtLeast {
            if names[pair.voice] == nil, !taken.contains(pair.name) { names[pair.voice] = pair.name; taken.insert(pair.name) }
        }
        // Everyone else gets the next free number, in the order they first spoke.
        var n = 1
        for v in order where names[v] == nil {
            while taken.contains("Speaker \(n)") { n += 1 }
            names[v] = "Speaker \(n)"
            taken.insert("Speaker \(n)")
        }
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
