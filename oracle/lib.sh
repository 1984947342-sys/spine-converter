# Shared by the oracle scripts, sourced not run

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
bin="$root/zig-out/bin"
# Every case writes dumps of tens of megabytes, ORACLE_TMP moves them off /tmp
tmp=$(mktemp -d "${ORACLE_TMP:-${TMPDIR:-/tmp}}/oracle.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
shared=$tmp
pass=0
fail=0
lossy=0
skipped=0
cases=0
# Cases take a token from a fifo, ORACLE_POOL shares one between concurrent scripts
if [ -z "${ORACLE_POOL:-}" ]; then
	mkfifo "$tmp/pool"
	exec 9<>"$tmp/pool"
	printf "x%.0s" $(seq "${ORACLE_JOBS:-$(nproc)}") >&9
else
	exec 9<>"$ORACLE_POOL"
fi

# each <function> <args>... runs one case in the background once it holds a token
# The case gets its own tmp and counters, gather prints its output and adds its counters
each() {
	local token
	read -r -n 1 -u 9 token
	cases=$((cases + 1))
	# the case sees every variable of the caller, so this one takes a name no script uses
	local each_dir="$shared/case-$cases"
	mkdir -p "$each_dir/tmp"
	printf "%s\n" "$*" >"$each_dir/command"
	(
		trap "printf x >&9" EXIT
		tmp=$each_dir/tmp
		pass=0 fail=0 lossy=0 skipped=0
		"$@"
		echo "$pass $fail $lossy $skipped" >"$each_dir/count"
		rm -rf "$tmp"
	) >"$each_dir/out" 2>&1 &
}

# gather waits for every case and reports in case order, a case that aborts fails
gather() {
	local i dir p f l s
	wait
	for ((i = 1; i <= cases; i++)); do
		dir="$shared/case-$i"
		cat "$dir/out"
		if read -r p f l s <"$dir/count" 2>/dev/null; then
			pass=$((pass + p)) fail=$((fail + f)) lossy=$((lossy + l)) skipped=$((skipped + s))
		else
			echo "FAIL aborted: $(cat "$dir/command")"
			fail=$((fail + 1))
		fi
		rm -rf "$dir"
	done
	cases=0
}

# Prints the atlas of an export, preferring <example>.atlas over premultiplied ones
atlas_for() {
	local dir=$1 atlas
	atlas="$dir/$(basename "$dir").atlas"
	if [ ! -f "$atlas" ]; then
		for candidate in "$dir"/*.atlas; do
			case "$candidate" in *-pma.atlas) ;; *) atlas=$candidate ;; esac
		done
	fi
	[ -f "$atlas" ] && printf '%s\n' "$atlas"
}

# dump <version> <skeleton> <atlas> <out>
# Dumpers pick the loader by extension, so the copy is named by content
# 3.8 runtimes reject the 3.8.75 version string of a layout identical to 3.8.99
dump() {
	local skeleton=$2 detected extension
	detected=$("$bin/spine-converter" detect "$2")
	extension=$([ "$(cut -f2 <<<"$detected")" = binary ] && echo skel || echo json)
	if [ "$1" = 3.8 ] && [ "$(cut -f3 <<<"$detected")" = 3.8.75 ]; then
		skeleton="$tmp/source.$extension"
		perl -0777 -pe "s/3\\.8\\.75/3.8.99/" "$2" >"$skeleton"
	elif [ "${2##*.}" != "$extension" ] && [ "${2##*.}" != spine-json ]; then
		skeleton="$tmp/source.$extension"
		cp "$2" "$skeleton"
	fi
	"$bin/oracle-$1" "$skeleton" "$3" >"$4" 2>"$tmp/err"
}

# check <name> <expected dump> <actual dump> [tolerances]
check() {
	local name=$1
	shift
	if "$bin/pose-compare" "$@" >"$tmp/compare"; then
		pass=$((pass + 1))
	else
		mismatched "$name"
	fi
}

# mismatched <name> fails with the comparison in $tmp/compare
mismatched() {
	echo "FAIL $1"
	sed -n '1,5s/^/  /p' "$tmp/compare"
	fail=$((fail + 1))
}

# excused <4.3 json> <compare args>... passes when the pose entries of $tmp/report cover every mismatch
excused() {
	local skeleton=$1
	shift
	excuse=""
	"$bin/pose-scope" "$skeleton" "$tmp/report" >"$tmp/scope" &&
		"$bin/pose-compare" --excuse "$tmp/scope" "$@" >"$tmp/compare" || return
	excuse=", $(tail -1 "$tmp/compare")"
}

failed() {
	echo "FAIL $1: $(head -1 "$tmp/err")"
	fail=$((fail + 1))
}

# written <convert args>... succeeds when the output exists, losses allowed
written() {
	local status=0
	"$bin/spine-converter" convert "$@" 2>"$tmp/err" || status=$?
	[ "$status" -eq 0 ] || [ "$status" -eq 3 ]
}

# Prints the path of an atlas converted to <version>
atlas_in() {
	written "$2" "$tmp/atlas-$1.atlas" --to "$1" && printf '%s\n' "$tmp/atlas-$1.atlas"
}

# linear_keys <json> <animation/kind/name/timeline/index>... prints the json with those stepped keys made linear
# Fails unless every key is found stepped, so a changed export cannot pass silently
linear_keys() {
	local json=$1
	shift
	awk -v keys="$*" '
		BEGIN { n = split(keys, list, " "); for (i = 1; i <= n; i++) want[list[i]] = 1 }
		/^[ \t]*"[^"]*": [{[][ \t]*$/ {
			name = $0
			sub(/^[ \t]*"/, "", name)
			sub(/".*/, "", name)
			stack[++depth] = name
			index_of[depth] = 0
			print
			next
		}
		/^[ \t]*\{[ \t]*$/ { stack[++depth] = ""; print; next }
		/^[ \t]*[]}],?[ \t]*$/ { depth--; print; next }
		/^[ \t]*\{.*\},?[ \t]*$/ && depth >= 6 && stack[2] == "animations" {
			path = stack[3] "/" stack[4] "/" stack[5] "/" stack[6] "/" index_of[depth]++
			if (path in want) {
				if (!sub(/, "curve": "stepped"/, "")) exit 1
				delete want[path]
				found++
			}
		}
		{ print }
		END { if (found != n) exit 1 }
	' "$json"
}

