const ComponentExecutor = @This();

const std = @import("std");

const unix = @import("../unix.zig");

const Message = @import("Message.zig");

ptr: *anyopaque,
getFdFn: *const fn (ptr: *anyopaque) unix.FD,
executeFn: *const fn (ptr: *anyopaque, message: Message) void,
readResultFn: *const fn (ptr: *anyopaque, buf: []u8) usize,
deinitFn: *const fn (ptr: *anyopaque) void,

/// 获取读端的 pipe 方便注册到多路复用器上
pub inline fn getFd(self: ComponentExecutor) unix.FD {
    return self.getFdFn(self.ptr);
}

/// 执行
pub inline fn execute(self: ComponentExecutor, message: Message) void {
    self.executeFn(self.ptr, message);
}

pub inline fn deinit(self: ComponentExecutor) void {
    self.deinitFn(self.ptr);
}

/// 读取执行结果
pub inline fn readResult(self: ComponentExecutor, buf: []u8) usize {
    return self.readResultFn(self.ptr, buf);
}
