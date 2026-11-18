#!/usr/bin/env bash
# spine-csharp must parse and pose every corpus export like the native runtime
# Usage: oracle/csharp.sh <version>...
set -euo pipefail
[ $# -gt 0 ] || { echo "usage: csharp.sh <version>..." >&2; exit 2; }
source "$(dirname "$0")/lib.sh"

# These exports amplify rounding that differs between the runtimes
tolerance() {
	case "$1" in
	*\ tank/tank-pro.* | 3.5\ tank/tank.json | 3.6\ vine/vine-pro.*) echo "5e-3 5e-5" ;;
	3.5\ test/test.*) echo "3e-1 5e-5" ;;
	3.5\ stretchyman/stretchyman.json) echo "2e-3 5e-5" ;;
	4.[1-2]\ chibi-stickers/*) echo "5e-3 5e-5" ;;
	4.[0-3]\ raptor/raptor-pro.*) echo "1e-1 5e-5" ;;
	4.[2-3]\ celestial-circus/*) echo "1e-3 5e-5" ;;
	*) echo "5e-4 5e-5" ;;
	esac
}

# parsed <version> <dll> <atlas> compares one atlas
parsed() {
	local version=$1 dll=$2 atlas=$3 name
	name="$version $(basename "$(dirname "$atlas")")/$(basename "$atlas")"
	"$bin/oracle-$version" "$atlas" >"$tmp/cpp.txt" 2>"$tmp/err" && dotnet_to "$tmp/csharp.txt" "$dll" "$atlas" || {
		failed "$name"
		return 0
	}
	if diff "$tmp/cpp.txt" "$tmp/csharp.txt" >"$tmp/diff"; then
		pass=$((pass + 1))
	else
		echo "FAIL $name"
		sed -n '1,6s/^/  /p' "$tmp/diff"
		fail=$((fail + 1))
	fi
}

# posed <version> <dll> <input> compares the poses of one export
posed() {
	local version=$1 dll=$2 input=$3 dir atlas name
	dir=$(dirname "$input")
	# the corpus also holds older exports and non-skeleton json
	case "$("$bin/spine-converter" detect "$input" | cut -f3)" in
	"$version".*) ;;
	*)
		skipped=$((skipped + 1))
		return 0
		;;
	esac
	atlas=$(atlas_for "$dir") || atlas=$(synth_atlas "$input" "$version") || return 0
	name="$version $(basename "$dir")/$(basename "$input")"
	dump "$version" "$input" "$atlas" "$tmp/cpp.jsonl" && csharp "$dll" "$input" "$atlas" "$tmp/csharp.jsonl" || {
		failed "$name"
		return 0
	}
	check "$name" "$tmp/cpp.jsonl" "$tmp/csharp.jsonl" $(tolerance "$name")
}

declare -A dll
for version in "$@"; do
	project=Dump${version/./}
	dll[$version]=$(csharp_build "$project" "$project") || exit 1
done
for version in "$@"; do
	for atlas in "$root/testdata/corpus/$version"/*/*.atlas; do
		each parsed "$version" "${dll[$version]}" "$atlas"
	done
	for input in "$root/testdata/corpus/$version"/*/*.json "$root/testdata/corpus/$version"/*/*.skel; do
		each posed "$version" "${dll[$version]}" "$input"
	done
done
gather
echo "oracle csharp $*: $pass passed, $fail failed, $skipped skipped"
[ "$fail" -eq 0 ]
