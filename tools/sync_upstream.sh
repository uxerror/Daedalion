#!/usr/bin/env bash
# Sync the `upstream` branch of Daedalion with Cogito on Codeberg.
#
# Daedalion's history is a filtered copy of Cogito's (see README), so
# upstream commits cannot be merged directly. This script clones Cogito,
# runs the SAME git-filter-repo command that created Daedalion (the
# result is deterministic: already-imported commits keep their hashes),
# and fast-forwards the local `upstream` branch to the result.
#
# Usage: tools/sync_upstream.sh [cogito-branch]   (default: main)
# Then:  git switch main && git merge upstream
#
# Needs: git, uv (for `uvx git-filter-repo`) or git-filter-repo in PATH.
set -euo pipefail

UPSTREAM_URL="${UPSTREAM_URL:-https://codeberg.org/Phazorknight/Cogito.git}"
BRANCH="${1:-main}"
ROOT="$(git rev-parse --show-toplevel)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/daedalion-sync.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# Must stay identical to the command that created Daedalion,
# otherwise the commit hashes will not match.
FILTER_ARGS=(--invert-paths
	--path .tmp.driveupload
	--path .godot
	--force)

if command -v git-filter-repo >/dev/null 2>&1; then
	FILTER=(git-filter-repo)
else
	FILTER=(uvx git-filter-repo)
fi

# Unfiltered Cogito mirror, cached inside .git so only the first run
# downloads the full ~1.5 GiB history; later runs fetch new commits only.
CACHE="$(git rev-parse --absolute-git-dir)/cogito-upstream.git"
if [ ! -d "$CACHE" ]; then
	echo "First run: mirroring $UPSTREAM_URL (~1.5 GiB, one time)..."
	git init -q --bare "$CACHE"
fi
echo "Fetching $UPSTREAM_URL ($BRANCH)..."
git -C "$CACHE" fetch -q "$UPSTREAM_URL" "+refs/heads/$BRANCH:refs/heads/$BRANCH"

GIT_LFS_SKIP_SMUDGE=1 git clone -q --no-checkout --single-branch \
	--branch "$BRANCH" "$CACHE" "$WORK/cogito"

echo "Filtering history..."
(cd "$WORK/cogito" && "${FILTER[@]}" "${FILTER_ARGS[@]}" >/dev/null)

NEW="$(git -C "$WORK/cogito" rev-parse HEAD)"
git fetch -q "$WORK/cogito" "$NEW"

if git rev-parse -q --verify refs/heads/upstream >/dev/null; then
	OLD="$(git rev-parse upstream)"
	if ! git merge-base --is-ancestor "$OLD" "$NEW"; then
		echo "ERROR: filtered upstream does not contain the current 'upstream' ($OLD)." >&2
		echo "Cogito history was rewritten, or the filter arguments changed." >&2
		echo "Nothing was changed. New head is $NEW (in FETCH_HEAD)." >&2
		exit 1
	fi
	if [ "$OLD" = "$NEW" ]; then
		echo "upstream is already up to date ($NEW)."
		exit 0
	fi
	if [ "$(git symbolic-ref -q --short HEAD)" = "upstream" ]; then
		git merge -q --ff-only "$NEW"
	else
		git update-ref refs/heads/upstream "$NEW" "$OLD"
	fi
	echo "upstream: $OLD -> $NEW"
	git log --oneline "$OLD..$NEW"
else
	git update-ref refs/heads/upstream "$NEW"
	echo "upstream created at $NEW"
fi

echo
echo "Next: git switch main && git merge upstream"
