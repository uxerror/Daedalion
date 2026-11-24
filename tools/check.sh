#!/usr/bin/env bash
# Run every check CI runs: gdlint/gdformat (baseline), Godot warnings, gdUnit4
# tests and a smoke run of the demo scenes.
#
# Usage: tools/check.sh [lint|warnings|tests|smoke ...]   (default: all)
# Env:   GODOT_BIN (default: godot), NICE (default: "nice -n 19"; set NICE= in CI)
#
# Needs: godot 4.7.x, python3, and uv (uvx) or gdtoolkit==4.5.0 installed.
set -uo pipefail

cd "$(dirname "$0")/.."
GODOT_BIN="${GODOT_BIN:-$(command -v godot)}"
export GODOT_BIN
NICE="${NICE-nice -n 19}"
STEPS=("$@")
[ ${#STEPS[@]} -eq 0 ] && STEPS=(lint warnings tests smoke)
SMOKE_SCENES=(
	res://addons/cogito/DemoScenes/COGITO_0_MainMenu.tscn
	res://addons/cogito/DemoScenes/COGITO_3_Lobby.tscn
	res://addons/cogito/DemoScenes/COGITO_4_Laboratory.tscn
)

if command -v gdlint >/dev/null 2>&1; then
	PY=(python3)
else
	PY=(uvx -q --from gdtoolkit==4.5.0 python)
fi

failed=()

step_import() {
	# The first import of a fresh checkout prints font/theme errors; they are harmless.
	if [ ! -d .godot/imported ]; then
		echo "== import"
		$NICE "$GODOT_BIN" --headless --path . --import >/dev/null 2>&1
	fi
}

step_lint() {
	echo "== lint (gdlint + gdformat, baseline tools/lint_baseline.json)"
	"${PY[@]}" tools/lint.py
}

step_warnings() {
	echo "== Godot warnings (LSP, baseline tools/gd_warnings_baseline.json)"
	$NICE python3 tools/gd_warnings.py
}

step_tests() {
	echo "== gdUnit4 tests"
	# user:// (app_userdata/Daedalion) holds the real playtest saves:
	# run the tests against a throwaway user data dir.
	local data_home
	data_home=$(mktemp -d)
	XDG_DATA_HOME="$data_home" $NICE timeout 1200 bash addons/gdUnit4/runtest.sh --headless --ignoreHeadlessMode -a res://tests 2>&1 \
		| grep -vE '^\s*$' | grep -E 'FAILED|ERROR|Overall Summary|Exit code|Run tests ends|SCRIPT ERROR|Parse Error'
	local rc=${PIPESTATUS[0]}
	rm -rf "$data_home"
	return "$rc"
}

step_smoke() {
	echo "== smoke: demo scenes"
	local rc=0 scene out
	for scene in "${SMOKE_SCENES[@]}"; do
		out=$($NICE timeout 300 "$GODOT_BIN" --headless --path . "$scene" --quit-after 400 2>&1)
		# Leaks reported at exit are known and harmless; anything else fails.
		if grep -E 'SCRIPT ERROR|Parse Error|^ERROR' <<<"$out" \
			| grep -vE 'leaked at exit|still in use at exit|Pages in use exist at exit'; then
			echo "FAIL $scene"
			rc=1
		else
			echo "ok   $scene"
		fi
	done
	return $rc
}

step_import
for s in "${STEPS[@]}"; do
	if ! "step_$s"; then
		failed+=("$s")
	fi
done

if [ ${#failed[@]} -gt 0 ]; then
	echo "FAILED: ${failed[*]}"
	exit 1
fi
echo "ALL CHECKS PASSED"
