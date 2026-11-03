# Vision

Read this before anything else. It explains why this project exists and what it should feel like. Every
decision, technical or not, should be checked against it. Technical choices live in [DESIGN.md](DESIGN.md).

The app is called **Loam**.

## In one sentence

A simple, beautiful Markdown notebook that anyone can turn into the exact tool they need, by adding bricks written
by the community or by their own AI agent.

## Why this exists

Note-taking apps today force a choice.

- The simple ones (Bear, Apple Notes) are a joy to use, but you hit a wall the day you need something more: a
  mindmap, a project board, a habit tracker, a meeting recorder. You either leave or you live without.
- The powerful ones (Notion, Craft, Obsidian) can do almost anything, but they are heavy. They ask you to learn a
  system, they lock your content in their own formats or their cloud, and they bolt features on until the app
  is no longer simple.

At the same time, something fundamental changed. In 2026, an AI agent can write a small piece of software in
minutes. The scarce thing is no longer the ability to build a feature. It is a place where that feature can live
safely, simply, and be shared. Notes apps were not designed for that. This one is.

We want the simplicity of Bear with the unlimited reach of a platform, where the user does not wait for the
company to build what they need.

## Who it is for

- **Everyone who writes.** Someone who only wants to jot down a thought should find a calm, fast, obvious app, and
  never see anything they did not ask for.
- **People who like to shape their tools.** They add a brick, change it, share it. They do not need to be
  programmers: they describe what they want to their AI agent and the app grows.
- **People who care about owning their data.** Their notes are plain files on their own machine, readable forever,
  by any tool, with or without us.

We start by building it for ourselves. If it is good for us, it will be good for others.

## The promise

1. **Simple on day one.** Open it, write, done. No setup, no account, no tutorial, no clutter.
2. **Yours, forever.** Everything is plain Markdown in a normal folder on your computer. You can leave at any
   moment, taking everything with you, with nothing to convert. Nothing is locked, nothing depends on our servers.
   The folder carries the whole app: notes, folders, plugins, themes and settings. Copy it to another computer and
   your notebook is there, exactly as you shaped it.
3. **As powerful as you want.** Need a mindmap? Add it. A board for a project? Add it. A meeting recorder like
   Granola, a habit tracker, a dashboard? Add it. The app becomes the tool you need, and only that tool.
4. **Built for your AI agent.** Your agent understands the app as well as you do. It can read your notes, work in
   them, and build new bricks for you. You never fight the tool to make it work with AI.
5. **Fast and calm.** It opens instantly, never lags, never nags. It feels native to the machine it runs on.

## What it feels like

Opening the app feels like opening a clean sheet of paper. You write in plain text, and it looks good as you
type: headings look like headings, lists look like lists. A short command menu helps you if you do not remember
how to format something, so you never have to learn symbols.

Behind that calm surface, the app can be anything. Install a plugin and a new capability appears, as if it had
always been there. Remove it and it is gone, leaving no trace. You can run a note-taker, a project tracker, or
a meeting archive on the same simple base, and each person's app ends up different.

## One base, many tools

With the right bricks, the same notebook becomes a mindmap tool, a map of your whole vault, a daily journal with a
calendar, a habit tracker, a goal and project tracker, a task list, a Kanban board. Folders and sub-folders hold
notes as you like. Cmd+P finds any action, Cmd+O any note. Notes open in tabs, and you drag one next to another to
see them side by side. All of this, and still a calm, simple app for the person who only wants to write.

## Everything is a plugin

This is the heart of the product, not a technical detail. The architecture is what wins or loses the project: if
"everything is a plugin" stays clean as the bricks multiply, everything else follows. So it comes first, before any
single feature. Nothing we build is final: when we learn that a part of the structure is wrong, we rebuild it.

- The base app is deliberately tiny. It is a notebook.
- Every capability beyond writing is a brick that plugs in: search, daily notes, backlinks, bases, mindmaps,
  canvases, a meeting recorder, importers, dashboards, trackers, even the editor itself.
- Our own features are built the same way as the community's. We eat our own cooking. If a plugin cannot do what
  our own feature does, the platform is not good enough yet.
- A plugin can be installed, disabled or removed at any time without damaging your notes.
- If something breaks, the app can start in a safe mode with only the essentials, so you are never locked out of
  your own writing.

