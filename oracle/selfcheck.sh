#!/usr/bin/env bash
# Json and skel of one export must give the same poses
# Tolerance covers json decimal rounding, exports before 4.3 keep two decimals
# Usage: oracle/selfcheck.sh <version>...
set -euo pipefail
[ $# -gt 0 ] || { echo "usage: selfcheck.sh <version>..." >&2; exit 2; }
source "$(dirname "$0")/lib.sh"

# Json keys of the corpus that are stepped where the skel of the same export is linear
linear_in_skel() {
	local key
	case "$1" in
	"3.5 powerup/powerup")
		for key in star5/rotate/1 star5/scale/1 star5/translate/1 star6/rotate/1 star6/scale/1 star6/translate/1 star8/rotate/1 star8/scale/1 star8/translate/1 star9/rotate/1 star9/scale/1 star9/translate/1; do echo "animation/bones/$key"; done
		for key in star5/color/2 star6/color/2 star8/color/2 star9/color/1; do echo "animation/slots/$key"; done
		;;
	"3.6 powerup/powerup-"* | "3.7 powerup/powerup-"* | "3.8 powerup/powerup-"*)
		for key in star6/rotate/1 star6/scale/1 star6/translate/1 star8/rotate/1 star8/scale/1 star8/translate/1 star9/rotate/1 star9/scale/1 star9/translate/1; do echo "bounce/bones/$key"; done
		for key in star5/color/2 star6/color/0 star6/color/2 star8/color/2 star9/color/1; do echo "bounce/slots/$key"; done
		;;
	esac
}

# Pairs no key edit can align, each matched once with the skel values put into the json
known() {
	case "$1" in
	"3.5 tank/tank") echo "json beziers keep three decimals, drive treads drift 7 units" ;;
	"3.6 raptor/raptor-pro") echo "skel steps the second front-arm-goal ik key where json steps the first" ;;
	esac
}

# one <version> <json> compares the json and skel of one export
one() {
	local version=$1 json=$2 dir stem skel atlas name reason keys tolerance=(0.05 5e-3)
	[ "$version" = 4.3 ] || tolerance=(5 5e-2 5e-3)
	dir=$(dirname "$json")
	stem=$(basename "$json" .json)
	skel="$dir/$stem.skel"
	[ -f "$skel" ] || return 0
	atlas=$(atlas_for "$dir") || return 0
	name="$version $(basename "$dir")/$stem"
	reason=$(known "$name")
	if [ -n "$reason" ]; then
		echo "SKIP $name: $reason"
		skipped=$((skipped + 1))
		return 0
	fi
	keys=$(linear_in_skel "$name")
	if [ -n "$keys" ]; then
		linear_keys "$json" $keys >"$tmp/linear.json" || {
			failed "$name: known stepped keys changed"
			return 0
		}
		json="$tmp/linear.json"
	fi
	dump "$version" "$json" "$atlas" "$tmp/json.jsonl" && dump "$version" "$skel" "$atlas" "$tmp/skel.jsonl" || {
		failed "$name"
		return 0
	}
	if [ "${version%%.*}" -lt 4 ]; then
		common_skins "$tmp/json.jsonl" "$tmp/skel.jsonl" >"$tmp/common.jsonl"
		mv "$tmp/common.jsonl" "$tmp/json.jsonl"
	fi
	check "$name" "$tmp/json.jsonl" "$tmp/skel.jsonl" "${tolerance[@]}"
}

for version in "$@"; do
	for json in "$root/testdata/corpus/$version"/*/*.json; do
		each one "$version" "$json"
	done
done
gather
echo "oracle selfcheck $*: $pass passed, $fail failed, $skipped skipped"
[ "$fail" -eq 0 ]
