const Block = @This();

const std = @import("std");
const log = std.log;

const posix = std.posix;
const SIG = posix.SIG;
const linux = std.os.linux;

const signal = @cImport({
    @cInclude("signal.h");
});

const Allocator = std.mem.Allocator;
const config = @import("config.zig");
const Event = @import("Multiplexer.zig").Event;
const SigEvent = @import("Multiplexer.zig").SigEvent;

var data_home: [:0]u8 = undefined;
var env_map: std.process.EnvMap = undefined;

pub const Button = enum(u8) {
    left = '1',
    middle = '2',
    right = '3',
    up = '4',
    down = '5',
    ctrlLeft = '6',
    ctrlRight = '7',

    pub fn fromInt(i: u8) ?Button {
        if (i < 1 or i > 7) return null;
        return @enumFromInt(i + 48);
    }

    pub fn getChar(self: Button) u8 {
        return @intFromEnum(self);
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
    const xdg_data_home = std.process.getEnvVarOwned(alloc, "XDG_DATA_HOME") catch {
        const home = std.process.getEnvVarOwned(alloc, "HOME") catch @panic("no 'HOME' environment to join script path");
        defer alloc.free(home);
        return std.fs.path.joinZ(alloc, &.{ home, ".local/share", config.DATA_DIR_NAME }) catch @panic("cannot join home path");
    };
    defer alloc.free(xdg_data_home);
    return std.fs.path.joinZ(alloc, &.{ xdg_data_home, config.DATA_DIR_NAME }) catch @panic("cannot join xdg data path");
}

pub fn staticInit(alloc: Allocator) void {
    data_home = initDataHome(alloc);
    env_map = std.process.getEnvMap(alloc) catch @panic("cannot get environment variable");
    ScriptExecutor.avoidZombieSubProcess() catch @panic("cannot handle child signal");
}

pub fn staticDeinit(alloc: Allocator) void {
    alloc.free(data_home);
    env_map.deinit();
}

pub fn init(alloc: Allocator, script: [:0]const u8, interval: i32, signum: u7) Block {
    const SIGRTMIN: u8 = @intCast(signal.__libc_current_sigrtmin());
    return .{
        .signum = @intCast(SIGRTMIN + signum),
        .alloc = alloc,
        .script = std.fs.path.joinZ(alloc, &.{ data_home, script }) catch @panic("cannot join script path"),
        .interval = interval,
        .pipe = posix.pipe2(.{ .NONBLOCK = true }) catch @panic("cannot create pipe"),
        .output = alloc.alloc(u8, config.MAX_OUTPUT) catch @panic("cannot create buf for reasult"),
    };
}

pub fn deinit(self: *Block) void {
    self.alloc.free(self.script);

    for (self.pipe) |p| posix.close(p);
    self.alloc.free(self.output);
}

pub fn execBlock(self: *Block, button: ?Button) void {
    if (self.lock) return;
    self.lock = true;
    const blk_btn_key = "BLOCK_BUTTON";
    if (button) |btn| env_map.put(blk_btn_key, &.{btn.getChar()}) catch @panic("cannot put env to env map");

    defer {
        env_map.remove(blk_btn_key);
    }
    ScriptExecutor.exec(self.alloc, self.pipe, self.script, &env_map);
}

pub fn getOutput(self: *Block) []u8 {
    return self.output[0..self.output_len];
}

pub fn updateBlock(self: *Block) void {
    self.lock = false;

    self.output_len = ScriptExecutor.readResult(self.pipe[0], self.output);
    if (self.output_len > 0 and self.output[self.output_len - 1] == '\n') self.output_len -= 1;
}

pub fn event(ctx: *Block) Event {
    const gen = struct {
        pub fn getFd(ptr: *anyopaque) posix.fd_t {
            const self: *Block = @ptrCast(@alignCast(ptr));
            return self.pipe[0];
        }
        pub fn onTrigger(ptr: *anyopaque) void {
            const self: *Block = @ptrCast(@alignCast(ptr));
            self.updateBlock();
        }
    };

    return .{
        .ptr = ctx,
        .getFdFn = gen.getFd,
        .onTriggerFn = gen.onTrigger,
    };
}

pub fn sigEvent(ctx: *Block) SigEvent {
    const gen = struct {
        pub fn getSig(ptr: *anyopaque) u8 {
            const self: *Block = @ptrCast(@alignCast(ptr));
            return self.signum;
        }
        pub fn onSigTrigger(ptr: *anyopaque, data: i32) void {
            const self: *Block = @ptrCast(@alignCast(ptr));
            self.execBlock(Button.fromInt(@intCast(data)));
        }
    };

    return .{
        .ptr = ctx,
        .getSigFn = gen.getSig,
        .onSigTriggerFn = gen.onSigTrigger,
    };
}

const ScriptExecutor = struct {
    pub fn exec(alloc: Allocator, pipe: [2]posix.fd_t, command: [:0]const u8, env: *std.process.EnvMap) void {
        const executor_pid = posix.fork() catch |err| {
            log.err("cannot fork process to execute command, error: {s}", .{@errorName(err)});
            return;
        };

        // 子进程开始执行脚本
        if (executor_pid == 0) {
            defer std.process.exit(0);
            posix.close(pipe[0]);
            defer posix.close(pipe[1]);

            // 由于父进程配置 SIGCHID 不处理子进程
            // 这里需要恢复 SIGCHID 默认处理方式才能调用 waitpid
            var sa = posix.Sigaction{ .mask = posix.empty_sigset, .flags = 0, .handler = .{ .handler = SIG.DFL } };
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

            const envp = std.process.createEnvironFromMap(alloc, env, .{}) catch |err| {
                log.err("create environment point error, error: {s}", .{@errorName(err)});
                return;
            };
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

    pub fn readResult(reader_pipe: posix.fd_t, buf: []u8) usize {
        return posix.read(reader_pipe, buf) catch |err| {
            log.err("execute script has no output, error: {s}", .{@errorName(err)});
            return 0;
        };
    }

    /// 避免僵尸子进程
    pub fn avoidZombieSubProcess() !void {
        var sa = posix.Sigaction{ .mask = posix.empty_sigset, .flags = posix.SA.NOCLDWAIT, .handler = .{ .handler = SIG.DFL } };
        try posix.sigaction(SIG.CHLD, &sa, null);
    }
};

test "scritp executor" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const pipe = try posix.pipe();

    // 获取脚本路径
    const script_path = try std.fs.cwd().realpathAlloc(alloc, "tests/scripts/test_script");
    defer alloc.free(script_path);
    const path = try std.mem.Allocator.dupeZ(alloc, u8, script_path);
    defer alloc.free(path);

    var env = std.process.EnvMap.init(alloc);
    defer env.deinit();

    const data = "dfs";
    try env.put("BLOCK_BUTTON", data);

    ScriptExecutor.exec(alloc, pipe, path, &env);

    var buf: [1024]u8 = undefined;
    const len = ScriptExecutor.readResult(pipe[0], &buf);
    try testing.expectEqualSlices(u8, data, buf[0..len]);
}

test "init data home" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const data_path = initDataHome(alloc);
    defer alloc.free(data_path);
    try testing.expect(std.mem.endsWith(u8, data_path, config.DATA_DIR_NAME));
}

test "execute block" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // 获取脚本路径
    const script_path = try std.fs.cwd().realpathAlloc(alloc, "tests/scripts");
    defer alloc.free(script_path);

    Block.staticInit(alloc);
    defer Block.staticDeinit(alloc);
    alloc.free(data_home);
    data_home = try std.mem.Allocator.dupeZ(alloc, u8, script_path);

    var block = Block.init(alloc, "test_script", 1, 1);
    defer block.deinit();

    const epoll_fd = try posix.epoll_create1(0);
    var evt = linux.epoll_event{
        .events = linux.EPOLL.IN,
        .data = .{ .fd = block.pipe[0] },
    };
    try posix.epoll_ctl(epoll_fd, linux.EPOLL.CTL_ADD, block.pipe[0], &evt);

    const mid = Button.middle;
    block.execBlock(mid);

    var events: [1]linux.epoll_event = undefined;
    _ = posix.epoll_wait(epoll_fd, &events, -1);

    block.updateBlock();
    try testing.expectEqualSlices(u8, &.{mid.getChar()}, block.getOutput());
}

test "create button" {
    const testing = std.testing;
    try testing.expectEqual(Button.left, Button.fromInt(1));
    try testing.expectEqual(Button.right, Button.fromInt(3));
    try testing.expectEqual(Button.ctrlLeft, Button.fromInt(6));
    try testing.expectEqual(null, Button.fromInt(10));
    try testing.expectEqual(null, Button.fromInt(0));
}
