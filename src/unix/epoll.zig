const std = @import("std");
const unix = @import("../unix.zig");

const FD = unix.FD;

const posix = std.posix;
const linux = std.os.linux;

pub const IN = linux.EPOLL.IN;
pub const CTL_ADD = linux.EPOLL.CTL_ADD;

pub const Event = linux.epoll_event;

pub inline fn create() !FD {
    return try posix.epoll_create1(0);
}

pub inline fn ctl(epfd: FD, op: u32, fd: FD, event: *Event) !void {
    try posix.epoll_ctl(epfd, op, fd, event);
}

pub inline fn wait(fd: FD, events: []Event, timeout: i32) usize {
    return posix.epoll_wait(fd, events, timeout);
}
