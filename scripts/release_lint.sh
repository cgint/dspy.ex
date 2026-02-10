#!/usr/bin/env bash
set -euo pipefail

# Small release hygiene checker.
# Ensures repo versioning artifacts are aligned before cutting/pushing a tag.

root="$(git rev-parse --show-toplevel)"
cd "$root"

if [[ ! -f VERSION ]]; then
  echo "ERROR: missing VERSION" >&2
  exit 1
fi

version="$(cat VERSION | tr -d '[:space:]')"
if [[ -z "$version" ]]; then
  echo "ERROR: VERSION is empty" >&2
  exit 1
fi

tag="v${version}"

echo "Version: ${version}"
echo "Tag: ${tag}"

echo

echo "Checking docs/RELEASES.md contains a row for ${tag}…"
release_row="| \`${tag}\` |"
if rg -n -F "$release_row" docs/RELEASES.md >/dev/null; then
  echo "OK: docs/RELEASES.md has ${tag}"
else
  echo "ERROR: docs/RELEASES.md missing ${tag} row" >&2
  exit 2
fi

echo

echo "Checking plan/STATUS.md log mentions Cut tag ${tag}…"
status_line="Cut tag \`${tag}\`"
if rg -n -F "$status_line" plan/STATUS.md >/dev/null; then
  echo "OK: plan/STATUS.md mentions Cut tag ${tag}"
else
  echo "WARN: plan/STATUS.md does not mention Cut tag ${tag} yet" >&2
fi

echo

echo "OK: release lint complete"
