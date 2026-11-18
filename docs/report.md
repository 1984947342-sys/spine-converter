[English](report.md) | [中文](report.zh-CN.md)

# Conversion report

`spc_result_report` returns a JSON array. Each entry describes one item that was not converted exactly.

```json
[
  {
    "code": "physics.dropped",
    "severity": "dropped",
    "impact": "pose",
    "step": "4.2-4.1",
    "path": "physics.hair",
    "message": "physics constraint",
    "remedy": "none"
  }
]
```

| Field | Meaning |
|---|---|
| `code` | stable identifier, safe to match in scripts |
| `severity` | `dropped`, `approximated` or `rewritten`, always the last segment of the code |
| `impact` | what the target runtime loses, fixed per code |
| `step` | migration step that produced the entry, empty for codecs |
| `path` | dotted path in the source document |
| `message` | human readable text, may change between releases |
| `remedy` | how the loss can be avoided, set per entry |

| Impact | Meaning |
|---|---|
| `none` | rewritten data, the target runtime behaves identically |
| `editor` | editor data, the target runtime behaves identically |
| `control` | playback is identical, code driving the runtime sees a difference |
| `pose` | bones, slots, attachments, deform or draw order differ during playback |
| `render` | the pose is identical, the rendered image differs |

| Remedy | Meaning |
|---|---|
| `none` | no converter flag changes the loss, its impact states what differs |
| `rewrite` | only under `SPC_FLAG_NO_REWRITE` or `--no-rewrite`, the default rewrites make the entry exact, found by a second migration with rewrites |
| `runtime` | a semantics of [changes/needs-a-runtime.md](changes/needs-a-runtime.md), no target data reproduces it, a runtime patch or a rig change does |

One code can carry different remedies, such as `transform.scale.approximated` with `rewrite` for a keyed bone scale and `runtime` for a bone scale that reaches 0. Rewritten entries carry `none`, and no entry carries `rewrite` without `--no-rewrite`.

Impacts are ordered from `none` to `render`. `spc_result_loss_count` counts entries that are not `rewritten`. `spc_result_max_impact` returns the most severe impact. `spc_result_remedy_count` counts entries of one remedy. `SPC_FLAG_FAIL_ON_LOSS` fails when the loss count is not zero.

The CLI prints each entry as `severity impact code path message remedy` separated by tabs, then a summary line when there are losses that also counts the `rewrite` and `runtime` remedies, and exits with 3 when the output was written with losses.

