# Contributing

Thank you for helping. Loam is a small, local-first Markdown notebook where everything beyond writing is a plugin.

1. Read [docs/VISION.md](docs/VISION.md) and [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): new behaviour goes in a
   plugin, and `LoamCore` stays minimal.
2. Build and run on a test vault, never on your real notes: `make test-vault`, then `make run`.
3. Test: `make test-fast` while working, `make test` before opening a pull request.
4. UI changes follow [docs/DESIGN.md](docs/DESIGN.md) and [docs/design/MOTION.md](docs/design/MOTION.md); add a
   screenshot to the pull request.
5. Code, comments and docs are in English. Match the style of the code around your change.

Writing a plugin instead of changing Loam: [docs/WRITING-PLUGINS.md](docs/WRITING-PLUGINS.md).

Bugs and ideas go in GitHub issues; security reports follow [SECURITY.md](SECURITY.md).
