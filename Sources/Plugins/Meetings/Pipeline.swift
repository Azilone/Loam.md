import Foundation
import PluginKit

/// What the pipeline needs from around it: where it is, who to ask.
struct PipelineHooks {
    var progress: (String) -> Void = { _ in }
    /// An `auto` recording is now known to be a meeting or a voice note: move it where it belongs.
    var relocate: (MeetingKind) throws -> Void = { _ in }
    /// Lets the user confirm or fix the names; nil to keep the model's.
    var askNames: (([Person], [Utterance]) async -> [Person])?
    /// The daily note's path for a date (`YYYY-MM-DD`).
    var dailyNotePath: (String) -> String? = { _ in nil }
}

public struct PipelineResult: Sendable {
    /// The note to open: the summary, or the daily note for a voice note.
    public var note: String
    public var cost: Double
}

/// After a recording: transcripts → type → speakers → clean transcript → summary or journal entry → title, mind map →
/// files. Every step reads what earlier steps left in `.raw/`, so running it again picks up where it stopped.
struct Pipeline {
    let vault: VaultAccess
    let ai: MeetingAI
    let settings: MeetingsSettings
    let box: StateBox
    let queue: TranscriptionQueue
    var hooks: PipelineHooks

    private var prompts: Prompts { settings.prompts }

