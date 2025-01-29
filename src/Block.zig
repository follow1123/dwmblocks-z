const Block = @This();

const std = @import("std");
const log = std.log;

const posix = std.posix;
const SIG = posix.SIG;
const linux = std.os.linux;

const Allocator = std.mem.Allocator;
const config = @import("config.zig");
const Event = @import("Multiplexer.zig").Event;
const SigEvent = @import("Multiplexer.zig").SigEvent;

var static_data: struct { env_map: ScriptEnvMap, data_home: [:0]u8 } = undefined;

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

    pub fn getChar(self: Button) u8 {
        return @intFromEnum(self);
    }
};

const ScriptEnvMap = struct {
    map: std.process.EnvMap,
    ext_envs: std.ArrayList([]const u8),

    pub fn init(alloc: Allocator) ScriptEnvMap {
        const env_map = std.process.getEnvMap(alloc) catch @panic("cannot init env map");
        return .{
            .map = env_map,
            .ext_envs = std.ArrayList([]const u8).init(alloc),
        };
    }
    pub fn deinit(self: *ScriptEnvMap) void {
        self.map.deinit();
        self.ext_envs.deinit();
    }

    pub fn put(self: *ScriptEnvMap, key: []const u8, value: []const u8) void {
        self.ext_envs.append(key) catch |err| {
            log.err("cannot add environment variable to env map, error: {s}", .{@errorName(err)});
        };
        self.map.put(key, value) catch |err| {
            log.err("cannot add environment variable to env map, error: {s}", .{@errorName(err)});
        };
    }
    pub fn restore(self: *ScriptEnvMap) void {
        for (self.ext_envs.items) |key| self.map.remove(key);
    }
};

alloc: Allocator,
script: [:0]const u8,
interval: i32,
signum: u7,
output: []u8,
output_len: usize = 0,
pipe: [2]posix.fd_t,
lock: bool = false,

fn initDataHome(alloc: Allocator) [:0]u8 {
    if (std.process.getEnvVarOwned(alloc, "XDG_DATA_HOME")) |xdg_data_home| {
        defer alloc.free(xdg_data_home);
        return std.fs.path.joinZ(alloc, &.{ xdg_data_home, config.DATA_DIR_NAME }) catch |err| {
            log.err("init datahome error, cannot join xdg data path, error: {s}", .{@errorName(err)});
            std.process.exit(1);
        };
    } else |_| {
        const home = std.process.getEnvVarOwned(alloc, "HOME") catch {
            @panic("no 'HOME' environment to join script path");
        };
        defer alloc.free(home);
        return std.fs.path.joinZ(alloc, &.{ home, ".local/share", config.DATA_DIR_NAME }) catch |err| {
            log.err("init datahome error, cannot join home path, error: {s}", .{@errorName(err)});
            std.process.exit(1);
        };
    }
}

pub fn staticInit(alloc: Allocator) void {
    static_data = .{
        .env_map = ScriptEnvMap.init(alloc),
        .data_home = initDataHome(alloc),
    };
}

pub fn staticDeinit(alloc: Allocator) void {
    static_data.env_map.deinit();
    alloc.free(static_data.data_home);
}

pub fn init(alloc: Allocator, script: [:0]const u8, interval: i32, signum: u7) !Block {
    return .{
        .signum = signum,
        .alloc = alloc,
        .script = try std.fs.path.joinZ(alloc, &.{ static_data.data_home, script }),
        .interval = interval,
        .pipe = try posix.pipe2(.{ .NONBLOCK = true }),
        .output = try alloc.alloc(u8, config.MAX_OUTPUT),
    };
}

pub fn deinit(self: *Block) void {
    self.alloc.free(self.script);
    for (self.pipe) |p| posix.close(p);
    self.alloc.free(self.output);
}

pub fn execBlock(self: *Block, button: ?Button) !void {
    if (self.lock) return;
    self.lock = true;

    if (button) |btn| static_data.env_map.put("BLOCK_BUTTON", &.{btn.getChar()});
    defer static_data.env_map.restore();

    exec(self.alloc, self.pipe, self.script, &static_data.env_map.map);
}