| Code | Severity | Impact | Meaning |
|---|---|---|---|
| `slider.dropped` | dropped | pose | slider constraint without an older equivalent |
| `animation.slider.dropped` | dropped | pose | slider timelines of an animation |
| `slider.linkedMesh.approximated` | approximated | pose | slider keying a linked mesh whose source mesh is in another slot, applied differently by 4.3 before 4.3.24 |
| `animation.color.dropped` | dropped | editor | animation color |
| `animation.drawOrderFolder.dropped` | dropped | pose | draw order folder timelines |
| `bone.icon.dropped` | dropped | editor | bone icon, or its size and rotation |
| `ik.scaleY.approximated` | approximated | pose | IK scaleY volume becomes none |
| `physics.scaleY.dropped` | dropped | pose | physics scaleY mode becomes none, also uniform above scaleX 1 in 4.3 binary, which reads it as volume |
| `transform.local.approximated` | approximated | pose | local source and local target differ, local target wins |
| `transform.clamp.dropped` | dropped | pose | transform constraint clamp |
| `transform.property.dropped` | dropped | pose | transform property mapped to another property or with offset or scale |
| `transform.scale.approximated` | approximated | pose | 4.2 local absolute scale divides by the bone scale, 4.3 does not, for a bone whose applied scale can differ from 1 |
| `transform.scale.rewritten` | rewritten | none | local absolute scale division folded into the scale mapping for a constant applied scale and mix, or rebuilt as a slider rig for a keyed bone scale |
| `clipping.convex.dropped` | dropped | render | convex clipping |
| `clipping.inverse.dropped` | dropped | render | inverse clipping |
| `clipping.convex.rewritten` | rewritten | none | convex clipping without weights or deform, vertices become the hull 4.3 clips with |
| `clipping.vertices.approximated` | approximated | render | clipping polygon with fewer than 3 vertices of a 3.6 export before 3.6.35, ignored by the editor from 3.6.35 and by spine-cpp 4.3 |
| `clipping.vertices.rewritten` | rewritten | none | clipping polygon with fewer than 3 vertices of a 3.6 export up to 3.6.32 became a far triangle on an unscaled helper bone, so every runtime clips the range away as that editor did |
| `linkedmesh.slot.approximated` | approximated | pose | source mesh in another slot is copied, its timelines are not inherited |
| `skeleton.referenceScale.dropped` | dropped | editor | physics reference scale |
| `bone.visible.dropped` | dropped | editor | bone editor visibility |
| `slot.visible.dropped` | dropped | editor | slot editor visibility |
| `skin.color.dropped` | dropped | editor | skin color |
| `physics.dropped` | dropped | pose | physics constraint |
| `physics.step.approximated` | approximated | pose | physics constraint of 4.2 in 4.3 or back, the minors step physics through different integrators |
| `animation.physics.dropped` | dropped | pose | physics timelines of an animation |
| `animation.duration.approximated` | approximated | control | animation ending earlier because its last keys were dropped, so loops and completion come sooner |
| `animation.inherit.dropped` | dropped | pose | bone inherit timeline |
| `animation.inherit.setup.dropped` | dropped | control | inherit timeline holding only the setup inherit of its bone |
| `mesh.triangles.approximated` | approximated | render | skel from 4.2 on implies the triangle count, extra triangles are cut |
| `mesh.padding.approximated` | approximated | control | skel from 4.2 on implies the triangle count, missing triangles are degenerate and draw nothing |
| `mesh.hull.approximated` | approximated | editor | skel from 4.2 on implies the triangle count, the hull is lowered so every triangle stays, only the hull outline of the editor and debug renderers changes |
| `attachment.sequence.dropped` | dropped | control | attachment sequence becomes its setup region |
| `animation.sequence.dropped` | dropped | pose | sequence timelines of an attachment |
| `sequence.mode.approximated` | approximated | pose | sequence in pingpongReverse mode, played differently by 4.1 before 4.1.10-beta |
| `sequence.mode.rewritten` | rewritten | none | pingpongReverse keys of 4.1 before 4.1.10-beta became once, which clamps the same index |
| `sequence.linked.approximated` | approximated | pose | sequence of a linked mesh, played differently by 4.1 before 4.1.27-beta |
| `sequence.linked.rewritten` | rewritten | none | a linked mesh of another frame count than its parent stops inheriting timelines and gets hold keys of the frames the parent keys showed before 4.1.27-beta, plus copies of the parent deform keys |
| `transform.mixScaleY.approximated` | approximated | pose | mixScaleY as the only nonzero transform mix, 4.0 and 4.1 exports before 4.1.18 skip it, kept for targets 4.1 and 4.2, for a gated mixScaleY with a shear mix and a negative factor and when another rewrite took the scale mix |
| `transform.mixScaleY.rewritten` | rewritten | none | mixScaleY as the only nonzero mix of a transform constraint whose other mixes stay 0 in every key and handle becomes 0, into 4.3 a mixScaleY that other mixes leave 0 around is gated by a slider |
| `color.curve.approximated` | approximated | pose | per channel color curves merged into one curve |
| `color.clamp.approximated` | approximated | pose | color Bézier control outside 0 to 1, clamped from 4.3 |
| `transform.mix.approximated` | approximated | pose | transform mixY or mixScaleY differs from the X mix |
| `transform.scaleMix.approximated` | approximated | pose | negative world scale mix in a key or Bézier control |
| `transform.scaleMix.rewritten` | rewritten | none | world scale mix that is never positive set to 0, or a mix of both signs clamped by a 4.3 slider |
| `transform.shearMix.approximated` | approximated | pose | negative world shear mix, skipped by 4.2 and applied by 4.3 |
| `transform.shearMix.rewritten` | rewritten | none | world shear mix that is never positive becomes 0 |
| `transform.shearOffset.approximated` | approximated | pose | absolute world shearY offset with a shear mix other than 0 or 1 or a source that may reflect, 4.2 adds it after the wrap and signs it by the source reflection and 4.3 does neither, also reported when the sum never crosses 180, or relative world shearY offset with a source that may reflect, which 4.2 negates, left over when the offset is 180 or more or the mix cannot be clamped |
| `transform.shearOffset.rewritten` | rewritten | none | absolute world shearY offset moved to an additive shear constraint, from the root or signed by helper bones, or relative world shearY offset negated for a source that stays reflected or signed by helper bones |
| `transform.shearWrap.approximated` | approximated | pose | relative world shear mix below 1, 4.2 wraps the source shear past 90, also reported when it never passes 90 |
| `transform.shearWrap.rewritten` | rewritten | none | relative world shear read through a helper bone rotation that wraps it like 4.2 |
| `transform.rotateRange.approximated` | approximated | pose | relative local rotate mix below 1 with target rotation keys past 180 from setup, 3.8 wraps them around the setup rotation |
| `transform.relativeScale.approximated` | approximated | pose | relative local scale mix on a bone with scale other than 1, 4.0 before 4.0.27 scales by another formula |
| `transform.relativeScale.rewritten` | rewritten | none | relative local scale of 4.0 before 4.0.27 rebuilt by helper bones in 4.3 |
| `transform.localWrap.approximated` | approximated | pose | absolute local rotate or shear mix below 1 with a difference past 180, wrapped by 4.1 and by 4.2 before 4.2.60-beta |
| `transform.localWrap.rewritten` | rewritten | none | absolute local offset moved by the whole turns the old wrap always removes, or the wrap rebuilt with helper bones in 4.3 |
| `transform.offsetReflect.approximated` | approximated | pose | rotate or shearY offset of a transform constraint on a reflected bone, 3.5 before 3.5.09-beta ignores the reflection |
| `transform.offsetReflect.rewritten` | rewritten | none | transform offsets of 3.5 before 3.5.09-beta negated for a target that stays reflected, or into 4.3 a rotation offset moved to the mapping offset |
| `transform.offsetFlip.approximated` | approximated | control | rotate or shearY offset of a transform constraint, 3.5 before 3.5.09-beta ignores a flipped skeleton |
| `transform.jsonMix.approximated` | approximated | pose | transform keys without mixY or mixScaleY beside an X mix other than 1 in 4.3 JSON before 4.3.24, provisional |
| `transform.jsonShear.approximated` | approximated | control | transform shear mix keys of 4.0 JSON, misread by the 4.0 runtime loaders and not by the editor |
| `path.mix.approximated` | approximated | pose | path mixY differs from mixX |
| `path.negative.approximated` | approximated | pose | negative path mix in a key or Bézier control |
| `path.negative.rewritten` | rewritten | none | 3.8 path rotate and translate mixes that never turn positive, which 3.8 skips and 4.0 applies, became 0, or gated by sliders in 4.3 |
| `path.position.approximated` | approximated | pose | fixed position on a constant speed path |
| `path.position.rewritten` | rewritten | none | fixed position of 3.7 and 3.8 on constant speed paths of one setup length became percent of that length |
| `path.spacing.approximated` | approximated | pose | spacing along zero length bones, or 3.6 scaling length and chain scale spacing by the bone world scale |
| `path.spacing.rewritten` | rewritten | none | 3.5 spacing on bones of one constant world scale became spacing over that scale, 3.6 spacing going down the reverse |
| `path.proportional.approximated` | approximated | pose | proportional spacing becomes percent |
| `path.length.approximated` | approximated | pose | length spacing below minus the bone length, 4.3 clamps it |
| `path.length.rewritten` | rewritten | none | length spacing below minus the bone length moved to fixed spacing plus the bone length |
| `path.offsetReflect.approximated` | approximated | pose | path rotation offset on a reflected bone, 3.5 before 3.5.09-beta ignores the reflection |
| `path.offsetReflect.rewritten` | rewritten | none | path rotation offset of 3.5 before 3.5.09-beta negated for a path bone that stays reflected |
| `path.offsetFlip.approximated` | approximated | control | path rotation offset, 3.5 before 3.5.09-beta ignores a flipped skeleton |
| `path.closed.approximated` | approximated | pose | closed constant speed path with negative spacing or spacing past its length |
| `ik.stretch.approximated` | approximated | pose | two bone stretch with a child Y position |
| `ik.stretch.rewritten` | rewritten | none | two bone stretch with a child Y position solved on a helper parent turned toward the child |
| `ik.uniform.dropped` | dropped | pose | two bone IK uniform stretch |
| `ik.beta.approximated` | approximated | pose | IK of 3.8 exports before 3.8.81 on one bone that does not inherit rotation, or does not inherit scale while stretching or compressing, or with the child at the origin of a parent that does not inherit rotation, or does not inherit scale while stretching, solved from the world transform by the final 3.8 runtime |
| `ik.beta.rewritten` | rewritten | none | one bone IK on a bone that does not inherit rotation, or not scale while it stretches or compresses, solved on a normal proxy bone with the local pose and keys of the bone; 4.3 hands back rotation and scale with a local transform constraint, 3.8 to 4.2 hand back rotation, and scale only for a bone of scale 1, with a local constraint ordered right after the IK |
| `ik.singular.approximated` | approximated | pose | IK whose parent scale passes through zero, posed differently near the crossing |
| `ik.inherit.approximated` | approximated | pose | one bone IK on a bone that does not inherit rotation, reflection or scale, solved differently before 3.8.81 |
| `ik.inherit.rewritten` | rewritten | none | one bone IK on a bone that does not inherit rotation, or not scale while it stretches or compresses, solved on a normal proxy bone with the local pose and keys of the bone; 4.3 hands back rotation and scale with a local transform constraint, 3.8 to 4.2 hand back rotation, and scale only for a bone of scale 1, with a local constraint ordered right after the IK |
| `ik.origin.approximated` | approximated | pose | two bone IK with the child at the parent origin, 3.8 turns only the parent |
| `ik.softness.approximated` | approximated | pose | IK softness on a bone with scale other than 1, solved differently by 3.8.25-beta |
| `ik.softness.rewritten` | rewritten | none | softness of 3.8.25-beta divided by the child scale factor 3.8 applies, for a parent of scale 1 and a child of constant scale |
| `ik.reset.approximated` | approximated | pose | two bone IK at mix 0 with an earlier constraint on its child, 3.8 resets the child |
| `ik.reset.rewritten` | rewritten | none | two bone IK at mix 0 in setup and keys or gated where its keys hold the mix at 0, the child set back to its local pose by a 4.3 local transform constraint that copies a clone of the child |
| `ik.skip.approximated` | approximated | pose | two bone IK on a bone with inherit other than normal, skipped from 4.2 |
| `ik.skip.rewritten` | rewritten | none | going down, two bone IK skipped from 4.2 gets setup mix 0 and loses its timelines; going up, the IK solves a normal clone of a child whose inherit is not normal and copies its rotation and y back |
| `ik.shear.approximated` | approximated | pose | two bone IK whose parent has setup or keyed shear, 4.3 keeps the shear |
| `ik.shear.rewritten` | rewritten | none | a slider right after a two bone IK keys the parent shear to 0, which 4.2 drops when it solves |
| `ik.volume.approximated` | approximated | pose | IK scaleY volume with compress or a factor below 0.7, 4.3 before 4.3.02 applies it before bounding |
| `ik.softness.dropped` | dropped | pose | IK softness |
| `linkedmesh.deform.approximated` | approximated | pose | deform keys of a linked mesh that inherits deform, applied before 3.8 only |
| `linkedmesh.deform.rewritten` | rewritten | none | linked mesh of 3.7 with its own deform keys and a parent without any stops inheriting deform |
| `skin.required.dropped` | dropped | pose | bone or constraint active only with its skin |
| `skeleton.position.dropped` | dropped | editor | setup pose bounds position, read by no runtime pose |
| `skeleton.scale.approximated` | approximated | control | 3.7 applies the skeleton scale twice to noRotationOrReflection bones and scales the columns of a root with rotation or shear where 3.6 and 3.8 scale the rows, which differ under a runtime skeleton scale of unequal or negative axes |
| `constraint.skipped.approximated` | approximated | pose | a constraint whose order repeats or reaches the constraint count, which 3.5 to 4.2 never update and 4.3 updates |
| `constraint.skipped.rewritten` | rewritten | none | a constraint 3.5 to 4.2 never update was removed with its timelines going to 4.3 |
| `constraint.order.approximated` | approximated | pose | 3.8, 4.0 before 4.0.76-beta and 4.3 before 4.3.18 reset the result when a later constraint moves an ancestor, 4.3 only where both run in one pose and the reset can move a bone |
| `constraint.order.rewritten` | rewritten | none | reset bones removed from the earlier constraint, or into 4.3 set back to their local pose by local transform constraints that copy clones of them |
| `slot.dark.dropped` | dropped | render | slot dark color, 3.5 has no two color tint |
| `animation.dark.dropped` | dropped | render | dark color of two color keys, the light color stays a color timeline |
| `transform.local.dropped` | dropped | pose | local transform constraint, 3.5 constrains world transforms only |
| `transform.relative.dropped` | dropped | pose | relative transform constraint, 3.5 constrains absolutely only |
| `attachment.clipping.dropped` | dropped | render | clipping attachment and its deform timelines |
| `attachment.point.dropped` | dropped | control | point attachment |
| `bone.reflection.approximated` | approximated | pose | noScale bone under a reflected ancestor, 3.6 from 3.6.38 reflects the parent axis before the shear of a sheared one, 3.7 before 3.7.72-beta does not reflect it |
| `bone.reflection.rewritten` | rewritten | none | noScale bone of 3.7 before 3.7.72-beta became noScaleOrReflection, or a sheared noScale bone of 3.5 and 3.6 before 3.6.38 under a parent that stays reflected got both shears negated |
| `bone.flip.approximated` | approximated | control | noScaleOrReflection bone under reflection, differs only when the skeleton is flipped |
| `bone.noRotation.approximated` | approximated | pose | noRotationOrReflection bone with nonuniform scale or shear on it or an ancestor, solved differently by 3.5.03-beta |
| `bone.noRotation.rewritten` | rewritten | none | noRotationOrReflection bone of 3.5.02 and 3.5.03 betas becomes a normal bone that copies the world matrix of a helper chain, the parent basis, its local pose, then a turn back by the parent angle |
| `bone.singular.approximated` | approximated | pose | noRotationOrReflection, noScale or noScaleOrReflection bone under a parent whose scale passes through zero in its setup, keys or Bézier handles, posed differently near zero and with NaN in 4.3 at exactly zero, where 4.3 no longer guards the normalization |
| `bone.applied.approximated` | approximated | pose | world or path constrained bone with a parent, with inherit other than normal, with shear, with a shearing transform, or with a rotate, scale or shear mix under nonuniform scale or shear of an ancestor, whose applied transform is recomposed later by a one bone IK, the child of a two bone IK, a local transform on it, or a constraint on an ancestor, or is read by a local transform that takes its shear, or its rotation or scale when the inherit is not normal; 4.1 and 4.2 decompose it differently |
| `bone.applied.rewritten` | rewritten | none | world or path constrained bone read later by local transforms through its target, or recomposed by one reader, now read through a normal mirror bone with its world, with copies of the 4.1 applied transform before the reader, or a 4.3 shear copy with scale -1 for a bone of constant shear |
| `bone.derive.approximated` | approximated | pose | world constrained bone with inherit noScale, noScaleOrReflection or noRotationOrReflection read later by a local constraint or IK, 4.3 derives its local pose from the world pass and 4.2 from a frame at the stale local rotation or without the parent rotation |
| `bone.derive.rewritten` | rewritten | none | noScale or noScaleOrReflection bone set by a world constraint that keeps rotation and shear, read by an always active one bone IK, setup rotation moved to 0 as 4.2 poses the bone without it |
| `transform.localMix.approximated` | approximated | pose | negative local scale or shear mix, applied from 3.7.74-beta and skipped before |
| `transform.localMix.rewritten` | rewritten | none | local scale or shear mix keyed through 0, which 3.6 and early 3.7 skip while not positive, clamped at 0 by a 4.3 slider on a helper bone |
| `transform.localShear.approximated` | approximated | pose | absolute local shear mix, 3.6 and 3.7 before 3.7.74-beta add it to the local pose instead of the applied pose |
| `path.spacingScale.approximated` | approximated | pose | fixed spacing scales with the bone length from 3.7, chain scale percent spacing stops scaling |
| `path.spacingScale.rewritten` | rewritten | none | fixed or chain scale percent spacing on bones of one constant world scale became spacing divided or multiplied by that scale |
| `path.start.approximated` | approximated | pose | path on its start or with tangents, 3.5 evaluates a curve start at 1e-4, 3.6 at 1e-5 or more, 3.7 at 0 and takes tangents near it from the curve |
| `ik.compress.dropped` | dropped | pose | one bone IK compress |
| `ik.stretch.dropped` | dropped | pose | IK stretch |
| `event.audio.dropped` | dropped | control | event audio path, volume and balance |
| `skeleton.audio.dropped` | dropped | editor | skeleton audio path |
| `atlas.header.dropped` | dropped | editor | atlas entry before the first page, ignored by the runtimes |
| `atlas.page.dropped` | dropped | editor | page entry the runtimes ignore, such as `scale` |
| `atlas.pma.dropped` | dropped | render | premultiplied alpha flag of a page, 3.8 sets it in the renderer |
| `atlas.rotate.dropped` | dropped | render | region rotation other than 0 or 90, 3.5 to 3.7 read only true or false |
| `atlas.strip.approximated` | approximated | render | region with stripped whitespace written for 3.5 or 3.6, or a 3.5 or 3.6 mesh converted up, because 3.5 and 3.6 map mesh UVs to the packed size |
| `atlas.strip.rewritten` | rewritten | none | mesh UVs of a 3.5 or 3.6 skeleton mapped through the stripped whitespace of an unrotated region of the atlas given with it |
| `atlas.values.dropped` | dropped | control | region values 3.8 cannot hold, split and pad need four values and pad needs split |
