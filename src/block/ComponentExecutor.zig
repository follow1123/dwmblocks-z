const ComponentExecutor = @This();

const std = @import("std");
const log = std.log;

const posix = std.posix;
const SIG = posix.SIG;

const EnvMap = std.process.EnvMap;

ptr: *anyopaque,
getFdFn: *const fn (ptr: *anyopaque) posix.fd_t,
executeFn: *const fn (ptr: *anyopaque, env: *EnvMap) void,

/// 获取读端的 pipe 方便注册到多路复用器上
pub fn getFd(self: ComponentExecutor) posix.fd_t {
    return self.getFdFn(self.ptr);
}

/// 执行
/// 统一开启子进程后执行
pub fn execute(self: ComponentExecutor, env: *EnvMap) void {
    const executor_pid = posix.fork() catch |err| {
        log.err("cannot fork process to execute, error: {s}", .{@errorName(err)});
        return;
    };
    // 子进程开始执行
    if (executor_pid == 0) {
        self.executeFn(self.ptr, env);
    }
}

/// 读取执行结果
pub fn readResult(self: ComponentExecutor, buf: []u8) usize {
    return posix.read(self.getFd(), buf) catch |err| {
        log.err("execute script has no output, error: {s}", .{@errorName(err)});
        return 0;
    };
}

/// 避免僵尸子进程
pub fn avoidZombieSubProcess() !void {
    var sa = posix.Sigaction{ .mask = posix.empty_sigset, .flags = posix.SA.NOCLDWAIT, .handler = .{ .handler = SIG.DFL } };
    try posix.sigaction(SIG.CHLD, &sa, null);
}
