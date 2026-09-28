#!/usr/bin/env bash
# Print the next release version from the conventional commits since the last
# vX.Y.Z tag; print nothing when there is nothing new to release.
#
#   feat: ...                         -> minor (0.1.3 -> 0.2.0)
#   type!: ... / BREAKING CHANGE: ... -> major
#   anything else                     -> patch
#
# With no release tag yet, the source version (AureVersion.source) is the base.
# Squash-merge bodies ("* feat: ...") count too; merge commits are skipped.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
root="$AURE_ROOT"

# Pre-release tags (v0.1.0-preview.1) are not a base for the next version.
last="$(git -C "$root" describe --tags --abbrev=0 --match 'v[0-9]*.[0-9]*.[0-9]*' --exclude '*-*' 2>/dev/null || true)"
if [ -n "$last" ]; then
  base="${last#v}"
  range="$last..HEAD"
else
  base="$(sed -n 's/.*source = "\(.*\)".*/\1/p' "$root/Packages/AureKit/Sources/AureCore/AureCore.swift")"
  range="HEAD"
fi

log="$(git -C "$root" log --no-merges --format='%s%n%b' "$range")"
[ -n "$log" ] || exit 0

IFS=. read -r major minor patch <<<"$base"
prefix='^(\* )?'
if grep -qE "${prefix}[a-z]+(\([^)]*\))?!:|${prefix}BREAKING[ -]CHANGE:" <<<"$log"; then
  echo "$((major + 1)).0.0"
elif grep -qE "${prefix}feat(\([^)]*\))?:" <<<"$log"; then
  echo "$major.$((minor + 1)).0"
else
  echo "$major.$minor.$((patch + 1))"
fi
