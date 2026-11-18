pub const Version = @import("Version.zig");
pub const Document = @import("Document.zig");
pub const Report = @import("Report.zig");
pub const Format = @import("detect.zig").Format;
pub const detect = @import("detect.zig").detect;
pub const convert = @import("convert.zig");

pub const library_version = @import("std").fmt.comptimePrint("{s}", .{@import("build_info").version});

test {
    _ = @import("Version.zig");
    _ = @import("Document.zig");
    _ = @import("Report.zig");
    _ = @import("detect.zig");
    _ = @import("atlas.zig");
    _ = @import("json.zig");
    _ = @import("convert.zig");
    _ = @import("binary/Reader.zig");
    _ = @import("binary/Writer.zig");
    _ = @import("binary/tree.zig");
    _ = @import("edit.zig");
    _ = @import("binary/v3_5.zig");
    _ = @import("binary/v3_8.zig");
    _ = @import("binary/v4_0.zig");
    _ = @import("binary/v4_1.zig");
    _ = @import("binary/v4_2.zig");
    _ = @import("binary/v4_3.zig");
    _ = @import("migrate/chain.zig");
    _ = @import("migrate/order.zig");
    _ = @import("migrate/v3_8_v4_0.zig");
    _ = @import("migrate/v4_0_v4_1.zig");
    _ = @import("migrate/v4_1_v4_2.zig");
    _ = @import("migrate/v4_2_v4_3.zig");
}
