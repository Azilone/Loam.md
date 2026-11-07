# Git sync

The `git-sync` plugin keeps a vault in sync with a git remote, usually a private GitHub repository, on its own. The
vault stays a plain git repository: Obsidian Git, a terminal or another Mac can use the same remote.

## Set up

In the app: Settings > Sync is a wizard, one screen at a time. **Connect GitHub** signs in with Loam's GitHub OAuth
app (device flow: a code, copied, to paste on the page it opens, then Authorize); **Encrypted** (the default) or
**Readable**; **Start Syncing** makes a private repository `loam-<folder>` on that account, if it is new, and syncs.
Encrypted, GitHub sees only scrambled files, and agents need Loam installed to read the notes. The token is kept in
the Keychain ("Loam GitHub") and given to git for github.com only, through the environment, never written to the
repository's config. "Use another server" takes any git address instead. From the command line, `sync.github` makes
`loam-<folder>` on the GitHub account this device is signed in to, if it is new, and syncs it, with the app's
sign-in or `LOAM_GITHUB_TOKEN`.

- **Another Mac:** on the first, Settings > Sync > Connect another Mac shows a code; on the second, Connect GitHub
  finds the repository and asks for that code (it carries the vault's key), or "I have a code from another Mac".
- **An AI agent:** Settings > Sync > Connect an AI agent, a name, Connect: Loam gives the agent a deploy key of its own
  on that repository. For a plain vault it shows the git commands to run once where the agent works (the key in
  `~/.ssh`, GitHub's host keys pinned, `git clone` into `~/vault`, commits under the agent's name); an agent that has
  GitHub access already (Claude Code, Codex) only needs the repository's name. For an encrypted vault it shows one
  line that installs Loam (below).

With another host, or a repository of your own:

```bash
loam --vault ~/MyVault sync.setup url=https://github.com/<you>/<vault>.git
```

`sync.setup` adds to what is there and never replaces it:

- runs `git init` if the vault is not a repository (`gitDir=<path>` keeps git's data outside the vault);
- adds `.loam/cache/`, `.DS_Store` and `.trash/` to `.gitignore`;
- sets a local git identity only if none exists;
- adds the remote (an existing remote with another address stops it);
- with `encrypt=true`, encrypts what goes to the remote from now on ([Encryption](#encryption));
- turns automatic sync on, and syncs once.

A vault that is already a repository with its remote (an Obsidian Git vault) only needs `sync.setup` from the command
line (it is not in the palette), or "Use another server" in Settings.
Turn Obsidian Git's automatic backup off on the same Mac first.

Loam uses the git installed on the Mac and its credentials (ssh keys, the osxkeychain helper, `gh auth`). It stores
no password or token, and it never prompts: missing credentials show as "Sync needs attention". The only secret it
keeps is an encrypted vault's key, in the Keychain.

## What a sync does

One cycle, never two at once, off the main thread:

1. Fetch the branch from the remote.
2. Save the unsaved typing of the notes the remote changed, so it is part of the merge.
3. Commit everything changed here: `vault backup: 2026-10-20 14:05:03 (<device>)`, Obsidian Git's format.
4. Merge the remote branch (a merge, never a rebase: history is never rewritten).
5. Push.

When it runs, while automatic sync is on:

| When | What |
|---|---|
| 30 s after the last change (`commitDelaySeconds`) | a cycle; at least every 5 min while changes keep coming |
| The app comes to the front | a cycle, if the remote was not checked in the last minute |
| Every 5 min while the app is in front (`pullIntervalMinutes`) | a cycle |
| The app is in the back | nothing, except a commit already pending |
| `sync.now`, or "Sync now" in the menu that a click on the status bar item opens | a cycle now |

Offline, commits keep happening here and the network rests 1, 2, 5, 10 then 30 min between attempts.

## Conflicts

Git merges edits to different lines of a note by itself. When both devices changed the same lines, or both sides
changed the same file in another way:

| Case | Result |
|---|---|
| Both changed the note (or both created it) | the note keeps this device's version; the other one is saved next to it as `Note (conflict <device> 2026-10-20).md` |
| One side deleted it, the other changed it | the changed file is kept |
| A binary file (an image) | same rules, whole files: `photo (conflict <device> 2026-10-20).png` |
| A note open with unsaved typing that differs from the merge | the editor keeps its text; the merged version is saved as a conflict copy |

Conflict copies are committed, so every device sees them; the status bar says "1 conflict", and a click opens a menu that lists the copy.
Merge it by hand and delete it. A file never gets conflict markers.

## Never destructive

- No `reset`, `clean`, `stash`, `rebase` or forced push, ever.
- A merge, rebase or cherry-pick started by another tool is left alone: `sync.resolve` finishes a merge the same way,
  only when asked.
- Deleting 50 files or more at once (and a quarter of the vault) pauses the sync until `sync.now confirm=deletions`.
- Files over 50 MB are left out of commits and listed.
- The first sync joins only a vault, an empty repository or a repository of notes. A codebase (Package.swift,
  package.json…), a repository mostly of other files, or one with other branches but not the vault's is refused before
  anything is merged or pushed; `sync.setup confirm=foreign-remote` goes ahead anyway.
- Before each merge the clone keeps where it stood (`refs/loam/before-merge`), and before it first joined a remote
  (`refs/loam/before-join`): `git reset --hard refs/loam/before-join` takes a join back. Never pushed.
- `.loam/cache/` never syncs, even when `.gitignore` does not list it (the clone's own `info/exclude` does).
- No fetch for over a day while offline shows as "Sync needs attention", so a sync can never stop silently.

## Settings and commands

Settings live in `.loam/config.json` and travel with the vault: `auto`, `remote` (`origin`), `branch` (empty: the
branch checked out), `commitDelaySeconds` (30), `pullIntervalMinutes` (5). The device name is per clone, in
`git config loam.device` (default: the computer's name), set by `sync.setup device=<name>`.

| Command | Does |
|---|---|
| `sync.setup` | sets the vault up and syncs once (`encrypt=true` to encrypt the remote; `key=`/`keyFile=` to join an encrypted one; `maxChanges=<n>` for an agent) |
| `sync.now` | syncs now (`confirm=deletions` for a mass deletion, `confirm=plain` for commits from before encryption, `confirm=plain-incoming` for notes that came unencrypted, `confirm=changes` over `loam.maxchanges`) |
| `sync.watch` | keeps a vault synced from a terminal or a service (`every=60`), for a server or an agent |
| `sync.undo` | takes back what one device or agent committed: `device=<name>`, optional `since=6h` |
| `sync.status` | where things stand, without changing anything (JSON) |
| `sync.enable`, `sync.disable` | automatic sync on or off |
| `sync.disconnect` | stops syncing and forgets the remote, to `sync.setup` another repository (Settings > Sync > Disconnect); files and history stay, nothing is deleted on the remote |
| `sync.resolve` | finishes a merge left by another tool, with conflict copies |
| `sync.key.export` | prints an encrypted vault's key, for another device (`file=<path>` writes it to a file instead) |
| `sync.key.import` | keeps that key on this device: `key=loam-key:…` or `file=<path>`; then syncs if automatic sync is on |
| `sync.key.rotate` | encrypts everything again with a new key; devices without it stop until they import it |
| `sync.protect` | adds the GitHub check that the remote holds only ciphertext (done by `sync.setup encrypt=true`) |
| `sync.leak.report` | lists commits that put a plain file on an encrypted remote |

## iCloud Drive

iCloud can damage a `.git` folder it syncs. In iCloud Drive, keep git's data outside the vault:
`sync.setup gitDir=~/.vault-git/<name>.git`, or `git init --separate-git-dir <path>` for an existing repository. The
vault then holds a `.git` file pointing there. The status warns when a `.git` folder sits inside iCloud Drive.

## Encryption

```bash
loam --vault ~/MyVault sync.setup encrypt=true
```

The remote then only holds ciphertext, while the vault on the Mac stays plain Markdown: GitHub, or whoever reads the
repository, sees file names, sizes and dates, not what the files say.

| What | Encrypted |
|---|---|
| Notes, attachments, `.loam/config.json`: every file's content | yes |
| `.gitattributes` and `.gitignore` (git reads them itself), `.github/` (GitHub reads it) | no |
| File and folder names, sizes, commit dates and messages ("vault backup: …") | no |
| The vault on each device | no, it stays plain |

How it works: a git filter. The vault's `.gitattributes` sends every file through `loam crypt`, which encrypts on
commit and decrypts on checkout (AES-256-GCM-SIV). The same file always gives the same bytes, so an unchanged file
is not a change and two devices agree on a merge; it also shows which files are identical. A merge driver decrypts
both versions, merges them with `git merge-file` and encrypts the result, so conflicts work as above: conflict
copies, never markers. Git runs `loam crypt` from the app (`Loam.app/Contents/Helpers/loam`) or the command line;
each clone's git config says where, and refuses to commit a file it cannot encrypt.

The key: 32 random bytes made by `sync.setup encrypt=true`, kept in the Keychain of each device ("Loam vault key"),
never in the vault or its settings. `.gitattributes` names it by an id (`# loam-crypt-key: 1a2b…`), which reveals
nothing about it.

### Another device

1. On a device that syncs: `sync.key.export file=~/Desktop/vault.key` (or `sync.key.export`, which prints it).
2. Bring the file to the new device (AirDrop), then: `sync.key.import file=~/Desktop/vault.key`. Delete the file.
3. Set the vault up as usual: `sync.setup url=…`.

Without the key, the new device shows "Sync needs attention" and changes nothing: no ciphertext lands in the vault and
nothing is committed. Importing the key resumes the sync. A clone made with plain `git clone` gets the ciphertext;
Loam decrypts its files in place once it has the key.

### Good to know

- Lose every copy of the key and the remote cannot be read again. The vaults on your devices stay plain: set up a new
  encrypted remote from one of them (below).
- Turning encryption on for a remote that already has commits encrypts what comes next; the commits already there
  stay readable. Commits made on a device before it switched, and not pushed yet (offline), wait: "Sync needs
  attention" until `sync.now confirm=plain` pushes them as they are. The same goes for a vault's own history
  joining an encrypted remote.
- For a remote with nothing readable: move the vault's `.git` folder aside (it keeps the old history), then
  `sync.setup url=<new, empty repository> encrypt=true`.
- The cost, measured on 1000 notes: nothing for a sync with no change, about 10–15 ms when files changed (git starts
  `loam crypt` once per command that reads them), a few hundred ms for a conflict. Turning encryption on takes about
  2 s, and a new device's first sync about 1 s.
- Obsidian Git, a phone, or an agent reading the repository without Loam only see ciphertext. A terminal on a Mac
  with Loam reads it: `git log -p` and `git diff` decrypt through the same filter.
- Changing the key is `sync.key.rotate` (above). Turning encryption off is not supported.

### A check on GitHub

`sync.setup encrypt=true` (or `sync.protect` for a vault encrypted before) adds `.github/workflows/loam-encrypted.yml`:
on every push, GitHub checks that each file starts like Loam ciphertext, reading only its first bytes. To refuse a
push that fails it, in the repository's Settings > Branches, protect `main`: require the check `encrypted`, and block
force pushes. Then a plain push never lands.

### Notes that came unencrypted

A clone without Loam's filter (an agent using plain git) commits files as they are. When such a file arrives, the
sync stops: "N files came from the remote unencrypted", with their names, before anything is merged.
`sync.now confirm=plain-incoming` takes them and pushes them back encrypted. A file whose ciphertext was changed by a
tool without the key also stops the sync, and nothing is merged: revert that commit (`git revert`) on any clone.

`sync.leak.report` lists the commits that hold such plain files. Taking them out of the remote's history rewrites it,
so Loam never does it itself: with [git filter-repo](https://github.com/newren/git-filter-repo), on a fresh mirror
clone, `git filter-repo --invert-paths --path <file>` for each file listed, then `git push --force`, then make each
device clone again (or `git fetch` and `git reset --hard origin/main` once its own changes are pushed). Anyone who
fetched before may still have the plain text.

### Agents on other machines

An agent on a server, in a cloud sandbox or in CI changes the vault through the repository, like another device. With
a plain vault, git is all it needs (above); it works like any git user (`git pull --rebase`, `git push`), and a note
it pushes with conflict markers shows as a warning on the Mac. With an encrypted vault it needs Loam: on the Mac,
Settings > Sync > Connect an AI agent shows a line to run where the agent works (Linux, amd64 or arm64):

```bash
curl -fsSL https://github.com/Azilone/loam-releases/releases/download/cli/install.sh | LOAM_CONNECT=loam-connect:… sh
```

It installs `loam` (no Swift needed; git, ssh, libcurl and libxml2 come from apt if missing) into `~/.local`, then
`sync.join` brings the vault to `~/vault`, decrypted. Keep `LOAM_CONNECT` as the agent's secret. After each task the
agent runs `loam --vault ~/vault sync.now`, or `loam --vault ~/vault sync.watch` runs as a service.

The connect code holds the repository, the agent's own SSH deploy key (this repository only; `ssh` checks GitHub's published
host keys) and the vault's key; `sync.join` keeps both keys in `~/.config/loam` (only the user can read it). From
the command line: `sync.connect agent=<name>` makes the code, `sync.agents` lists them.

What protects the vault from an agent:

- Its clone commits at most 50 files per sync (`maxChanges`): more pause until `sync.now confirm=changes`.
- Each sync on the Mac says who changed what ("research changed 4 notes", in the Sync menu).
- `sync.undo device=research since=6h` takes its changes back, with new commits.
- Remove (Settings > Sync, or `sync.agents agent=research remove=true`) deletes its deploy key: it can no longer fetch
  or push, and its next sync says so. The vault key stays, so the other agents go on; `sync.key.rotate` is there for
  a key that leaked some other way.
- The GitHub check, and the sync's own refusal of plain files, catch an agent that pushes without Loam.
- Loam's settings (`.loam/*.json`) merge key by key, so a device joining with its own defaults never overwrites the
  vault's values nor leaves a conflict copy.

`scripts/e2e-github.sh` runs all of this on the real GitHub (a Mac, a second Mac, an agent, plain pushes, broken
ciphertext, a killed sync, mass changes, undo, removal) and checks every clone for loss and corruption.


