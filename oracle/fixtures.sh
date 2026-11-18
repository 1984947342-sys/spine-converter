#!/usr/bin/env bash
# Every fixture in oracle/fixtures must convert as its sidecar NAME.expect states, posed by the C# dumpers
# Sidecar lines are to <version>, code <code>, rewrite yes, from <version>, editor <keys>, tolerance <abs> <rel>, remedy <remedy>, expect fail, flip <x or y>
# A flip line poses both sides with ORACLE_FLIP and judges the control codes a flip shows as pose
# The minor of from picks the source dumper
# Without code or with only rewritten codes and no rewrite line the poses must match
# A report fixture needs its codes, poses that differ without excuse and match with the excuse of pose-scope
# A rewrite fixture needs its codes and differing poses with --no-rewrite, their codes marked rewrite, and without it their rewritten codes, no other loss but control and matching poses
# A remedy line requires that remedy on every code
# The source dumps with SPC_EDITOR set to the keys its editor predates unless the sidecar names them
# 4.3 corpus exports with clipping also go to 4.2 with rewrites after the convex flag
# Usage: oracle/fixtures.sh
set -euo pipefail
source "$(dirname "$0")/lib.sh"

declare -A dll
for version in 3.5 3.6 3.7 3.8 4.0 4.1 4.2 4.3; do
	dll[$version]=$(csharp_build "Dump${version/./}" "Dump${version/./}") || exit 1
done

# value <key> prints the rest of each sidecar line starting with key
value() {
	awk -v key="$1" '$1 == key { $1 = ""; sub(/^ /, ""); print }' "$expect"
}

# converted <input> <to> <format> [flags] dumps the conversion into $tmp/target.jsonl with its report in $tmp/report
converted() {
	local input=$1 to=$2 format=$3 output status=0
	shift 3
	output="$tmp/out.$([ "$format" = json ] && echo json || echo skel)"
	"$bin/spine-converter" convert "$input" "$output" --to "$to" "--$format" "$@" 2>"$tmp/report" || status=$?
	[ "$status" -eq 0 ] || [ "$status" -eq 3 ] || {
		why="conversion failed: $(head -1 "$tmp/report")"
		return 1
	}
	flip_report
	csharp "${dll[$to]}" "$output" "$target_atlas" "$tmp/target.jsonl" || {
		why="$to runtime does not load the output: $(head -1 "$tmp/err")"
		return 1
	}
}

# reported <code>... fails unless the report holds every code
reported() {
	local code
	for code in "$@"; do
		awk -F'\t' -v code="$code" '$3 == code { found = 1 } END { exit !found }' "$tmp/report" || {
			why="$code missing from the report"
			return 1
		}
	done
}

# remedied <remedy> <code>... fails unless every code carries the remedy
remedied() {
	local remedy=$1 code
	shift
	for code in "$@"; do
		awk -F'\t' -v code="$code" -v remedy="$remedy" '$3 == code && $6 == remedy { found = 1 } END { exit !found }' "$tmp/report" || {
			why="$code not marked $remedy"
			return 1
		}
	done
}

# judged <input> <format> runs one fixture in one format, leaving the reason of a failure in why
judged() {
	local input=$1 format=$2 to codes rewritten tolerance code
	to=$(value to)
	codes=$(value code)
	tolerance=$(value tolerance)
	tolerance=${tolerance:-5e-4 5e-5}
	if [ "$(value rewrite)" = yes ]; then
		converted "$input" "$to" "$format" --no-rewrite && reported $codes && remedied rewrite $codes || return 1
		if "$bin/pose-compare" --clip-region "$tmp/source.jsonl" "$tmp/target.jsonl" $tolerance >"$tmp/compare"; then
			why="poses match with --no-rewrite"
			return 1
		fi
		rewritten=$(for code in $codes; do echo "${code%.*}.rewritten"; done)
		converted "$input" "$to" "$format" && reported $rewritten || return 1
		if awk -F"\t" '($1 == "dropped" || $1 == "approximated") && $2 != "control"' "$tmp/report" | grep -q .; then
			why="rewritten with losses: $(awk -F"\t" '($1 == "dropped" || $1 == "approximated") && $2 != "control"' "$tmp/report" | cut -f3 | sort -u | paste -sd' ')"
			return 1
		fi
		"$bin/pose-compare" --clip-region "$tmp/source.jsonl" "$tmp/target.jsonl" $tolerance >"$tmp/compare" || {
			why="poses differ with rewrites: $(sed -n 1p "$tmp/compare")"
			return 1
		}
	elif [ -z "$codes" ] || ! grep -qv "\.rewritten\$" <<<"$codes"; then
		converted "$input" "$to" "$format" && reported $codes || return 1
		"$bin/pose-compare" $(render_flags) "$tmp/source.jsonl" "$tmp/target.jsonl" $tolerance >"$tmp/compare" || {
			why="poses differ: $(sed -n 1p "$tmp/compare")"
			return 1
		}
	else
		converted "$input" "$to" "$format" && reported $codes || return 1
		if [ -n "$(value remedy)" ]; then remedied "$(value remedy)" $codes || return 1; fi
		if "$bin/pose-compare" $(render_flags) "$tmp/source.jsonl" "$tmp/target.jsonl" $tolerance >"$tmp/compare"; then
			why="poses match without excuse"
			return 1
		fi
		written "$input" "$tmp/scope.json" --to 4.3 --json && "$bin/pose-scope" "$tmp/scope.json" "$tmp/report" >"$tmp/scope" &&
			"$bin/pose-compare" $(render_flags) --excuse "$tmp/scope" "$tmp/source.jsonl" "$tmp/target.jsonl" $tolerance >"$tmp/compare" || {
			why="poses differ with excuse: $(sed -n 1p "$tmp/compare")"
			return 1
		}
	fi
}

