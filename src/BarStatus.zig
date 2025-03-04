const BarStatus = @This();

const std = @import("std");
const log = std.log;
const Allocator = std.mem.Allocator;

const posix = std.posix;
const SIG = posix.SIG;

const Block = @import("block/Block.zig");
const SigEvent = @import("Multiplexer.zig").SigEvent;
const TriggerEvent = @import("Timer.zig").TriggerEvent;
const X11 = @import("X11.zig");

alloc: Allocator,
blocks: []Block,
sig: u8 = SIG.USR1,
x11: X11,
current: std.ArrayList(u8),
previous: std.ArrayList(u8),

pub fn init(alloc: Allocator, blocks: []Block) !BarStatus {
    return .{
        .alloc = alloc,
        .blocks = blocks,
        .x11 = try X11.init(),
        .current = std.ArrayList(u8).init(alloc),
        .previous = std.ArrayList(u8).init(alloc),
    };
}

pub fn deinit(self: *BarStatus) void {
    self.x11.deinit();
    self.current.deinit();
    self.previous.deinit();
}

pub fn updateStatus(self: *BarStatus) !bool {
    self.previous.clearRetainingCapacity();
    try self.previous.appendSlice(self.current.items);

    self.current.clearRetainingCapacity();
    for (self.blocks) |*block| {
        const output = block.getOutput();
        if (output.len == 0) continue;
        try self.current.append(' ');
        try self.current.appendSlice(output);
    }
    // log.debug("current status: {s}", .{self.current.items});

    return std.mem.eql(u8, self.previous.items, self.current.items);
}

pub fn execBlocks(self: *BarStatus, time: i32) void {
    log.debug("execute block by time", .{});
    for (self.blocks) |*block| {
        if (time == 0 or (block.interval != 0 and @mod(time, block.interval) == 0)) {
            block.execBlock(null);
        }
    }
}

pub fn writeStatus(self: *BarStatus) !void {
    if (try self.updateStatus()) {
        log.debug("nothing to update", .{});
        return;
    }
    log.debug("{s}", .{self.current.items});
    // const status = try self.alloc.alloc(u8, self.current.items.len);
    // defer self.alloc.free(status);
    // std.mem.copyForwards(u8, status, self.current.items);
    // self.x11.setRoot(status.ptr);
}

pub fn sigEvent(ctx: *BarStatus) SigEvent {
    const gen = struct {
        pub fn getSig(ptr: *anyopaque) u8 {
            const self: *BarStatus = @ptrCast(@alignCast(ptr));
            return self.sig;
        }
        pub fn onSigTrigger(ptr: *anyopaque, _: i32) void {
            const self: *BarStatus = @ptrCast(@alignCast(ptr));
            self.execBlocks(0);
        }
    };

    return .{
        .ptr = ctx,
        .getSigFn = gen.getSig,
        .onSigTriggerFn = gen.onSigTrigger,
    };
}

pub fn triggerEvent(ctx: *BarStatus) TriggerEvent {
    const gen = struct {
        pub fn onTrigger(ptr: *anyopaque, time: u16) void {
            const self: *BarStatus = @ptrCast(@alignCast(ptr));
            self.execBlocks(time);
        }
    };

    return .{
        .ptr = ctx,
        .onTriggerFn = gen.onTrigger,
    };
}

test "init bar status" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var bs = BarStatus.init(alloc);
    defer bs.deinit();
}

test "write status bar" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // 获取脚本路径
    const script_path = try std.fs.cwd().realpathAlloc(alloc, "tests/scripts/test_script");
    defer alloc.free(script_path);
    const path = try std.mem.Allocator.dupeZ(alloc, u8, script_path);
    defer alloc.free(path);

    var bs = [_]Block{
        Block.init(alloc, path, 1, 1),
        Block.init(alloc, path, 1, 1),
    };
    for (&bs, 0..) |*b, i| {
        var buf: [1]u8 = undefined;
        const s = try std.fmt.bufPrint(&buf, "{}", .{i});
        b.execBlock(s);
    }
    defer for (&bs) |*b| b.deinit();

    var status = BarStatus.init(alloc);
    defer status.deinit();
    _ = try status.updateStatus(&bs);
    try status.writeStatus();
}
