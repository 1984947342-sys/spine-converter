#!/usr/bin/env bash
# Converted atlases must parse in the target runtime like the source in its own runtime
# Fields named by a report entry are left out of the comparison
# Usage: oracle/atlas.sh <version>...
set -euo pipefail
[ $# -gt 0 ] || { echo "usage: atlas.sh <version>..." >&2; exit 2; }
source "$(dirname "$0")/lib.sh"

# Blanks page pma and the reported fields of regions
masked() {
	awk -F'\t' -v OFS='\t' -v report="$2" '
		BEGIN {
			while ((getline line < report) > 0) {
				split(line, f, "\t")
				if (f[3] == "atlas.pma.dropped") pma = 1
				if (f[3] == "atlas.values.dropped") values[f[4]] = 1
				if (f[3] == "atlas.rotate.dropped") rotated[f[4]] = 1
			}
		}
		$1 == "page" && pma { $10 = "" }
		$1 == "region" {
			name = substr($3, 2, length($3) - 2)
			for (key in values) if (index(key, "regions." name ".") == 1) { $18 = ""; $19 = "" }
			if (("regions." name ".rotate") in rotated) { $8 = ""; $9 = ""; $10 = ""; $11 = ""; $16 = "" }
		}
		{ print }
	' "$1"
}

# one <from> <atlas> <version>... converts one atlas to every version
one() {
	local from=$1 atlas=$2 name to
	shift 2
	name="$(basename "$(dirname "$atlas")")/$(basename "$atlas")"
	"$bin/oracle-$from" "$atlas" >"$tmp/source.txt" 2>"$tmp/err" || {
		failed "$from $name"
		return 0
	}
	for to in "$@"; do
		written "$atlas" "$tmp/out.atlas" --to "$to" && "$bin/oracle-$to" "$tmp/out.atlas" >"$tmp/target.txt" 2>>"$tmp/err" || {
			failed "$from $name to $to"
			continue
		}
		if grep -q "^dropped" "$tmp/err"; then lossy=$((lossy + 1)); fi
		if diff <(masked "$tmp/source.txt" "$tmp/err") <(masked "$tmp/target.txt" "$tmp/err") >"$tmp/diff"; then
			pass=$((pass + 1))
		else
			echo "FAIL $from $name to $to"
			sed -n '1,6s/^/  /p' "$tmp/diff"
			fail=$((fail + 1))
		fi
	done
}

for from in "$@"; do
	for atlas in "$root/testdata/corpus/$from"/*/*.atlas; do
		each one "$from" "$atlas" "$@"
	done
done
gather
echo "oracle atlas $*: $pass passed with $lossy lossy, $fail failed"
[ "$fail" -eq 0 ]
