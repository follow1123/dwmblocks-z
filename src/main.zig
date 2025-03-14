const std = @import("std");
const log = std.log;

const block = @import("block.zig");
const Block = block.Block;
const ScriptExecutor = block.ScriptExecutor;

const BarStatus = @import("BarStatus.zig");
const Timer = @import("Timer.zig");
const Multiplexer = @import("Multiplexer.zig");
const SigEventCombinator = @import("Multiplexer.zig").SigEventCombinator;

const config = @import("config.zig");

pub fn main() void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var max_interval: u16 = 0;
    var timer_tick: u16 = 0;

    var blocks: [config.blocks.len]Block = undefined;

    log.debug("load block from config", .{});
    ScriptExecutor.staticInit();
    inline for (config.blocks, 0..) |b, i| {
        const name, const component, const interval: u16 = b;
        // Calculate the max interval and tick size for the timer
        if (interval > 0) {
            max_interval = @max(interval, max_interval);
            timer_tick = std.math.gcd(interval, timer_tick);
        }
        var component_executor = if (@TypeOf(component) == type) block.CodeExecutor(component).init(alloc) else ScriptExecutor.init(alloc, component);
        blocks[i] = Block.init(alloc, component_executor.executor(), interval, i + 1);
        log.debug("component name: {s}, \tinterval: {}, \tsignum: {}", .{ name, interval, blocks[i].signum });
    }
    defer for (&blocks) |*b| b.deinit();
    log.debug("max_interval: {}, timer_tick: {}", .{ max_interval, timer_tick });
    var sig_event_combinator = SigEventCombinator.init(alloc);
    defer sig_event_combinator.deinit();

    var multiplexer = Multiplexer.init();
    defer multiplexer.deinit();

    var status = BarStatus.init(alloc, &blocks);
    defer status.deinit();

    sig_event_combinator.add(status.sigEvent());

    var trigger_event = status.triggerEvent();
    var timer = Timer.init(max_interval, timer_tick, &trigger_event);
    sig_event_combinator.add(timer.sigEvent());

    inline for (&blocks) |*b| {
        var block_event = b.event();
        multiplexer.registerEvent(&block_event);
        if (b.signum > 0) sig_event_combinator.add(b.sigEvent());
    }

    var sig_event = sig_event_combinator.getEvent();
    multiplexer.registerEvent(&sig_event);
    log.debug("register all signal", .{});

    // Update all blocks initially
    timer.start();

    while (timer.isRunning()) {
        const evt_count = multiplexer.waitEvents();
        if (evt_count != -1) status.writeStatus();
    }

    log.debug("exit", .{});
}

// 自定义 log 格式
fn logFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    // Stuff we can do before the lock
    const level_txt = comptime level.asText();
    const prefix = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";

    // Lock so we are thread-safe
    std.debug.lockStdErr();
    defer std.debug.unlockStdErr();

    const stderr = std.io.getStdErr().writer();
    nosuspend stderr.print(level_txt ++ prefix ++ format ++ "\n", args) catch return;
}

// 覆盖自定义 log 方法
pub const std_options: std.Options = .{
    .logFn = logFn,
};

test "app test" {
    _ = BarStatus;
    _ = Timer;
    _ = Multiplexer;
    _ = block;
}
