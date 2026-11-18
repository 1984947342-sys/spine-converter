# Architecture

The core is a Zig library without libc. Every binding goes through the C ABI in `include/spine_converter.h`.

## Pipeline

| Stage | Input | Output |
|---|---|---|
| detect | bytes | format and exact version |
| decode | bytes of version A | Document of version A |
| migrate | Document of version X | Document of version X+1 or X−1 |
| encode | Document of version B | bytes of version B |

An atlas skips these stages. `src/atlas.zig` parses it and writes the layout of the target version.

A conversion from A to B runs every adjacent migration between them. Every stage appends to one report.

## Document

```zig
Document = struct {
    version: Version,
    origin: Format,
    root: std.json.Value,
}
```

`root` is the tree in the JSON schema of `version`. Unknown keys and nonessential data pass through untouched.

`version` is the exact version such as 3.8.99. One binary codec serves one minor version in its final layout. JSON and binary beta exports older than the first supported beta of their minor fail with `UnsupportedVersion`. Release exports are always accepted.

| Minor | First supported beta | Last layout change in spine-runtimes |
|---|---|---|
| 3.5 | 3.5.03-beta | 36000e3c5 merge of the 3.5 betas with 3.5.03-beta exports |
| 3.6 | 3.6.14-beta | bc3cbf22e clipping attachments |
| 3.7 | 3.7.29-beta | 45fbd64e3 event volume and balance |
| 3.8 | 3.8.25-beta | 15b4c5488 IK softness |
| 4.0 | 4.0.27-beta | da1b28027 path constraint mix X and Y |
| 4.1 | 4.1.04-beta | 515d23888 sequences |
| 4.2 | 4.2.56-beta | f4f22cd5a bone inherit |
| 4.3 | 4.3.74-beta | 3b72294c6 IK scaleY |

`Document.setVersion` keeps `skeleton.spine` in sync with `version`.

Numbers are f64 through all stages. JSON output formats the shortest string that round-trips the f32 value. JSON output always holds `skeleton.hash`, empty when the source has none, because spine-csharp reads it without a default. Skel from 4.0 on holds eight hash bytes, so a JSON hash that is not base64 of eight bytes or more is written as none.

## Codecs

`src/json.zig` reads and writes the tree of every version. `src/binary/` holds one binary codec per minor version, listed in the table of `src/binary.zig`. A binary codec maps binary data to the JSON tree of the same version and interprets no semantics.

The porting reference is `SkeletonJson.java` and `SkeletonBinary.java` of spine-libgdx in the matching branch. spine-csharp drops nonessential data such as bone color, icon and visibility. Binary curves are read as raw Bézier control points.

## Migrations

`src/migrate/` holds one module per adjacent pair with `up` and `down`, listed in the table of `src/migrate.zig`.

| Step | Main changes |
|---|---|
| 3.5 to 3.6 | clipping and point attachments, two color tint, local and relative transform constraints, path spacing scaled by the bone world scale, curve start parameter, reflection of sheared noScale bones |
| 3.6 to 3.7 | IK compress and stretch, event audio, negative local transform mixes, absolute local shear, path spacing, fixed position and curve start semantics |
| 3.7 to 3.8 | skins become a list, curves split into curve c2 c3 c4, `paths` timelines become `path`, scale keys default to 1, IK softness, skin required bones and constraints, linked mesh deform, one bone IK on bones that do not inherit rotation or scale, two bone IK with the child at the parent origin |
| 3.8 to 4.0 | per-value Bézier curves, component timelines, constraint mix renames, rotation unwrapping, IK stretch, path and update order semantics |
| 4.0 to 4.1 | sequences and sequence timelines, deform timelines move under attachment timelines, linked mesh `deform` becomes `timelines`, transform mixScaleY alone no longer skipped |
| 4.1 to 4.2 | physics constraints and timelines, `transform` becomes `inherit`, inherit timeline |
| 4.2 to 4.3 | sliders, transform constraint `properties`, draw order folders, clipping modes, IK scaleY mode, linked meshes across slots |

Every runtime change is listed under `docs/changes` with its upstream commit, its class in the converter and its fixture. One file covers each minor and one each step, and `docs/changes/README.md` is their index.

A schema change renames or restructures data. A semantic change is identical data that the newer runtime evaluates differently, such as the 3.8 transform constraint solver.

A semantic change is handled by rewriting data so the target runtime produces the source pose or by a report entry. `down` steps drop or approximate features the older version lacks. Every case has a stable report code and impact in `docs/report.md`. Data without effect in the target runtime is reported with the impact it has, such as an inherit timeline that only holds the setup value.

## Rewrites

