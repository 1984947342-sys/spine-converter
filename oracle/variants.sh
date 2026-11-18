#!/usr/bin/env bash
# Exports with one uncommon field must keep their poses wherever the source runtime loads them
# Variants that runtime refuses are skipped, the change of a failing variant is printed with it
# Rounding sensitive exports get the loose tolerance of oracle/migrate.sh
# Usage: oracle/variants.sh [variants per export] [exports per version] [version]...
set -euo pipefail
source "$(dirname "$0")/lib.sh"
per_export=${1:-20}
per_version=${2:-4}
shift $(($# < 2 ? $# : 2))
versions=${*:-3.5 3.6 3.7 3.8 4.0 4.1 4.2 4.3}
all="3.5 3.6 3.7 3.8 4.0 4.1 4.2 4.3"
out=$tmp/variants

# targets <version> prints the version, its neighbors and the latest
targets() {
	local previous="" next="" v seen=""
	for v in $all; do
		[ -n "$seen" ] && [ -z "$next" ] && next=$v
		[ "$v" = "$1" ] && seen=1
		[ -z "$seen" ] && previous=$v
	done
	printf '%s\n' "$1" $previous $next 4.3 | sort -u
}

# exports <version> prints small exports, those with constraints first
exports() {
	find "$root/testdata/corpus/$1" -name '*.json' -size -120k | sort >"$tmp/exports"
	xargs -d '\n' grep -lE '"(path|transform|physics)": *\[' <"$tmp/exports" || true
	xargs -d '\n' grep -LE '"(path|transform|physics)": *\[' <"$tmp/exports" || true
}

# one <from> <to> <variant> <atlas> <label> checks one variant as JSON and as binary
one() {
	local change tolerance="5e-3 5e-5"
	case "$5" in *4-wave-principle* | *vine-pro*) tolerance="3e-2 5e-5" ;; esac
	change=$(tr '\n' ';' <"${3%.json}.txt")
	migrated "$1" "$2" "$3" "$4" "$5 [$change]" $tolerance
	written "$3" "$tmp/variant.skel" --binary || return 0
	migrated "$1" "$2" "$tmp/variant.skel" "$4" "$5 binary [$change]" $tolerance
}

for version in $versions; do
	while IFS= read -r input; do
		dir=$(dirname "$input")
		atlas=$(atlas_for "$dir") || atlas=$(synth_atlas "$input" "$version") || continue
		stem=$(basename "$input" .json)
		kept=$out/$version-$stem
		"$bin/hostile" variants "$input" "$kept" "$per_export" || continue
		for variant in "$kept"/*.json; do
			for to in $(targets "$version"); do
				each one "$version" "$to" "$variant" "$atlas" "$version $stem $(basename "$variant" .json)"
			done
		done
	done < <(exports "$version" | head -n "$per_version")
done
gather
echo "oracle variants $versions: $pass passed with $lossy lossy, $fail failed, $skipped skipped"
[ "$fail" -eq 0 ] && [ "$pass" -gt 0 ]
