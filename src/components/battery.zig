const std = @import("std");
const log = std.log;

const Allocator = std.mem.Allocator;
const Button = @import("../block.zig").Button;
const Message = @import("../block.zig").Message;

const BAT_ICONS = [_][:0]const u8{ "󰁺", "󰁻", "󰁼", "󰁽", "󰁾", "󰁿", "󰂀", "󰂁", "󰂂", "󰁹" };
const CHARGING_BAT_ICONS = [_][:0]const u8{ "󰢜", "󰂆", "󰂇", "󰂈", "󰢝", "󰂉", "󰢞", "󰂊", "󰂋", "󰂅" };
const BAT_NAME = "BAT0";

const BatteryStatus = enum {
    Full,
    Charging,
    Discharging,
    NotCharging,
};

/// 使用 run 方法内的 allocator 分配的内存可以不用释放
/// 调用结束后由 CodeExecutor 统一释放
pub fn run(alloc: Allocator, message: Message) !?[]u8 {
    if (!message.show_all) return null;
    const capacity = try getBatteryCapacity(alloc);
    const icon_idx: u8 = @as(u8, @intCast((capacity + 9) / 10)) - 1;
    const icon = if (try getBatteryStatus(alloc) == .Charging) CHARGING_BAT_ICONS[icon_idx] else BAT_ICONS[icon_idx];
    const buf = try alloc.alloc(u8, icon.len);
    @memcpy(buf, icon);
    return buf;
}

fn getBatteryCapacity(alloc: Allocator) !u8 {
    const bat_cap_file_path = try std.fmt.allocPrint(alloc, "/sys/class/power_supply/{s}/capacity", .{BAT_NAME});
    var bat_cap_file = try std.fs.openFileAbsolute(bat_cap_file_path, .{});
    defer bat_cap_file.close();
    var buf: [10]u8 = undefined;
    const len = try bat_cap_file.readAll(&buf);
    return std.fmt.parseInt(u8, buf[0 .. len - 1], 10);
}

fn getBatteryStatus(alloc: Allocator) !BatteryStatus {
    const bat_status_file_path = try std.fmt.allocPrint(alloc, "/sys/class/power_supply/{s}/status", .{BAT_NAME});
    var bat_status_file = try std.fs.openFileAbsolute(bat_status_file_path, .{});
    defer bat_status_file.close();
    var buf: [30]u8 = undefined;
    const len = try bat_status_file.readAll(&buf);
    const status_str = buf[0..len];
    if (std.mem.startsWith(u8, status_str, "Full")) {
        return BatteryStatus.Full;
    } else if (std.mem.startsWith(u8, status_str, "Discharging")) {
        return BatteryStatus.Discharging;
    } else if (std.mem.startsWith(u8, status_str, "Not charging")) {
        return BatteryStatus.NotCharging;
    } else if (std.mem.startsWith(u8, status_str, "Charging")) {
        return BatteryStatus.Charging;
    } else @panic("unknow battery status");
}
