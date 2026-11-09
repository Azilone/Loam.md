# The installer wizard

Loam's Mac app is installed by `scripts/install.sh`, a shell script the user pipes into their terminal. The wizard is
the same thing as a native Mac app: a window that asks two questions, copies the app, links the command line and
opens the first vault.

## What it does

| Step | What happens |
|---|---|
| Welcome | What the user gets, and whether this Mac can run Loam (macOS 26, Apple silicon). |
| Destination | `/Applications` or `~/Applications`, and whether the `loam` command line is linked into `~/.local/bin`. |
| Your vault | Whether a vault folder is created, and where. |
| Installing | A running Loam is asked to quit, then the app is copied into place. |
| Ready | What was installed, and a button that opens Loam on the vault. |

The copy lands beside the old app and only then replaces it, so a failure never leaves a half-written `Loam.app`. The
quarantine flag a downloaded file carries is removed, or Gatekeeper would refuse Loam's own first launch.

## Building it

```bash
make installer               # Installer/build/Loam Installer.app, plus a zip and a dmg
scripts/build-installer.sh debug
```

The wizard is a package of its own (`Installer/`), like the app's executable (`App/Executable/`): it links nothing but
the system frameworks. `scripts/build-installer.sh` builds the app first (`scripts/build-app.sh`), then puts that
`Loam.app` in the wizard's bundle as `Contents/Resources/Payload/Loam.app` — the payload the wizard installs. The
installed copy keeps the signature `build-app.sh` gave it.

## In CI

`.github/workflows/macos-installer.yml` builds the wizard on `macos-26`, checks the bundle (the signature, the
wizard's executable, the payload, the command line and the SDK inside it) and uploads the zip and the dmg as a
workflow artifact. It runs on demand, on a pull request that touches the app or the wizard, and on a `v*` tag.

The artifact is a build, not a release: publishing it stays with `scripts/release.sh`, which owns the update feed and
the signatures the installed app trusts.

## What it does not do

The wizard installs the app it carries. It does not update Loam: once installed, the app updates itself (docs/UPDATES.md).
It does not install what the plugins need (`git`, `ffmpeg`, `webp`): Loam asks for those from Settings > Plugins >
Dependencies, with `scripts/install-dependencies.command`.