    func run() async throws -> PipelineResult {
        let p = prompts
        var cost = 0.0
        func chat(_ model: String, _ system: String, _ user: String, json: Bool = false,
                  schema: [String: Any]? = nil, maxTokens: Int? = nil) async throws -> String {
            let reply = try await ai.chat(model: model, system: system, user: user, json: json, schema: schema, maxTokens: maxTokens)
            cost += reply.cost
            return reply.text
        }

        // 1. Finish the transcription, trying failed chunks once more.
        hooks.progress("Transcribing…")
        await queue.drain(retryErrors: true)
        var state = box.value
        if let failed = state.chunks.first(where: { $0.status != .done }) {
            let count = state.chunks.filter { $0.status != .done }.count
            throw AIError("\(count) segment(s) could not be transcribed: \(failed.error ?? "unknown error")", status: 0)
        }
        cost += state.chunks.reduce(0) { $0 + ($1.cost ?? 0) }
        let results: [(ChunkState, SttResult)] = try state.chunks.map { chunk in
            let data = try RawFolder.readData(vault, state.folder, "\(chunk.name).json")
            return (chunk, try JSONDecoder().decode(SttResult.self, from: data))
        }
        var utterances = Transcript.merge(results, micIsMe: state.micIsMe)
        guard !utterances.isEmpty else { throw NoSpeech() }

        // 2. A memo or a file from the inbox: what it is, from what was said.
        if state.kind == .auto {
            hooks.progress("Analyzing…")
            let found = await classify(utterances, duration: state.duration, chat: chat)
            try hooks.relocate(found.type.kind)
            box.update { state in
                state.noteType = found.type
                if found.type.hasOwnTemplate, let name = p.template(for: found.type) { state.template = name }
            }
            state = box.value
        }
        if state.noteType == nil {
            box.update { $0.noteType = $0.kind == .voice ? .journal : .meeting }
            state = box.value
        }
        let type = state.noteType ?? .meeting
        // Alone with the microphone: every voice is the user, even when a new run diarized it again.
        if type.isSolo { for i in utterances.indices { utterances[i].label = "me" } }

        // 3. Who is who.
        var people: [Person] = []
        if utterances.contains(where: { $0.label != "me" }) {
            hooks.progress("Speakers…")
            let reply = try? await chat(settings.llmModel, p.speakers, Transcript.rawLines(utterances).joined(separator: "\n"), json: true)
            people = Speakers.people(from: reply.flatMap(ModelReplies.json), utterances: utterances)
            if let ask = hooks.askNames { people = await ask(people, utterances) }
        }
        let names = Speakers.names(people, me: settings.myName, unnamed: p.speaker)
        box.update { $0.speakerNames = names }

        // 4. The clean transcript, three blocks at a time.
        hooks.progress("Transcript…")
        let blocks = Self.blocks(Transcript.rawLines(utterances, names: names), size: 14_000)
        let languageName = Locale(identifier: "en").localizedString(forLanguageCode: state.language) ?? state.language
        let cleanPrompt = p.clean(language: state.language.isEmpty ? "" : languageName)
        var cleaned = [String](repeating: "", count: blocks.count)
        var next = 0
        while next < blocks.count {
            let batch = Array(next..<min(blocks.count, next + 3))
            try await withThrowingTaskGroup(of: (Int, String, Double).self) { group in
                for i in batch {
                    group.addTask { [ai, settings] in
                        let reply = try await ai.chat(model: settings.llmModel, system: cleanPrompt, user: blocks[i],
                                                      json: false, schema: nil, maxTokens: nil)
                        return (i, reply.text, reply.cost)
                    }
                }
                for try await (i, text, price) in group {
                    cleaned[i] = text.trimmed
                    cost += price
                }
            }
            next += batch.count
        }
        let transcript = cleaned.joined(separator: "\n\n")
        let writer = MeetingWriter(vault: vault, prompts: p)

        if state.kind == .voice {
            hooks.progress("Journal…")
            let reply = try await chat(settings.llmModel, p.voice(language: settings.summaryLanguage), transcript, json: true)
            let daily = try writer.writeVoiceNote(state: box.value, transcript: transcript, entry: ModelReplies.journalEntry(reply),
                                                  dailyPath: hooks.dailyNotePath(Self.day(state.startDate)))
            box.update {
                $0.status = .done
                $0.error = nil
            }
            return PipelineResult(note: daily, cost: cost)
        }

        // 5. The summary, around the user's notes.
        hooks.progress("Summary…")
        let notesPath = state.notesPath
        let notes = vault.exists(notesPath) ? MeetingWriter.userNotes((try? vault.read(notesPath)) ?? "") : ""
        if notes.isEmpty, vault.exists(notesPath) {
            // Nothing was written: the note goes to the trash rather than staying next to the summary.
            let name = ((notesPath as NSString).lastPathComponent as NSString).deletingPathExtension
            try? vault.move(notesPath, to: ".trash/\(name) \(Int(Date().timeIntervalSince1970)).md")
        }
        let template = templateText(state.template)
        let participants = Self.unique(utterances.compactMap { names[$0.label] })
        let date = DateFormatter.localizedString(from: state.startDate, dateStyle: .full, timeStyle: .short)
        let input = [
            "\(p.meetingLabel)\(p.separator)\(state.title)",
            "Date\(p.separator)\(date)",
            "\(p.durationLabel)\(p.separator)\(Int((state.duration / 60).rounded())) min",
            "Participants\(p.separator)\(participants.joined(separator: ", "))",
            "",
            p.notesHeader,
            notes.isEmpty ? p.noNotes : Self.annotate(notes, times: state.noteTimes),
            "",
            "=== TRANSCRIPT ===",
            transcript,
        ].joined(separator: "\n")
        let summary = try await chat(settings.llmModel, p.summary(template: template, language: settings.summaryLanguage, type: type), input)

        // 6. Title, mind map, files.
        if state.autoTitle == true {
            hooks.progress("Title…")
            if let reply = try? await chat(settings.llmModel, p.title(language: settings.summaryLanguage), String(summary.prefix(4000)), maxTokens: 40) {
                let title = ModelReplies.title(reply)
                if !title.isEmpty { try? rename(to: title) }
            }
        }
        var mindmap = ""
        if settings.mindmap, type != .dictation {
            hooks.progress("Mind map…")
            if let reply = try? await chat(settings.llmModel, p.mindmap(language: settings.summaryLanguage),
                                           "\(box.value.title)\n\n\(summary.prefix(12_000))", maxTokens: 1500) {
                mindmap = ModelReplies.mindmap(title: box.value.title, reply: reply)
            }
        }
        hooks.progress("Notes…")
        let summaryPath = try writer.writeMeeting(state: box.value, transcript: transcript, summary: summary.trimmed,
                                                  participants: participants, mindmap: mindmap)
        box.update {
            $0.status = .done
            $0.error = nil
        }
        return PipelineResult(note: summaryPath, cost: cost)
    }

