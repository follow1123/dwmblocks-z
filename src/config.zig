/// 默认使用 XDG_DATA_HOME 目录
/// 否则使用 HOME/.local/share 目录
pub const DATA_DIR_NAME = "dwmblocks";
pub const MAX_OUTPUT = 60;

pub const blocks = .{
    .{ "icon", "icon.sh", 0 },
    // .{ "netspeed", "netspeed.sh", 1 },
    .{ "netspeed", @import("components/netspeed.zig"), 1 },
    .{ "volume", "volume.sh", 5 },
    // "", .{ "bluetooth.sh", 15},
    // "", .{ "battery.sh", 60},
    .{ "battery", @import("components/battery.zig"), 60 },
    .{ "bluetooth", "bluetooth.sh", 7 },
    .{ "battery", "battery.sh", 7 },
    .{ "datetime", "datetime.sh", 1 },
    .{ "trayer_toggle", "trayer_toggle.sh", 0 },
};
