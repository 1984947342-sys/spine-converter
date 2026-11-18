[English](report.md) | [中文](report.zh-CN.md)

# 转换报告

`spc_result_report` 返回一个 JSON 数组。每个条目描述一项未能精确转换的内容。

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

| 字段 | 含义 |
|---|---|
| `code` | 稳定的标识符，可在脚本中直接匹配 |
| `severity` | `dropped`、`approximated` 或 `rewritten`，始终是代码的最后一段 |
| `impact` | 目标运行时损失的内容，每个代码固定 |
| `step` | 产生该条目的迁移步骤，编解码器产生的条目为空 |
| `path` | 源文档中以点分隔的路径 |
| `message` | 可读文本，不同版本之间可能变化 |
| `remedy` | 避免该损失的方式，每个条目单独设置 |

| 影响 | 含义 |
|---|---|
| `none` | 数据已改写，目标运行时的行为完全相同 |
| `editor` | 编辑器数据，目标运行时的行为完全相同 |
| `control` | 播放结果相同，驱动运行时的代码会看到差异 |
| `pose` | 播放期间骨骼、插槽、附件、变形或绘制顺序存在差异 |
| `render` | 姿势相同，渲染结果存在差异 |

| 处理方式 | 含义 |
|---|---|
| `none` | 没有任何转换器标志能改变该损失，其影响说明了差异所在 |
| `rewrite` | 仅在使用 `SPC_FLAG_NO_REWRITE` 或 `--no-rewrite` 时出现，默认的改写会使该条目变为精确，可通过启用改写的第二次迁移找到 |
| `runtime` | 属于 [changes/needs-a-runtime.md](changes/needs-a-runtime.md) 中的语义（英文），没有任何目标数据可以复现，需要修补运行时或修改骨架 |

同一个代码可以带有不同的处理方式，例如 `transform.scale.approximated`，带关键帧的骨骼缩放为 `rewrite`，骨骼缩放达到 0 时为 `runtime`。已改写的条目带有 `none`，未使用 `--no-rewrite` 时没有条目带有 `rewrite`。

影响按从 `none` 到 `render` 的顺序排列。`spc_result_loss_count` 统计未改写的条目。`spc_result_max_impact` 返回最严重的影响。`spc_result_remedy_count` 统计某一种处理方式的条目。`SPC_FLAG_FAIL_ON_LOSS` 在损失数不为零时失败。

CLI 以制表符分隔的 `severity impact code path message remedy` 格式输出每个条目，存在损失时随后输出一行汇总，汇总同时统计 `rewrite` 和 `runtime` 处理方式，输出带有损失写入时以退出码 3 退出。

