import Foundation
import GooglyShared

/// Turns recorded audio into a proper transcript (with speaker labels) and keeps each session's
/// meeting notes as plain files any agent can read: ~/Documents/Bluey Notes/<date> <id>/.
enum MeetingNotes {
    static let model = "gpt-4o-transcribe-diarize"
    static let fallbackModel = "gpt-transcribe"

    static var root: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Bluey Notes", isDirectory: true)
    }

    struct Segment {
        var speaker: String
        var start: Double
        var end: Double
        var text: String
    }

    // MARK: Folders

    /// The session's folder, made the first time it's needed.
    static func folder(session: String, started: Date) -> URL {
        let fm = FileManager.default
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        writeReadmeIfNeeded()
        let tag = String(session.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(8)).lowercased()  // phone-supplied: no path characters
        guard !tag.isEmpty else { return root.appendingPathComponent("unknown", isDirectory: true) }
        // Match whole folders ending in " <tag>" only, so a short or odd id can't land in another session's folder.
        if let existing = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]))?
            .first(where: { $0.lastPathComponent.hasSuffix(" " + tag) && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }) {
            return existing
        }
        let name = DateFormatter.folderName.string(from: started) + " " + tag
        let url = root.appendingPathComponent(name, isDirectory: true)
        try? fm.createDirectory(at: url.appendingPathComponent("audio"), withIntermediateDirectories: true)
        return url
    }

    private static func writeReadmeIfNeeded() {
        let url = root.appendingPathComponent("README.md")
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        let text = """
        # Bluey Notes

        Meeting notes recorded by the Bluey app (the blueberry on the iPhone). One folder per listening \
        session, named by start time.

        In each session folder:
        - `notes.md`: the full transcript with timestamps and speaker labels, plus your questions to Bluey, \
        Bluey's replies and any research reports, in time order. Start here. A short summary is appended at \
        the end once the session is finished.
        - `summary.md`: the same summary on its own.
        - `session.json`: the same data, structured.
        - `audio/`: the raw recording, as five-minute AAC chunks.

        Speaker letters (A, B, …) are assigned per five-minute chunk, so the same letter can mean different people \
        in different chunks. Lines marked "(live)" are a rough live transcript for audio that hasn't been fully \
        transcribed yet.
        """
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: Transcription

    /// Saves the chunk's audio into the session folder and transcribes it.
    static func transcribe(audio: Data, session: String, index: Int, sessionStarted: Date) async throws -> (segments: [Segment], folder: URL) {
        let folder = folder(session: session, started: sessionStarted)
        let audioURL = folder.appendingPathComponent("audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: audioURL, withIntermediateDirectories: true)
        try audio.write(to: audioURL.appendingPathComponent(String(format: "chunk-%03d.m4a", index)))
        do {
            return (try await diarized(audio), folder)
        } catch {
            NSLog("Googly: diarized transcription failed (\(error)), trying \(fallbackModel)")
            return (try await plain(audio), folder)
        }
    }

    private static func diarized(_ audio: Data) async throws -> [Segment] {
        let json = try await post(audio, fields: ["model": model, "response_format": "diarized_json", "chunking_strategy": "auto"])
        let raw = (json["segments"] as? [[String: Any]] ?? []).map {
            Segment(speaker: $0["speaker"] as? String ?? "?", start: $0["start"] as? Double ?? 0,
                    end: $0["end"] as? Double ?? 0, text: ($0["text"] as? String ?? "").trimmingCharacters(in: .whitespaces))
        }
        // Join one speaker's consecutive pieces into a single turn.
        var turns: [Segment] = []
        for segment in raw where !segment.text.isEmpty {
            if var last = turns.last, last.speaker == segment.speaker, segment.start - last.end < 2.5 {
                last.text += " " + segment.text
                last.end = segment.end
                turns[turns.count - 1] = last
            } else {
                turns.append(segment)
            }
        }
        return turns
    }

    private static func plain(_ audio: Data) async throws -> [Segment] {
        let json = try await post(audio, fields: ["model": fallbackModel, "response_format": "json"])
        let text = (json["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? [] : [Segment(speaker: "?", start: 0, end: 0, text: text)]
    }

    private static func post(_ audio: Data, fields: [String: String]) async throws -> [String: Any] {
        guard let key = Keychain.get(.openai) else { throw RealtimeHost.TokenError.noKey }
        let boundary = "googly-\(UUID().uuidString)"
        var body = Data()
        for (name, value) in fields {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"chunk.m4a\"\r\nContent-Type: audio/mp4\r\n\r\n".data(using: .utf8)!)
        body.append(audio)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.upload(for: request, from: body)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RealtimeHost.TokenError.failed("transcription \(code) " + (String(data: data, encoding: .utf8) ?? ""))
        }
        return json
    }

    // MARK: Notes files

    /// Writes session.json and notes.md from the phone's copy of the session. Returns the folder.
    @discardableResult
    static func write(session json: [String: Any]) -> URL? {
        guard let id = json["id"] as? String, let startedAt = json["started"] as? Double else { return nil }
        let started = Date(timeIntervalSince1970: startedAt)
        let folder = folder(session: id, started: started)
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: folder.appendingPathComponent("session.json"), options: .atomic)
        }
        var notes = markdown(json, started: started)
        // A later sync rewrites notes.md from the phone's copy; keep the summary that was added after the session ended.
        if let summary = try? String(contentsOf: folder.appendingPathComponent("summary.md"), encoding: .utf8), !summary.isEmpty {
            notes += "\n## Summary\n\n" + summary + "\n"
        }
        try? notes.write(to: folder.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        summarizeSoon(json: json, folder: folder)
        return folder
    }

    /// Once a session has properly ended and nothing is left to transcribe, write a short summary
    /// (a few bullets + action items) into the folder as summary.md and tagged onto notes.md.
    /// Runs once per session, and only for transcripts worth summarizing.
    private static func summarizeSoon(json: [String: Any], folder: URL) {
        guard let id = json["id"] as? String, json["ended"] is Double else { return }
        guard (json["transcribing"] as? Int ?? 0) == 0 else { return }  // chunks still landing
        let lines = (json["entries"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
        let transcript = lines.joined(separator: "\n")
        guard transcript.count > 400 else { return }
        let done = UserDefaults.standard.array(forKey: "summarizedSessions") as? [String] ?? []
        guard !done.contains(id), !summarizing.contains(id) else { return }
        summarizing.insert(id)  // one attempt at a time; it's only recorded as done once the files are written
        Task { @MainActor in
            defer { summarizing.remove(id) }
            guard let key = Keychain.get(.openai) else { return }
            do {
                let summary = try await summarize(transcript: transcript,
                                                  started: Date(timeIntervalSince1970: (json["started"] as? Double) ?? 0),
                                                  name: json["name"] as? String, key: key)
                guard !summary.isEmpty else { return }
                try? summary.write(to: folder.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
                var finished = UserDefaults.standard.array(forKey: "summarizedSessions") as? [String] ?? []
                finished.append(id)
                UserDefaults.standard.set(finished, forKey: "summarizedSessions")
                writeActionItems(summary: summary, folder: folder)
                let notesURL = folder.appendingPathComponent("notes.md")
                if let notes = try? String(contentsOf: notesURL, encoding: .utf8), !notes.contains("## Summary") {
                    try? (notes + "\n## Summary\n\n" + summary + "\n").write(to: notesURL, atomically: true, encoding: .utf8)
                }
            } catch {
                NSLog("Googly: summary failed: \(error)")
            }
        }
    }

    // Touched only on the main thread (notes arrive there); marked so strict concurrency checking accepts it.
    nonisolated(unsafe) private static var summarizing: Set<String> = []

    private static func summarize(transcript: String, started: Date, name: String?, key: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60
        let title = name.map { " called '\($0)'" } ?? ""
        let body: [String: Any] = [
            "model": "gpt-4o-mini",
            "temperature": 0.3,
            "messages": [
                ["role": "system", "content": """
                Summarize this meeting transcript for its owner. Reply with exactly two short sections:
                **What happened** (up to 4 bullets, plain sentences) and **Action items** (bullets, or "None").
                Speaker letters per five-minute chunk may not match across chunks — don't over-trust them.
                Write the summary in the language the transcript mostly uses (Arabic stays Arabic), keeping the two English section titles.
                """],
                ["role": "user", "content": "Meeting\(title), started \(started.formatted()):\n\n\(String(transcript.prefix(28000)))"],
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let content = (choices.first?["message"] as? [String: Any])?["content"] as? String else {
            throw NSError(domain: "Googly", code: 1, userInfo: [NSLocalizedDescriptionKey: "OpenAI didn't answer"])
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func markdown(_ json: [String: Any], started: Date) -> String {
        let ended = (json["ended"] as? Double).map { Date(timeIntervalSince1970: $0) }
        let entries = json["entries"] as? [[String: Any]] ?? []
        let pending = json["transcribing"] as? Int ?? 0
        let name = json["name"] as? String
        let day = DateFormatter()
        day.dateStyle = .full
        day.timeStyle = .short
        let clock = DateFormatter()
        clock.dateFormat = "h:mm:ss a"

        var out = ["# \(name ?? "Bluey session"): \(day.string(from: started))", ""]
        if let ended {
            let minutes = Int(ended.timeIntervalSince(started) / 60)
            out.append("Ended \(clock.string(from: ended)) (\(minutes / 60)h \(minutes % 60)m).")
        } else {
            out.append("Still recording.")
        }
        if pending > 0 { out.append("\(pending) recording chunk(s) still being transcribed; this file updates when they're done.") }
        let asked = entries.filter { $0["kind"] as? String == "asked" }.count
        if asked > 0 { out.append("You asked Bluey \(asked) question(s); they're marked inline below.") }
        out += ["", "## Transcript", ""]

        // A held question is in both the recording and the live recognizer: show it once, as your question.
        let merged = TranscriptMerge.merge(entries.map {
            TranscriptMerge.Line(isTranscript: $0["kind"] as? String == "transcript", isAsked: $0["kind"] as? String == "asked",
                                 time: $0["time"] as? Double ?? 0, text: $0["text"] as? String ?? "")
        })
        for (index, entry) in entries.enumerated() where !merged.drop.contains(index) {
            let text = (entry["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let time = (entry["time"] as? Double).map { clock.string(from: Date(timeIntervalSince1970: $0)) } ?? ""
            if merged.asQuestion.contains(index) {
                out.append("> **[\(time)] You asked Bluey:** \(text)")
                out.append("")
                continue
            }
            switch entry["kind"] as? String {
            case "transcript":
                out.append("**[\(time)] Speaker \(entry["speaker"] as? String ?? "?"):** \(text)")
            case "heard":
                out.append("[\(time)] (live) \(text)")
            case "asked":
                out.append("> **[\(time)] You asked Bluey:** \(text)")
            case "reply":
                out.append("> **Bluey:** \(text)")
            case "report":
                let quoted = text.components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n")
                out.append("> **Research report:**\n" + quoted)
            default:
                out.append("[\(time)] \(text)")
            }
            out.append("")
        }
        return out.joined(separator: "\n")
    }
}

private extension DateFormatter {
    static let folderName: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm"
        return f
    }()
}