fn exec(alloc: Allocator, pipe: [2]posix.fd_t, command: [:0]const u8, env_map: *std.process.EnvMap) void {
    const executor_pid = posix.fork() catch |err| {
        log.err("cannot fork process to execute command, error: {s}", .{@errorName(err)});
        return;
    };

    // 子进程开始执行脚本
    if (executor_pid == 0) {
        defer std.process.exit(0);
        posix.close(pipe[0]);
        defer posix.close(pipe[1]);

        var sa = posix.Sigaction{ .mask = posix.empty_sigset, .flags = 0, .handler = .{ .handler = SIG.DFL } };

        // 由于父进程配置 SIGCHID 不处理子进程
        // 这里需要恢复 SIGCHID 默认处理方式才能调用 waitpid
        posix.sigaction(SIG.CHLD, &sa, null) catch |err| {
            log.err("cannot reset SIGCHILD handler, error: {s}", .{@errorName(err)});
            return;
        };

        const cmd_pipe = posix.pipe2(.{
            .NONBLOCK = true,
        }) catch |err| {
            log.err("cannot create pipe for read script output, error: {s}", .{@errorName(err)});
            return;
        };

        const cmd_pid = posix.fork() catch |err| {
            log.err("cannot fork process to execute script, error: {s}", .{@errorName(err)});
            return;
        };

        const envp = std.process.createEnvironFromMap(alloc, env_map, .{}) catch |err| {
            log.err("create environment point error, error: {s}", .{@errorName(err)});
            return;
        };
        // for (envp) |env| log.debug("env: {s}", .{env orelse "null"});
        defer alloc.free(envp);
        // 再创建一个子进程执行脚本
        if (cmd_pid == 0) {
            posix.close(cmd_pipe[0]);
            posix.dup2(cmd_pipe[1], posix.STDOUT_FILENO) catch |err| {
                log.err("cannot refer stdout to parent pipe, error: {s}", .{@errorName(err)});
                return;
            };
            posix.close(cmd_pipe[1]);
            const err = posix.execveZ(command, &.{null}, envp.ptr);
            log.err("execve error: {s}", .{@errorName(err)});
            std.process.exit(1);
        }
        const result = posix.waitpid(cmd_pid, 0);
        if (linux.W.IFEXITED(result.status) and linux.W.EXITSTATUS(result.status) == 0) {
            var buf: [config.MAX_OUTPUT]u8 = undefined;
            var len = posix.read(cmd_pipe[0], &buf) catch 0;
            if (len > 0) {
                _ = try posix.write(pipe[1], buf[0..len]);
                // 丢弃多余的内容
                while (len == buf.len) len = posix.read(cmd_pipe[0], &buf) catch 0;
                return;
            }
        }
        log.debug("{s} has no stdout, write a nextline char", .{command});
        _ = try posix.write(pipe[1], "\n");
    }
}

pub fn getOutput(self: *Block) []u8 {
    return self.output[0..self.output_len];
}

pub fn updateBlock(self: *Block) !void {
    self.lock = false;

    self.output_len = try posix.read(self.pipe[0], self.output);
    if (self.output[self.output_len - 1] == '\n') self.output_len -= 1;
}

pub fn getFd(self: *Block) posix.fd_t {
    return self.pipe[0];
}

pub fn onTrigger(self: *Block) void {
    self.updateBlock() catch |err| {
        log.err("execute script has no output, error: {s}", .{@errorName(err)});
        return;
    };
}

pub fn getEvent(self: *Block) Event {
    return Event.init(self);
}

pub fn getSig(self: *Block) u8 {
    return self.signum;
}

pub fn onSigTrigger(self: *Block, data: i32) void {
    const button = if (Button.fromInt(@intCast(data))) |btn| btn else |err| e: {
        log.err("parse button error: {s}", .{@errorName(err)});
        break :e null;
    };
    self.execBlock(button) catch |err| {
        log.err("cannot execute block script, error: {s}", .{@errorName(err)});
        return;
    };
}

pub fn getSigEvent(self: *Block) SigEvent {
    return SigEvent.init(self);
}

test "exec" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // 获取脚本路径
    const script_path = try std.fs.cwd().realpathAlloc(alloc, "tests/scripts/test_script");
    defer alloc.free(script_path);
    const path = try std.mem.Allocator.dupeZ(alloc, u8, script_path);
    defer alloc.free(path);

    var env_map = try std.process.getEnvMap(alloc);
    defer env_map.deinit();
    const btn = "1";
    try env_map.put("BLOCK_BUTTON", btn);

    const pipe = try posix.pipe();
    exec(alloc, pipe, path, &env_map);

    var buf: [1024]u8 = undefined;
    const len = try posix.read(pipe[0], &buf);
    try testing.expectEqualSlices(u8, btn, buf[0..len]);
    // log.err("output: {s}", .{buf[0..len]});
}

test "init data home" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const data_home = initDataHome(alloc);
    defer alloc.free(data_home);
    try testing.expect(data_home.len > 0);
}

test "execute block" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // 获取脚本路径
    const script_path = try std.fs.cwd().realpathAlloc(alloc, "tests/scripts");
    defer alloc.free(script_path);

    Block.staticInit(alloc);
    alloc.free(Block.static_data.data_home);
    Block.static_data.data_home = try std.mem.Allocator.dupeZ(alloc, u8, script_path);
    defer Block.staticDeinit(alloc);

    var block = try Block.init(alloc, "test_script", 1, 1);
    defer block.deinit();

    const mid = Button.middle;
    try block.execBlock(mid);

    const epoll_fd = try posix.epoll_create1(0);
    var event = linux.epoll_event{
        .events = linux.EPOLL.IN,
        .data = .{ .fd = block.pipe[0] },
    };
    try posix.epoll_ctl(epoll_fd, linux.EPOLL.CTL_ADD, block.pipe[0], &event);
    var events: [1]linux.epoll_event = undefined;
    _ = posix.epoll_wait(epoll_fd, &events, -1);

    try block.updateBlock();
    try testing.expectEqualSlices(u8, &.{mid.getChar()}, block.getOutput());
}

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

test "script env map" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var script_env_map = ScriptEnvMap.init(alloc);
    defer script_env_map.deinit();

    script_env_map.put("AAA", "aaa");
    script_env_map.put("BBB", "bbb");

    try testing.expect(script_env_map.map.hash_map.contains("HOME"));
    try testing.expect(script_env_map.map.hash_map.contains("AAA"));
    try testing.expect(script_env_map.map.hash_map.contains("BBB"));
    script_env_map.restore();
    try testing.expect(script_env_map.map.hash_map.contains("HOME"));
    try testing.expect(!script_env_map.map.hash_map.contains("AAA"));
    try testing.expect(!script_env_map.map.hash_map.contains("BBB"));
}