| 代码 | 严重程度 | 影响 | 含义 |
|---|---|---|---|
| `slider.dropped` | dropped | pose | 没有旧版本等价物的滑块约束 |
| `animation.slider.dropped` | dropped | pose | 动画的滑块时间轴 |
| `slider.linkedMesh.approximated` | approximated | pose | 滑块为源网格位于另一个插槽的链接网格设置关键帧，4.3.24 之前的 4.3 应用方式不同 |
| `animation.color.dropped` | dropped | editor | 动画颜色 |
| `animation.drawOrderFolder.dropped` | dropped | pose | 绘制顺序文件夹时间轴 |
| `bone.icon.dropped` | dropped | editor | 骨骼图标，或其大小和旋转 |
| `ik.scaleY.approximated` | approximated | pose | IK 的 scaleY 体积变为无 |
| `physics.scaleY.dropped` | dropped | pose | 物理的 scaleY 模式变为无，4.3 二进制中 scaleX 大于 1 的统一模式也是如此，该版本将其读作体积 |
| `transform.local.approximated` | approximated | pose | 本地源与本地目标不一致，以本地目标为准 |
| `transform.clamp.dropped` | dropped | pose | 变换约束的限制 |
| `transform.property.dropped` | dropped | pose | 映射到其他属性或带有偏移或缩放的变换属性 |
| `transform.scale.approximated` | approximated | pose | 4.2 的本地绝对缩放除以骨骼缩放，4.3 不除，适用于应用缩放可能不等于 1 的骨骼 |
| `transform.scale.rewritten` | rewritten | none | 对于恒定的应用缩放和混合值，本地绝对缩放的除法折入缩放映射，对于带关键帧的骨骼缩放，则重建为滑块装置 |
| `clipping.convex.dropped` | dropped | render | 凸裁剪 |
| `clipping.inverse.dropped` | dropped | render | 反向裁剪 |
| `clipping.convex.rewritten` | rewritten | none | 不带权重或变形的凸裁剪，顶点变为 4.3 用于裁剪的凸包 |
| `clipping.vertices.approximated` | approximated | render | 3.6.35 之前的 3.6 导出中顶点少于 3 个的裁剪多边形，编辑器自 3.6.35 起忽略，spine-cpp 4.3 也忽略 |
| `clipping.vertices.rewritten` | rewritten | none | 直至 3.6.32 的 3.6 导出中顶点少于 3 个的裁剪多边形，变为未缩放辅助骨骼上的远处三角形，使所有运行时与该编辑器一样裁掉该范围 |
| `linkedmesh.slot.approximated` | approximated | pose | 另一个插槽中的源网格被复制，其时间轴不会被继承 |
| `skeleton.referenceScale.dropped` | dropped | editor | 物理参考缩放 |
| `bone.visible.dropped` | dropped | editor | 骨骼的编辑器可见性 |
| `slot.visible.dropped` | dropped | editor | 插槽的编辑器可见性 |
| `skin.color.dropped` | dropped | editor | 皮肤颜色 |
| `physics.dropped` | dropped | pose | 物理约束 |
| `physics.step.approximated` | approximated | pose | 4.2 的物理约束转入 4.3 或转回，两个次版本使用不同的积分器推进物理 |
| `animation.physics.dropped` | dropped | pose | 动画的物理时间轴 |
| `animation.duration.approximated` | approximated | control | 因最后的关键帧被丢弃，动画提前结束，循环和完成事件因此提前 |
| `animation.inherit.dropped` | dropped | pose | 骨骼继承时间轴 |
| `animation.inherit.setup.dropped` | dropped | control | 只保存其骨骼初始继承方式的继承时间轴 |
| `mesh.triangles.approximated` | approximated | render | 4.2 起的 skel 由顶点推定三角形数量，多余的三角形被裁掉 |
| `mesh.padding.approximated` | approximated | control | 4.2 起的 skel 由顶点推定三角形数量，缺少的三角形为退化三角形，不绘制任何内容 |
| `mesh.hull.approximated` | approximated | editor | 4.2 起的 skel 由顶点推定三角形数量，降低外壳顶点数以保留所有三角形，只有编辑器和调试渲染器的外壳轮廓会改变 |
| `attachment.sequence.dropped` | dropped | control | 附件序列变为其初始区域 |
| `animation.sequence.dropped` | dropped | pose | 附件的序列时间轴 |
| `sequence.mode.approximated` | approximated | pose | pingpongReverse 模式的序列，4.1.10-beta 之前的 4.1 播放方式不同 |
| `sequence.mode.rewritten` | rewritten | none | 4.1.10-beta 之前的 4.1 的 pingpongReverse 关键帧变为 once，二者对同一索引的限制结果相同 |
| `sequence.linked.approximated` | approximated | pose | 链接网格的序列，4.1.27-beta 之前的 4.1 播放方式不同 |
| `sequence.linked.rewritten` | rewritten | none | 帧数与其父网格不同的链接网格不再继承时间轴，并获得保持关键帧，内容为 4.1.27-beta 之前父网格关键帧所显示的帧，另加父网格变形关键帧的副本 |
| `transform.mixScaleY.approximated` | approximated | pose | mixScaleY 是唯一非零的变换混合值，4.1.18 之前的 4.0 和 4.1 导出会跳过它，目标为 4.1 和 4.2 时保留，带有斜切混合值和负系数的受控 mixScaleY，以及另一项改写已占用缩放混合值时同样保留 |
| `transform.mixScaleY.rewritten` | rewritten | none | mixScaleY 是变换约束唯一非零的混合值，其他混合值在每个关键帧中保持 0 且 handle 变为 0，转入 4.3 时，其他混合值为 0 的情况下的 mixScaleY 由滑块控制 |
| `color.curve.approximated` | approximated | pose | 各通道的颜色曲线合并为一条曲线 |
| `color.clamp.approximated` | approximated | pose | 颜色贝塞尔控制点超出 0 到 1，自 4.3 起被限制 |
| `transform.mix.approximated` | approximated | pose | 变换的 mixY 或 mixScaleY 与 X 混合值不同 |
| `transform.scaleMix.approximated` | approximated | pose | 关键帧或贝塞尔控制点中的负世界缩放混合值 |
| `transform.scaleMix.rewritten` | rewritten | none | 从不为正的世界缩放混合值设为 0，正负皆有的混合值由 4.3 滑块限制 |
| `transform.shearMix.approximated` | approximated | pose | 负世界斜切混合值，4.2 跳过而 4.3 应用 |
| `transform.shearMix.rewritten` | rewritten | none | 从不为正的世界斜切混合值变为 0 |
| `transform.shearOffset.approximated` | approximated | pose | 斜切混合值不是 0 或 1 的绝对世界 shearY 偏移，或源可能镜像的绝对世界 shearY 偏移，4.2 在回绕之后加上该偏移并按源的镜像取符号，4.3 两者都不做，总和从未越过 180 时同样报告，另有源可能镜像的相对世界 shearY 偏移，4.2 将其取负，偏移达到 180 或更大，或混合值无法被限制时，该条目被保留 |
| `transform.shearOffset.rewritten` | rewritten | none | 绝对世界 shearY 偏移移到加法斜切约束，从根骨骼开始或由辅助骨骼取符号，或相对世界 shearY 偏移对仍保持镜像的源取负，或由辅助骨骼取符号 |
| `transform.shearWrap.approximated` | approximated | pose | 混合值小于 1 的相对世界斜切，4.2 在源斜切超过 90 时回绕，从未超过 90 时同样报告 |
| `transform.shearWrap.rewritten` | rewritten | none | 经由辅助骨骼旋转读取的相对世界斜切，其回绕方式与 4.2 相同 |
| `transform.rotateRange.approximated` | approximated | pose | 相对本地旋转混合值小于 1，且目标旋转关键帧距初始姿势超过 180，3.8 将其绕初始旋转回绕 |
| `transform.relativeScale.approximated` | approximated | pose | 骨骼缩放不等于 1 时的相对本地缩放混合值，4.0.27 之前的 4.0 按另一公式缩放 |
| `transform.relativeScale.rewritten` | rewritten | none | 4.0.27 之前的 4.0 的相对本地缩放在 4.3 中由辅助骨骼重建 |
| `transform.localWrap.approximated` | approximated | pose | 绝对本地旋转或斜切混合值小于 1 且差值超过 180，4.1 以及 4.2.60-beta 之前的 4.2 会回绕 |
| `transform.localWrap.rewritten` | rewritten | none | 绝对本地偏移移动旧回绕总会去除的整圈数，或在 4.3 中用辅助骨骼重建回绕 |
| `transform.offsetReflect.approximated` | approximated | pose | 镜像骨骼上变换约束的旋转或 shearY 偏移，3.5.09-beta 之前的 3.5 忽略镜像 |
| `transform.offsetReflect.rewritten` | rewritten | none | 3.5.09-beta 之前的 3.5 的变换偏移对仍保持镜像的目标取负，或转入 4.3 时，旋转偏移移到映射偏移 |
| `transform.offsetFlip.approximated` | approximated | control | 变换约束的旋转或 shearY 偏移，3.5.09-beta 之前的 3.5 忽略翻转的骨架 |
| `transform.jsonMix.approximated` | approximated | pose | 4.3.24 之前的 4.3 JSON 中，X 混合值不是 1 时没有 mixY 或 mixScaleY 的变换关键帧，暂定 |
| `transform.jsonShear.approximated` | approximated | control | 4.0 JSON 的变换斜切混合值关键帧，被 4.0 运行时加载器误读，编辑器则不会 |
| `path.mix.approximated` | approximated | pose | 路径的 mixY 与 mixX 不同 |
| `path.negative.approximated` | approximated | pose | 关键帧或贝塞尔控制点中的负路径混合值 |
| `path.negative.rewritten` | rewritten | none | 从不转为正的 3.8 路径旋转和位移混合值，3.8 跳过而 4.0 应用，已变为 0，转入 4.3 时由滑块控制 |
| `path.position.approximated` | approximated | pose | 匀速路径上的固定位置 |
| `path.position.rewritten` | rewritten | none | 3.7 和 3.8 中长度相同的匀速路径上的固定位置，变为该长度的百分比 |
| `path.spacing.approximated` | approximated | pose | 沿零长度骨骼的间距，或 3.6 按骨骼世界缩放来缩放长度和链缩放间距 |
| `path.spacing.rewritten` | rewritten | none | 世界缩放恒定且相同的骨骼上的 3.5 间距，变为除以该缩放的间距，3.6 间距向下转换时则相反 |
| `path.proportional.approximated` | approximated | pose | 比例间距变为百分比 |
| `path.length.approximated` | approximated | pose | 长度间距小于骨骼长度的负值，4.3 将其限制 |
| `path.length.rewritten` | rewritten | none | 小于骨骼长度的负值的长度间距，改为固定间距加骨骼长度 |
| `path.offsetReflect.approximated` | approximated | pose | 镜像骨骼上的路径旋转偏移，3.5.09-beta 之前的 3.5 忽略镜像 |
| `path.offsetReflect.rewritten` | rewritten | none | 3.5.09-beta 之前的 3.5 的路径旋转偏移，对仍保持镜像的路径骨骼取负 |
| `path.offsetFlip.approximated` | approximated | control | 路径旋转偏移，3.5.09-beta 之前的 3.5 忽略翻转的骨架 |
| `path.closed.approximated` | approximated | pose | 间距为负或间距超过其长度的闭合匀速路径 |
| `ik.stretch.approximated` | approximated | pose | 子骨骼带 Y 位置的双骨骼拉伸 |
| `ik.stretch.rewritten` | rewritten | none | 子骨骼带 Y 位置的双骨骼拉伸，在朝向子骨骼的辅助父骨骼上求解 |
| `ik.uniform.dropped` | dropped | pose | 双骨骼 IK 的统一拉伸 |
| `ik.beta.approximated` | approximated | pose | 3.8.81 之前的 3.8 导出中的 IK，涉及不继承旋转的单骨骼，或拉伸或压缩时不继承缩放的单骨骼，或子骨骼位于不继承旋转的父骨骼原点，或拉伸时不继承缩放的父骨骼原点，由最终的 3.8 运行时根据世界变换求解 |
| `ik.beta.rewritten` | rewritten | none | 不继承旋转的骨骼上的单骨骼 IK，或拉伸或压缩时不继承缩放的单骨骼 IK，在使用该骨骼本地姿势和关键帧的普通代理骨骼上求解，4.3 通过本地变换约束交还旋转和缩放，3.8 至 4.2 交还旋转，仅对缩放为 1 的骨骼交还缩放，并使用紧随 IK 之后排序的本地约束 |
| `ik.singular.approximated` | approximated | pose | 父骨骼缩放经过零的 IK，在交叉点附近的姿势不同 |
| `ik.inherit.approximated` | approximated | pose | 不继承旋转、镜像或缩放的骨骼上的单骨骼 IK，3.8.81 之前的求解方式不同 |
| `ik.inherit.rewritten` | rewritten | none | 不继承旋转的骨骼上的单骨骼 IK，或拉伸或压缩时不继承缩放的单骨骼 IK，在使用该骨骼本地姿势和关键帧的普通代理骨骼上求解，4.3 通过本地变换约束交还旋转和缩放，3.8 至 4.2 交还旋转，仅对缩放为 1 的骨骼交还缩放，并使用紧随 IK 之后排序的本地约束 |
| `ik.origin.approximated` | approximated | pose | 子骨骼位于父骨骼原点的双骨骼 IK，3.8 只转动父骨骼 |
| `ik.softness.approximated` | approximated | pose | 缩放不等于 1 的骨骼上的 IK 柔和度，3.8.25-beta 求解方式不同 |
| `ik.softness.rewritten` | rewritten | none | 3.8.25-beta 的柔和度除以 3.8 应用的子骨骼缩放系数，适用于缩放为 1 的父骨骼和缩放恒定的子骨骼 |
| `ik.reset.approximated` | approximated | pose | 混合值为 0 且其子骨骼上有更早约束的双骨骼 IK，3.8 会重置子骨骼 |
| `ik.reset.rewritten` | rewritten | none | 初始姿势和关键帧中混合值为 0 的双骨骼 IK，或其关键帧将混合值保持为 0 的受控双骨骼 IK，子骨骼通过复制子骨骼副本的 4.3 本地变换约束恢复到其本地姿势 |
| `ik.skip.approximated` | approximated | pose | 继承方式不是 normal 的骨骼上的双骨骼 IK，自 4.2 起被跳过 |
| `ik.skip.rewritten` | rewritten | none | 向下转换时，自 4.2 起被跳过的双骨骼 IK 获得初始混合值 0 并失去其时间轴，向上转换时，IK 求解继承方式不是 normal 的子骨骼的普通副本，并将其旋转和 y 复制回去 |
| `ik.shear.approximated` | approximated | pose | 父骨骼带有初始斜切或带关键帧斜切的双骨骼 IK，4.3 保留该斜切 |
| `ik.shear.rewritten` | rewritten | none | 紧随双骨骼 IK 之后的滑块将父骨骼斜切的关键帧设为 0，4.2 在求解时会丢弃该斜切 |
| `ik.volume.approximated` | approximated | pose | 带压缩或系数小于 0.7 的 IK scaleY 体积，4.3.02 之前的 4.3 在限制之前应用 |
| `ik.softness.dropped` | dropped | pose | IK 柔和度 |
| `linkedmesh.deform.approximated` | approximated | pose | 继承变形的链接网格的变形关键帧，仅在 3.8 之前应用 |
| `linkedmesh.deform.rewritten` | rewritten | none | 3.7 中带有自身变形关键帧而父网格没有变形关键帧的链接网格，不再继承变形 |
| `skin.required.dropped` | dropped | pose | 仅随其皮肤激活的骨骼或约束 |
| `skeleton.position.dropped` | dropped | editor | 初始姿势边界的位置，没有任何运行时姿势读取它 |
| `skeleton.scale.approximated` | approximated | control | 3.7 对 noRotationOrReflection 骨骼两次应用骨架缩放，并缩放带旋转或斜切的根骨骼的列，3.6 和 3.8 缩放其行，两者在运行时骨架缩放各轴不等或为负时不同 |
| `constraint.skipped.approximated` | approximated | pose | 顺序重复或达到约束数量的约束，3.5 至 4.2 从不更新它，4.3 会更新 |
| `constraint.skipped.rewritten` | rewritten | none | 转入 4.3 时，3.5 至 4.2 从不更新的约束连同其时间轴一起被移除 |
| `constraint.order.approximated` | approximated | pose | 3.8、4.0.76-beta 之前的 4.0 以及 4.3.18 之前的 4.3，在后面的约束移动祖先骨骼时重置结果，4.3 仅在两者运行于同一姿势且重置可以移动骨骼时重置 |
| `constraint.order.rewritten` | rewritten | none | 被重置的骨骼从较早的约束中移除，或转入 4.3 时，由复制其副本的本地变换约束恢复到其本地姿势 |
| `slot.dark.dropped` | dropped | render | 插槽的暗色，3.5 没有双色着色 |
| `animation.dark.dropped` | dropped | render | 双色关键帧的暗色，亮色保留为颜色时间轴 |
| `transform.local.dropped` | dropped | pose | 本地变换约束，3.5 只约束世界变换 |
| `transform.relative.dropped` | dropped | pose | 相对变换约束，3.5 只做绝对约束 |
| `attachment.clipping.dropped` | dropped | render | 裁剪附件及其变形时间轴 |
| `attachment.point.dropped` | dropped | control | 点附件 |
| `bone.reflection.approximated` | approximated | pose | 镜像祖先之下的 noScale 骨骼，3.6.38 起的 3.6 在带斜切骨骼的斜切之前镜像父骨骼轴，3.7.72-beta 之前的 3.7 不镜像 |
| `bone.reflection.rewritten` | rewritten | none | 3.7.72-beta 之前的 3.7 的 noScale 骨骼变为 noScaleOrReflection，或 3.6.38 之前的 3.5 和 3.6 中位于仍保持镜像的父骨骼之下的带斜切 noScale 骨骼，其两个斜切都被取负 |
| `bone.flip.approximated` | approximated | control | 镜像之下的 noScaleOrReflection 骨骼，仅在骨架翻转时不同 |
| `bone.noRotation.approximated` | approximated | pose | 自身或祖先带有非均匀缩放或斜切的 noRotationOrReflection 骨骼，3.5.03-beta 求解方式不同 |
| `bone.noRotation.rewritten` | rewritten | none | 3.5.02 和 3.5.03 beta 的 noRotationOrReflection 骨骼变为普通骨骼，该骨骼复制一条辅助链的世界矩阵，即父骨骼基、其本地姿势，再按父骨骼角度转回 |
| `bone.singular.approximated` | approximated | pose | 父骨骼的缩放在其初始姿势、关键帧或贝塞尔 handle 中经过零时，其下的 noRotationOrReflection、noScale 或 noScaleOrReflection 骨骼，在零附近姿势不同，在恰好为零时 4.3 中出现 NaN，因为 4.3 不再保护归一化 |
| `bone.applied.approximated` | approximated | pose | 带父骨骼、继承方式不是 normal、带斜切、带斜切变换，或在祖先的非均匀缩放或斜切之下带旋转、缩放或斜切混合值的世界或路径约束骨骼，其应用变换之后被单骨骼 IK、双骨骼 IK 的子骨骼、其上的本地变换或祖先上的约束重新合成，或被读取其斜切，或在继承方式不是 normal 时读取其旋转或缩放的本地变换所读取，4.1 和 4.2 的分解方式不同 |
| `bone.applied.rewritten` | rewritten | none | 之后经由其目标被本地变换读取，或被某个读取者重新合成的世界或路径约束骨骼，现经由带其世界变换的普通镜像骨骼读取，并在读取者之前加入 4.1 应用变换的副本，或对斜切恒定的骨骼使用缩放为 -1 的 4.3 斜切副本 |
| `bone.derive.approximated` | approximated | pose | 继承方式为 noScale、noScaleOrReflection 或 noRotationOrReflection 的世界约束骨骼，之后被本地约束或 IK 读取，4.3 由世界计算推导其本地姿势，4.2 由过时本地旋转处的坐标系推导，或不带父骨骼旋转 |
| `bone.derive.rewritten` | rewritten | none | 由保留旋转和斜切的世界约束设置的 noScale 或 noScaleOrReflection 骨骼，被始终激活的单骨骼 IK 读取，初始旋转移到 0，因为 4.2 在没有该旋转时摆放该骨骼 |
| `transform.localMix.approximated` | approximated | pose | 负本地缩放或斜切混合值，自 3.7.74-beta 起应用，之前跳过 |
| `transform.localMix.rewritten` | rewritten | none | 经过 0 的带关键帧本地缩放或斜切混合值，3.6 和早期 3.7 在其不为正时跳过，由辅助骨骼上的 4.3 滑块在 0 处限制 |
| `transform.localShear.approximated` | approximated | pose | 绝对本地斜切混合值，3.7.74-beta 之前的 3.6 和 3.7 将其加到本地姿势而不是应用姿势 |
| `path.spacingScale.approximated` | approximated | pose | 自 3.7 起固定间距随骨骼长度缩放，链缩放百分比间距不再缩放 |
| `path.spacingScale.rewritten` | rewritten | none | 世界缩放恒定且相同的骨骼上的固定间距或链缩放百分比间距，变为除以或乘以该缩放的间距 |
| `path.start.approximated` | approximated | pose | 位于起点或带切线的路径，3.5 在 1e-4 处计算曲线起点，3.6 在 1e-5 或更大处计算，3.7 在 0 处计算，并从曲线取其附近的切线 |
| `ik.compress.dropped` | dropped | pose | 单骨骼 IK 的压缩 |
| `ik.stretch.dropped` | dropped | pose | IK 拉伸 |
| `event.audio.dropped` | dropped | control | 事件音频路径、音量和平衡 |
| `skeleton.audio.dropped` | dropped | editor | 骨架音频路径 |
| `atlas.header.dropped` | dropped | editor | 第一个页面之前的图集条目，被运行时忽略 |
| `atlas.page.dropped` | dropped | editor | 运行时忽略的页面条目，例如 `scale` |
| `atlas.pma.dropped` | dropped | render | 页面的预乘 alpha 标志，3.8 在渲染器中设置 |
| `atlas.rotate.dropped` | dropped | render | 不是 0 或 90 的区域旋转，3.5 至 3.7 只读取 true 或 false |
| `atlas.strip.approximated` | approximated | render | 为 3.5 或 3.6 写出的去除空白的区域，或向上转换的 3.5 或 3.6 网格，因为 3.5 和 3.6 将网格 UV 映射到打包尺寸 |
| `atlas.strip.rewritten` | rewritten | none | 3.5 或 3.6 骨架的网格 UV，通过随骨架提供的图集中未旋转区域的去除空白部分进行映射 |
| `atlas.values.dropped` | dropped | control | 3.8 无法保存的区域值，split 和 pad 需要四个值，pad 需要 split |
