#!/usr/bin/env bash
# Prints the release version after checking every package manifest agrees
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
version=$(sed -n 's/^ *\.version = "\(.*\)",$/\1/p' "$root/build.zig.zon")
check() {
	if [ "$2" != "$version" ]; then
		echo "$1 has version $2, build.zig.zon has $version" >&2
		exit 1
	fi
}
check bindings/js/package.json "$(sed -n 's/^  "version": "\(.*\)",$/\1/p' "$root/bindings/js/package.json")"
check bindings/python/pyproject.toml "$(sed -n 's/^version = "\(.*\)"$/\1/p' "$root/bindings/python/pyproject.toml")"
check bindings/csharp/Directory.Build.props "$(sed -n 's/^ *<Version>\(.*\)<\/Version>$/\1/p' "$root/bindings/csharp/Directory.Build.props")"
check bindings/unity/package.json "$(sed -n 's/^  "version": "\(.*\)",$/\1/p' "$root/bindings/unity/package.json")"
echo "$version"
