const Block = @This();

const std = @import("std");

const Allocator = std.mem.Allocator;
const config = @import("config.zig");

const posix = std.posix;
const SIG = posix.SIG;
const linux = std.os.linux;

const log = std.log;

const MAX_OUTPUT = 60;

pub const ButtonError = error{InvalidNumberASCII};

pub const Button = enum(u8) {
    left = '1',
    middle = '2',
    right = '3',
    up = '4',
    down = '5',
    ctrlLeft = '6',
    ctrlRight = '7',

    pub fn fromInt(i: u8) ButtonError!Button {
        if (i < 1 or i > 7) return ButtonError.InvalidNumberASCII;
        return @enumFromInt(i + 48);
    }

    pub fn toString(self: Button) []const u8 {
        return &.{@intFromEnum(self)};
    }
};

alloc: Allocator,
script: [:0]const u8,
interval: i32,
signum: u7,
output: std.ArrayList(u8),
pipe: [2]posix.fd_t,
lock: bool = false,
sub_pid: posix.pid_t = -1,

fn setupScriptFullPath(alloc: Allocator, script_name: [:0]const u8) ![:0]u8 {
    if (std.process.getEnvVarOwned(alloc, "XDG_DATA_HOME")) |xdg_data_home| {
        defer alloc.free(xdg_data_home);
        return try std.fs.path.joinZ(alloc, &.{ xdg_data_home, config.DATA_DIR_NAME, script_name });
    } else |_| {
        const home = std.process.getEnvVarOwned(alloc, "HOME") catch {
            log.err("no `HOME` environment to join script path", .{});
            std.process.exit(1);
        };
        defer alloc.free(home);
        return try std.fs.path.joinZ(alloc, &.{ home, ".local/share", config.DATA_DIR_NAME, script_name });
    }
}

pub fn init(alloc: Allocator, script: [:0]const u8, interval: i32, signum: u7) !Block {
    return .{
        .signum = signum,
        .alloc = alloc,
        .script = try setupScriptFullPath(alloc, script),
        .interval = interval,
        .pipe = try posix.pipe(),
        .output = std.ArrayList(u8).init(alloc),
    };
}

/// 判断指定进程 id 的子进程是否存活
fn isAlive(pid: posix.pid_t) bool {
    // 由于 zig 封装的 waitpid 方法如果没有子进程直接就 panic 了
    // 需要使用 kill 先判断指定进程是否存活
    posix.kill(pid, 0) catch return false;
    return posix.waitpid(pid, posix.W.NOHANG).pid == 0;
}

pub fn execBlock(self: *Block, button: ?Button) !void {
    if (self.lock) {
        // 有些脚本输出一个空字符串导致无法触发 epoll 事件
        // 导致无法解锁，使用这种方式跳过锁定部分
        if (self.output.items.len > 0) return;
        log.debug("check sub process: {}", .{self.sub_pid});
        if (isAlive(self.sub_pid)) return;
        log.debug("execute script: {s} with no reslut", .{self.script});
    }
    self.lock = true;

    const pp = self.pipe;
    const sub_pid = try posix.fork();
    if (sub_pid == 0) {
        posix.close(pp[0]);
        try posix.dup2(pp[1], posix.STDOUT_FILENO);
        posix.close(pp[1]);

        var env_map = try std.process.getEnvMap(self.alloc);
        defer env_map.deinit();

        if (button) |btn| try env_map.put("BLOCK_BUTTON", btn.toString());

        const envp = try std.process.createEnvironFromMap(self.alloc, &env_map, .{});
        defer self.alloc.free(envp);

        const err = posix.execveZ(self.script, &.{null}, envp.ptr);
        log.err("execve error: {s}", .{@errorName(err)});
        std.process.exit(0);
    } else self.sub_pid = sub_pid;
}

pub fn getResult(self: *Block) []u8 {
    return self.output.items;
}

pub fn updateBlock(self: *Block) !void {
    self.lock = false;

    const read_pipe = self.pipe[0];

    self.output.clearRetainingCapacity();
    var buf: [MAX_OUTPUT]u8 = undefined;
    var len = try posix.read(read_pipe, &buf);
    if (len > 0) {
        if (buf[len - 1] == '\n') len -= 1;
        try self.output.appendSlice(buf[0..len]);
    }
}

pub fn deinit(self: *Block) void {
    self.alloc.free(self.script);
    posix.close(self.pipe[0]);
    posix.close(self.pipe[1]);
    self.output.deinit();
}

test "setup script path" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const full_path1 = try setupScriptFullPath(alloc, "aaa");
    const full_path2 = try setupScriptFullPath(alloc, "bbb");
    defer {
        alloc.free(full_path1);
        alloc.free(full_path2);
    }
    try testing.expectEqualSlices(u8, full_path1[0 .. full_path1.len - 3], full_path2[0 .. full_path2.len - 3]);
}

// test "execute block" {
//     const testing = std.testing;
//     const alloc = testing.allocator;
//
//     // 获取脚本路径
//     const script_path = try std.fs.cwd().realpathAlloc(alloc, "tests/scripts/test_script");
//     defer alloc.free(script_path);
//     const path = try std.mem.Allocator.dupeZ(alloc, u8, script_path);
//     defer alloc.free(path);
//
//     var block = try Block.init(alloc, path, 1, 1);
//     defer block.deinit();
//
//     const mid = Button.middle;
//     try block.execBlock(mid);
//     try block.updateBlock();
//     const result = block.getResult();
//     try testing.expectEqualSlices(u8, mid.toString(), result);
// }

test "create button" {
    const testing = std.testing;
    try testing.expectEqual(Button.left, try Button.fromInt(1));
    try testing.expectEqual(Button.right, try Button.fromInt(3));
    try testing.expectEqual(Button.ctrlLeft, try Button.fromInt(6));
    try testing.expectError(ButtonError.InvalidNumberASCII, Button.fromInt(10));
    try testing.expectError(ButtonError.InvalidNumberASCII, Button.fromInt(0));
    const btn = if (Button.fromInt(100)) |btn| btn else |_| e: {
        break :e null;
    };

    try testing.expectEqual(null, btn);
}
