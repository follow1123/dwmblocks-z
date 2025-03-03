const std = @import("std");
const log = std.log;

const posix = std.posix;
const SIG = posix.SIG;

const Block = @import("Block.zig");
const BarStatus = @import("BarStatus.zig");
const Timer = @import("Timer.zig");
const Multiplexer = @import("Multiplexer.zig");
const SigEventCombinator = @import("Multiplexer.zig").SigEventCombinator;

const config = @import("config.zig");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const block_count = config.blocks.len;
    var max_interval: u16 = 0;
    var timer_tick: u16 = 0;

    var blocks: [block_count]Block = undefined;

    log.debug("load block from config", .{});
    Block.staticInit(alloc);
    defer Block.staticDeinit(alloc);
    inline for (config.blocks, 0..) |b, i| {
        const path, const interval: u16, const signum: u8 = b;
        // Calculate the max interval and tick size for the timer
        if (interval > 0) {
            max_interval = @max(interval, max_interval);
            timer_tick = std.math.gcd(interval, timer_tick);
        }
        blocks[i] = try Block.init(alloc, path, interval, signum);
        log.debug("script path: {s}, \tinterval: {}, \tsignum: {}, pipe: ({}, {})", .{ blocks[i].script, blocks[i].interval, blocks[i].signum, blocks[i].pipe[0], blocks[i].pipe[1] });
    }
    defer for (&blocks) |*block| block.deinit();
    log.debug("max_interval: {}, timer_tick: {}", .{ max_interval, timer_tick });
    var sig_event_combinator = SigEventCombinator.init(alloc);
    defer sig_event_combinator.deinit();

    var multiplexer = Multiplexer.init();
    defer multiplexer.deinit();

    var status = try BarStatus.init(alloc, &blocks);
    defer status.deinit();

    sig_event_combinator.add(status.sigEvent());

    var trigger_event = status.triggerEvent();
    var timer = Timer.init(max_interval, timer_tick, &trigger_event);
    sig_event_combinator.add(timer.sigEvent());

    inline for (&blocks) |*block| {
        var block_event = block.event();
        multiplexer.registerEvent(&block_event);
        log.debug("register block: {s}", .{block.script});
        if (block.signum > 0) sig_event_combinator.add(block.sigEvent());
    }

    // 避免僵尸子进程
    var sa = posix.Sigaction{ .mask = posix.empty_sigset, .flags = posix.SA.NOCLDWAIT, .handler = .{ .handler = SIG.DFL } };
    try posix.sigaction(SIG.CHLD, &sa, null);

    var sig_event = sig_event_combinator.getEvent();
    multiplexer.registerEvent(&sig_event);
    log.debug("register all signal", .{});

    // Update all blocks initially
    timer.start();

    while (timer.isRunning()) {
        const evt_count = multiplexer.waitEvents();
        if (evt_count != -1) try status.writeStatus();
    }

    log.debug("exit", .{});
}

test "app test" {
    // _ = Block;
    // _ = BarStatus;
    _ = Timer;
    // _ = Multiplexer;
}