# common_skins <dump> <other dump>, prints the samples of skins the other dump also has
# skel exports before 4.0 drop skins without attachments
common_skins() {
	perl -e '
		open my $o, "<", $ARGV[1] or die; my $h = <$o>;
		my ($list) = $h =~ /"skins":(\[[^]]*\])/;
		my %keep = map { $_ => 1 } $list =~ /"((?:[^"\\]|\\.)*)"/g;
		open my $d, "<", $ARGV[0] or die;
		while (<$d>) {
			if ($. == 1) { s/"skins":\[[^]]*\]/"skins":$list/; print; next }
			my ($skin) = /^\{"skin":"((?:[^"\\]|\\.)*)"/;
			print if $keep{$skin};
		}
	' "$1" "$2"
}

declare -A dumpers

# csharp_dumper <minor> sets dll to the C# dumper of a minor, built once per run and shared by cases
csharp_dumper() {
	local cache="$shared/dumper-$1"
	if [ -z "${dumpers[$1]:-}" ]; then
		{
			flock 9
			[ -f "$cache" ] || csharp_build "Dump${1/./}" "Dump${1/./}" >"$cache" || : >"$cache"
		} 9>"$cache.lock"
		dumpers[$1]=$(cat "$cache")
	fi
	dll=${dumpers[$1]}
	[ -n "$dll" ]
}

# editor_dated <version> succeeds when the editor of <version> predates or may predate a runtime change
editor_dated() {
	[ -n "$("$bin/pose-scope" editor "$1" 2>/dev/null)$("$bin/pose-scope" unsure "$1" 2>/dev/null)" ]
}

