import Foundation

/// The LLM prompts, the default summary templates and the words written into notes, all in English (Muesli's, adapted
/// to Loam). The summary itself is written in the summary language whatever was spoken.
struct Prompts {
    // MARK: Speakers

    var speakers: String {
        """
        You receive the raw transcript of a meeting, split into audio segments transcribed separately.
        Each line is "[timestamp] label: text". Labels look like "<track><segment>:<n>" (e.g. "system0:1"): a speaker number <n> is ONLY valid within its segment — "system0:1" and "system1:1" may be two different people, and the same person has a different label in each segment.
        The label "me" is the user themself (their microphone): never group it with anyone.

        Your task: group the labels that belong to the same real person (continuity of topic, way of speaking, role, who answers whom, first names used), and guess each person's first name when the conversation reveals it (e.g. "thanks Paul", "over to you, Marie", someone introducing themselves). Never invent a name without evidence; leave "name" empty in that case.

        Reply ONLY with a JSON object:
        {"people":[{"name":"Paul","labels":["system0:0","system1:1"],"evidence":"short justification"}]}
        Every label (except "me") must appear in exactly one person.
        """
    }

    // MARK: Clean-up

    func clean(language: String) -> String {
        """
        You clean up an excerpt of an automatic meeting transcript.
        Each input line is "[timestamp] Name: text".

        Rules:
        - Keep the original language of what was said (\(language.isEmpty ? "do not translate" : "mostly \(language)")).
        - Fix obvious speech-recognition errors using the context (misheard words, words wrongly switched to another language, inconsistent proper nouns).
        - Remove hesitations, verbal tics (um, uh, like, you know…), false starts and repetitions, without changing the meaning or the tone.
        - Correct punctuation and capitalization; split into paragraphs when a turn is long.
        - Merge consecutive lines from the same person.
        - Do not summarize, do not comment, add nothing that was not said. Do not drop anything meaningful.
        - Keep the timestamp at the start of each turn and the name as is.

        Output format, nothing else (one blank line between turns):
        **[mm:ss] Name:** text
        """
    }

    // MARK: Summary

    private func hint(_ type: NoteType?) -> String {
        guard let type else { return "" }
        let hints: [NoteType: String] = [
            .idea: "This is not a meeting: the user is alone, developing an idea. Structure it, do not narrate the session.",
            .reading: "This is not a meeting: the user is alone, commenting on something they read (book, article). Keep their words and reactions, and separate what they retain from the source from what they think about it.",
            .dictation: "This is not a meeting: the user is dictating a text. The result is that text, cleaned up and ready to use, not a summary.",
            .lesson: "This is not a meeting: it is a class, a talk or a training. Keep what is taught, not the course of the session.",
        ]
        guard let hint = hints[type] else { return "" }
        return "\n" + hint
    }

    func summary(template: String, language: String, type: NoteType?) -> String {
        """
        You are the user's note-taking assistant. You write the summary of a meeting in \(language), in Markdown.\(hint(type))

        You receive:
        1. The RAW NOTES the user took during the meeting (with the time each line was written when known, and ⏱ markers for key moments). They show what matters to the user: they come first. Every point of the notes must appear in the summary, enriched and made precise with the transcript.
        2. The meeting TRANSCRIPT, with who said what.

        Rules:
        - Faithful to the transcript: no invented information. If something is uncertain, say so.
        - Attribute statements, decisions and actions to the right people (by name).
        - Tasks as "- [ ] Name — action (due date if mentioned)".
        - You may cite the timestamp of a key moment in parentheses, e.g. (12:03).
        - No frontmatter, no level-1 heading: start directly with the sections.
        - Concise and dense: no filler, no pleasantries.

        Requested structure:
        \(template.trimmed)
        """
    }

    // MARK: Journal, type, title, mind map

    func voice(language: String) -> String {
        """
        You turn the user's voice note (spoken journaling, ideas, things to do) into a bullet-journal entry, in \(language).

        Reply ONLY with a JSON object:
        {"title":"…","tldr":"…","tasks":[{"text":"…","done":false}],"events":["…"],"notes":["…"]}

        - title: 2 to 6 words, natural, the main topic (e.g. "Job interview prep", "Weekly review"). No date, no emoji.
        - tldr: one short sentence, the gist.
        - tasks: things to do; "done": true if the user says it is already done.
        - events: appointments, plans, deadlines; start with the time or date when it is said ("14:00 — call with Paul").
        - notes: ideas, observations, reflections, feelings; one short idea per item.
        - Highlight 1 to 3 truly important passages in total (decision, deadline, urgent task, blocker) by wrapping them in == (e.g. "==interview on Thursday=="). Never a whole sentence out of habit, never more than 3.
        - Short sentences, no bullet, no dash, no Markdown other than ==, no emoji. Keep the user's words (mixed languages included). Do not translate, invent nothing, add no advice.
        - Empty lists when nothing fits. No duplicate between tldr and notes when the note is very short: put it only in tldr.
        """
    }