Rewrites run by default and behave identically in every use of the official target runtime. `SPC_FLAG_NO_REWRITE` and `--no-rewrite` keep the source structure, the data is then dropped and reported. A rewrite that loses runtime interaction, gives different results when tracks mix or needs a different runtime API is never made, apart from the slider rig. With that flag `convert.zig` migrates a lossy source a second time with rewrites and gives every loss that run rewrites the remedy `rewrite`, matched by step, path and code stem. The semantics of `changes/needs-a-runtime.md` carry the remedy `runtime` where they are reported.

| Rewrite | Condition |
|---|---|
| negative world scale mix of 3.5 to 3.8 becomes 0 in 4.0 and later | setup, keys and Bézier controls at most 0 |
| negative world shear mix of 3.5 to 4.2 becomes 0 in 4.3 | setup, keys and Bézier controls at most 0 |
| a world shear mix of 3.5 to 4.2 or a local scale or shear mix of 3.6 keyed through 0 becomes a 4.3 slider clamp | the source of an absolute world shear is not a constrained bone or below one |
| absolute world shearY offset of 3.5 to 4.2 moves to an additive shear constraint from the root in 4.3, signed by two helper bones when the source may reflect | root never sheared and a constant source reflection, else an offset below 180 |
| relative world shearY offset of 3.5 to 4.2 negated in 4.3 for a source that stays reflected, else signed by two helper bones | normal inherit, no shear or constraint and one scale sign per axis up to the root, else an offset below 180 |
| bones reset by a later ancestor constraint in 3.8 and early 4.0 and 4.3 exports leave the earlier constraint | the later constraint runs whenever the earlier does and nothing between reads those bones |
| 4.2 local absolute scale folds the division by the bone scale into the 4.3 scale mapping | one constant nonzero scale on every constrained bone and no transform keys |
| negative world scale mix of 3.5 to 3.8 that also turns positive becomes a 4.3 slider clamp | the root is not a constrained bone |
| 4.2 local absolute scale divided by a keyed bone scale becomes a slider rig in 4.3 | bone scales of one strict sign or 0, scale mixes of one sign or reaching 0 from one side, earlier constraints that keep the applied scale |
| absolute local rotate or shear offset of 4.1 and early 4.2 drops the whole turns the old wrap always removes | every difference stays in one window of 360, no physics or earlier constraint on the bones |
| relative world shear of 3.5 to 4.2 with a partial mix reads the source through a helper bone rotation that 4.3 wraps | a shear mix below 0 needs the slider clamp, a nonzero offset needs a constant source reflection or an offset below 180 |
| relative local scale of 4.0 before 4.0.27 becomes `1 + s * k` on helper bones in 4.3 | bone scale never 0, the constraint always runs, no earlier constraint on the bone |
| two bone stretch with a child Y position of 3.8 and early 4.0 solves a helper parent turned toward the child in 4.3 | uniform unkeyed parent scale, unkeyed child position, no other constraint on the bones |
| length spacing of 3.5 to 4.2 below minus the bone length becomes fixed spacing plus the bone length in 4.3 | every bone has the same nonzero length |
| 3.5 length and chain scale spacing and 3.6 fixed and chain scale percent spacing scaled by the bone world scale of a later version are divided or multiplied by that scale | every spaced bone keeps one constant world scale and a nonzero length |
| noRotationOrReflection of 3.5.02 and 3.5.03 betas becomes a normal bone copying the world of a three bone helper chain in 4.3 | no constraint on the bone or its ancestors |
| one bone IK of 3.x and of 3.8 before 3.8.81 on a bone that does not inherit rotation solves a normal proxy bone whose result a local transform constraint copies back | no other constraint moves the bone, below 4.3 its own running order and for stretch a bone of scale 1 |
| IK softness of 3.8.25-beta is divided by the child scale factor of 3.8 | parent scale 1, constant child scale, no other scaling constraint on the bones |
| linked mesh sequence of 4.1 betas played with the parent frame count becomes own hold keys and copied deform keys | no own keys, delays above 0, within the animation duration |
| mesh UVs of a 3.5 or 3.6 skeleton on a stripped region are mapped through the whitespace in 3.7 | atlas given, region unrotated |
| mixScaleY of 4.0 and 4.1 before 4.1.18 that other mixes leave 0 around becomes a slider gated copy in 4.3 | mixScaleY within 0 to 1 and no negative scaleY offset beside a shear mix, no scale rewrite on the constraint |
| 3.8 path mixes of which one turns positive and one drops to 0 or below become a slider gate in 4.3 | no skin bound path constraint |
| two bone IK that 4.2 skips gets setup mix 0 without timelines in 4.1 | no inherit timeline on its bones |
| setup rotation of a noScale bone read by a one bone IK after a world transform constraint of 4.2 or of 4.3 before 4.3.03 becomes 0 in 4.3 | rotation and shear mixes 0, scale mixes below 1, IK mix above 0 without stretch or compress, no rotate or inherit keys, no path or physics constraint |
| two bone IK of 4.1 on a child whose inherit is not normal solves a normal clone of the child in 4.2 | normal parent, no other constraint on the child |
| applied transform of a 4.1 bone with inherit other than normal, read by local transforms, becomes a normal mirror bone with its world | no shear, only local transforms read it, no other constraint on the bone |
| applied transform of a 4.1 bone read by one recomposing reader gets a mirror, a clone and copies before the reader, or into 4.3 a shear copy with scale -1 | no shear for the first, constant shear for the second, a reader that cannot skip |
| absolute local rotate or shear of 4.1 and 4.2 before 4.2.60-beta wrapped to 180 becomes helper bones in 4.3 | no physics or earlier constraint on the target or its bones |
| result reset by a later ancestor constraint or by a two bone IK at mix 0 in 3.8 and 4.0 betas, or by a later ancestor constraint in 4.3 before 4.3.18, becomes a local transform constraint after the resetting one that copies a clone of the bone in 4.3 | no shearX, scale never 0, no skin bone, the resetting constraint always active, in 4.3 no local constraint on the bone |
| 4.3 convex clipping becomes its convex hull in 4.2 | unweighted vertices and no deform timeline |

