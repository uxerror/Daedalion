#!/usr/bin/env bash
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
godot=${GODOT_BIN:-godot}
version=$(nice -n 19 "$godot" --version | cut -d. -f1-4)
template="linux_release.x86_64"
dir="${XDG_DATA_HOME:-$HOME/.local/share}/godot/export_templates/$version"
# Distribution builds may install templates system-wide.
if [[ ! -r "$dir/$template" && ! -r "/usr/share/godot/export_templates/$version/$template" ]]; then
	echo "Install the Godot $version export templates ($dir/$template)." >&2
	exit 77
fi
output=$(realpath -m "${1:-$root/build/daedalion-server}")
mkdir -p "$(dirname "$output")"
# Godot reuses customized scenes from this cache even after the export plugin changes.
rm -rf "$root/.godot/exported"
nice -n 19 "$godot" --headless --path "$root" --export-release "Linux dedicated server" "$output"
