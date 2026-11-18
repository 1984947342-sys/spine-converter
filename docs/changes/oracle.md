# Oracle blind spots

The native oracle uses spine-c for 3.5 and 3.6 and spine-cpp from 3.7, which differ from spine-libgdx in these places. `oracle/patches/<version>.patch` aligns each with spine-libgdx. spine-csharp matches spine-libgdx in these places except where a row names it.

| Runtime | Difference to spine-libgdx | Oracle |
|---|---|---|
| spine-c 3.5 3.6 | path rotation offset added and also subtracted scaled by degrees to radians | patched |
| spine-c 3.6 | path epsilons of 3.5 | patched |
| spine-c 3.6 and spine-csharp 3.6 | world and absolute local scale guard `> 0.00001` and a relative local guard skip negative scale where spine-libgdx tests `!= 0` and has no relative guard | patched |
| spine-cpp 3.7 3.8 | scale guard `> 0.00001` skips negative local scale | patched |
| spine-cpp 3.7 to 4.2 | absolute local shear mix changes the local pose and never reaches the world | patched |
| spine-cpp 4.0 4.1 | negative world scale mix skipped where spine-libgdx and spine-csharp apply it | fixed by [7d92f9e31](https://github.com/EsotericSoftware/spine-runtimes/commit/7d92f9e31de178d163a86fb817ebe56829e74ce9), not patched |
| spine-cpp 4.1 | carries [efb015ef4](https://github.com/EsotericSoftware/spine-runtimes/commit/efb015ef4eb89f2b1cf205e469cc311632d7217c) through backport [96c084202](https://github.com/EsotericSoftware/spine-runtimes/commit/96c0842021c87f350adedc88376a5a41107e9684) | patched |
| spine-cpp 4.2 | absolute local transform still wraps to 180 | patched |
| spine-libgdx 4.0 to 4.2 | path setup without mixY reads 1 where spine-cpp spine-csharp and spine-ts read mixX | fixed by [489532921](https://github.com/EsotericSoftware/spine-runtimes/commit/48953292156fde8a638e87a4eceb175c1475f2ac), the converter follows the fix |
| spine-csharp | binary strings decode as UTF-8 where spine-libgdx and spine-ts read each UTF-16 unit from one to three bytes | not covered, JSON output joins surrogate pairs from binary and binary output keeps the bytes of its source |
| spine-csharp | a null `ik`, `transform`, `path`, `events` or `constraints` list throws where spine-c and spine-cpp read it as missing | sources it poses are skipped by `oracle/variants.sh`, the JSON reader drops null members of the root |

The final runtime of a minor never poses like an earlier patch editor. The C# dumpers restore the spine-libgdx code before each change listed in the file of its minor when `SPC_EDITOR` names its key, see `architecture.md`.

`oracle/migrate.sh` and `oracle/external.sh` excuse a mismatch only on the bones, slots and animations that `pose-scope` maps from the pose entries of the report. A source whose editor predates or may predate a change of its own minor is posed by spine-csharp of both minors, the source with `SPC_EDITOR`. An animation reported shorter excuses only its samples past the new end.

`ORACLE_FLIP=x` or `y` flips the skeleton in every dumper. `oracle/migrate.sh` and `oracle/variants.sh` then judge `bone.flip.approximated`, `skeleton.scale.approximated`, `transform.offsetFlip.approximated` and `path.offsetFlip.approximated` as pose, and a fixture with a `flip` line does the same. `ORACLE_PHYSICS=1` runs physics from 4.2 on, restarted for each animation and stepped by one sample per frame.

| Pass | Result |
|---|---|
| selfcheck and csharp with either switch | match |
| migrate with `ORACLE_FLIP=x` | match after the offsetFlip codes |
| migrate 4.2 to 4.2 and 4.3 to 4.3 with `ORACLE_PHYSICS=1` | match |
| migrate between 4.2 and 4.3 with `ORACLE_PHYSICS=1` | differs on every export with physics, trajectories changed between the minors |

A 4.3 reset by a later physics constraint, as in celestial-circus-pro and snowglobe-pro, shows only with physics enabled.

Fixtures the C# runner cannot settle carry `expect fail` and a note in their sidecar.

| Fixture | Code | Reason |
|---|---|---|
| B14-color-clamp-43 | `color.clamp.approximated` | spine-csharp 4.2 clamps every color timeline, the native 4.2 and 4.3 dumpers show the difference |
| E4-json-mix-43 | `transform.jsonMix.approximated` | no 4.3.00 to 4.3.23 JSON export to restore the old loader from |
| I19-slider-linked-43 | `slider.linkedMesh.approximated` | the dumpers reset the setup pose before every sample and the difference needs continuous playback |
| I4-clip-vertices-36 | `clipping.vertices.approximated` | spine-csharp never ignores a clipping polygon below 3 vertices and the dumps show no slot it clips away |
