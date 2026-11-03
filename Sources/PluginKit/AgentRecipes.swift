import Foundation

/// How an agent makes each kind of note Loam shows specially, with the command that does it. Shared by
/// `loam guide recipes` and the Assistant's instructions, so both say the same thing. `loam` stands for the CLI's path.
public enum AgentRecipes {
    public static func text(cli loam: String = "loam") -> String {
        """
        Commands print JSON. `\(loam) list <word>` shows the commands matching a word, with their arguments;
        `\(loam) list --brief` lists them all, one line each.

        - Find: `\(loam) search.content q="…"` (full text), `search.names q=…` (titles), `search.meaning q=…`
          (by meaning); by property: `\(loam) query.run folder=… tag=…
          where='[{"key":"status","op":"equals","value":"Active"}]'` (op: equals, notEquals, contains, exists,
          missing, lessThan, greaterThan).
        - Tasks: `\(loam) tasks.list done=false dueBefore=YYYY-MM-DD`, `tasks.add path=… text="… 📅 YYYY-MM-DD !high"`,
          `tasks.toggle path=… line=… text=…`.
        - Daily note: `\(loam) daily.append text="…"`, `daily.read`.
        - Properties: `\(loam) query.set-property path=… key=… value=…` (value as JSON: `3`, `true`, `["a","b"]`;
          empty removes it). Keys are English, lower case (`status`, `due`, `tags`, `priority`).
        - Project with a Kanban: `\(loam) projects.new title=… due=YYYY-MM-DD`, then one card per task:
          `\(loam) projects.add-task project=… title=… status="To do|In progress|Done" due=…`. A card is a note in
          the project's folder; a `- [ ]` line in the project note is not a card.
        - Any other Kanban, table or gallery: a collection over a folder. `\(loam) collection.create folder=…`,
          `collection.add-view path=….base type=kanban`, `collection.new-entry path=….base title=… values='{"status":"To do"}'`.
        - Habit: `\(loam) habits.create name=…`, `habits.check name=… date=YYYY-MM-DD` (one call per day).
        - Meeting notes: `\(loam) meetings.new title=… participants="Ann, Bob" text="## Decisions …\\n## Actions\\n- [ ] …"`.
          An audio file: `meetings.import path=…` (paid transcription: ask first).
        - Mind map: a note whose frontmatter is `mindmap-plugin: basic`, then `# Central topic` and a nested `- `
          list (tab indented), one topic per item. It opens as a map.
        - Board (whiteboard, flow, slides): `\(loam) canvas.new title=…`, `canvas.add-node path=… text="…" near=<id>`,
          `canvas.connect path=… from=… to=… label=…`, `canvas.align`, `canvas.add-frame` for a slide.
        - Drawing (hand-drawn diagram): `\(loam) excalidraw.new title=…`, `excalidraw.add-shape path=… text=…
          type=rectangle|ellipse|diamond color=blue`, `excalidraw.connect path=… from=… to=… label=…`.
        - Diagram as text: a ```mermaid block in a note.
        - Notes and folders: write the `.md` file; move with `\(loam) files.move from=… to=…` (keeps links), delete
          with `files.trash path=…` (never rm).
        """
    }
}
