const Timer = @This();

const std = @import("std");
const log = std.log;

const posix = std.posix;
const SIG = posix.SIG;
const c = std.c;

const SigEvent = @import("Multiplexer.zig").SigEvent;

pub const TriggerEvent = struct {
    ptr: *anyopaque,
    onTriggerFn: *const fn (ptr: *anyopaque, time: u16) void,

    pub fn onTrigger(self: TriggerEvent, time: u16) void {
        self.onTriggerFn(self.ptr, time);
    }
};

const SigUtil = struct {
    /// 程序是否运行的标识
    var running: bool = true;

    /// 给自己发送一个信号
    pub fn raise(sig: u8) void {
        posix.raise(sig) catch |err| {
            log.err("cannot send signal alrm, error: {s}", .{@errorName(err)});
            std.process.exit(1);
        };
    }

    /// 指定时间后给自己发送一个 ALRM(14) 信号
    pub fn alarm(timer_tick: u16) void {
        _ = c.alarm(@intCast(timer_tick));
    }

    /// 阻塞停止信号
    pub fn blockStopSignal() void {
        var sa = posix.Sigaction{ .mask = posix.empty_sigset, .flags = 0, .handler = .{ .handler = SigUtil.termHandler } };

        // 处理结束信号
        posix.sigaction(SIG.TERM, &sa, null) catch @panic("handle sigterm sigaction error");
        posix.sigaction(SIG.INT, &sa, null) catch @panic("handle sigint sigaction error");
    }

    /// 捕获到 INT(2) 或 TERM(15) 信号设置结束标识
    fn termHandler(_: i32) callconv(.C) void {
        SigUtil.running = false;
        log.debug("handle exit signal", .{});
    }
};

max_interval: u16,
timer_tick: u16,
time: u16 = 0,
sig: u8 = SIG.ALRM,
event: *TriggerEvent,

pub fn init(max_interval: u16, timer_tick: u16, event: *TriggerEvent) Timer {
    return .{ .max_interval = max_interval, .timer_tick = timer_tick, .event = event };
}

pub fn start(self: Timer) void {
    SigUtil.blockStopSignal();
    SigUtil.raise(self.sig);
}

pub fn isRunning(_: Timer) bool {
    return SigUtil.running;
}

fn nextTime(self: *Timer) void {
    self.time = @mod(self.time + self.timer_tick - 1, self.max_interval) + 1;
    log.debug("timer: {}", .{self.time});
}

pub fn trigger(self: *Timer) void {
    SigUtil.alarm(self.timer_tick);

    self.event.onTrigger(self.time);
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

test "execute timer" {
    const testing = std.testing;

    const timer_tick = 1;
    const max_inteval = 3;

    const gen = struct {
        pub fn onTrigger(_: *anyopaque, _: u16) void {}
    };
    var g = gen{};
    var evt = TriggerEvent{
        .ptr = &g,
        .onTriggerFn = gen.onTrigger,
    };

    var timer = Timer.init(max_inteval, timer_tick, &evt);
    try testing.expectEqual(0, timer.time);
    timer.nextTime();
    try testing.expectEqual(1, timer.time);
    timer.nextTime();
    try testing.expectEqual(2, timer.time);
    timer.nextTime();
    try testing.expectEqual(3, timer.time);
    timer.nextTime();
    try testing.expectEqual(1, timer.time);
    timer.nextTime();
    try testing.expectEqual(2, timer.time);
}
