#!/usr/bin/env bash
# Installs the addon zip into the test project and runs its scripts headless
# A Windows Godot runs from WSL when its path ends in .exe
# Usage: bindings/godot/tests/run.sh <godot binary> <addon zip>
set -euo pipefail
godot=${1:?usage: run.sh <godot binary> <addon zip>}
zip=${2:?usage: run.sh <godot binary> <addon zip>}
project=$(cd "$(dirname "$0")/project" && pwd)
rm -rf "$project/addons" "$project/.godot"
python3 -m zipfile -e "$zip" "$project"
path=$project
if [[ $godot == *.exe ]]; then path=$(wslpath -w "$project"); fi

# the first import writes .godot/extension_list.cfg and exits with a restart request
timeout 300 "$godot" --headless --path "$path" --import || true
timeout 300 "$godot" --headless --path "$path" --import
timeout 300 "$godot" --headless --path "$path" --script res://test.gd

out=$(timeout 300 "$godot" --headless --path "$path" --script res://wrong_argument.gd 2>&1) || true
if ! grep -q "after the wrong argument" <<<"$out" || ! grep -q "Cannot convert argument 1 from int to PackedByteArray" <<<"$out"; then
	echo "$out"
	echo "wrong argument check failed"
	exit 1
fi
echo "wrong argument check passed"
