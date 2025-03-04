const ScriptExecutor = @This();

const std = @import("std");
const log = std.log;

const posix = std.posix;
const SIG = posix.SIG;
const linux = std.os.linux;

const Allocator = std.mem.Allocator;
const config = @import("../config.zig");
const ComponentExecutor = @import("ComponentExecutor.zig");
const EnvMap = std.process.EnvMap;

pub var data_home: [:0]u8 = undefined;
pub var env_map: std.process.EnvMap = undefined;

alloc: Allocator,
script: [:0]const u8,
pipe: [2]posix.fd_t,

/// 初始化脚本保存路径
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
    ComponentExecutor.avoidZombieSubProcess() catch @panic("cannot handle child signal");
}

pub fn staticDeinit(alloc: Allocator) void {
    alloc.free(data_home);
    env_map.deinit();
}

pub fn init(alloc: Allocator, script_name: [:0]const u8) ScriptExecutor {
    return .{
        .alloc = alloc,
        .script = std.fs.path.joinZ(alloc, &.{ data_home, script_name }) catch @panic("cannot join script path"),
        .pipe = posix.pipe2(.{ .NONBLOCK = true }) catch @panic("cannot create pipe"),
    };
}

pub fn deinit(self: *ScriptExecutor) void {
    self.alloc.free(self.script);
    for (self.pipe) |p| posix.close(p);
}

/// 执行脚本实现
/// 这个方法会在子进程内执行
pub fn execute(self: ScriptExecutor, env: *EnvMap) void {
    var env_iter = env.iterator();
    while (env_iter.next()) |e| {
        env_map.put(e.key_ptr.*, e.value_ptr.*) catch |err| {
            log.err("cannot put envirnoment variable: {s}, write a nextline", .{@errorName(err)});
            _ = posix.write(self.pipe[1], "\n") catch @panic("cannot write content to fd");
        };
    }
    defer while (env_iter.next()) |e| env_map.remove(e.key_ptr.*);

    exec(self.alloc, self.pipe, self.script, &env_map) catch |err| {
        log.err("execute command error: {s}, write a nextline", .{@errorName(err)});
        _ = posix.write(self.pipe[1], "\n") catch @panic("cannot write content to fd");
    };
}

fn exec(alloc: Allocator, pipe: [2]posix.fd_t, script: [:0]const u8, env: *EnvMap) !void {
    defer std.process.exit(0);
    posix.close(pipe[0]);
    defer posix.close(pipe[1]);

    // 由于父进程配置 SIGCHID 不处理子进程
    // 这里需要恢复 SIGCHID 默认处理方式才能调用 waitpid
    var sa = posix.Sigaction{ .mask = posix.empty_sigset, .flags = 0, .handler = .{ .handler = SIG.DFL } };
    try posix.sigaction(SIG.CHLD, &sa, null);

    const cmd_pipe = try posix.pipe2(.{
        .NONBLOCK = true,
    });
    const cmd_pid = try posix.fork();

    const envp = try std.process.createEnvironFromMap(alloc, env, .{});
    defer alloc.free(envp);

    // 再创建一个子进程执行脚本
    // 这里再创建一个子进程的原因是脚本执行错误或没有输出任何结果的情况下不会触发 epoll 事件
    // 所以在套一层子进程用于处理错误或无返回值的情况，让脚本始终有输出
    if (cmd_pid == 0) execScript(cmd_pipe, script, envp.ptr);

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
    log.debug("{s} has no stdout, write a nextline", .{script});
    _ = try posix.write(pipe[1], "\n");
}

/// 具体执行脚本的方法
/// 这个方法会在子进程的子进程内实现
fn execScript(
    pipe: [2]posix.fd_t,
    script: [:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
) void {
    posix.close(pipe[0]);
    posix.dup2(pipe[1], posix.STDOUT_FILENO) catch @panic("cannot refer stdout to parent pipe");
    posix.close(pipe[1]);
    const err = posix.execveZ(script, &.{null}, envp);
    log.err("execve error: {s}", .{@errorName(err)});
    std.process.exit(1);
}

pub fn executor(ctx: *ScriptExecutor) ComponentExecutor {
    const gen = struct {
        pub fn getFd(ptr: *anyopaque) posix.fd_t {
            const self: *ScriptExecutor = @ptrCast(@alignCast(ptr));
            return self.pipe[0];
        }
        pub fn execute(ptr: *anyopaque, env: *EnvMap) void {
            const self: *ScriptExecutor = @ptrCast(@alignCast(ptr));
            self.execute(env);
        }
    };
    return .{
        .ptr = ctx,
        .getFdFn = gen.getFd,
        .executeFn = gen.execute,
    };
}

test "script executor" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // 获取脚本路径
    const script_path = try std.fs.cwd().realpathAlloc(alloc, "tests/scripts");
    defer alloc.free(script_path);

    ScriptExecutor.staticInit(alloc);
    defer ScriptExecutor.staticDeinit(alloc);
    alloc.free(data_home);
    data_home = try std.mem.Allocator.dupeZ(alloc, u8, script_path);

    var env = std.process.EnvMap.init(alloc);
    defer env.deinit();

    const data = "dfs";
    try env.put("BLOCK_BUTTON", data);

    var script_executor = ScriptExecutor.init(alloc, "test_script");
    for (script_executor.pipe) |p| posix.close(p);
    script_executor.pipe = try posix.pipe();
    defer script_executor.deinit();

    if (try posix.fork() == 0) script_executor.execute(&env);
    var buf: [1024]u8 = undefined;
    const len = try posix.read(script_executor.pipe[0], &buf);
    // log.err("script result: {s}", .{buf[0..len]});
    try testing.expectEqualSlices(u8, data, buf[0..len]);
}

test "init data home" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const data_path = initDataHome(alloc);
    defer alloc.free(data_path);
    try testing.expect(std.mem.endsWith(u8, data_path, config.DATA_DIR_NAME));
}
