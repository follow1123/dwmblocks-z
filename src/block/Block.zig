const Block = @This();

const std = @import("std");
const log = std.log.scoped(.block);

const unix = @import("../unix.zig");
const signal = unix.signal;

const Allocator = std.mem.Allocator;
const config = @import("../config.zig");
const Event = @import("../Multiplexer.zig").Event;
const SigEvent = @import("../Multiplexer.zig").SigEvent;
const ComponentExecutor = @import("ComponentExecutor.zig");

const EnvMap = std.process.EnvMap;

alloc: Allocator,
interval: i32,
signum: u7,
output: []u8,
output_len: usize = 0,
executor: ComponentExecutor,
lock: bool = false,

inline fn rtSignal(sig: u7) u7 {
    return @intCast(signal.RTMIN() + sig);
}

pub fn init(alloc: Allocator, executor: ComponentExecutor, interval: i32, signum: u7) Block {
    return .{
        .signum = rtSignal(signum),
        .alloc = alloc,
        .interval = interval,
        .output = alloc.alloc(u8, config.MAX_OUTPUT) catch @panic("cannot create buf for reasult"),
        .executor = executor,
    };
}

pub fn deinit(self: *Block) void {
    self.alloc.free(self.output);
    self.executor.deinit();
}

pub fn execBlock(self: *Block, button: ?Button) void {
    if (self.lock) return;
    self.lock = true;

    self.executor.execute(Message.init(button));
}

pub fn getOutput(self: *Block) []u8 {
    return self.output[0..self.output_len];
}

pub fn updateBlock(self: *Block) void {
    self.lock = false;
    self.output_len = self.executor.readResult(self.output);
    if (self.output_len > 0 and self.output[self.output_len - 1] == '\n') self.output_len -= 1;
}

pub fn event(ctx: *Block) Event {
    const gen = struct {
        pub fn getFd(ptr: *anyopaque) unix.FD {
            const self: *Block = @ptrCast(@alignCast(ptr));
            return self.executor.getFd();
        }
        pub fn onTrigger(ptr: *anyopaque) void {
            const self: *Block = @ptrCast(@alignCast(ptr));
            self.updateBlock();
        }
    };

    return .{
        .ptr = ctx,
        .getFdFn = gen.getFd,
        .onTriggerFn = gen.onTrigger,
    };
}

pub fn sigEvent(ctx: *Block) SigEvent {
    const gen = struct {
        pub fn getSig(ptr: *anyopaque) u8 {
            const self: *Block = @ptrCast(@alignCast(ptr));
            return self.signum;
        }
        pub fn onSigTrigger(ptr: *anyopaque, data: i32) void {
            const self: *Block = @ptrCast(@alignCast(ptr));
            self.execBlock(Button.fromInt(@intCast(data)));
        }
    };

    return .{
        .ptr = ctx,
        .getSigFn = gen.getSig,
        .onSigTriggerFn = gen.onSigTrigger,
    };
}

pub const Message = struct {
    button: ?Button,
    pid: unix.Pid,

    pub fn init(button: ?Button) Message {
        return .{
            .button = button,
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
};

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
