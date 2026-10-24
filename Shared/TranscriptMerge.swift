import Foundation

/// A question you hold the screen to ask is heard twice: by the meeting recorder (accurate, with a speaker label)
/// and by the live recognizer (rougher; it once heard "Open TextEdit" as Czech). This pairs them up so the notes
/// and the phone show it once, as your question, in the recorder's wording.
public enum TranscriptMerge {
    public struct Line {
        public var isTranscript: Bool
        public var isAsked: Bool
        public var time: Double
        public var text: String

        public init(isTranscript: Bool, isAsked: Bool, time: Double, text: String) {
            self.isTranscript = isTranscript
            self.isAsked = isAsked
            self.time = time
            self.text = text
        }
    }

    /// `asQuestion`: transcript lines to show as your question. `drop`: live question lines they replace.
    public static func merge(_ lines: [Line]) -> (asQuestion: Set<Int>, drop: Set<Int>) {
        var asQuestion = Set<Int>(), drop = Set<Int>()
        for (i, line) in lines.enumerated() where line.isTranscript {
            let spoken = words(line.text)
            guard spoken.count >= 3 else { continue }
            // Questions registered from just before this line started to a little after it (the live
            // recognizer reports when you let go, and may split one question into two).
            let nearby = lines.indices.filter {
                lines[$0].isAsked && !drop.contains($0)
                    && lines[$0].time >= line.time - 5 && lines[$0].time <= line.time + 25
            }
            guard !nearby.isEmpty else { continue }
            let asked = nearby.reduce(into: Set<String>()) { $0.formUnion(words(lines[$1].text)) }
            let covered = Double(spoken.filter(asked.contains).count) / Double(spoken.count)
            if covered >= 0.6 {
                asQuestion.insert(i)
                drop.formUnion(nearby)
            }
        }
        return (asQuestion, drop)
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}