# fixture <input> runs one fixture in both formats
fixture() {
	local input=$1 name version from atlas editor format
	expect="${input%.*}.expect"
	name=$(basename "$input")
	export ORACLE_FLIP=$(value flip)
	[ -f "$expect" ] || {
		echo "FAIL $name: no sidecar"
		fail=$((fail + 1))
		return 0
	}
	version=$("$bin/spine-converter" detect "$input" | cut -f3)
	from=$(value from)
	from=$(cut -d. -f1,2 <<<"${from:-$version}")
	atlas="${input%.*}.atlas"
	[ -f "$atlas" ] || atlas=$(synth_atlas "$input" "$from")
	target_atlas=$(atlas_in "$(value to)" "$atlas")
	# no skel holds an empty default skin, which every JSON loader keeps
	if [ "${input##*.}" = json ]; then
		perl -0pe 's/"skins"\s*:\s*\{\s*"default"\s*:\s*\{\s*\}\s*\}/"skins": {}/; s/"skins"\s*:\s*\[\s*\{\s*"name"\s*:\s*"default"\s*\}\s*\]/"skins": []/' "$input" >"$tmp/fixture.json"
		input="$tmp/fixture.json"
	fi
	editor=$(value editor)
	editor=$(tr " " , <<<"${editor:-$(editor_keys "$version")}")
	for format in json binary; do
		why=""
		if ! SPC_EDITOR=$editor csharp "${dll[$from]}" "$input" "$atlas" "$tmp/source.jsonl"; then
			why="$from runtime does not load the source: $(head -1 "$tmp/err")"
		else
			judged "$input" "$format" || true
		fi
		if [ "$(value expect)" = fail ]; then
			if [ -n "$why" ]; then
				echo "XFAIL $name $format: $why"
				pass=$((pass + 1))
			else
				echo "FAIL $name $format: passed although expected to fail"
				fail=$((fail + 1))
			fi
		elif [ -n "$why" ]; then
			echo "FAIL $name $format: $why"
			fail=$((fail + 1))
		else
			pass=$((pass + 1))
		fi
	done
}

# convex <input> converts one 4.3 corpus export with convex clipping to 4.2
convex() {
	local input=$1 dir atlas name version format
	grep -q '"clipping"' "$input" || return 0
	dir=$(dirname "$input")
	atlas=$(atlas_for "$dir")
	name="$(basename "$dir")/$(basename "$input")"
	sed 's/"type": *"clipping",/& "convex": true,/' "$input" >"$tmp/convex.json"
	version=$("$bin/spine-converter" detect "$input" | cut -f3)
	SPC_EDITOR=$(editor_keys "$version") csharp "${dll[4.3]}" "$tmp/convex.json" "$atlas" "$tmp/source.jsonl" || {
		failed "$name"
		return 0
	}
	target_atlas=$(atlas_in 4.2 "$atlas")
	for format in json binary; do
		if ! converted "$tmp/convex.json" 4.2 "$format"; then
			echo "FAIL $name $format: $why"
			fail=$((fail + 1))
		elif ! grep -q "clipping.convex.rewritten" "$tmp/report"; then
			echo "SKIP $name $format: no clipping qualifies"
			skipped=$((skipped + 1))
		elif grep "^dropped\|^approximated" "$tmp/report" | cut -f3 | grep -q "^clipping\."; then
			echo "FAIL $name $format: clipping rewritten with losses"
			fail=$((fail + 1))
		elif grep -q "^dropped\|^approximated" "$tmp/report"; then
			# other losses of the export may differ only inside their scope
			if "$bin/pose-compare" --clip-region "$tmp/source.jsonl" "$tmp/target.jsonl" 5e-4 5e-5 >"$tmp/compare" ||
				{ written "$tmp/convex.json" "$tmp/scope.json" --to 4.3 --json && excused "$tmp/scope.json" --clip-region "$tmp/source.jsonl" "$tmp/target.jsonl" 5e-4 5e-5; }; then
				pass=$((pass + 1))
			else
				mismatched "$name $format"
			fi
		else
			check "$name $format" --clip-region "$tmp/source.jsonl" "$tmp/target.jsonl" 5e-4 5e-5
		fi
	done
}

for input in "$root/oracle/fixtures"/*.json "$root/oracle/fixtures"/*.skel; do
	[ -f "$input" ] || continue
	each fixture "$input"
done
for input in "$root/testdata/corpus/4.3"/*/*.json; do
	each convex "$input"
done
gather
echo "oracle fixtures: $pass passed, $fail failed, $skipped skipped"
[ "$fail" -eq 0 ] && [ "$pass" -gt 0 ]
