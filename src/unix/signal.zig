const std = @import("std");

const posix = std.posix;
const linux = std.os.linux;
const signal = @cImport({
    @cInclude("signal.h");
    @cInclude("sys/signalfd.h");
});

const unix = @import("../unix.zig");

const FD = unix.FD;
const Pid = unix.Pid;

pub const INT = posix.SIG.INT;
pub const CHLD = posix.SIG.CHLD;
pub const TERM = posix.SIG.TERM;
pub const ALRM = posix.SIG.ALRM;
pub const USR1 = posix.SIG.USR1;
pub const BLOCK = posix.SIG.BLOCK;
pub const DFL = posix.SIG.DFL;
pub const IGN = posix.SIG.IGN;

pub const SA_NOCLDWAIT = posix.SA.NOCLDWAIT;

pub const EMPTY_SIGSET = posix.empty_sigset;

pub const Action = posix.Sigaction;
pub const SigSet = signal.sigset_t;
pub const FdInfo = linux.signalfd_siginfo;
pub const SigVal = signal.union_sigval;

pub inline fn RTMIN() u8 {
    return @intCast(signal.__libc_current_sigrtmin());
}

pub inline fn RTMAX() u8 {
    return @intCast(signal.__libc_current_sigrtmax());
}

pub inline fn raise(sig: u8) !void {
    try posix.raise(sig);
}

pub inline fn action(sig: u6, act: *const Action) !void {
    try posix.sigaction(sig, act, null);
}

pub inline fn queue(pid: Pid, sig: u8, val: SigVal) !void {
    switch (posix.errno(signal.sigqueue(pid, sig, val))) {
        .SUCCESS => return,
        else => |err| return posix.unexpectedErrno(err),
    }
}

pub inline fn emptySigSet(set: *SigSet) !void {
    switch (posix.errno(signal.sigemptyset(set))) {
        .SUCCESS => return,
        else => |err| return posix.unexpectedErrno(err),
    }
}

pub inline fn sigAddSet(set: *SigSet, sig: u8) !void {
    switch (posix.errno(signal.sigaddset(set, sig))) {
        .SUCCESS => return,
        else => |err| return posix.unexpectedErrno(err),
    }
}

pub inline fn setToFd(set: *SigSet) FD {
    return signal.signalfd(-1, set, linux.SFD.NONBLOCK);
}

pub inline fn blockSet(set: *SigSet) !void {
    switch (posix.errno(signal.sigprocmask(BLOCK, set, null))) {
        .SUCCESS => return,
        else => |err| return posix.unexpectedErrno(err),
    }
}
