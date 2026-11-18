#!/usr/bin/env bash
# Exports official runtimes for the oracle dumpers
# Usage: tools/fetch-runtimes.sh <spine-runtimes checkout> [output dir]
set -euo pipefail

src=${1:?usage: fetch-runtimes.sh <spine-runtimes checkout> [output dir]}
out=${2:-"$(cd "$(dirname "$0")/.." && pwd)/testdata/runtimes"}
patches="$(cd "$(dirname "$0")/.." && pwd)/oracle/patches"

# spine-cpp starts with 3.7 and moved up one directory in 4.3, the 3.5 branch moved on to 3.6 betas
refs=(
	"3.5=3.5.51:spine-c/spine-c"
	"3.6=origin/3.6:spine-c/spine-c"
	"3.7=origin/3.7:spine-cpp/spine-cpp"
	"3.8=origin/3.8:spine-cpp/spine-cpp"
	"4.0=origin/4.0:spine-cpp/spine-cpp"
	"4.1=origin/4.1:spine-cpp/spine-cpp"
	"4.2=origin/4.2:spine-cpp/spine-cpp"
	"4.3=origin/4.3:spine-cpp"
)

for entry in "${refs[@]}"; do
	label=${entry%%=*}
	rest=${entry#*=}
	ref=${rest%%:*}
	runtime=${rest#*:}
	dest="$out/$label"
	rm -rf "$dest"
	mkdir -p "$dest/archive"
	git -C "$src" archive "$ref" "$runtime/src" "$runtime/include" LICENSE | tar -x -C "$dest/archive"
	mv "$dest/archive/$runtime" "$dest/$(basename "$runtime")"
	mv "$dest/archive/LICENSE" "$dest/LICENSE"
	rm -rf "$dest/archive"
	# fixes of the runtime the oracle depends on, listed in docs/architecture.md
	if [ -f "$patches/$label.patch" ]; then
		patch -s -p1 -d "$dest/$(basename "$runtime")" <"$patches/$label.patch"
	fi
	git -C "$src" rev-parse "$ref" >"$dest/REF"
	echo "$label: $runtime from $ref"
done

# spine-csharp for the C# dumpers
csharp=(
	"3.5=3.5.51"
	"3.6=origin/3.6"
	"3.7=origin/3.7"
	"3.8=origin/3.8"
	"4.0=origin/4.0"
	"4.1=origin/4.1"
	"4.2=origin/4.2"
	"4.3=origin/4.3"
)

for entry in "${csharp[@]}"; do
	label=${entry%%=*}
	ref=${entry#*=}
	dest="$out/$label/spine-csharp"
	rm -rf "$dest"
	mkdir -p "$dest"
	git -C "$src" archive "$ref" spine-csharp/src | tar -x -C "$dest" --strip-components=1
	if [ -f "$patches/$label-csharp.patch" ]; then
		patch -s -p1 -d "$dest" <"$patches/$label-csharp.patch"
	fi
	git -C "$src" rev-parse "$ref" >"$dest/REF"
	echo "$label: spine-csharp from $ref"
done
