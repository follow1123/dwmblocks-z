const Multiplexer = @This();

const std = @import("std");
const log = std.log;

const Allocator = std.mem.Allocator;
const posix = std.posix;
const SIG = posix.SIG;
const linux = std.os.linux;

const signal = @cImport({
    @cInclude("signal.h");
    @cInclude("sys/signalfd.h");
});

const unix = @cImport({
    @cInclude("unistd.h");
});

pub const Event = struct {
    ptr: *anyopaque,
    getFdFn: *const fn (ptr: *anyopaque) posix.fd_t,
    onTriggerFn: *const fn (ptr: *anyopaque) void,

    pub fn init(ptr: anytype) Event {
        const T = @TypeOf(ptr);
        const ptr_info = @typeInfo(T);

        const gen = struct {
            pub fn getFd(pointer: *anyopaque) posix.fd_t {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.Pointer.child.getFd(self);
            }
            pub fn onTrigger(pointer: *anyopaque) void {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.Pointer.child.onTrigger(self);
            }
        };

        return .{
            .ptr = ptr,
            .getFdFn = gen.getFd,
            .onTriggerFn = gen.onTrigger,
        };
    }

    pub fn getFd(self: Event) posix.fd_t {
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

    pub fn init(ptr: anytype) SigEvent {
        const T = @TypeOf(ptr);
        const ptr_info = @typeInfo(T);

        const gen = struct {
            pub fn getSig(pointer: *anyopaque) u8 {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.Pointer.child.getSig(self);
            }
            pub fn onSigTrigger(pointer: *anyopaque, data: i32) void {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.Pointer.child.onSigTrigger(self, data);
            }
        };

        return .{
            .ptr = ptr,
            .getSigFn = gen.getSig,
            .onSigTriggerFn = gen.onSigTrigger,
        };
    }

    pub fn getSig(self: SigEvent) u8 {
        return self.getSigFn(self.ptr);
    }

    pub fn onSigTrigger(self: SigEvent, data: i32) void {
        self.onSigTriggerFn(self.ptr, data);
    }
};

pub const SigEventComposition = struct {
    sig_fd: posix.fd_t,
    sig_events: []SigEvent,

    pub fn init(sig_events: []SigEvent) SigEventComposition {
        const SIGRTMIN: u8 = @intCast(signal.__libc_current_sigrtmin());
        const SIGRTMAX: u8 = @intCast(signal.__libc_current_sigrtmax());
        var handled_sig: signal.sigset_t = undefined;
        _ = signal.sigemptyset(&handled_sig);
        for (sig_events) |sig_evt| {
            _ = signal.sigaddset(&handled_sig, sig_evt.getSig());
        }

        // Create a signal file descriptor for epoll to watch
        const sig_fd = signal.signalfd(-1, &handled_sig, linux.SFD.NONBLOCK);

        // Block all realtime and handled signals
        for (SIGRTMIN..SIGRTMAX + 1) |i| _ = signal.sigaddset(&handled_sig, @intCast(i));
        _ = signal.sigprocmask(SIG.BLOCK, &handled_sig, null);

        return .{
            .sig_fd = sig_fd,
            .sig_events = sig_events,
        };
    }

    pub fn deinit(self: *SigEventComposition) void {
        posix.close(self.sig_fd);
    }

    pub fn getFd(self: *SigEventComposition) posix.fd_t {
        return self.sig_fd;
    }

    pub fn onTrigger(self: *SigEventComposition) void {
        var info: linux.signalfd_siginfo = undefined;
        _ = unix.read(self.sig_fd, &info, @sizeOf(linux.signalfd_siginfo));

        for (self.sig_events) |sig_evt| {
            if (sig_evt.getSig() == info.signo) sig_evt.onSigTrigger(info.int & 0xff);
        }
    }

    pub fn composeEvent(self: *SigEventComposition) Event {
        return Event.init(self);
    }
};

epoll_fd: posix.fd_t,

pub fn init() Multiplexer {
    return .{
        .epoll_fd = posix.epoll_create1(0) catch |err| {
            log.err("cannot create epoll fd, error: {s}", .{@errorName(err)});
            std.process.exit(1);
        },
    };
}

pub fn deinit(self: *Multiplexer) void {
    posix.close(self.epoll_fd);
}

pub fn registerEvent(self: *Multiplexer, e: *Event) void {
    var event = linux.epoll_event{ .events = linux.EPOLL.IN, .data = .{ .ptr = @intFromPtr(e) } };

    log.debug("register a fd: {}", .{e.getFd()});
    posix.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_ADD, e.getFd(), &event) catch |err| {
        log.err("cannot register event to epoll, error: {s}", .{@errorName(err)});
        std.process.exit(1);
    };
}

pub fn waitEvents(self: *Multiplexer) usize {
    var events: [10]linux.epoll_event = undefined;
    const evt_count = posix.epoll_wait(self.epoll_fd, &events, 500);
    for (events[0..evt_count]) |event| {
        const e: *Event = @ptrFromInt(event.data.ptr);
        e.onTrigger();
    }
    return evt_count;
}

test "register event" {
    const testing = std.testing;
    // testing.log_level = .debug;

    var multiplexer = Multiplexer.init();

    const Pipe = struct {
        const Self = @This();
        pipe: [2]posix.fd_t,
        pub fn getFd(self: *Self) posix.fd_t {
            return self.pipe[0];
        }
        pub fn onTrigger(self: *Self) void {
            _ = self;
            log.debug("test trigger", .{});
        }
        pub fn getEvent(self: *Self) Event {
            return Event.init(self);
        }
    };

    var pipe = Pipe{
        .pipe = try posix.pipe2(.{ .NONBLOCK = true }),
    };

    log.debug("create a pipe event: {*}, read: {}, write: {}", .{ &pipe, pipe.pipe[0], pipe.pipe[1] });

    var event = pipe.getEvent();
    multiplexer.registerEvent(&event);

    const pp = pipe.pipe;
    if (try posix.fork() == 0) {
        posix.close(pp[0]);
        defer posix.close(pp[1]);
        defer std.process.exit(0);
        std.time.sleep(500 * std.time.ns_per_ms);
        const len = try posix.write(pp[1], "hello");
        log.debug("subprocess write {} length data", .{len});
    }

    _ = multiplexer.waitEvents();

    var buf: [100]u8 = undefined;

    const len = try posix.read(pipe.getFd(), &buf);
    try testing.expectEqualSlices(u8, "hello", buf[0..len]);
}

test "register block event" {
    const testing = std.testing;
    const alloc = testing.allocator;
    // testing.log_level = .debug;

    const Block = @import("Block.zig");

    Block.staticInit(alloc);
    defer Block.staticDeinit(alloc);

    var block = try Block.init(alloc, "test_script", 1, 1);
    defer block.deinit();

    var multiplexer = Multiplexer.init();

    var event = block.getEvent();
    multiplexer.registerEvent(&event);

    const btn = Block.Button.up;
    try block.execBlock(btn);
    _ = multiplexer.waitEvents();

    try testing.expectEqualSlices(u8, &.{btn.getChar()}, block.getOutput());
    // log.debug("block output: {s}", .{block.getOutput()});
}
