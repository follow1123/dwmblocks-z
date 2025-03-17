const Message = @This();

const std = @import("std");
const log = std.log.scoped(.block);

const unix = @import("../unix.zig");
const signal = unix.signal;

const config = @import("../config.zig");

button: ?Button = null,
show_all: bool = false,
pid: unix.Pid,

pub fn init() Message {
    return .{
        .pid = unix.getpid(),
    };
}

pub fn notifyBlock(self: Message, block_name: [:0]const u8, button: ?Button) void {
    const sig = for (config.blocks, signal.RTMIN() + 1..) |b, i| {
        if (std.mem.eql(u8, block_name, b[0])) break i;
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
