const std = @import("std");
const log = std.log;

const posix = std.posix;
const SIG = posix.SIG;

const Block = @import("Block.zig");
const Button = Block.Button;
const BarStatus = @import("BarStatus.zig");
const Timer = @import("Timer.zig");
const Multiplexer = @import("Multiplexer.zig");
const SigEvent = @import("Multiplexer.zig").SigEvent;
const Event = @import("Multiplexer.zig").Event;
const SigEventComposition = @import("Multiplexer.zig").SigEventComposition;

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
            timer_tick = gcd(interval, timer_tick);
        }
        blocks[i] = try Block.init(alloc, path, interval, signum);
        log.debug("script path: {s}, \tinterval: {}, \tsignum: {}", .{ blocks[i].script, blocks[i].interval, blocks[i].signum });
    }
    defer for (&blocks) |*block| block.deinit();
    log.debug("max_interval: {}, timer_tick: {}", .{ max_interval, timer_tick });
    var sig_event_list = std.ArrayList(SigEvent).init(alloc);

    var multiplexer = Multiplexer.init();
    defer multiplexer.deinit();

    var status = try BarStatus.init(alloc, &blocks);
    defer status.deinit();
    try sig_event_list.append(status.getSigEvent());

    var timer = Timer.init(max_interval, timer_tick, &status, "execBlocks");
    try sig_event_list.append(timer.getSigEvent());

    for (&blocks) |*block| {
        // TODO 注册 block 后会导致脚本写管道被无限触发
        // var block_event = block.getEvent();
        // multiplexer.registerEvent(&block_event);
        if (block.signum > 0) try sig_event_list.append(block.getSigEvent());
    }

    var sa = posix.Sigaction{ .mask = posix.empty_sigset, .flags = 0, .handler = .{ .handler = termHandler } };

    // TODO 无法处理结束信号
    // Handle termination signals
    try posix.sigaction(SIG.INT, &sa, null);
    try posix.sigaction(SIG.TERM, &sa, null);

    // Avoid zombie subprocesses
    sa.flags = posix.SA.NOCLDWAIT;
    sa.handler.handler = SIG.DFL;
    try posix.sigaction(SIG.CHLD, &sa, null);

    var sec = SigEventComposition.init(sig_event_list.items);
    defer sec.deinit();
    var compose_event = sec.composeEvent();
    multiplexer.registerEvent(&compose_event);

    // Update all blocks initially
    timer.start();

    while (status_cuntinue) {
        const evt_count = multiplexer.waitEvents();
        if (evt_count != -1) try status.writeStatus();
    }

    log.debug("exit", .{});
}

test "app test" {
    // _ = Block;
    // _ = BarStatus;
    // _ = Timer;
    _ = Multiplexer;
}
