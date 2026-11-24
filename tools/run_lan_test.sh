#!/usr/bin/env bash
# Run from any directory. Ctrl-C stops the foreground remote Godot process.
set -euo pipefail
remote=${1:?Usage: tools/run_lan_test.sh [user@]host [port]}
port=${2:-7777}
[[ $remote != -* && $remote =~ ^([a-zA-Z0-9_.-]+@)?[a-zA-Z0-9_.-]+$ ]] || exit 2
[[ $port =~ ^[0-9]{1,5}$ ]] && (( 10#$port >= 1 && 10#$port <= 65535 )) || exit 2
cd "$(dirname "$0")/.."
rsync -az --exclude='/.*' --exclude='/reports' --exclude='__pycache__' ./ "$remote:daedalion/"
printf 'After NET READY, join with: godot --path . -- --join %s --port %s\n' "${remote#*@}" "$port"
ssh -t "$remote" "cd ~/daedalion && nice -n 19 godot --headless --import && exec nice -n 19 godot --headless --path . -- --server --bind 0.0.0.0 --port $port"
