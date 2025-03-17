/// 默认使用 XDG_DATA_HOME 目录
/// 否则使用 HOME/.local/share 目录
pub const DATA_DIR_NAME = "dwmblocks";

/// 每个组件最大内容长度
pub const MAX_OUTPUT = 60;

// 组件名称, 脚本文件名, 时间（秒，0 表示只执行一直）
pub const blocks = .{
    .{ "icon", "icon.sh", 0 },
    .{ "netspeed", @import("components/netspeed.zig"), 1 },
    .{ "volume", "volume.sh", 5 },
    .{ "battery", @import("components/battery.zig"), 60 },
    .{ "datetime", "datetime.sh", 1 },
    .{ "trayer_toggle", "trayer_toggle.sh", 0 },
};
