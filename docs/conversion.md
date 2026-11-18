[English](conversion.md) | [中文](conversion.zh-CN.md)

# Conversion

A conversion loads in the official runtime of the target version and poses as the source poses in its own editor. Every difference is listed in the [report](report.md).

## Versions

| Minor | Earliest accepted beta |
|---|---|
| 3.5 | 3.5.03-beta |
| 3.6 | 3.6.14-beta |
| 3.7 | 3.7.29-beta |
| 3.8 | 3.8.25-beta |
| 4.0 | 4.0.27-beta |
| 4.1 | 4.1.04-beta |
| 4.2 | 4.2.56-beta |
| 4.3 | 4.3.74-beta |

Every release export is accepted. Beta exports before the beta in which the format of their minor was frozen fail with `SPC_ERR_UNSUPPORTED_VERSION`. Data that carries no version cannot be converted. A JSON skeleton without `skeleton.spine` fails with `SPC_ERR_UNSUPPORTED_VERSION` and a binary without hash and version, as some early exports are, fails with `SPC_ERR_UNKNOWN_FORMAT`. Export such skeletons as JSON with a version or set `skeleton.spine` by hand.

A target version such as `4.3` writes `4.3.0`. A target of the same minor as the source keeps the source patch only when the source already has the final behavior of that minor. An older export converted within its minor gets the final behavior and patch 0, so converting the output again changes nothing.

## Steps

| Step | Effect |
|---|---|
| detect | format and version from the data |
| decode | JSON or binary of the source version into one tree |
| migrate | one adjacent version at a time, such as 3.8 to 4.0 to 4.1 |
| encode | JSON or binary of the target version |

Unknown keys and editor data pass through when the target can hold them. Numbers keep their f32 value. JSON output always holds `skeleton.hash`.

## Rewrites

The runtimes changed how some data poses, such as transform constraint mixes, IK of bones that do not inherit rotation and the constraint order. A rewrite restructures such data, often with helper bones or constraints, so the target runtime gives the source pose. A rewrite is made only when it holds for every use of the target runtime, including mixed tracks.

| Mode | Behavior |
|---|---|
| default | rewrites run, each is reported as `rewritten` with impact `none` |
| `--no-rewrite`, `SPC_FLAG_NO_REWRITE` | the source structure is kept, the data that needed a rewrite is dropped or approximated and reported with remedy `rewrite` |

Data outside the condition of a rewrite is reported. [changes/rewrites.md](changes/rewrites.md) lists every rewrite and its condition.

## Downgrades

An older target drops or approximates the features it lacks, such as physics, sliders, sequences, clipping modes and transform constraint properties. Each one is reported with its impact.

| Impact | Meaning |
|---|---|
| `editor` | only editor data is lost, playback is identical |
| `control` | playback is identical, code that drives the runtime sees a difference |
| `pose` | bones, slots, attachments, deform or draw order differ |
| `render` | the pose is identical, the rendered image differs |

## Atlases

3.5 to 3.8 atlases are positional, 4.0 and later atlases use named entries. Converting an atlas writes the layout of the target version.

| A 3.8 or older atlas cannot hold | Code |
|---|---|
| header entries | `atlas.header.dropped` |
| `pma` | `atlas.pma.dropped` |
| unknown page entries | `atlas.page.dropped` |
| custom region values, split without four values, pad without a four value split | `atlas.values.dropped` |
| rotation other than 0 or 90, before 3.8 | `atlas.rotate.dropped` |
| stripped whitespace, before 3.7 | `atlas.strip.approximated` |

3.7 maps mesh UVs through the stripped whitespace of a region, 3.5 and 3.6 map them to the packed size. Converting a 3.5 or 3.6 skeleton up reports every mesh unless its atlas is given by `--atlas`, `spc_options.atlas` or the `atlas` argument of a binding. With the atlas, meshes on unstripped regions and on stripped unrotated regions are exact.

## Exports

Export from the latest patch of a minor when the project is still available. Beta exports and early patches carry runtime changes that the final runtime of their minor poses differently, and the converter reports or rewrites them.

Re-export 3.8.75 skeletons with another 3.8 editor. No runtime documents what the 3.8.75 exporter broke.

| Data that poses differently between versions | Versions |
|---|---|
| negative transform scale mix | skipped in world mode before 4.0, in local mode before 3.7.74-beta |
| negative transform shear mix | skipped in world mode before 4.3, in local mode before 3.7.74-beta |
| shearY offset on an absolute world transform | 4.3 adds it before the wrap |
| rotate or shear difference past 180 on a local absolute transform | wrapped before 4.2.60-beta |
| local scale not 1 under a local transform | relative before 4.0.27, absolute divided before 4.3 |
| negative scale on an ancestor of a noScale bone | 3.6 before 3.6.38, 3.7 before 3.7.72-beta |
| bone scale passing zero | IK and inherit thresholds changed in 4.1 and 4.3 |
| constraint order with a later constraint on an ancestor | earlier results reset in 3.8, 4.0 before 4.0.76-beta and 4.3 before 4.3.18 |

## Limits

| Case | Behavior |
|---|---|
| runtime behavior that no target data reproduces, such as physics integration between 4.2 and 4.3 | reported with remedy `runtime`, listed in [changes/needs-a-runtime.md](changes/needs-a-runtime.md) |
| AnimationState mixing, renderers, skeleton position, scale and flip set at runtime | out of scope |
| import of the output into the Spine editor | not verified |
| `.spine` project files | not supported |

[changes/README.md](changes/README.md) lists every runtime change from 3.5 to 4.3 with its upstream commit and its handling, in English.
