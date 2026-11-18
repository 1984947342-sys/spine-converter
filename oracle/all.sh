#!/usr/bin/env bash
# Builds once, then runs every check of the verification list at once
# All checks share one pool of ORACLE_JOBS tokens, so cores stay busy until the last case
# Each check logs to ORACLE_LOGS, zig-out/oracle by default, and prints its last line when done
# ORACLE_VARIANTS passes arguments to oracle/variants.sh
# Usage: oracle/all.sh
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
logs=${ORACLE_LOGS:-$root/zig-out/oracle}
versions="3.5 3.6 3.7 3.8 4.0 4.1 4.2 4.3"
cd "$root"

zig fmt --check src cli tests oracle build.zig
zig build test
zig build -Doptimize=ReleaseSafe
zig build corpus -Doptimize=ReleaseSafe
zig build oracle
zig build dist

pool=$(mktemp -u "${ORACLE_TMP:-${TMPDIR:-/tmp}}/oracle-pool.XXXXXX")
mkfifo "$pool"
trap 'rm -f "$pool"' EXIT
exec 9<>"$pool"
printf "x%.0s" $(seq "${ORACLE_JOBS:-$(nproc)}") >&9
export ORACLE_POOL=$pool

# long checks first so they never become the tail
checks=(
	"variants ${ORACLE_VARIANTS:-}"
	"hostile"
	"csharp $versions"
	"fixtures"
	"selfcheck $versions"
	"codec $versions"
	"atlas $versions"
)
for pair in "3.5 3.6" "3.6 3.7" "3.7 3.8" "3.8 4.0" "4.0 4.1" "4.1 4.2" "4.2 4.3" "3.8 4.3" "3.7 4.3" "3.6 4.3" "3.5 4.3"; do
	read -r a b <<<"$pair"
	checks+=("migrate $a $b" "migrate $b $a")
done

mkdir -p "$logs"
rm -f "$logs"/*.log
declare -A pids
for check in "${checks[@]}"; do
	read -r script args <<<"$check"
	name=$(tr ' ' - <<<"$check" | sed 's/-$//')
	# word splitting of args is wanted
	# shellcheck disable=SC2086
	oracle/$script.sh $args </dev/null >"$logs/$name.log" 2>&1 &
	pids[$name]=$!
done
"${DOTNET:-dotnet}" run --project bindings/csharp/Tests </dev/null >"$logs/bindings.log" 2>&1 &
pids[bindings]=$!

failed=0
for name in $(printf "%s\n" "${!pids[@]}" | sort); do
	if wait "${pids[$name]}"; then status=ok; else status=FAIL failed=$((failed + 1)); fi
	echo "$status $name: $(tail -1 "$logs/$name.log")"
done
[ "$failed" -eq 0 ]