# flip_report marks the control entries a flipped skeleton shows as pose
flip_report() {
	[ -z "${ORACLE_FLIP:-}" ] ||
		perl -pi -e 's/\tcontrol\t(bone\.flip|skeleton\.scale|transform\.offsetFlip|path\.offsetFlip)\.approximated\t/\tpose\t$1.approximated\t/' "$tmp/report"
}

# migrated <from> <to> <input> <atlas> <name> <abs> <rel> converts to <to> in both formats and compares poses
# Poses may differ only where pose-scope maps the pose entries of the report
# Sources whose editor predates a runtime change are posed by spine-csharp on both sides, the source with SPC_EDITOR
migrated() {
	local from=$1 to=$2 input=$3 atlas=$4 name=$5 format output status clip codes excuse version editor sharp="" dll
	shift 5
	version=$("$bin/spine-converter" detect "$input" 2>/dev/null | cut -f3) || true
	if [ "$(cut -d. -f1,2 <<<"$version")" = "$from" ] && editor_dated "$version"; then
		sharp=1
		editor=$(editor_keys "$version")
		csharp_dumper "$from" && SPC_EDITOR=$editor csharp "$dll" "$input" "$atlas" "$tmp/source.jsonl"
	else
		dump "$from" "$input" "$atlas" "$tmp/source.jsonl" 2>/dev/null
	fi || {
		echo "SKIP $name: $from runtime does not load it"
		skipped=$((skipped + 1))
		return
	}
	for format in json binary; do
		output="$tmp/out.$([ $format = json ] && echo json || echo skel)"
		status=0
		"$bin/spine-converter" convert "$input" "$output" --to "$to" "--$format" 2>"$tmp/report" || status=$?
		if [ "$status" -ne 0 ] && [ "$status" -ne 3 ]; then
			if grep -q UnsupportedVersion "$tmp/report"; then
				skipped=$((skipped + 1))
			else
				cp "$tmp/report" "$tmp/err"
				failed "$name to $to $format"
			fi
			continue
		fi
		if [ -n "$sharp" ]; then
			csharp_dumper "$to" && csharp "$dll" "$output" "$(atlas_in "$to" "$atlas")" "$tmp/target.jsonl"
		else
			dump "$to" "$output" "$(atlas_in "$to" "$atlas")" "$tmp/target.jsonl" 2>/dev/null
		fi || {
			failed "$name to $to $format"
			continue
		}
		flip_report
		clip=$(render_flags)
		codes=$(awk -F'\t' '$2 == "pose" || $3 == "animation.duration.approximated" { print $3 }' "$tmp/report" | sort -u | paste -sd' ')
		if "$bin/pose-compare" $clip "$tmp/source.jsonl" "$tmp/target.jsonl" "$@" >"$tmp/compare"; then
			pass=$((pass + 1))
		elif [ -n "$codes" ] && written "$input" "$tmp/scope.json" --to 4.3 --json &&
			excused "$tmp/scope.json" $clip "$tmp/source.jsonl" "$tmp/target.jsonl" "$@"; then
			echo "LOSSY $name to $to $format: $codes$excuse"
			lossy=$((lossy + 1))
			pass=$((pass + 1))
		else
			mismatched "$name to $to $format"
		fi
	done
}

