#!/usr/bin/env bash
# Extracts the official example exports of every Spine version
# Assets are fetched at test time and never committed
# Usage: tools/fetch-corpus.sh <spine-runtimes checkout> [output dir]
set -euo pipefail

src=${1:?usage: fetch-corpus.sh <spine-runtimes checkout> [output dir]}
out=${2:-"$(cd "$(dirname "$0")/.." && pwd)/testdata/corpus"}

# Branches carry the last re-export of each version, the 3.5 branch moved on to 3.6 betas
refs=(
	"2.1=2.1.25"
	"3.1=3.1.07"
	"3.4=3.4.02"
	"3.5=3.5.51"
	"3.6=origin/3.6"
	"3.7=origin/3.7"
	"3.8=origin/3.8"
	"4.0=origin/4.0"
	"4.1=origin/4.1"
	"4.2=origin/4.2"
	"4.3=origin/4.3"
)

git -C "$src" rev-parse --git-dir >/dev/null

for entry in "${refs[@]}"; do
	label=${entry%%=*}
	ref=${entry#*=}
	if ! git -C "$src" rev-parse --verify --quiet "$ref^{commit}" >/dev/null; then
		echo "skip $label: $ref not found" >&2
		continue
	fi
	dest="$out/$label"
	rm -rf "$dest"
	mkdir -p "$dest"
	count=0
	# 2.1 and 3.1 exports live in libgdx test assets
	while IFS= read -r path; do
		case "$path" in
			examples/*/export/*) name=$(echo "$path" | cut -d/ -f2) ;;
			spine-libgdx/spine-libgdx-tests/assets/*) name=$(echo "$path" | cut -d/ -f4) ;;
			*) continue ;;
		esac
		# libgdx test assets come later and must not replace an example export
		[ -e "$dest/$name/$(basename "$path")" ] && continue
		mkdir -p "$dest/$name"
		git -C "$src" show "$ref:$path" >"$dest/$name/$(basename "$path")"
		count=$((count + 1))
	done < <(git -C "$src" ls-tree -r --name-only "$ref" -- examples spine-libgdx/spine-libgdx-tests/assets |
		grep -E '\.(json|skel|atlas)$' |
		grep -E '^examples/[^/]+/export/|^spine-libgdx/spine-libgdx-tests/assets/')
	git -C "$src" rev-parse "$ref" >"$dest/REF"
	echo "$label: $count files from $ref"
done

# Single exports kept for a codec quirk of one editor version
singles=(
	"3.8.25-beta=5f13f1b8e=raptor/raptor-pro spineboy/spineboy-pro"
)

for entry in "${singles[@]}"; do
	IFS== read -r label ref names <<<"$entry"
	dest="$out/$label"
	rm -rf "$dest"
	for name in $names; do
		mkdir -p "$dest/${name%%/*}"
		for ext in json skel; do
			git -C "$src" show "$ref:examples/${name%%/*}/export/${name#*/}.$ext" >"$dest/$name.$ext"
		done
	done
	git -C "$src" rev-parse "$ref" >"$dest/REF"
	echo "$label: $names from $ref"
done
