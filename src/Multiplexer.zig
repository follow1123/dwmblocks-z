const Multiplexer = @This();

const std = @import("std");
const log = std.log;

const Allocator = std.mem.Allocator;
const unix = @import("unix.zig");
const signal = unix.signal;
const epoll = unix.epoll;

const EPOLL_EVENT_COUNT = @import("config.zig").blocks.len + 1;

pub const Event = struct {
    ptr: *anyopaque,
    getFdFn: *const fn (ptr: *anyopaque) unix.FD,
    onTriggerFn: *const fn (ptr: *anyopaque) void,

    pub fn getFd(self: Event) unix.FD {
        return self.getFdFn(self.ptr);
    }

    pub fn onTrigger(self: Event) void {
        self.onTriggerFn(self.ptr);
    }
};

pub const SigEvent = struct {
    ptr: *anyopaque,
    getSigFn: *const fn (ptr: *anyopaque) u8,
    onSigTriggerFn: *const fn (ptr: *anyopaque, data: i32) void,

    pub fn getSig(self: SigEvent) u8 {
        return self.getSigFn(self.ptr);
    }

    pub fn onSigTrigger(self: SigEvent, data: i32) void {
        self.onSigTriggerFn(self.ptr, data);
    }
};

pub const SigEventCombinator = struct {
    sig_fd: ?unix.FD = null,
    events: std.ArrayList(SigEvent),

    pub fn init(alloc: Allocator) SigEventCombinator {
        return .{
            .events = std.ArrayList(SigEvent).init(alloc),
        };
    }

    pub fn deinit(self: *SigEventCombinator) void {
        if (self.sig_fd) |fd| unix.close(fd);
        self.events.deinit();
    }

    pub fn add(self: *SigEventCombinator, event: SigEvent) void {
        self.events.append(event) catch @panic("cannot add sig event");
    }

    pub fn onTrigger(self: *SigEventCombinator) void {
        var info: signal.FdInfo = undefined;
        _ = unix.uread(self.sig_fd, &info, @sizeOf(signal.FdInfo));

        for (self.sig_events) |sig_evt| {
            if (sig_evt.getSig() == info.signo) sig_evt.onSigTrigger(info.int & 0xff);
        }
    }

    pub fn getEvent(self: *SigEventCombinator) Event {
        if (self.sig_fd != null) @panic("sig already convert to fd");

        var handled_sig: signal.SigSet = undefined;
        signal.emptySigSet(&handled_sig) catch @panic("cannot empty sig set");
        for (self.events.items) |sig_evt| signal.sigAddSet(&handled_sig, sig_evt.getSig()) catch @panic("cannot add signal to sigset");

        // Create a signal file descriptor for epoll to watch
        self.sig_fd = signal.setToFd(&handled_sig);

        // Block all realtime and handled signals
        for (signal.RTMIN()..signal.RTMAX() + 1) |i| signal.sigAddSet(&handled_sig, @intCast(i)) catch @panic("cannot add signal to sigset");
        signal.blockSet(&handled_sig) catch @panic("cannot block sigset");

        const gen = struct {
            pub fn getFd(ptr: *anyopaque) unix.FD {
                const slf: *SigEventCombinator = @ptrCast(@alignCast(ptr));
                return slf.sig_fd.?;
            }
            pub fn onTrigger(ptr: *anyopaque) void {
                const slf: *SigEventCombinator = @ptrCast(@alignCast(ptr));

                var info: signal.FdInfo = undefined;
                _ = unix.uread(slf.sig_fd.?, &info, @sizeOf(signal.FdInfo));
                for (slf.events.items) |sig_evt| {
                    if (sig_evt.getSig() == info.signo) {
                        sig_evt.onSigTrigger(info.int & 0xff);
                    }
                }
            }
        };

        return .{
            .ptr = self,
            .getFdFn = gen.getFd,
            .onTriggerFn = gen.onTrigger,
        };
    }
};

epoll_fd: unix.FD,

pub fn init() Multiplexer {
    return .{
        .epoll_fd = epoll.create() catch @panic("cannot create epoll fd"),
    };
}

pub fn deinit(self: *Multiplexer) void {
    unix.close(self.epoll_fd);
}

pub fn registerEvent(self: *Multiplexer, e: *Event) void {
    var event = epoll.Event{ .events = epoll.IN, .data = .{ .ptr = @intFromPtr(e) } };
    epoll.ctl(self.epoll_fd, epoll.CTL_ADD, e.getFd(), &event) catch @panic("cannot register event to epoll");
}

pub fn waitEvents(self: *Multiplexer) usize {
    var events: [EPOLL_EVENT_COUNT]epoll.Event = undefined;
    const evt_count = epoll.wait(self.epoll_fd, &events, 500);
    for (events[0..evt_count]) |event| {
        const e: *Event = @ptrFromInt(event.data.ptr);
        e.onTrigger();
    }
    return evt_count;
}

test "register event" {
    const testing = std.testing;

    const gen = struct {
        var flag = false;
        var pipe: [2]unix.FD = undefined;
        pub fn getFd(_: *anyopaque) unix.FD {
            return pipe[0];
        }
        pub fn onTrigger(_: *anyopaque) void {
            flag = true;
        }
    };
    gen.pipe = try unix.pipe();

    var event = Event{
        .ptr = undefined,
        .getFdFn = gen.getFd,
        .onTriggerFn = gen.onTrigger,
    };

    var multiplexer = Multiplexer.init();
    defer multiplexer.deinit();

    multiplexer.registerEvent(&event);
    _ = try unix.write(gen.pipe[1], "111");
    const evt_count = multiplexer.waitEvents();
    try testing.expectEqual(1, evt_count);
    try testing.expect(gen.flag);
}

test "register signal event" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const sig = signal.INT;
    const gen = struct {
        var flag1: i32 = undefined;
        var flag2 = false;
        pub fn getSig(_: *anyopaque) u8 {
            return sig;
        }

        pub fn onSigTrigger(_: *anyopaque, data: i32) void {
            flag1 = data;
            flag2 = true;
        }
    };

    const sig_event = SigEvent{
        .ptr = undefined,
        .getSigFn = gen.getSig,
        .onSigTriggerFn = gen.onSigTrigger,
    };

    var multiplexer = Multiplexer.init();
    defer multiplexer.deinit();

    var combinator = SigEventCombinator.init(alloc);
    defer combinator.deinit();

    combinator.add(sig_event);
    var event = combinator.getEvent();

    multiplexer.registerEvent(&event);

    try signal.raise(sig);

    var evt_count = multiplexer.waitEvents();
    try testing.expectEqual(1, evt_count);
    try testing.expect(gen.flag2);

    const val = signal.SigVal{ .sival_int = 101 };

    try signal.queue(unix.getpid(), sig, val);
    evt_count = multiplexer.waitEvents();
    try testing.expectEqual(1, evt_count);
    try testing.expectEqual(val.sival_int, gen.flag1);
}
