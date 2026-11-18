#!/usr/bin/env bash
# Migrated data in the target runtime must give the poses of the source in its own runtime
# Tolerance covers float rounding of constraints reformulated between runtimes
# Usage: oracle/migrate.sh <from> <to>
set -euo pipefail
from=${1:?usage: migrate.sh <from> <to>}
to=${2:?usage: migrate.sh <from> <to>}
source "$(dirname "$0")/lib.sh"

# These exports amplify float rounding of a runtime, measured with 3.x on one side
tolerance() {
	case "$1" in
	3.[78]\ *\ tank/tank-pro.* | *\ 3.[78]\ tank/tank-pro.*) echo "5e-3 5e-5" ;;
	3.8\ *\ chibi-stickers/* | *\ 3.8\ chibi-stickers/*) echo "5e-3 5e-5" ;;
	3.6\ *\ alien/alien-pro.* | *\ 3.6\ alien/alien-pro.*) echo "5e-3 5e-5" ;;
	3.8\ 4.0\ alien/alien-pro.* | 4.1\ 4.0\ alien/alien-pro.*) echo "2e-3 5e-5" ;;
	3.[5-8]\ *\ 4-wave-principle/* | *\ 3.[5-8]\ 4-wave-principle/*) echo "3e-2 5e-5" ;;
	4.3\ 3.[56]\ tank/tank-pro.* | 4.3\ 3.[5-8]\ 6-arcs/6-arcs-pro.* | 4.3\ 3.[5-8]\ */sack-pro.*) echo "5e-3 5e-5" ;;
	4.3\ 3.[5-8]\ raptor/raptor-pro.* | 4.0\ 3.8\ spineboy/spineboy-pro.*) echo "2e-3 5e-5" ;;
	3.8\ 4.[0-3]\ stretchyman/stretchyman-pro.*) echo "1e-3 5e-5" ;;
	*) echo "5e-4 5e-5" ;;
	esac
}

# one <input> migrates one corpus export
one() {
	local input=$1 dir atlas name
	dir=$(dirname "$input")
	atlas=$(atlas_for "$dir") || atlas=$(synth_atlas "$input" "$from") || return 0
	name="$(basename "$dir")/$(basename "$input")"
	migrated "$from" "$to" "$input" "$atlas" "$name" $(tolerance "$from $to $name")
}

for input in "$root/testdata/corpus/$from"/*/*.json "$root/testdata/corpus/$from"/*/*.skel; do
	each one "$input"
done
gather
echo "oracle migrate $from to $to: $pass passed with $lossy lossy, $fail failed, $skipped skipped"
[ "$fail" -eq 0 ]
