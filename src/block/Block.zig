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
const Message = @import("Message.zig");
const Button = Message.Button;

const EnvMap = std.process.EnvMap;

alloc: Allocator,
interval: i32,
name: [:0]const u8,
signum: u7,
output: []u8,
output_len: usize = 0,
executor: ComponentExecutor,
lock: bool = false,

pub fn init(alloc: Allocator, executor: ComponentExecutor, name: [:0]const u8, interval: i32, signum: u7) Block {
    return .{
        .name = name,
        .signum = @intCast(signal.RTMIN() + signum),
        .alloc = alloc,
        .interval = interval,
        .output = alloc.alloc(u8, config.MAX_OUTPUT) catch @panic("cannot create buf for reasult"),
        .executor = executor,
    };
}

pub fn deinit(self: Block) void {
    self.alloc.free(self.output);
    self.executor.deinit();
}

pub fn execBlock(self: *Block, message: Message) void {
    if (self.lock) return;
    self.lock = true;

    self.executor.execute(message);
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
            var message = Message.init();
            message.button = Button.fromInt(@intCast(data));
            self.execBlock(message);
        }
    };

    return .{
        .ptr = ctx,
        .getSigFn = gen.getSig,
        .onSigTriggerFn = gen.onSigTrigger,
    };
}
