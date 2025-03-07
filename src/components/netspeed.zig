const std = @import("std");
const log = std.log;

const Allocator = std.mem.Allocator;
const Button = @import("../block.zig").Button;
const Message = @import("../block.zig").Message;

const CACHE_DIR_NAME = "sde";
const CACHE_FILE_NAME = "dwmblocks-neetspeed";

/// 组件初始化时调用，只调用一次
pub fn init(alloc: Allocator) !void {
    try createCacheFile(alloc);
}

/// 程序退出时调用，只调用一次
pub fn deinit(alloc: Allocator) !void {
    try removeCacheFile(alloc);
}

/// 使用 run 方法内的 allocator 分配的内存可以不用释放
/// 调用结束后由 CodeExecutor 统一释放
pub fn run(alloc: Allocator, message: Message) ![]u8 {
    _ = message;
    const interface = try findInterfaceName(alloc);
    const rx_file_path = try std.fmt.allocPrint(alloc, "/sys/class/net/{s}/statistics/rx_bytes", .{interface});
    const tx_file_path = try std.fmt.allocPrint(alloc, "/sys/class/net/{s}/statistics/tx_bytes", .{interface});
    const cur_rx_bytes = try getSpeed(rx_file_path);
    const cur_tx_bytes = try getSpeed(tx_file_path);
    const last_rx_bytes, const last_tx_bytes = getLastSpeedBytes(alloc) catch .{ cur_rx_bytes, cur_tx_bytes };
    const speed = (cur_rx_bytes + cur_tx_bytes) - (last_rx_bytes + last_tx_bytes);
    try saveSpeedBytes(alloc, cur_rx_bytes, cur_tx_bytes);

    if (speed < 1024) {
        return std.fmt.allocPrint(alloc, "{d: >3}B/s", .{speed});
    } else if (speed < (1024 * 1024)) {
        return std.fmt.allocPrint(alloc, "{d: >3}K/s", .{speed / 1024});
    } else if (speed < (1024 * 1024 * 1024)) {
        return std.fmt.allocPrint(alloc, "{d: >3}M/s", .{speed / (1024 * 1024)});
    } else return std.fmt.allocPrint(alloc, "{d: >3}G/s", .{speed / (1024 * 1024 * 1024)});
}

fn findInterfaceName(alloc: Allocator) ![:0]const u8 {
    var interface_dir = try std.fs.openDirAbsolute("/sys/class/net", .{ .iterate = true });
    defer interface_dir.close();
    var walker = try interface_dir.walk(alloc);
    defer walker.deinit();
    return while (try walker.next()) |entry| {
        const sub_path = try std.fmt.allocPrint(alloc, "{s}/operstate", .{entry.basename});
        var interface_state_file = try interface_dir.openFile(sub_path, .{});
        defer interface_state_file.close();
        var buf: [10]u8 = undefined;
        const len = try interface_state_file.readAll(&buf);
        if (std.mem.startsWith(u8, buf[0..len], "up")) {
            const name = try alloc.allocSentinel(u8, entry.basename.len, 0);
            @memcpy(name, entry.basename);
            break name;
        }
    } else @panic("no interface");
}

fn saveSpeedBytes(alloc: Allocator, rx_bytes: u64, tx_bytes: u64) !void {
    const cache_home_path = try std.process.getEnvVarOwned(alloc, "XDG_CACHE_HOME");
    const cache_file_path = try std.fmt.allocPrint(alloc, "{s}/{s}/{s}", .{ cache_home_path, CACHE_DIR_NAME, CACHE_FILE_NAME });
    var cache_file = try std.fs.openFileAbsolute(cache_file_path, .{ .mode = .write_only });
    defer cache_file.close();
    const data = try std.fmt.allocPrint(alloc, "{}\n{}", .{ rx_bytes, tx_bytes });
    _ = try cache_file.write(data);
}

fn getLastSpeedBytes(alloc: Allocator) !struct { u64, u64 } {
    const cache_home_path = try std.process.getEnvVarOwned(alloc, "XDG_CACHE_HOME");
    const cache_file_path = try std.fmt.allocPrint(alloc, "{s}/{s}/{s}", .{ cache_home_path, CACHE_DIR_NAME, CACHE_FILE_NAME });
    var cache_file = try std.fs.openFileAbsolute(cache_file_path, .{});
    defer cache_file.close();
    var buf: [100]u8 = undefined;
    const len = try cache_file.readAll(&buf);
    var sp_iter = std.mem.splitScalar(u8, buf[0..len], '\n');
    return .{
        try std.fmt.parseInt(u64, sp_iter.next() orelse @panic("read rx bytes error"), 10),
        try std.fmt.parseInt(u64, sp_iter.next() orelse @panic("read tx bytes error"), 10),
    };
}

fn createCacheFile(alloc: Allocator) !void {
    const cache_home_path = try std.process.getEnvVarOwned(alloc, "XDG_CACHE_HOME");
    defer alloc.free(cache_home_path);
    var cache_home = try std.fs.openDirAbsolute(cache_home_path, .{});
    defer cache_home.close();
    cache_home.access(CACHE_DIR_NAME, .{}) catch |e| if (e == error.FileNotFound) {
        try cache_home.makeDir(CACHE_DIR_NAME);
    };
    var sde = try cache_home.openDir(CACHE_DIR_NAME, .{});
    defer sde.close();
    sde.access(CACHE_FILE_NAME, .{}) catch |e| if (e == error.FileNotFound) {
        var file = try sde.createFile(CACHE_FILE_NAME, .{});
        file.close();
    };
}

fn removeCacheFile(alloc: Allocator) !void {
    const cache_home_path = try std.process.getEnvVarOwned(alloc, "XDG_CACHE_HOME");
    defer alloc.free(cache_home_path);
    const cache_file_path = try std.fmt.allocPrint(alloc, "{s}/{s}/{s}", .{ cache_home_path, CACHE_DIR_NAME, CACHE_FILE_NAME });
    defer alloc.free(cache_file_path);
    try std.fs.deleteFileAbsolute(cache_file_path);
}

fn getSpeed(path: []u8) !u64 {
    var file = try std.fs.openFileAbsolute(path, .{ .mode = .read_only });
    defer file.close();

    var buf: [30]u8 = undefined;
    const len = try file.read(&buf);
    return std.fmt.parseInt(u64, buf[0 .. len - 1], 10);
}