## AI native

AI native does not mean an AI feature glued on top. It means the product is designed around the fact that agents
are now a normal way to work.

- **Your agent is a first-class user.** Whatever you can do in the app, your agent can do too, through the same
  actions. There is no second, weaker way for it.
- **Your agent is a builder.** Asking for a new capability should be as easy as describing it. The platform
  provides the building blocks, the conventions and the documentation so that an agent produces a good plugin on
  the first try. A plugin should be small enough to read in one sitting.
- **Plain, familiar formats.** We use conventions agents already know and avoid inventing our own. If an agent
  has never seen a format, we should not create it.
- **You stay in control.** The agent proposes, you decide. Changes to your notes are shown clearly before they
  are applied. Your data is always safe and recoverable.
- **Your choice of AI.** Any provider, or a model running on your own machine. We do not tie you to one.

## Community and open source

The long-term product is the community around the platform, more than any single feature we ship.

- The project is open source. The code, the plugin kit and the conventions are public.
- Anyone can write a plugin, and sharing it is easy. Over time there is a community place to discover plugins,
  with automatic checks on their code so that installing one feels safe.
- We start for ourselves, then open it to the world once it deserves it.
- The success of the project is measured by the plugins people create that we never imagined, not by what we
  built ourselves.

## Principles for every decision

1. **Simplicity wins.** When in doubt, remove. A feature that is not needed by everyone becomes a plugin.
2. **Your notes are sacred.** Never risk, lock or hide the user's content. Plain files, always.
3. **No proprietary formats.** Use what everyone, including AI agents, already understands.
4. **Plugins are equals.** Nothing we build is more privileged than what the community can build.
5. **Agents are users too.** If an action is possible for a person, it must be possible for an agent.
6. **Local first.** It works offline, on your machine, with no account. Anything online is a choice, never a
   requirement.
7. **Native and fast.** It should feel like it belongs on the device, and never feel heavy.
8. **Safe by default.** A bad plugin must never be able to destroy your writing. Always recoverable.
9. **Architecture first.** We never trade a clean structure for a quick feature. Anything can be rebuilt when we
   learn better.

## What we are not

- Not a Notion clone. We do not build a closed workspace with its own database and its own cloud.
- Not an Obsidian clone. We do not keep its compatibility as a goal; we start clean and offer an import.
- Not an all-in-one app that ships every feature. We ship a simple base and a platform to grow it.
- Not an AI product that happens to store notes. Notes come first, AI makes them more useful.
- Not a service. There is no account, no subscription needed to own your notes.

## The first chapters

1. **The notebook.** A beautiful, fast Markdown writing app for the Mac, with daily notes, links between notes,
   backlinks, and search that understands meaning. This alone should be a pleasure to use.
2. **The platform.** The plugin kit and the tools that let anyone, and any agent, add a brick. A first handful of
   small plugins proves it: a board, a habit tracker, an importer for notes coming from other apps.
3. **The assistant and the phone.** An AI assistant inside the app that works on your notes and builds
   plugins with you. The same notebook on iPhone.
4. **The big bricks.** Meeting recording and summaries, mindmaps, canvases, dashboards, all as plugins, proving
   that one simple base can become many different tools.
5. **The community.** A public place to share plugins, with automated safety checks. Later, other platforms.

## What success looks like

- A newcomer opens the app and, within a minute, is writing without help.
- Someone says to their agent "I want a reading tracker" and ten minutes later has one, in their own app, in
  their own notes.
- The community ships plugins faster than we could, and some of them surprise us.
- Years from now, every note ever written in the app is still a plain file that opens anywhere.

## Open questions for the founder

These are not decided. Answering them sharpens the vision.

1. **Who is the very first user beyond you?** A developer who already uses an agent, or a curious non-technical
   person? It changes how much we polish the first experience versus the platform.
2. **Business model.** Free and open source forever, or is there a paid layer (a hosted plugin store, sync,
   a managed AI)? Nothing in the vision requires money, but it shapes what we build first.
3. **The name.** Decided: Loam.
4. **iPhone.** Is the phone a full notebook with the same plugins, or a lighter companion first?
5. **Sharing between people.** Is collaboration ever part of the picture, or is this a personal tool by design?
