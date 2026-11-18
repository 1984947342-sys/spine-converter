#!/usr/bin/env bash
# Every skeleton under a directory converted to the target version must give its source poses
# The atlas is <name>.atlas without -pro or -ess, else the only atlas beside the skeleton
# Lines of the tolerance file are <path in directory> <abs> <rel>
# Usage: oracle/external.sh <directory> [target version] [tolerance file]
set -euo pipefail
dir=${1:?usage: external.sh <directory> [target version] [tolerance file]}
to=${2:-4.3}
tolerances=${3:-/dev/null}
source "$(dirname "$0")/lib.sh"

# one <input> migrates one skeleton under the directory
one() {
	local input=$1 name from base atlas atlases tolerance
	name=${input#"$dir"/}
	from=$("$bin/spine-converter" detect "$input" | cut -f3 | cut -d. -f1,2)
	[ -x "$bin/oracle-$from" ] || {
		echo "SKIP $name: no $from runtime"
		skipped=$((skipped + 1))
		return 0
	}
	base=$(basename "${input%.*}")
	base=${base%-pro}
	base=${base%-ess}
	atlas="$(dirname "$input")/$base.atlas"
	if [ ! -f "$atlas" ]; then
		atlases=("$(dirname "$input")"/*.atlas)
		[ ${#atlases[@]} -eq 1 ] && [ -f "${atlases[0]}" ] || {
			echo "SKIP $name: no atlas"
			skipped=$((skipped + 1))
			return 0
		}
		atlas=${atlases[0]}
	fi
	tolerance=$(awk -v name="$name" '$1 == name { print $2, $3; exit }' "$tolerances")
	migrated "$from" "$to" "$input" "$atlas" "$name" ${tolerance:-5e-4 5e-5}
}

while IFS= read -r input; do
	each one "$input"
done < <(find "$dir" -type f \( -name '*.skel' -o -name '*.json' -o -name '*.spine-json' \) | sort | while IFS= read -r f; do
	case $("$bin/spine-converter" detect "$f" 2>/dev/null | cut -f2) in json | binary) printf "%s\n" "$f" ;; esac
done)
gather
echo "oracle external $dir to $to: $pass passed with $lossy lossy, $fail failed, $skipped skipped"
[ "$fail" -eq 0 ]
