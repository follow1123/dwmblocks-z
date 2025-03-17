const Message = @This();

const std = @import("std");
const log = std.log.scoped(.block);

const unix = @import("../unix.zig");
const signal = unix.signal;
const Block = @import("Block.zig");

pub var blocks: []Block = undefined;

button: ?Button = null,
show_all: bool = false,
pid: unix.Pid,

pub fn init() Message {
    return .{
        .pid = unix.getpid(),
    };
}

/// 更新指定 name 的Blcok
/// blocks 属性必须初始化
/// 用于代码编写的 component
pub fn notifyBlock(self: Message, block_name: [:0]const u8, button: ?Button) void {
    const sig = for (blocks) |blk| {
        if (std.mem.eql(u8, block_name, blk.name)) break blk.signum;
    } else {
        log.err("no block name: {s}", .{block_name});
        return;
    };
    if (button) |btn| {
        const val = signal.SigVal{ .sival_int = @intFromEnum(btn) };
        signal.queue(self.pid, sig, val) catch |err| {
            log.err("cannot send signal {} to {}, error: {s}", .{ sig, self.pid, @errorName(err) });
        };
    } else {
        unix.kill(self.pid, sig) catch |err| {
            log.err("cannot send signal {} to {}, error: {s}", .{ sig, self.pid, @errorName(err) });
        };
    }
}

/// 生成更新脚本存入环境变量内方便在脚本内调用
/// 用于脚本编写的 component
pub fn generateNotifyCommand(self: Message, alloc: std.mem.Allocator, env: *std.process.EnvMap) !void {
    for (blocks) |blk| {
        const key = try std.fmt.allocPrint(alloc, "update_block_{s}", .{blk.name});
        defer alloc.free(key);
        const command = try std.fmt.allocPrint(alloc, "kill -{} {}", .{ blk.signum, self.pid });
        defer alloc.free(command);
        try env.put(key, command);
    }
}

pub const Button = enum(u8) {
    left = '1',
    middle = '2',
    right = '3',
    up = '4',
    down = '5',
    ctrlLeft = '6',
    ctrlRight = '7',

    pub fn fromInt(i: u8) ?Button {
        if (i < 1 or i > 7) return null;
        return @enumFromInt(i + 48);
    }

    pub fn getChar(self: Button) u8 {
        return @intFromEnum(self);
    }
};

test "create button" {
    const testing = std.testing;
    try testing.expectEqual(Button.left, Button.fromInt(1));
    try testing.expectEqual(Button.right, Button.fromInt(3));
    try testing.expectEqual(Button.ctrlLeft, Button.fromInt(6));
    try testing.expectEqual(null, Button.fromInt(10));
    try testing.expectEqual(null, Button.fromInt(0));
}
