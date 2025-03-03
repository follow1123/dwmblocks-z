const Timer = @This();

const std = @import("std");
const log = std.log;

const posix = std.posix;
const SIG = posix.SIG;
const linux = std.os.linux;
const c = std.c;

const Allocator = std.mem.Allocator;
const config = @import("config.zig");
const SigEvent = @import("Multiplexer.zig").SigEvent;

const SigUtil = struct {
    raise: *const fn (sig: u8) void,
    alarm: *const fn (timer_tick: u16) void,
    pub fn defalut() SigUtil {
        return .{
            .raise = SigUtil.raise_impl,
            .alarm = SigUtil.alarm_impl,
        };
    }
    fn raise_impl(sig: u8) void {
        posix.raise(sig) catch |err| {
            log.err("cannot send signal alrm, error: {s}", .{@errorName(err)});
            std.process.exit(1);
        };
    }
    fn alarm_impl(timer_tick: u16) void {
        _ = c.alarm(@intCast(timer_tick));
    }
};

max_interval: u16,
timer_tick: u16,
time: u16 = 0,
sig: u8 = SIG.ALRM,
ptr: *anyopaque,
on_trigger: *const fn (ptr: *anyopaque, time: u16) anyerror!void,
sig_util: SigUtil,

pub fn init(max_interval: u16, timer_tick: u16, ptr: anytype, comptime method: []const u8) Timer {
    const T = @TypeOf(ptr);
    const ptr_info = @typeInfo(T);
    const gen = struct {
        pub fn on_trigger(pointer: *anyopaque, time: u16) anyerror!void {
            const self: T = @ptrCast(@alignCast(pointer));
            return @field(ptr_info.Pointer.child, method)(self, time);
        }
    };

    return .{ .max_interval = max_interval, .timer_tick = timer_tick, .ptr = ptr, .on_trigger = gen.on_trigger, .sig_util = SigUtil.defalut() };
}

pub fn start(self: Timer) void {
    self.sig_util.raise(self.sig);
}

fn nextTime(self: *Timer) void {
    self.time = @mod(self.time + self.timer_tick - 1, self.max_interval) + 1;
    log.debug("timer: {}", .{self.time});
}

pub fn trigger(self: *Timer) void {
    self.sig_util.alarm(self.timer_tick);

    self.on_trigger(self.ptr, self.time) catch {};
    self.nextTime();
}

pub fn sigEvent(ctx: *Timer) SigEvent {
    const gen = struct {
        pub fn getSig(ptr: *anyopaque) u8 {
            const self: *Timer = @ptrCast(@alignCast(ptr));
            return self.sig;
        }
        pub fn onSigTrigger(ptr: *anyopaque, _: i32) void {
            const self: *Timer = @ptrCast(@alignCast(ptr));
            self.trigger();
        }
    };

    return .{
        .ptr = ctx,
        .getSigFn = gen.getSig,
        .onSigTriggerFn = gen.onSigTrigger,
    };
}

pub fn main() !void {
    const ST = struct {
        pub fn on_trigger(self: *@This(), time: u16) void {
            _ = self;
            log.debug("run some code with time: {}", .{time});
        }
    };

    var st = ST{};

    var timer = Timer.init(5, 1, &st, "on_trigger");
    const sig_handler = struct {
        pub var tmr: *Timer = undefined;
        pub fn handle(signal: i32) callconv(.C) void {
            _ = signal;
            tmr.trigger();
        }
    };

    sig_handler.tmr = &timer;

    var sa = posix.Sigaction{
        .handler = .{ .handler = sig_handler.handle },
        .flags = 0,
        .mask = posix.empty_sigset,
    };

    try posix.sigaction(SIG.ALRM, &sa, null);
    timer.start();

    while (true) {
        log.debug("waiting...", .{});
        std.time.sleep(100 * std.time.ns_per_ms);
    }
}

test "execute timer" {
    const testing = std.testing;

    const ST = struct {
        pub fn on_trigger(self: *@This(), time: u16) void {
            _ = self;
            log.debug("run some code with time: {}", .{time});
        }
    };
    const sig_test_util = struct {
        pub fn raise(sig: u8) void {
            _ = sig;
        }

        pub fn alarm(timer_tick: u16) void {
            _ = timer_tick;
        }
    };

    var st = ST{};

    const timer_tick = 1;
    const max_inteval = 3;
    var timer = Timer.init(max_inteval, timer_tick, &st, "on_trigger");
    timer.sig_util = .{
        .raise = sig_test_util.raise,
        .alarm = sig_test_util.alarm,
    };
    timer.start();
    try testing.expectEqual(0, timer.time);
    timer.trigger();
    try testing.expectEqual(1, timer.time);
    timer.trigger();
    try testing.expectEqual(2, timer.time);
    timer.trigger();
    try testing.expectEqual(3, timer.time);
    timer.trigger();
    try testing.expectEqual(1, timer.time);
    timer.trigger();
    try testing.expectEqual(2, timer.time);
}
