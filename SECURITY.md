# Security

Loam reads and writes plain files on your Mac and loads plugins as native code. Please report a vulnerability
privately through GitHub's "Report a vulnerability" (Security tab of this repository), not in a public issue.
You get an answer within a week.

## What Loam promises

- A note changes only when you, or a plugin you turned on, change it.
- A vault's own plugins (`.loam/plugins/`) run native code with your rights. They start only once you turned them on
  in Settings › Plugins or with `loam plugin enable` on this Mac, for this vault: a vault you receive (a zip, a clone,
  a shared folder) never runs its plugins on opening, whatever its `.loam/config.json` says.
- A symbolic link inside a vault is followed only while it leads to a place inside the vault.
- The debug control socket, which `scripts/loam-ctl` drives, exists only in debug builds and builds made with
  `LOAM_AGENT_BRIDGE`.

## Known limits

- Turning a plugin on trusts the code in its folder; a later change to that folder is not checked again.
