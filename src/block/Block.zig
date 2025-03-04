const Block = @This();

const std = @import("std");
const log = std.log;

const posix = std.posix;
const SIG = posix.SIG;
const linux = std.os.linux;

const signal = @cImport({
    @cInclude("signal.h");
});

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
executor: *ComponentExecutor,

pub fn init(alloc: Allocator, executor: *ComponentExecutor, interval: i32, signum: u7) Block {
    const SIGRTMIN: u8 = @intCast(signal.__libc_current_sigrtmin());

    return .{
        .signum = @intCast(SIGRTMIN + signum),
        .alloc = alloc,
        .interval = interval,
        .output = alloc.alloc(u8, config.MAX_OUTPUT) catch @panic("cannot create buf for reasult"),
        .executor = executor,
    };
}

pub fn deinit(self: *Block) void {
    self.alloc.free(self.output);
}

pub fn execBlock(self: *Block, button: ?Button) void {
    const blk_btn_key = "BLOCK_BUTTON";
    var env = EnvMap.init(self.alloc);
    defer env.deinit();

    if (button) |btn| env.put(blk_btn_key, &.{btn.getChar()}) catch @panic("cannot put env to env map");

    self.executor.execute(&env);
}

pub fn getOutput(self: *Block) []u8 {
    return self.output[0..self.output_len];
}

pub fn updateBlock(self: *Block) void {
    self.output_len = self.executor.readResult(self.output);
    if (self.output_len > 0 and self.output[self.output_len - 1] == '\n') self.output_len -= 1;
}

pub fn event(ctx: *Block) Event {
    const gen = struct {
        pub fn getFd(ptr: *anyopaque) posix.fd_t {
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

test "execute script block" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const ScriptExecutor = @import("ScriptExecutor.zig");

    // 获取脚本路径
    const script_path = try std.fs.cwd().realpathAlloc(alloc, "tests/scripts");
    defer alloc.free(script_path);

    ScriptExecutor.staticInit(alloc);
    defer ScriptExecutor.staticDeinit(alloc);

    alloc.free(ScriptExecutor.data_home);
    ScriptExecutor.data_home = try std.mem.Allocator.dupeZ(alloc, u8, script_path);
    var script_executor = ScriptExecutor.init(alloc, "test_script");
    defer script_executor.deinit();
    var executor = script_executor.executor();

    var block = Block.init(alloc, &executor, 1, 1);
    defer block.deinit();

    const epoll_fd = try posix.epoll_create1(0);
    var evt = linux.epoll_event{
        .events = linux.EPOLL.IN,
        .data = .{ .fd = script_executor.pipe[0] },
    };
    try posix.epoll_ctl(epoll_fd, linux.EPOLL.CTL_ADD, script_executor.pipe[0], &evt);

    const mid = Button.middle;
    block.execBlock(mid);

    var events: [1]linux.epoll_event = undefined;
    _ = posix.epoll_wait(epoll_fd, &events, -1);

    block.updateBlock();
    try testing.expectEqualSlices(u8, &.{mid.getChar()}, block.getOutput());
}

test "create button" {
    const testing = std.testing;
    try testing.expectEqual(Button.left, Button.fromInt(1));
    try testing.expectEqual(Button.right, Button.fromInt(3));
    try testing.expectEqual(Button.ctrlLeft, Button.fromInt(6));
    try testing.expectEqual(null, Button.fromInt(10));
    try testing.expectEqual(null, Button.fromInt(0));
}
