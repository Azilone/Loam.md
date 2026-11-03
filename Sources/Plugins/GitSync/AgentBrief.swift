import Foundation

/// The one text a user pastes into an AI agent to connect it to the vault: what the vault is, the command that gives
/// the agent access (its own deploy key and, for an encrypted vault, the vault's key), how to work in it, and what
/// protects the vault. A secret: it holds the agent's access.
enum AgentBrief {
    static func text(repository: String, agent: String, encrypted: Bool, setup: String) -> String {
        let work = encrypted ? """
            The vault is encrypted on GitHub: use `loam` to sync, never plain git.
            - After each task, run: `loam --vault ~/vault sync.now`
            - Or keep it synced in the background: `loam --vault ~/vault sync.watch`
            - See where things stand: `loam --vault ~/vault sync.status`
            """ : """
            - Before a task: `cd ~/vault && git pull --rebase`
            - After each task: `git add -A && git commit -m "\(agent): <what changed>" && git pull --rebase && git push`
            - If the rebase stops on a conflict in a note, keep both versions' content, `git add` it and `git rebase --continue`.
            """
        let encryption = encrypted
            ? "The vault's encryption key is inside the command below. Do not print it, log it or share it."
            : "The vault is not encrypted: the repository holds the notes as they are."
        return """
            # Connect to a Loam vault

            You are being given access to a Loam vault: a folder of plain Markdown notes (CommonMark + GFM, YAML
            frontmatter) kept in the private GitHub repository \(repository). Every Mac and agent that uses the vault
            works on its own copy and syncs through that repository. You are the agent "\(agent)".

            ## 1. Connect (once)

            \(encryption)
            The command below is your access: run it exactly as it is, where you work (a shell with git and ssh), and keep
            it secret. It creates `~/vault`.

            ```sh
            \(setup)
            ```

            ## 2. Work in the vault

            - Edit and create `.md` files in `~/vault`. New notes go in `Inbox/` unless you were told where.
            - Use `[[Note name]]` for links between notes and `- [ ]` for tasks.
            - Never touch `.loam/cache/`, `.trash/` or `.git/`.
            \(work)

            ## 3. What to expect

            - Edits to different lines of a note merge by themselves. If you and someone else changed the same lines,
              your version stays and theirs is saved next to it as `Note (conflict <device> <date>).md`: open both, merge
              them by hand, delete the copy.
            - One sync commits at most 50 files; more pauses until `loam --vault ~/vault sync.now confirm=changes`.
              Deleting many files at once pauses the sync too. Stop and ask the user before confirming either.
            - History is never rewritten: no `reset --hard`, no force-push, no `git clean`.
            - The user sees "\(agent) changed N notes" on their Mac and can undo everything you did
              (`sync.undo device=\(agent)`), or remove your access at any time.
            - If a command fails or the sync says "needs attention", report the message to the user instead of working
              around it.
            """
    }
}