    struct NoSpeech: Error, LocalizedError {
        var errorDescription: String? { "No speech was heard in this recording." }
    }

    private func classify(_ utterances: [Utterance], duration: Double,
                          chat: (String, String, String, Bool, [String: Any]?, Int?) async throws -> String) async
        -> ModelReplies.Classification {
        var talk: [String: Double] = [:]
        for u in utterances { talk[u.label, default: 0] += max(0, u.end - u.start) }
        let total = max(1, talk.values.reduce(0, +))
        let voices = talk.values.filter { $0 / total >= 0.1 }.count
        let p = prompts
        let input = "\(p.durationLabel)\(p.separator)\(Int((duration / 60).rounded())) min\n\(p.voicesLabel)\(p.separator)\(voices)\n\n"
            + String(Transcript.rawLines(utterances).joined(separator: "\n").prefix(8000))
        for strict in [true, false] {
            guard let reply = try? await chat(settings.classifier, p.kind, input, !strict,
                                              strict ? ModelReplies.classificationSchema : nil, nil) else { continue }
            if let found = ModelReplies.classification(reply), found.confidence >= ModelReplies.minimumConfidence { return found }
            break
        }
        return .init(type: voices >= 2 ? .meeting : .journal, confidence: 0, reason: "voice count")
    }

    /// The template's text: the note in the templates folder, else the built-in one of that name, else the first.
    func templateText(_ name: String) -> String {
        let path = "\(settings.templatesFolder)/\(name).md"
        if vault.exists(path), let text = try? vault.read(path) { return MeetingWriter.body(text) }
        let builtIn = prompts.defaultTemplates
        return builtIn.first { $0.name == name }?.body ?? builtIn[0].body
    }

    /// Renames the folder and the notes' heading after the model's title, keeping the date and time.
    private func rename(to title: String) throws {
        let safe = MeetingWriter.safeName(title)
        guard !safe.isEmpty else { return }
        let state = box.value
        let parent = VaultPath.directory(of: state.folder)
        let name = (state.folder as NSString).lastPathComponent
        let stamp = name.range(of: #"^\d{4}-\d{2}-\d{2} \d{4}"#, options: .regularExpression).map { String(name[$0]) } ?? ""
        let base = [stamp, safe].filter { !$0.isEmpty }.joined(separator: " ")
        let target = MeetingWriter.freePath(vault, parent.isEmpty ? base : "\(parent)/\(base)")
        try vault.move(state.folder, to: target)
        // The notes follow the meeting's new name, when they still have the one they were given.
        var notesFile = state.notesFile
        let given = MeetingWriter.notesTitle(state.title, date: state.startDate, prompts: prompts)
        if notesFile == "\(given).md", vault.exists("\(target)/\(given).md") {
            let name = MeetingWriter.notesTitle(safe, date: state.startDate, prompts: prompts)
            let path = "\(target)/\(name).md"
            if !vault.exists(path), (try? vault.move("\(target)/\(given).md", to: path)) != nil {
                notesFile = (path as NSString).lastPathComponent
                if let text = try? vault.read(path), text.hasPrefix("# \(given)\n") {
                    try? vault.write(path, "# \(name)\n" + text.dropFirst("# \(given)\n".count))
                }
            }
        }
        box.update {
            $0.folder = target
            $0.title = safe
            $0.autoTitle = false
            $0.notesFile = notesFile
        }
    }

    // MARK: Helpers

    /// Lines in blocks of about `size` characters.
    static func blocks(_ lines: [String], size: Int) -> [String] {
        var out: [String] = [], current: [String] = [], length = 0
        for line in lines {
            if length + line.count > size, !current.isEmpty {
                out.append(current.joined(separator: "\n"))
                current = []
                length = 0
            }
            current.append(line)
            length += line.count + 1
        }
        if !current.isEmpty { out.append(current.joined(separator: "\n")) }
        return out
    }

    /// The notes with the time each line was typed, for the summary prompt.
    static func annotate(_ notes: String, times: [String: Double]) -> String {
        notes.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            let key = String(line).trimmed
            guard !key.isEmpty, let time = times[key] else { return String(line) }
            return "[\(clock(time))] \(line)"
        }.joined(separator: "\n")
    }

    static func unique(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }

    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
