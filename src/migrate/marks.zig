//! Fields one step leaves for a later step of the same run

/// 3.8 skips a world scale mix up to 0, 4.3 clamps it with a slider
pub const scale_floor = "spine-converter-scale-floor";

/// One bone IK solved in the parent frame by a normal proxy bone
pub const ik_proxy = "spine-converter-ik-proxy";

/// Two bone IK whose parent shear 4.2 drops
pub const shear_reset = "spine-converter-shear-reset";

/// Shear mix keyed through 0 that 3.6 skips while not positive
pub const shear_floor = "spine-converter-shear-floor";

/// 3.8 stretch keeps the child Y position, 4.3 needs a helper parent
pub const stretch_offset = "spine-converter-stretch-offset";

/// 4.0 betas scale relative local transforms by 1 + s * k, 4.3 needs helper bones
pub const relative_scale = "spine-converter-relative-scale";

/// 3.5 betas add a rotation offset without the reflection sign, 4.3 maps it unsigned
pub const offset_unsigned = "spine-converter-offset-unsigned";

/// 3.7 and 3.8 scale a fixed path position, a 3.5 or 3.6 source going to 4.0 keeps it
pub const position_unscaled = "spine-converter-position-unscaled";

/// 3.5 clamps length spacing at 0, so a 3.5 source going to 4.3 keeps it
pub const length_clamped = "spine-converter-length-clamped";

/// 3.5 and 3.7 leave chain scale percent spacing unscaled, only 3.6 scales it
pub const spacing_unscaled = "spine-converter-spacing-unscaled";

/// 4.1 and 4.2 wrap partial local rotate and shear, 4.3 needs helper bones
pub const local_wrap = "spine-converter-local-wrap";

/// noRotationOrReflection bone of a 3.5 beta rebuilt by helper bones
pub const no_rotation = "spine-converter-no-rotation";

/// Scale floor reads a snapshot of the source taken before the constraint
pub const scale_snapshot = "spine-converter-scale-snapshot";

/// Restore of a two bone IK child that runs only where the IK mix is 0
pub const restore_gate = "spine-converter-restore-gate";

/// Bones a 4.3 helper constraint restores to their local pose after this constraint
pub const restore = "spine-converter-restore";

/// 3.8 skips a path constraint while neither mix is positive, 4.3 gates it with sliders
pub const path_gate = "spine-converter-path-gate";

/// 4.0 skips mixScaleY while the other mixes are 0, 4.3 gates it with a slider
pub const mix_scale_y_gate = "spine-converter-mix-scale-y-gate";

/// 4.1 applied shear has the opposite sign, 4.3 maps the shear copy with scale -1
pub const applied_flip = "spine-converter-applied-flip";