# synth_atlas <skeleton> <version> prints a <version> atlas holding every region the skeleton names
# Some corpus exports ship without an atlas, poses do not depend on its contents
synth_atlas() {
	local out status=0
	out="$tmp/synth-$(basename "$1").atlas"
	"$bin/spine-converter" convert "$1" "$tmp/synth.json" --to 4.3 --json 2>/dev/null || status=$?
	[ "$status" -eq 0 ] || [ "$status" -eq 3 ] || return 1
	perl -MJSON::PP -e '
		local $/;
		my $json = JSON::PP->new->utf8->decode(<STDIN>);
		my %regions;
		for my $skin (@{ $json->{skins} || [] }) {
			for my $slot (values %{ $skin->{attachments} || {} }) {
				for my $key (keys %$slot) {
					my $a = $slot->{$key};
					next unless ($a->{type} // "region") =~ /^(region|mesh|linkedmesh)$/;
					my $path = $a->{path} // $key;
					my @size = map { my $v = int(abs($_ // 16)); $v < 1 ? 1 : $v } $a->{width}, $a->{height};
					my $sequence = $a->{sequence};
					my @names = $sequence
						? map { $path . sprintf("%0*d", $sequence->{digits} // 0, ($sequence->{start} // 1) + $_) } 0 .. ($sequence->{count} // 1) - 1
						: ($path);
					$regions{$_} //= [@size] for @names;
				}
			}
		}
		binmode STDOUT, ":utf8";
		print "synth.png\nsize: 4096, 4096\nfilter: Linear, Linear\n";
		print "$_\nbounds: 0, 0, $regions{$_}[0], $regions{$_}[1]\n" for sort keys %regions;
	' <"$tmp/synth.json" >"$tmp/synth-4.3.atlas" || return 1
	written "$tmp/synth-4.3.atlas" "$out" --to "$2" && printf '%s\n' "$out"
}

# editor_keys <version> prints the runtime changes the editor of <version> predates, comma separated
editor_keys() {
	"$bin/pose-scope" editor "$1" | paste -sd,
}

# render_flags prints the pose-compare flags for the losses of $tmp/report that keep the pose
render_flags() {
	awk -F'\t' '
		$2 == "render" { render = 1 }
		$3 ~ /\.dark\.dropped$/ { dark = 1 }
		$3 ~ /^attachment\.(clipping|point)\.dropped$/ { dropped = 1 }
		END { if (render) print "--no-clip"; if (dark) print "--no-dark"; if (dropped) print "--no-dropped" }
	' "$tmp/report" | paste -sd' '
}

# DOTNET picks the dotnet host
dotnet=${DOTNET:-dotnet}

# csharp_build <project> <name> [msbuild args] prints the dll of a C# dumper built into zig-out/csharp/bin/<name>
csharp_build() {
	local project=$1 name=$2
	shift 2
	mkdir -p "$root/zig-out/csharp"
	# concurrent scripts build the same dumper one at a time
	# a resident compiler would keep the lock for minutes
	flock -o "$root/zig-out/csharp/$name.lock" "$dotnet" build "$root/oracle/csharp/$project/$project.csproj" -c Release -nologo -v q \
		-nodeReuse:false -p:UseSharedCompilation=false \
		"-p:BaseOutputPath=$root/zig-out/csharp/bin/$name/" \
		"-p:BaseIntermediateOutputPath=$root/zig-out/csharp/obj/$name/" "$@" </dev/null >"$tmp/build" 9>&- || {
		cat "$tmp/build" >&2
		return 1
	}
	echo "$root/zig-out/csharp/bin/$name/Release/net8.0/$project.dll"
}

# csharp <dll> <skeleton> <atlas> <out>, the dumpers pick the loader by extension
csharp() {
	local skeleton=$2 extension
	extension=$([ "$("$bin/spine-converter" detect "$2" | cut -f2)" = binary ] && echo skel || echo json)
	if [ "${2##*.}" != "$extension" ]; then
		skeleton="$tmp/source.$extension"
		cp "$2" "$skeleton"
	fi
	# spine-csharp JSON loaders require the skeleton hash
	if [ "$extension" = json ] && ! grep -q '"hash"' "$skeleton"; then
		perl -0pe 's/"skeleton"\s*:\s*\{/"skeleton": { "hash": "",/' "$skeleton" >"$tmp/hashed.json"
		skeleton="$tmp/hashed.json"
	fi
	dotnet_to "$4" "$1" "$skeleton" "$3"
}

# dotnet_to <out> <args>... runs dotnet into out with its errors in $tmp/err
dotnet_to() {
	local out=$1
	shift
	"$dotnet" "$@" </dev/null >"$out" 2>"$tmp/err"
}
