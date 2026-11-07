# Loam plugin catalog

The plugins anyone can install from Loam by id: `loam plugin install --catalog <id>`, or Settings > Plugins.
`index.json` is the whole catalog; Loam reads it from the main branch of
[Azilone/loam-community](https://github.com/Azilone/loam-community), which also lists community themes in `themes.json`
(see docs/THEMES.md in Loam).

## Add a plugin, or a new version

1. Tag the release in your plugin's repository: `version` in plugin.json, then `git tag v1.2.0 && git push --tags`.
2. Get the commit: `git rev-parse v1.2.0^{commit}`.
3. Open a pull request adding it to `index.json`:

```json
{
  "id": "word-count",
  "name": "Word Count",
  "description": "Counts the words of the open note.",
  "author": "your-github-name",
  "repo": "https://github.com/you/loam-word-count",
  "versions": [
    { "version": "1.2.0", "tag": "v1.2.0", "commit": "<40-character sha>", "minSDK": "1.12", "permissions": ["vault.read"] }
  ]
}
```

Add new versions to the end of `versions`; keep the old ones, so a Mac with an older Loam still finds one it can build.

## What is checked

`check.py` runs on every pull request: the tag exists, points to the pinned commit, and its plugin.json has the same
id, version and permissions. A reviewer reads the code before merging. Loam refuses any commit the catalog does not
pin, so a moved tag or a taken-over repository never installs.
