const ScriptExecutor = @This();

const std = @import("std");
const log = std.log.scoped(.script_executor);

const unix = @import("../unix.zig");
const signal = unix.signal;

const Allocator = std.mem.Allocator;
const config = @import("../config.zig");
const ComponentExecutor = @import("ComponentExecutor.zig");

const Message = @import("Message.zig");
const Button = Message.Button;

alloc: Allocator,
script: [:0]const u8,
pipe: [2]unix.FD,

/// 初始化脚本保存路径
fn initScriptFullPath(alloc: Allocator, script_name: [:0]const u8) [:0]u8 {
    const xdg_data_home = std.process.getEnvVarOwned(alloc, "XDG_DATA_HOME") catch {
        const home = std.process.getEnvVarOwned(alloc, "HOME") catch @panic("no 'HOME' environment to join script path");
        defer alloc.free(home);
        return std.fs.path.joinZ(alloc, &.{ home, ".local/share", config.DATA_DIR_NAME, script_name }) catch @panic("cannot join home path");
    };
    defer alloc.free(xdg_data_home);
    return std.fs.path.joinZ(alloc, &.{ xdg_data_home, config.DATA_DIR_NAME, script_name }) catch @panic("cannot join xdg data path");
}

pub fn staticInit() void {
    // 避免僵尸子进程
    var sa = signal.Action{ .mask = signal.EMPTY_SIGSET, .flags = signal.SA_NOCLDWAIT, .handler = .{ .handler = signal.DFL } };
    signal.action(signal.CHLD, &sa) catch @panic("cannot config sig chld to avoid zombie subporcess");
}

pub fn init(alloc: Allocator, script_name: [:0]const u8) ScriptExecutor {
    return .{
        .alloc = alloc,
        .script = initScriptFullPath(alloc, script_name),
        .pipe = unix.ubpipe() catch @panic("cannot create pipe"),
    };
}

pub fn deinit(self: *ScriptExecutor) void {
    self.alloc.free(self.script);
    for (self.pipe) |p| unix.close(p);
}

/// 执行脚本实现
pub fn execute(self: ScriptExecutor, message: Message) void {
    const executor_pid = unix.fork() catch |err| {
        log.err("cannot fork process to execute, error: {s}", .{@errorName(err)});
        return;
    };
    var env = std.process.getEnvMap(self.alloc) catch @panic("cannot get environment variable");
    defer env.deinit();

    setEnvMap(self.alloc, &env, message) catch @panic("cannot put value to environment map");

    // 开启子进程执行
    if (executor_pid == 0) {
        exec(self.alloc, self.pipe, self.script, &env) catch |err| {
            log.err("execute command error: {s}, write a nextline", .{@errorName(err)});
            _ = unix.write(self.pipe[1], "\n") catch @panic("cannot write content to fd");
        };
    }
}

fn setEnvMap(alloc: Allocator, env: *std.process.EnvMap, message: Message) !void {
    const pid_str = try std.fmt.allocPrint(alloc, "{}", .{message.pid});
    defer alloc.free(pid_str);
    try env.put("CALLER_PID", pid_str);
    if (message.show_all) try env.put("BLOCK_SHOW_ALL", "1");

    inline for (config.blocks, signal.RTMIN() + 1..) |b, i| {
        const update_block_command = try std.fmt.allocPrint(alloc, "kill -s {} {}", .{ i, message.pid });
        defer alloc.free(update_block_command);
        try env.put("update_block_" ++ b[0], update_block_command);
    }
    if (message.button) |btn| try env.put("BLOCK_BUTTON", &.{btn.getChar()});
}

fn exec(alloc: Allocator, pipe: [2]unix.FD, script: [:0]const u8, env: *std.process.EnvMap) !void {
    defer std.process.exit(0);
    unix.close(pipe[0]);
    defer unix.close(pipe[1]);

    // 由于父进程配置 SIGCHID 不处理子进程
    // 这里需要恢复 SIGCHID 默认处理方式才能调用 waitpid
    var sa = signal.Action{ .mask = signal.EMPTY_SIGSET, .flags = 0, .handler = .{ .handler = signal.DFL } };
    try signal.action(signal.CHLD, &sa);

    const cmd_pipe = try unix.ubpipe();
    const cmd_pid = try unix.fork();

    const envp = try std.process.createEnvironFromMap(alloc, env, .{});
    defer alloc.free(envp);

    // 再创建一个子进程执行脚本
    // 这里再创建一个子进程的原因是脚本执行错误或没有输出任何结果的情况下不会触发 epoll 事件
    // 所以在套一层子进程用于处理错误或无返回值的情况，让脚本始终有输出
    if (cmd_pid == 0) execScript(cmd_pipe, script, envp.ptr);

    const result = unix.waitPid(cmd_pid, 0);
    if (unix.isProcessExecSucceed(result)) {
        var buf: [config.MAX_OUTPUT]u8 = undefined;
        var len = unix.read(cmd_pipe[0], &buf) catch 0;
        if (len > 0) {
            _ = try unix.write(pipe[1], buf[0..len]);
            // 丢弃多余的内容
            while (len == buf.len) len = unix.read(cmd_pipe[0], &buf) catch 0;
            return;
        }
    }
    log.debug("{s} has no stdout, write a nextline", .{script});
    _ = try unix.write(pipe[1], "\n");
}

