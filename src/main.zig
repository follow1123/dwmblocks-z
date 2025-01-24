const std = @import("std");
const log = std.log;

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

const Block = @import("Block.zig");
const Button = Block.Button;
const BarStatus = @import("BarStatus.zig");
const Timer = @import("Timer.zig");

const config = @import("config.zig");

var status_cuntinue: bool = true;

fn gcd(a: u16, b: u16) u16 {
    var temp: u16 = undefined;
    var at: u16 = a;
    var bt: u16 = b;
    while (bt > 0) {
        temp = @mod(at, bt);
        at = bt;
        bt = temp;
    }
    return at;
}

pub fn termHandler(_: i32) callconv(.C) void {
    status_cuntinue = false;
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const SIGRTMIN: u8 = @intCast(signal.__libc_current_sigrtmin());
    const SIGRTMAX: u8 = @intCast(signal.__libc_current_sigrtmax());
    log.debug("SIGRTMIN: {}, SIGRTMAX: {}", .{ SIGRTMIN, SIGRTMAX });

    const block_count = config.blocks.len;
    var max_interval: u16 = 0;
    var timer_tick: u16 = 0;

    var sig_fd: posix.fd_t = undefined;
    var blocks: [block_count]Block = undefined;

    log.debug("load block from config", .{});
    Block.staticInit(alloc);
    defer Block.staticDeinit(alloc);
    inline for (config.blocks, 0..) |b, i| {
        const path, const interval: u16, const signum: u8 = b;
        // Calculate the max interval and tick size for the timer
        if (interval > 0) {
            max_interval = @max(interval, max_interval);
            timer_tick = gcd(interval, timer_tick);
        }
        blocks[i] = try Block.init(alloc, path, interval, signum);
        log.debug("script path: {s}, \tinterval: {}, \tsignum: {}", .{ blocks[i].script, blocks[i].interval, blocks[i].signum });
    }
    defer for (&blocks) |*block| block.deinit();
    log.debug("max_interval: {}, timer_tick: {}", .{ max_interval, timer_tick });

    var status = try BarStatus.init(alloc, &blocks);
    defer status.deinit();

    var timer = Timer.init(max_interval, timer_tick, &status, "execBlocks");
    const epoll_fd = try posix.epoll_create1(0);
    defer posix.close(epoll_fd);

    var event = linux.epoll_event{
        .events = linux.EPOLL.IN,
        .data = .{ .u32 = 0 },
    };

    var handled_sig: signal.sigset_t = undefined;
    _ = signal.sigemptyset(&handled_sig);

    _ = signal.sigaddset(&handled_sig, SIG.USR1);
    _ = signal.sigaddset(&handled_sig, timer.sig);

    for (&blocks, 0..) |*block, i| {
        log.debug("add block {} to sigset, next realtime signal is: {}", .{ i, SIGRTMIN + block.signum });
        event.data.u32 = @intCast(i);
        try posix.epoll_ctl(epoll_fd, linux.EPOLL.CTL_ADD, block.pipe[0], &event);
        if (block.signum > 0) _ = signal.sigaddset(&handled_sig, SIGRTMIN + block.signum);
    }

    // Create a signal file descriptor for epoll to watch
    sig_fd = signal.signalfd(-1, &handled_sig, linux.SFD.NONBLOCK);
    defer posix.close(sig_fd);

    // Block all realtime and handled signals
    for (SIGRTMIN..SIGRTMAX + 1) |i| _ = signal.sigaddset(&handled_sig, @intCast(i));
    _ = signal.sigprocmask(SIG.BLOCK, &handled_sig, null);

    var sa = posix.Sigaction{ .mask = posix.empty_sigset, .flags = 0, .handler = .{ .handler = termHandler } };

    // Handle termination signals
    try posix.sigaction(SIG.INT, &sa, null);
    try posix.sigaction(SIG.TERM, &sa, null);

    // Avoid zombie subprocesses
    sa.flags = posix.SA.NOCLDWAIT;
    sa.handler.handler = SIG.DFL;
    try posix.sigaction(SIG.CHLD, &sa, null);

    // Watch signal file descriptor as well
    event.data.u32 = block_count;
    try posix.epoll_ctl(epoll_fd, linux.EPOLL.CTL_ADD, sig_fd, &event);

    // Update all blocks initially
    timer.start();
    var events: [block_count + 1]linux.epoll_event = undefined;
    while (status_cuntinue) {
        // log.debug("waiting...", .{});
        const evt_count = posix.epoll_wait(epoll_fd, &events, 500);
        for (events[0..evt_count]) |evt| {
            switch (evt.data.u32) {
                block_count => {
                    // log.debug("handle signal...", .{});
                    var info: linux.signalfd_siginfo = undefined;
                    _ = unix.read(sig_fd, &info, @sizeOf(linux.signalfd_siginfo));
                    switch (info.signo) {
                        SIG.ALRM => {
                            timer.trigger();
                            break;
                        },
                        SIG.USR1 => {
                            // log.debug("handle signal usr1...", .{});
                            // Update all blocks on receiving SIGUSR1
                            try status.execBlocks(0);
                            break;
                        },
                        else => |sig| {
                            for (&blocks) |*block| {
                                if (block.signum == sig - SIGRTMIN) {
                                    const i = info.int & 0xff;
                                    log.debug("data from signal: {}", .{i});
                                    const button = if (Button.fromInt(@intCast(i))) |btn| btn else |err| e: {
                                        log.err("parse button error: {s}", .{@errorName(err)});
                                        break :e null;
                                    };
                                    try block.execBlock(button);
                                }
                            }
                        },
                    }
                },
                else => |idx| {
                    // log.debug("update block {}...", .{idx});
                    try blocks[idx].updateBlock();
                },
            }
        }

        if (evt_count != -1) try status.writeStatus();
    }

    log.debug("exit", .{});
}

test "app test" {
    // _ = Block;
    // _ = BarStatus;
    _ = Timer;
}
