#!/usr/bin/env bash
# Damaged skeletons may fail but must not crash hang or write what the converter cannot read back
# Text that is no skeleton must not detect as one
# A failing case stays in HOSTILE_KEEP, zig-out/hostile by default, for hostile replay
# Usage: oracle/hostile.sh [cases per skeleton] [directory]
set -euo pipefail
source "$(dirname "$0")/lib.sh"
damaged=${1:-40}
dir=${2:-$root/testdata/corpus}
keep=${HOSTILE_KEEP:-$root/zig-out/hostile}
mkdir -p "$keep"
: "${HOSTILE_TIMEOUT:=300}"

# one <input> damages one skeleton
one() {
	local input=$1 name status=0
	name=${input#"$dir"/}
	(
		ulimit -v 8000000
		timeout "$HOSTILE_TIMEOUT" "$bin/hostile" damage "$input" "$tmp/case" "$damaged"
	) >"$tmp/out" 2>"$tmp/err" || status=$?
	if [ "$status" -eq 0 ]; then
		pass=$((pass + 1))
		return 0
	fi
	cp "$tmp/case" "$keep/${name//\//_}.case" 2>/dev/null || true
	cp "$tmp/case.out" "$keep/${name//\//_}.out" 2>/dev/null || true
	fail=$((fail + 1))
	echo "FAIL $name status $status: $(grep -m1 -E 'panic|UNREADABLE|Segmentation|error:' "$tmp/err" "$tmp/out" | cut -d: -f2- | cut -c1-200)"
	grep -m3 -E '^/.*\.zig:[0-9]+' "$tmp/err" | sed 's/^/  /' | cut -c1-160 || true
}

if "$bin/hostile" text 20000 >"$tmp/text"; then
	pass=$((pass + 1))
else
	fail=$((fail + 1))
	echo "FAIL text: $(tail -1 "$tmp/text" | cut -d' ' -f2) misdetected"
	head -3 "$tmp/text" | cut -c1-120 | sed 's/^/  /'
fi

while IFS= read -r input; do
	each one "$input"
done < <(find "$dir" -type f \( -name '*.skel' -o -name '*.json' \) | sort)
gather
echo "oracle hostile $dir: $pass passed, $fail failed, $skipped skipped"
[ "$fail" -eq 0 ]