/// 具体执行脚本的方法
/// 这个方法会在子进程的子进程内实现
fn execScript(
    pipe: [2]unix.FD,
    script: [:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
) void {
    unix.close(pipe[0]);
    unix.referToStdout(pipe[1]) catch @panic("cannot refer stdout to parent pipe");
    unix.close(pipe[1]);
    const err = unix.execve(script, envp);
    log.err("execve error: {s}", .{@errorName(err)});
    std.process.exit(1);
}

/// 读取执行结果
pub fn readResult(self: ScriptExecutor, buf: []u8) usize {
    return unix.read(self.pipe[0], buf) catch |err| {
        log.err("execute script has no output, error: {s}", .{@errorName(err)});
        return 0;
    };
}

pub fn executor(ctx: *ScriptExecutor) ComponentExecutor {
    const gen = struct {
        pub fn getFd(ptr: *anyopaque) unix.FD {
            const self: *ScriptExecutor = @ptrCast(@alignCast(ptr));
            return self.pipe[0];
        }
        pub fn execute(ptr: *anyopaque, message: Message) void {
            const self: *ScriptExecutor = @ptrCast(@alignCast(ptr));
            self.execute(message);
        }
        pub fn readResult(ptr: *anyopaque, buf: []u8) usize {
            const self: *ScriptExecutor = @ptrCast(@alignCast(ptr));
            return self.readResult(buf);
        }

        pub fn deinit(ptr: *anyopaque) void {
            const self: *ScriptExecutor = @ptrCast(@alignCast(ptr));
            self.deinit();
        }
    };
    return .{
        .ptr = ctx,
        .getFdFn = gen.getFd,
        .executeFn = gen.execute,
        .readResultFn = gen.readResult,
        .deinitFn = gen.deinit,
    };
}

test "script executor" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // 获取脚本路径
    const script_path = try std.fs.cwd().realpathAlloc(alloc, "tests/scripts/test_script");
    defer alloc.free(script_path);
    const script = try std.fmt.allocPrintZ(alloc, "{s}", .{script_path});

    ScriptExecutor.staticInit();

    var env = std.process.EnvMap.init(alloc);
    defer env.deinit();

    var script_executor = ScriptExecutor.init(alloc, "test_script");
    alloc.free(script_executor.script);
    script_executor.script = script;

    for (script_executor.pipe) |p| unix.close(p);
    script_executor.pipe = try unix.pipe();
    defer script_executor.deinit();

    const pid = unix.getpid();
    const btn = Button.left;
    var message = Message.init();
    message.button = btn;
    script_executor.execute(message);
    var buf: [1024]u8 = undefined;
    var len = try unix.read(script_executor.pipe[0], &buf);
    var expect_data = try std.fmt.allocPrint(alloc, "{c} {}", .{ btn.getChar(), pid });
    // log.err("expect: {s}, result: {s}", .{ expect_data, buf[0..len] });
    try testing.expectEqualSlices(u8, expect_data, buf[0..len]);
    alloc.free(expect_data);

    message.button = null;
    script_executor.execute(message);

    len = try unix.read(script_executor.pipe[0], &buf);
    expect_data = try std.fmt.allocPrint(alloc, " {}", .{pid});
    defer alloc.free(expect_data);
    // log.err("expect: {s}, result: {s}", .{ expect_data, buf[0..len] });
    try testing.expectEqualSlices(u8, expect_data, buf[0..len]);
}

test "init script full path" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const script_name = "test.sh";
    const data_path = initScriptFullPath(alloc, script_name);
    defer alloc.free(data_path);
    const end_path = try std.fs.path.join(alloc, &.{ config.DATA_DIR_NAME, script_name });
    defer alloc.free(end_path);
    try testing.expect(std.mem.endsWith(u8, data_path, end_path));
}
