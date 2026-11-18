using System;
using System.Collections.Generic;

/// Keys are Version.Change names, oracle/patches/<version>-csharp.patch restores the libgdx code before each change
static class SpcEditor {
	static readonly HashSet<string> keys = new HashSet<string>((Environment.GetEnvironmentVariable("SPC_EDITOR") ?? "").Split(','));

	public static bool Old (string key) {
		return keys.Contains(key);
	}
}
