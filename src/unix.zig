const std = @import("std");

const posix = std.posix;
const linux = std.os.linux;
const c = std.c;

const unix = @cImport({
    @cInclude("unistd.h");
});

pub const signal = @import("unix/signal.zig");
pub const epoll = @import("unix/epoll.zig");

pub const SFD_NONBLOCK = linux.SFD.NONBLOCK;
pub const FD = posix.fd_t;
pub const Pid = posix.pid_t;

pub inline fn alarm(seconds: u32) u32 {
    return @intCast(c.alarm(@intCast(seconds)));
}

/// unix.read
pub inline fn uread(fd: FD, info: *anyopaque, nbytes: usize) isize {
    return unix.read(fd, info, nbytes);
}

pub inline fn read(fd: FD, buf: []u8) !usize {
    return posix.read(fd, buf);
}

pub inline fn write(fd: FD, bytes: []const u8) !usize {
    return posix.write(fd, bytes);
}

pub inline fn close(fd: FD) void {
    posix.close(fd);
}

pub inline fn pipe() ![2]FD {
    return posix.pipe();
}
pub inline fn ubpipe() ![2]FD {
    return posix.pipe2(.{ .NONBLOCK = true });
}

pub inline fn fork() !Pid {
    return posix.fork();
}

pub inline fn getpid() Pid {
    return linux.getpid();
}

pub inline fn waitPid(pid: Pid, flags: u32) posix.WaitPidResult {
    return posix.waitpid(pid, flags);
}

pub inline fn isProcessExecSucceed(result: posix.WaitPidResult) bool {
    return linux.W.IFEXITED(result.status) and linux.W.EXITSTATUS(result.status) == 0;
}

pub inline fn referToStdout(fd: FD) !void {
    try posix.dup2(fd, posix.STDOUT_FILENO);
}

pub inline fn execve(path: [*:0]const u8, envp: [*:null]const ?[*:0]const u8) posix.ExecveError {
    return posix.execveZ(path, &.{null}, envp);
}

pub inline fn kill(pid: Pid, sig: u8) !void {
    try posix.kill(pid, sig);
}
