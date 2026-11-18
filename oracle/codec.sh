#!/usr/bin/env bash
# Converted data must give the poses of its source in the official runtime
# Usage: oracle/codec.sh <version>...
set -euo pipefail
[ $# -gt 0 ] || { echo "usage: codec.sh <version>..." >&2; exit 2; }
source "$(dirname "$0")/lib.sh"

# one <version> <skel> converts one export between its formats
one() {
	local version=$1 skel=$2 dir stem json atlas name step from to source_file target flag
	dir=$(dirname "$skel")
	stem=$(basename "$skel" .skel)
	json="$dir/$stem.json"
	[ -f "$json" ] || return 0
	atlas=$(atlas_for "$dir") || return 0
	name="$version $(basename "$dir")/$stem"
	dump "$version" "$skel" "$atlas" "$tmp/skel.jsonl" && dump "$version" "$json" "$atlas" "$tmp/json.jsonl" || {
		failed "$name"
		return 0
	}
	for step in "skel json" "json skel" "skel skel"; do
		read -r from to <<<"$step"
		source_file=$([ "$from" = skel ] && echo "$skel" || echo "$json")
		target="$tmp/out.$to"
		flag=$([ "$to" = json ] && echo --json || echo --binary)
		written "$source_file" "$target" "$flag" && dump "$version" "$target" "$atlas" "$tmp/out.jsonl" || {
			failed "$name $from to $to"
			continue
		}
		check "$name $from to $to" "$tmp/$from.jsonl" "$tmp/out.jsonl" 1e-5 1e-6
	done
}

for version in "$@"; do
	for skel in "$root/testdata/corpus/$version"/*/*.skel; do
		each one "$version" "$skel"
	done
done
gather
echo "oracle codec $*: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