    var kind: String {
        """
        You classify an audio recording made by the user into one of these types:
        - "meeting": a conversation with at least one other person (meeting, call, interview, discussion, appointment), even if the user talks a lot.
        - "journal": the user speaks alone about their life (journaling, review of the day, feelings, plans, to-do list, memo to self), even if they mention other people.
        - "idea": the user speaks alone to develop an idea (product, project, content, business), dig into it or structure it.
        - "reading": the user speaks alone about something they read or watch (book, article, podcast, video): what they retain and what they think of it.
        - "dictation": the user dictates a text meant to be written (email, post, document, message).
        - "lesson": a class, talk or training they listen to, with one main speaker teaching.
        You receive the duration, the number of voices detected automatically (indicative, sometimes wrong: one person can be counted twice) and the start of the transcript.
        Pick the most likely type; "confidence" goes from 0 to 1 (below 0.5 you really hesitate).
        Reply with a JSON object: {"type":…,"confidence":…,"reason":"short justification"}
        """
    }

    func title(language: String) -> String {
        "You give a title to a meeting from its summary. In \(language), 2 to 6 words, concrete (topic or project, not \"Meeting\"), no quotes, no date, no final punctuation. Reply with the title only."
    }

    func mindmap(language: String) -> String {
        """
        You turn a summary into a mind map, in \(language).
        Reply ONLY with a Markdown list of nested bullets (indent with tabs), no heading, no surrounding text.
        - 4 to 7 main branches (the big themes), each with 2 to 5 sub-points, 3 levels at most, 40 items in total.
        - Short items: 2 to 8 words, noun phrases, not sentences.
        - Faithful to the summary: invent nothing. Include a branch for decisions and one for actions if there are any.
        - No bold, no checkboxes, no links.
        """
    }

    // MARK: Labels of the user message

    var meetingLabel: String { "Meeting" }
    var durationLabel: String { "Duration" }
    var separator: String { ": " }
    var notesHeader: String { "=== RAW NOTES ===" }
    var noNotes: String { "(no notes)" }
    var voicesLabel: String { "Voices detected (≥ 10% of speaking time)" }

    // MARK: Templates

    /// The templates written into the templates folder the first time, in the order they are offered.
    var defaultTemplates: [(name: String, body: String)] {
        [
            ("General", """
            ## TL;DR
            3 to 5 sentences: the gist of the meeting and its outcome.

            ## Decisions
            The decisions made, with who drove them.

            ## Actions
            Tasks to do, one per line, as "- [ ] Name — action (due date)".

            ## Topics
            One sub-section (###) per topic, in the order of the meeting. Build on and complete the user's notes; add the important points they did not write down.

            ## Open questions
            What is still to be decided or clarified.
            """),
            ("1:1", """
            ## TL;DR
            2 to 3 sentences.

            ## Mood
            How the person is doing, weak signals, friction points.

            ## Topics discussed
            One bullet per topic with the gist of the exchange.

            ## Feedback
            Feedback given and received, both ways.

            ## Actions
            "- [ ] Name — action (due date)".

            ## For the next 1:1
            """),
            ("Idea", """
            ## TL;DR
            1 to 2 sentences: the idea.

            ## Problem or opportunity
            What it solves or opens up.

            ## Development
            A structured outline of the idea, as the user expressed it; fill in the logical links without inventing anything.

            ## Risks and questions
            Weak points, unknowns, objections.

            ## Next steps
            "- [ ] action".
            """),
            ("Reading", """
            ## Source
            The book, article or chapter being discussed (if named).

            ## What I retain
            Ideas, arguments and examples from the source.

            ## My take
            The user's reactions, agreements and disagreements.

            ## Quotes and passages
            Passages quoted or paraphrased.

            ## To dig into
            "- [ ] action" or questions.
            """),
            ("Dictation", """
            ## Text
            The dictated text, cleaned up: punctuation, tics removed, ideas and tone kept. No summary.

            ## Actions
            "- [ ] action", only if there are any.
            """),
            ("Lesson", """
            ## TL;DR
            3 to 5 sentences: the subject and what to remember.

            ## Outline
            The main parts in order, with the start timestamp when useful.

            ## Key concepts
            Short definitions of the important terms.

            ## Examples
            Examples and cases given.

            ## Review questions
            5 questions to check understanding.
            """),
        ]
    }

    /// The template a non-meeting type uses (a name of `defaultTemplates`, or a note of that name in the folder).
    func template(for type: NoteType) -> String? {
        let names: [NoteType: String] = [.idea: "Idea", .reading: "Reading", .dictation: "Dictation", .lesson: "Lesson"]
        return names[type]
    }

    // MARK: Words written into notes

    var meeting: String { "Meeting" }
    /// "Meeting on October 29": an untitled meeting's notes.
    func meeting(on date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.setLocalizedDateFormatFromTemplate("dMMMM")
        return "Meeting on \(formatter.string(from: date))"
    }
    var notesHint: String { "What you write here guides the meeting summary. Left empty, this note is deleted." }
    var journal: String { "Journal" }
    var memo: String { "Voice memo" }
    var summaryFile: String { "Summary" }
    var rawNotes: String { "Raw notes" }
    var audio: String { "Audio" }
    var mindmapLink: String { "Mind map" }
    var transcript: String { "Transcript" }
    func speaker(_ n: Int) -> String { "Speaker \(n)" }
}
