const BarStatus = @This();

const std = @import("std");
const log = std.log.scoped(.bar_status);
const Allocator = std.mem.Allocator;

const unix = @import("unix.zig");
const signal = unix.signal;

const block = @import("block.zig");
const Block = block.Block;
const Message = block.Message;
const SigEvent = @import("Multiplexer.zig").SigEvent;
const TriggerEvent = @import("Timer.zig").TriggerEvent;

alloc: Allocator,
blocks: []Block,
show_all_flag: bool = false,
x11: X11,
current: std.ArrayList(u8),
previous: std.ArrayList(u8),

pub fn init(alloc: Allocator, blocks: []Block) BarStatus {
    return .{
        .alloc = alloc,
        .blocks = blocks,
        .x11 = X11.init(),
        .current = std.ArrayList(u8).init(alloc),
        .previous = std.ArrayList(u8).init(alloc),
    };
}

pub fn deinit(self: *BarStatus) void {
    self.x11.deinit();
    self.current.deinit();
    self.previous.deinit();
}

fn updateStatus(self: *BarStatus) !bool {
    self.previous.clearRetainingCapacity();
    try self.previous.appendSlice(self.current.items);

    self.current.clearRetainingCapacity();
    for (self.blocks) |*blk| {
        const output = blk.getOutput();
        if (output.len == 0) continue;
        try self.current.append(' ');
        try self.current.appendSlice(output);
    }
    return std.mem.eql(u8, self.previous.items, self.current.items);
}

pub fn execBlocks(self: *BarStatus, time: i32) void {
    log.debug("execute block by timer", .{});
    for (self.blocks) |*blk| {
        if (time == 0 or (blk.interval != 0 and @mod(time, blk.interval) == 0)) {
            var message = Message.init();
            message.show_all = self.show_all_flag;
            blk.execBlock(message);
        }
    }
}

pub fn writeStatus(self: *BarStatus) void {
    const updated = self.updateStatus() catch |err| {
        log.err("cannot update status, error: {s}", .{@errorName(err)});
        return;
    };
    if (!updated) return;

    log.debug("{s}", .{self.current.items});

    const status = self.alloc.allocSentinel(u8, self.current.items.len, 0) catch |err| {
        log.err("cannot alloc status buffer in heap, error: {s}", .{@errorName(err)});
        return;
    };
    defer self.alloc.free(status);
    @memcpy(status, self.current.items);
    self.x11.setRoot(status.ptr);
}

pub fn updateAllBlocksEvent(ctx: *BarStatus) SigEvent {
    const gen = struct {
        pub fn getSig(_: *anyopaque) u8 {
            return signal.USR1;
        }
        pub fn onSigTrigger(ptr: *anyopaque, _: i32) void {
            const self: *BarStatus = @ptrCast(@alignCast(ptr));
            log.debug("update all blocks", .{});
            self.execBlocks(0);
        }
    };

    return .{
        .ptr = ctx,
        .getSigFn = gen.getSig,
        .onSigTriggerFn = gen.onSigTrigger,
    };
}

pub fn showAllBlocksEvent(ctx: *BarStatus) SigEvent {
    const gen = struct {
        pub fn getSig(_: *anyopaque) u8 {
            return signal.USR2;
        }
        pub fn onSigTrigger(ptr: *anyopaque, _: i32) void {
            const self: *BarStatus = @ptrCast(@alignCast(ptr));
            log.debug("show all blocks", .{});
            self.show_all_flag = !self.show_all_flag;
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

pub const X11 = struct {
    const xlib = @cImport({
        @cInclude("X11/Xlib.h");
    });

    display: *xlib.Display,
    root_window: xlib.Window,

    pub fn init() X11 {
        const dpy = xlib.XOpenDisplay(null) orelse @panic("cannot open x display");
        return .{
            .display = dpy,
            .root_window = xlib.DefaultRootWindow(dpy),
        };
    }

    pub fn deinit(self: X11) void {
        if (xlib.XCloseDisplay(self.display) != 0) {
            log.err("cannot close x display", .{});
        }
    }

    pub fn setRoot(self: X11, text: [*]const u8) void {
        _ = xlib.XStoreName(self.display, self.root_window, text);
        _ = xlib.XFlush(self.display);
    }
};