Three exact rewrites also run under `--no-rewrite`. negative local mixes of 3.7 betas become 0, two bone IK of 4.0 betas loses uniform and a 4.1 transform whose only mix is mixScaleY before 4.1.18 gets mixScaleY 0. `changes/rewrites.md` lists the full conditions.

The hull is a port of `SkeletonClipping::makeConvex` of 4.3. A rewrite is reported as `rewritten` with impact `none`.

## Atlases

3.5 to 3.8 atlases are positional. 4.0 and later atlases use named entries. A 4.x target always gets the named layout.

| 3.8 cannot hold | Code |
|---|---|
| header entries | `atlas.header.dropped` |
| `pma` | `atlas.pma.dropped` |
| unknown page entries | `atlas.page.dropped` |
| custom region values, split without four values, pad without a four value split | `atlas.values.dropped` |
| rotation other than 0 or 90, before 3.8 | `atlas.rotate.dropped` |
| stripped whitespace, before 3.7 | `atlas.strip.approximated` |

A region without `index` gets -1 and a region without `orig` gets its size, as in spine-libgdx.

3.7 maps mesh UVs through the stripped whitespace of a region and 3.5 and 3.6 map them to the packed size. An atlas carries no version, so only a 3.5 or 3.6 target reports stripped regions. Converting a 3.5 or 3.6 skeleton up reports every mesh and linked mesh with this code unless its atlas is given by `--atlas`, `spc_options.atlas` or `Options.atlas`. With the atlas a mesh on an unstripped region is exact, a mesh on a stripped unrotated region gets UVs mapped through the whitespace, u to u w plus offset x over original width and v to v h plus original height minus offset y minus h over original height, and a linked mesh is exact when its region strips like the region of its parent. A rotated stripped region stays reported, spine-libgdx 3.7 offsets it by the packed width and spine-csharp 3.7 by the packed height. 3.7 runtimes before [63238bfc6](https://github.com/EsotericSoftware/spine-runtimes/commit/63238bfc69d449bffa6518f2c357a8204ba90bff) 2018-12-19 still map to the packed size, the final 3.7 runtime is the reference.

## Output targets

Output loads in the official runtime of the target version. Editor import is not verified.

## Verification

`tools/fetch-corpus.sh` extracts the official example exports of each spine-runtimes branch into `testdata/corpus`. The assets are never committed.

Some early binaries carry no hash or version and cannot be detected. They need an explicit source version.

`zig build corpus` runs these checks on every file.

| Check | Rule |
|---|---|
| detect | right format and version, non-skeleton files rejected |
| json-round-trip | JSON decodes and encodes unchanged |
| skel-decode | a skel decoded to a Document equals the official JSON of the same export |
| skel-round-trip | a skel encoded again decodes to the identical Document |
| json-encode | the official JSON encoded to skel decodes to the Document of the official skel |
| atlas | detected as an atlas and converted to 3.8 and 4.3 |
| robustness | truncated and damaged skeletons and atlases return an error without crashing |

The comparator ignores key order and compares numbers by their f32 value. Checks against official JSON allow for how JSON exports differ from binary exports.

| JSON export behavior | Allowance |
|---|---|
| numbers keep seven significant digits | relative 2e-6 |
| setup vertices keep two decimals | absolute 0.0051 |
| 3.5 truncates every number to two decimals | absolute 0.0101 |
| values near their default are omitted | missing equals 0 or 1 within 0.0051 |
| mixY is written even when it equals mixX | covered by the missing rule |
| deform values that round to zero are trimmed | compared as dense arrays |
| the last key keeps its curve, stepped between keys equal within tolerance | curve ignored |
| 3.8 JSON splits bezier curves into curve c2 c3 c4 | c2 c3 c4 count as curve |
| skin bone and constraint lists are written in set order | sorted, hash ignored when a skin lists names |
| bone and slot visibility is omitted | ignored |
| one bone IK keeps its bend direction only in binary | ignored |
| bone slider max is written as time | read as max |
| 3.8 JSON and binary exports hash different data | hash ignored before 4.0 |
| 3.8 binary exports drop skins without attachments | such skins ignored before 4.0 |

The powerup exports of 3.6 to 3.8 hold 14 keys that are stepped in JSON and linear in skel, the 3.5 export holds 16. The corpus and the selfcheck make exactly those keys linear and then compare everything else, and they fail if any of those keys is not stepped.

The selfcheck skips two pairs that no key edit aligns. 3.5 tank keeps three decimals of its JSON Bézier handles, which moves the drive treads 7 units, and the skel handles put into the JSON make it match. 3.6 raptor-pro steps the first front-arm-goal IK key in JSON and the second in skel, and moving the step makes it match. The corpus makes the second skel key linear, since the first JSON key steps between equal mixes.

`oracle/codec.sh` checks semantics in the official runtime. skel to JSON, JSON to skel and skel to skel output must give the poses of the source within 1e-5.

`oracle/hostile.sh` damages every export of the corpus and text that is no skeleton. Damage covers references, parents, repeated names, wrong types, extreme numbers and bytes of a binary. A conversion may fail but must not crash or hang, and its output must read back. A case that fails stays in `zig-out/hostile` for `hostile replay`.

`oracle/variants.sh` changes one field of an export, deletes one or adds one the export leaves out. The last two variants of an export set an absent list to null and replace the hash with other text. Where the source runtime loads the variant it runs through `migrated` below towards the same version, both neighbors and 4.3. The change is printed with a failure.

`oracle/migrate.sh X Y` converts every X export to Y in both formats. The X runtime evaluates the original and the Y runtime evaluates the result.

| Rule | Detail |
|---|---|
| atlas | exports without one get one from `synth_atlas` in `oracle/lib.sh`, listing every region, mesh and sequence frame the skeleton names with placeholder bounds in the layout of X, poses do not depend on atlas contents |
| editor sources | a source whose editor predates a runtime change, as `pose-scope editor` and `pose-scope unsure` print, is posed by the C# dumpers of both minors, the source with `SPC_EDITOR`, because the converter reports against the editor of the source |
| editor source exports | every 3.5.03-beta, 3.6.14-beta, 3.6.32, 3.8.55, 3.8.76, 4.1.17 and 4.3.75-beta export of the corpus |
| tolerance | 5e-4 absolute and 5e-5 relative, which covers float rounding of constraints reformulated between runtimes |
| excuses | poses may differ only where a report entry of impact `pose` reaches, `editor` and `control` entries excuse nothing |
| render | with a `render` entry clipped regions are not compared |
| dropped data | a dropped dark color excuses dark colors, a dropped clipping or point attachment excuses the slots that held it |
| load | the Y runtime must still load the result |

Nine exports get a looser absolute tolerance. Each perturbation in the table moves the pose that far within one runtime alone.

| Export | Pairs | Tolerance | Cause |
|---|---|---|---|
| tank-pro | 3.7 or 3.8 on one side, 4.3 to 3.5 or 3.6 | 5e-3 | tank-root x keys scaled by 1+1e-7 move tread vertices 3.9e-3 in 3.8 and 3.4e-3 in 3.7 |
| chibi-stickers | 3.8 on one side | 5e-3 | left leg IK almost straight in emotes/thinking, hips setup y moved by 3e-5 moves leg-down-l 3.9e-3 in 3.8, 4.0 and 3.8 land one f32 step apart on the hips |
| 4-wave-principle | any 3.x on one side | 3e-2 | 4.0 and later sample Bézier curves in f32 from absolute key times, near 7 s curve points move 1.4e-6 s and chain-end vertices at 17870 units per second land up to 2.5e-2 off, measured 2.15e-2 |
| alien-pro | 3.6 on one side | 5e-3 | the eye bone crosses 926 units on one curve of death, 4.0 and later land 2.0e-3 apart at 1.92 s, 3.8 passes because its eyeball vertices sit farther out and fall under the relative tolerance |
| 6-arcs-pro | 4.3 to any 3.x | 5e-3 | Bézier class of `oracle/external.sh`, lands 3.5e-3 apart |
| sack-pro | 4.3 to any 3.x | 5e-3 | Bézier class, 2.9e-3 |
| tank-pro | 4.3 to any 3.x | 5e-3 | Bézier class, 1.5e-3 |
| raptor-pro | 4.3 to any 3.x | 2e-3 | Bézier class, 1.1e-3 |
| spineboy-pro | 4.0 to 3.8 | 2e-3 | Bézier class, 1.3e-3 |
| stretchyman-pro | 3.8 to 4.x | 1e-3 | body vertices land 7.0e-4 apart between spine-csharp 3.8 and 4.x |

The Bézier class passes within 5e-4 once every source key is linear. The 3.8 result of 4-wave-principle stays within 1.3e-4° of the exact curve, 4.0 is 1.6e-3° off.

A mismatch passes only inside the scope of the pose entries. `pose-scope`, built from `oracle/scope.zig`, reads the source converted to 4.3 JSON and the report, and prints the bones, slots and animations each pose entry reaches. `pose-compare --excuse` compares bones one by one and passes when every mismatch lies in that scope. The file then prints `LOSSY` with its pose codes and the number of excused mismatches.

| Report path | Excused |
|---|---|
| `ik.C` `transform.C` `path.C` `physics.C` `slider.C` `constraints.C` | bones of constraint C, for a slider what its animation keys |
| `bones.B` | bone B |
| `slots.S` | slot S |
| `skins.K.S.A` | slot S in skin K |
| `animations.A.<list>.<name>` | the row of the list for that name, in samples of A |
| `animations.A.attachments.K.S.A` `animations.A.deform.K.S.A` | slot S in skin K, in samples of A |
| `animations.A.drawOrder` `animations.A.drawOrderFolder` | draw order in samples of A |
| `animations.A.slider` | every value in samples of A |
| `animations.A.physics` | bones of every physics constraint, in samples of A |
| `skeleton.*` | every value |
| `animations.A` with `animation.duration.approximated` | samples of A past the shorter end, an entry of impact `control` |
| anything else | nothing, with a warning on stderr |

The scope then grows to descendants of excused bones, to the bones of every constraint whose target, source, bone or path slot is excused, to slots on excused bones or with vertices weighted to them and to slots inside a clipping range that starts at an excused slot. Names may hold dots, so the longest known name wins. `pose-compare` pairs samples in order within each skin and animation, so a shorter animation shifts no other sample.

`oracle/external.sh <directory> [target version] [tolerance file]` runs the migrate comparison on every skeleton under a directory outside the repository, so private assets stay out of it.

| Rule | Detail |
|---|---|
| atlas | the one named after the skeleton, else the only atlas beside it |
| skipped | skeletons of a version without a runtime |
| loader | picked by content, a skel named `.json` still loads |
| tolerance | that of `oracle/migrate.sh`, or lines of `<path in directory> <abs> <rel>` in a tolerance file kept with the assets |

| Noise class in game assets | Cause | Handling |
|---|---|---|
| fast Bézier curves | 3.8 builds curve tables in percent space and 4.0 from absolute times, a bone keyed at 12399 units per second lands 7.3e-3 apart while moving its control times by 3 to 6 f32 steps moves it up to 1.27e-2 within 4.0 alone | tolerance |
| parent scale keyed through zero | IK inverts a nearly singular matrix, 3.8 interpolates the key as `1 - (time - frameTime) / (prevTime - frameTime)` and 4.0 as `(time - before) / (after - before)`, one f32 step apart moves a bone by 8, from 4.1 the solve is skipped below a determinant of 1e-4 | reported as `ik.singular.approximated` |

A deviation belongs to the curve class when it falls under the default tolerance once every key of the source is made linear.

`oracle/atlas.sh` converts every atlas of each listed version to each listed version. The source runtime parses the source and the target runtime parses the result. Pages and regions must be equal apart from the fields a report entry names.

`oracle/fixtures.sh` converts every fixture of `oracle/fixtures` in both formats as its sidecar `NAME.expect` states. The C# dumpers pose source and result, and the source dumps with `SPC_EDITOR` set to the runtime changes its editor predates, see C# dumpers. A fixture without an atlas gets one from `synth_atlas`. The runner removes an empty default skin before converting and posing, because no skel holds one and every JSON loader keeps it.

| Sidecar line | Meaning |
|---|---|
| `to <version>` | target version |
| `code <code>` | expected code, may repeat |
| `rewrite yes` | rewrite fixture and its rewritten run may keep only control losses |
| `from <version>` | its minor picks the dumper of the source, default the source version |
| `editor <keys>` | `SPC_EDITOR` of the source dump, keys apart by spaces or commas, default from `pose-scope editor` |
| `tolerance <abs> <rel>` | default 5e-4 and 5e-5 |
| `expect fail` | the fixture must fail, used by the self tests |

| Kind | Passes when |
|---|---|
| exact | no code, or only `rewritten` codes without `rewrite yes`, every code is reported and poses match |
| report | every code is reported, poses differ without excuse and match with the excuse of `oracle/migrate.sh`, a `remedy` line names the remedy every code carries |
| rewrite | with `--no-rewrite` every code is reported with remedy `rewrite` and poses differ, without it every code ends in `rewritten`, no other loss is reported and poses match |

Rewrite fixtures compare clipped regions instead of clipping polygon vertices. `self-report` passes as a report fixture, while the `absent` self tests lack their trigger and must fail. The runner also converts the 4.3 exports with clipping to 4.2 with rewrites after giving their clipping the convex flag. Poses and clipped regions must match within 5e-4 absolute and 5e-5 relative, a clipping loss fails and other losses of the export may differ only inside their scope. Output under `--no-rewrite` was checked byte for byte against the output before rewrites existed.

## Oracle dumpers

`oracle/` holds one program per version, built by `build.zig` from the official runtime of that version. `dump_c.c` serves the spine-c of 3.5 and 3.6, `dump.cpp` serves the spine-cpp of 3.7 to 4.2 and `dump_4.3.cpp` serves the pose API of 4.3. 3.5 comes from tag 3.5.51, because the 3.5 branch moved on to 3.6 betas. spine-c builds without the shift and nonnull sanitizers, because it shifts into the sign bit and copies zero bytes from null. The runtimes are development dependencies only.

`tools/fetch-runtimes.sh` applies `oracle/patches/<version>.patch` to spine-c for 3.5 and 3.6 or spine-cpp from 3.7, and `oracle/patches/<version>-csharp.patch` to spine-csharp after export. Each patch backports an upstream fix the oracle depends on or aligns the runtime with spine-libgdx, which the editor runs.

| Version | Backported fix |
|---|---|
| 3.8 | JSON true and false read as the default |
| 3.8 | a skin without attachments crashes the JSON loader |
| 4.0 | JSON transform timelines ignore mixShearY after the first key |
| 4.0 | two bone IK yields NaN from float rounding |
| 4.1 | JSON transform constraint timelines keep the shear mix of the first key |
| 3.8 | skel slot dark colors read in the wrong byte order |
| 4.0 | JSON two color timelines read dark green in place of dark red |
| 3.5 | JSON path constraint mix timelines are dropped |
| 3.5 | a path constraint whose slot has no setup attachment crashes the skeleton |
| 3.7 | atlas regions have no accessor |
| 3.7 to 4.3 | atlas format names are off by one |
| 4.0 to 4.3 | atlas regions without index get 0 instead of -1 |
| 4.0 to 4.3 spine-csharp | atlas regions without index get 0 instead of -1 |
| 3.5 to 3.7 spine-csharp | sin, cos and atan2 come from a table and an approximation |
| 3.6 spine-csharp | the setup pose keeps the dark color of the last pose |
| 3.7 spine-csharp | JSON IK timelines default compress to true |
| 3.7 | the setup pose keeps the dark color of the last pose |
| 3.7 | skel slot dark colors read in the wrong byte order |
| 3.5 3.6 | path rotation offset added and also subtracted scaled by degrees to radians |
| 3.6 | path epsilons of 3.5, comparing against 0 and starting a curve at 1e-4 |
| 3.7 3.8 | transform scale guards skip a scale up to 1e-5, negative local scale included |
| 3.7 to 4.2 | absolute local shear mix written to the local pose and not to the applied shear |
| 4.1 | backport 96c084202 of the 4.2 applied transform, which also negates its shear and dereferences the root parent |
| 4.2 | absolute local transform wraps rotation and shear to 180 |
| 4.3 spine-csharp | f83b75ea9, a slider constrains slots of linked meshes it keys |

Each dumper loads skeleton data and its atlas without textures. It samples the setup pose, then every animation at time 0 and at half frames of 30 fps. Half frames keep sample times off stepped keys and attachment keys.

The 3.8 dumper reads a 4.x atlas after `atlas_in` in `oracle/lib.sh` converts it to the 3.8 layout with the converter.

For each sample it resets to the setup pose, applies the animation with `Animation.apply`, disables physics on 4.2 and later, and updates world transforms. `ORACLE_FLIP` and `ORACLE_PHYSICS` flip the skeleton and enable physics, see `changes/oracle.md`. `AnimationState` is not used because its mixing differs across versions.

The output holds bone world transforms, slot attachments, slot colors and dark colors, draw order and deformed vertices in one format for all versions. From 4.1 a slot showing a sequence also carries the region index the sequence draws, in 4.3 only for sequences of more than one region, and `oracle/compare.zig` compares it when both dumps have it. Region vertices start at the bottom right corner as from 3.6, so the 3.5 dumpers rotate them by one corner. Every skin is sampled. The first sample of each animation also lists the events fired over its whole duration. A slot with a clipping attachment carries the fraction of each cell of a 4 by 4 grid over its polygon that the official clipper keeps.

With only an atlas argument a dumper prints the pages and regions the runtime parsed. The 4.3 dumper swaps back the size of rotated regions, which 4.3 stores packed.

`oracle/compare.zig` compares two dumps with absolute and relative tolerance. Colors use at most 2e-3 absolute. Event volume and balance are compared only with an audio path, because runtimes load them only then and 4.3 defaults them to 0. `--no-clip` skips the clipped regions and `--clip-region` compares clipped regions instead of clipping polygon vertices. `--no-dark` skips dark colors and `--no-dropped` skips slots whose attachment is gone from the actual dump. `oracle/migrate.sh` passes `--no-clip` with any `render` entry, `--no-dark` with a dropped dark color and `--no-dropped` with a dropped clipping or point attachment. `oracle/selfcheck.sh` compares the JSON and skel of every export of one version with a loose tolerance and only proves the dumper is consistent. Exports before 4.3 keep two decimals in JSON, so their tolerance is 5 absolute, 5e-2 relative and 5e-3 for colors.

## C# dumpers

`oracle/csharp/Dump.cs` prints the format of `dump_c.c` from spine-csharp 3.5 and 3.6 and of `dump.cpp` from spine-csharp 3.7 to 4.2. `oracle/csharp/Dump35` to `Dump42` compile it with the exported sources of their version through `Dump.props`, and each defines `V36` to `V42` up to its version. `oracle/csharp/Dump43` prints the format of `dump_4.3.cpp`. They need only the .NET 8 SDK. Dump38 reads 3.8.75 exports as 3.8.99 like `oracle/lib.sh`. Atlas lists are private before 3.8 and are read by reflection. 4.1 and later swap the packed size of rotated regions, so the dumpers swap it back.

spine-csharp before 3.8 takes sin and cos from a table of 16384 entries and atan2 from an approximation off by up to 0.28°. The 3.5 to 3.7 patches backport the exact functions 3.8 made the default, so the dumpers show what the runtime computes and not the table noise.

`oracle/csharp.sh <version>...` dumps every export of those versions in the corpus with the native runtime and with spine-csharp. Exports without an atlas use `synth_atlas` as in `oracle/migrate.sh`. Poses must match within 5e-4 absolute and 5e-5 relative and atlases must print the same. Files that detect as another version are skipped.

The native runtimes as built for the oracle round differently from spine-csharp.

| Versions | native runtime | spine-csharp |
|---|---|---|
| all | clang fuses multiply and add into FMA on hosts that have it | separate multiply and add |
| all | float sin, cos, atan2 and acos | double math rounded to float |
| 4.0 to 4.3 | Bézier steps from double constants | float constants like spine-libgdx |
| 3.8 | region offsets from region scale | region offsets from half sizes |
| 3.8 | two bone IK multiplies by l1 squared | multiplies by l1 twice |

With spine-cpp aligned on all five in a scratch build, every 3.8 and 4.3 export dumps the same bytes in both runtimes. Only 3.8 events without an audio path differ, spine-cpp defaults their volume to 1 and spine-csharp to 0 like spine-libgdx. These exports amplify the differences and get a looser absolute tolerance. Each perturbation moves the pose that far within the native runtime alone.

| Export | Tolerance | Measured | Amplifier |
|---|---|---|---|
| tank-pro | 5e-3 | 2.9e-3 | 36 tread bones chained by one path constraint |
| 3.5 tank | 5e-3 | 1.5e-3 | the same treads, tankRoot x keys scaled by 1+1e-7 move them 1.5e-3 |
| 3.5 stretchyman | 2e-3 | 9.9e-4 | bone rotations scaled by 1+1e-7 move the body vertices 1.0e-3 |
| 3.5 test | 3e-1 | 2.9e-1 | pathfollower tangent from a curve parameter of 1e-4, spine-c without FMA lands 1.2e-4 from spine-csharp |
| 3.6 vine-pro | 5e-3 | 3.4e-3 | tangents at the curve start, spine-c without FMA lands 3.7e-4 from spine-csharp |
| 4.1 and 4.2 chibi-stickers | 5e-3 | 1.9e-3 | left leg IK almost straight in emotes, one ulp on the hips y moves leg-l 2.3e-3 |
| 4.0 to 4.3 raptor-pro | 1e-1 | 9.4e-2 | front arm IK fully straight in roar from 0.55 to 0.62 s, front-arm x scaled by 1+1e-7 moves it 9.4e-2 |
| 4.2 and 4.3 celestial-circus | 1e-3 | 7.9e-4 | vertices up to 600 units from the swing pivot, one ulp on the swing-top rotation moves them 7.8e-4 |

Editor toggles bring back what an early patch editor ran. `oracle/csharp/SpcEditor.cs` reads `SPC_EDITOR`, a comma separated list of `Version.Change` keys, and `oracle/patches/<version>-csharp.patch` restores the spine-libgdx code before each listed change. Without the variable every corpus dump is byte identical to the runtime before the toggles. `pose-scope editor <version>` prints the keys whose `Version.editor` is old for a version and `pose-scope unsure <version>` those that may be old.

| Key | Restored spine-libgdx code | Commits reversed |
|---|---|---|
| offset_reflect_35 | transform and path offsets keep their sign under a reflected target | 5b8a7420e f5a6b4bf9 c21502385 16eb6b5ed |
| no_rotation_35 | noRotationOrReflection rebuilds the parent and rotates the local matrix by the parent angle | 3bfe46253 |
| reflect_order_36 | noScale reflection applied after the local shear | 8f6725db3 |
| path_epsilon_36 | path epsilons of 3.5 | bcf90240d |
| zero_bone_nan_36 | NaN spacing after a zero length bone, which puts later bones on the path start | 84fe30a2b |
| zero_bone_36 | zero length bones keep their spacing | bcf90240d |
| reflect_37 | noScale bones lose the reflection of their parent | cb5e05008 |
| local_mix_37 | local mixes up to 0 skipped, absolute local shear written to the local pose | 006242458 |
| path_start_37 | curve start and tangent from the cubic at 1e-5 | 9be30c44c |
| ik_solve_3825 | two bone IK without the origin fallback, softness not scaled | e3bc0822e |
| ik_world_38 | one bone IK solved in parent space | 203a648ae d94ebeae7 |
| order_40 | applied transforms validated lazily, so a later ancestor constraint resets earlier results | 4f73fbbb3 |
| stretch_40 | two bone stretch keeps the child y, uniform does not scale y | f9862b10b 33bce01fe |
| relative_scale_40 | relative local scale `1 + s * k` | efac69ee7 |
| zero_bone_40 | zero length path bones get space 0 | 1b4973628 df489b1f4 |
| mix_scale_y_41 | a transform constraint with only mixScaleY skipped | 4bad9ec25 |
| ik_singular_41 | IK solved through a singular parent | 3fd5ed228 e04e7b58f |
| sequence_mode_41 | no pingpongReverse mode | a898aed29 |
| sequence_linked_41 | linked mesh sequences counted by the parent | 4efd63f89 |
| local_wrap_42 | absolute local rotate and shear differences wrapped to 180 | 508e501fd |
| reset_43 | world constrained children rebuilt from their local pose | 50e82f316 |
| volume_43 | IK scaleY volume divides by the raw factor | 701f8831c |
| derive_43 | local pose derived like 4.2, thresholds 1e-4 | 6532b08b7 |
| singular_43 | noRotationOrReflection threshold 1e-5 | 7dc4d495c |
| slider_linked_43 | a slider does not constrain slots of linked meshes it keys | f83b75ea9 |

The dumpers reset the setup pose before every sample, so two keys differ from the editor. local_mix_37 gives the first update after a reset where the old editor accumulated absolute local shear across updates. slider_linked_43 only matters when slider output carries over between updates. spine-csharp 4.3 lacks the port of f83b75ea9, so its patch also ports it into the default path. ik_frames_3825 and json_mix_43 are export fixes and have no toggle, and clip_vertices_36 has none yet.

## Licensing

Codecs and migrations are ported from the Spine Runtimes and keep its license header. The repository is distributed under the Spine Runtimes License. Users must hold their own Spine Editor license.
