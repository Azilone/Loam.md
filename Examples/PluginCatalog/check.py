#!/usr/bin/env python3
"""Checks index.json, the Loam plugin catalog: run by CI on every pull request, and by hand with `python3 check.py`.

For every version of every plugin: the tag exists in the repository, points to the pinned commit, and the
plugin.json there has the plugin's id, the version's version and the permissions the catalog lists.
"""
import json
import re
import subprocess
import sys
import tempfile

ID = re.compile(r"^[a-z][a-z0-9.-]*$")
VERSION = re.compile(r"^\d+(\.\d+){0,3}$")
COMMIT = re.compile(r"^[0-9a-f]{40}$")
SDK = re.compile(r"^\d+\.\d+$")


def git(*args, cwd=None):
    return subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True).stdout.strip()


def main(path="index.json"):
    with open(path) as file:
        catalog = json.load(file)
    problems = []
    seen = set()
    for plugin in catalog.get("plugins", []):
        pid = plugin.get("id", "")
        where = f"plugin {pid or '?'}"
        if not ID.match(pid):
            problems.append(f"{where}: id must be lowercase letters, digits, '-' and '.'")
        if pid in seen:
            problems.append(f"{where}: listed twice")
        seen.add(pid)
        for key in ("name", "repo"):
            if not plugin.get(key):
                problems.append(f"{where}: no {key}")
        if not plugin.get("repo", "").startswith("https://"):
            problems.append(f"{where}: repo must be an https URL")
        versions = plugin.get("versions") or []
        if not versions:
            problems.append(f"{where}: no versions")
        for version in versions:
            label = f"{where} {version.get('version', '?')}"
            before = len(problems)
            if not VERSION.match(version.get("version", "")):
                problems.append(f"{label}: version must be numbers, like 1.2.0")
            if not COMMIT.match(version.get("commit", "")):
                problems.append(f"{label}: commit must be a full 40-character sha")
            if version.get("minSDK") and not SDK.match(version["minSDK"]):
                problems.append(f"{label}: minSDK must look like 1.12")
            if len(problems) > before or not plugin.get("repo", "").startswith("https://"):
                continue
            with tempfile.TemporaryDirectory() as folder:
                try:
                    git("clone", "-q", "--depth", "1", "--branch", version["tag"], "--", plugin["repo"], folder)
                except subprocess.CalledProcessError as error:
                    problems.append(f"{label}: cannot clone tag {version['tag']}: {error.stderr.strip()}")
                    continue
                commit = git("rev-parse", "HEAD", cwd=folder)
                if commit != version["commit"]:
                    problems.append(f"{label}: tag {version['tag']} is {commit}, not {version['commit']}")
                try:
                    with open(f"{folder}/plugin.json") as file:
                        manifest = json.load(file)
                except (OSError, ValueError) as error:
                    problems.append(f"{label}: no readable plugin.json: {error}")
                    continue
                if manifest.get("id") != pid:
                    problems.append(f"{label}: plugin.json says id {manifest.get('id')!r}")
                if manifest.get("version") != version["version"]:
                    problems.append(f"{label}: plugin.json says version {manifest.get('version')!r}")
                if version.get("permissions") is not None and sorted(manifest.get("permissions", [])) != sorted(version["permissions"]):
                    problems.append(f"{label}: plugin.json asks for {manifest.get('permissions', [])}, the catalog lists {version['permissions']}")
    for problem in problems:
        print(problem)
    print(f"{len(seen)} plugins, {len(problems)} problems")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(*sys.argv[1:]))
