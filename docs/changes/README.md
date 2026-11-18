# Runtime changes

Every change in the official runtimes that makes the same skeleton data pose, load or render differently, from 3.5 to 4.3. Changes inside a minor are listed as well as changes between minors.

The editor is built on spine-libgdx, so the spine-libgdx core decides what an artist saw. Tags of spine-runtimes are sparse and mark no editor release. Editor bounds come from the `spine` version of example exports committed on each branch, commit dates and the editor changelog at esotericsoftware.com/spine-changelog.

Mixing changes inside AnimationState are out of scope, such as the turn direction a rotate timeline of an upper track picks, as are renderer changes, changes that need a runtime skeleton position, scale or flip, and mixes changed through the runtime API.

| Class | Meaning |
|---|---|
| rewrite | data the target runtime poses like the source editor, with the condition it needs. A failed condition falls back to the report code of the row |
| unconditional rewrite | rewrite made even with `--no-rewrite` |
| report | stable code of [report.md](../report.md), its impact is fixed per code |
| needs a runtime | no target data reproduces the source in general, listed in [changes/needs-a-runtime.md](needs-a-runtime.md) and still reported |
| undetectable | the data does not show the difference, no code |

## Files

Every commit is a link into spine-runtimes with its commit date. The Converter column names the files that hold the report code and the Fixture column the cases of `oracle/fixtures` that reproduce the row.

| Scope | File | Migration |
|---|---|---|
| inside 3.5 | [changes/3.5.md](3.5.md) | |
| inside 3.6 | [changes/3.6.md](3.6.md) | |
| inside 3.7 | [changes/3.7.md](3.7.md) | |
| inside 3.8 | [changes/3.8.md](3.8.md) | |
| inside 4.0 | [changes/4.0.md](4.0.md) | |
| inside 4.1 | [changes/4.1.md](4.1.md) | |
| inside 4.2 | [changes/4.2.md](4.2.md) | |
| inside 4.3 | [changes/4.3.md](4.3.md) | |
| 3.5 to 3.6 | [changes/3.5-3.6.md](3.5-3.6.md) | `src/migrate/v3_5_v3_6.zig` |
| 3.6 to 3.7 | [changes/3.6-3.7.md](3.6-3.7.md) | `src/migrate/v3_6_v3_7.zig` |
| 3.7 to 3.8 | [changes/3.7-3.8.md](3.7-3.8.md) | `src/migrate/v3_7_v3_8.zig` |
| 3.8 to 4.0 | [changes/3.8-4.0.md](3.8-4.0.md) | `src/migrate/v3_8_v4_0.zig` |
| 4.0 to 4.1 | [changes/4.0-4.1.md](4.0-4.1.md) | `src/migrate/v4_0_v4_1.zig` |
| 4.1 to 4.2 | [changes/4.1-4.2.md](4.1-4.2.md) | `src/migrate/v4_1_v4_2.zig` |
| 4.2 to 4.3 | [changes/4.2-4.3.md](4.2-4.3.md) | `src/migrate/v4_2_v4_3.zig` |
| rewrites and their conditions | [changes/rewrites.md](rewrites.md) | |
| semantics no data reproduces | [changes/needs-a-runtime.md](needs-a-runtime.md) | |
| runtime differences the oracle patches or misses | [changes/oracle.md](oracle.md) | |

## Editor versions

`src/Version.zig` maps each change of the files above to the last editor version with the old behavior and the first with the new one. An editor between both bounds is unsure.

| Direction | Editor old | Editor unsure | Editor new |
|---|---|---|---|
| within a minor or up | reported | reported | nothing |
| down | not reported, the old editor already poses like the older minor | reported | reported |
| rewrite | made | reported | nothing |

Converter output is labelled with patch 0 of its minor, such as `4.3.0`, and counts as new. A target without patch keeps the patch of a source of the same minor only when that source is new for every dated change of the minor. An older export converted within its minor gets the final semantics and patch 0, so converting the output again changes nothing and its binary layout is the final one. 3.8.80 was never released.

## Notes for users

[conversion.md](../conversion.md) lists the export advice and the data values that move a pose between versions.
