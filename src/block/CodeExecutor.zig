const std = @import("std");
const log = std.log.scoped(.code_executor);

const unix = @import("../unix.zig");

const config = @import("../config.zig");
const ComponentExecutor = @import("ComponentExecutor.zig");
const Button = @import("Block.zig").Button;
const Message = @import("Block.zig").Message;

const Allocator = std.mem.Allocator;

pub fn GenericCodeExecutor(comptime component: type) type {
    return struct {
        const Self = @This();
        alloc: Allocator,
        pipe: [2]unix.FD,

        pub fn init(alloc: Allocator) Self {
            if (@hasDecl(component, "init")) component.init(alloc) catch @panic("component init failed");
            return .{
                .alloc = alloc,
                .pipe = unix.ubpipe() catch @panic("cannot create pipe"),
            };
        }

        pub fn deinit(self: *Self) void {
            if (@hasDecl(component, "deinit")) component.deinit(self.alloc) catch @panic("component deinit failed");
            for (self.pipe) |p| unix.close(p);
        }

        pub fn run(self: *Self, message: Message) void {
            const executor_pid = unix.fork() catch |err| {
                log.err("cannot fork process to execute, error: {s}", .{@errorName(err)});
                return;
            };
            // 开启子进程执行
            if (executor_pid == 0) {
                const pipe = self.pipe;
                defer std.process.exit(0);
                unix.close(pipe[0]);
                defer unix.close(pipe[1]);

                var arean = std.heap.ArenaAllocator.init(self.alloc);
                defer arean.deinit();
                const buf = component.run(arean.allocator(), message) catch |err| {
                    log.err("run component get a error: {s}", .{@errorName(err)});
                    _ = unix.write(pipe[1], "\n") catch @panic("cannot write content to fd");
                    return;
                };
                _ = unix.write(pipe[1], buf) catch @panic("cannot write content to fd");
            }
        }

        /// 读取执行结果
        pub fn readResult(self: Self, buf: []u8) usize {
            return unix.read(self.pipe[0], buf) catch |err| {
                log.err("execute script has no output, error: {s}", .{@errorName(err)});
                return 0;
            };
        }

        pub fn executor(ctx: *Self) ComponentExecutor {
            const gen = struct {
                pub fn getFd(ptr: *anyopaque) unix.FD {
                    const self: *Self = @ptrCast(@alignCast(ptr));
                    return self.pipe[0];
                }
                pub fn execute(ptr: *anyopaque, message: Message) void {
                    const self: *Self = @ptrCast(@alignCast(ptr));
                    self.run(message);
                }
                pub fn readResult(ptr: *anyopaque, buf: []u8) usize {
                    const self: *Self = @ptrCast(@alignCast(ptr));
                    return self.readResult(buf);
                }
                pub fn deinit(ptr: *anyopaque) void {
                    const self: *Self = @ptrCast(@alignCast(ptr));
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
    };
}

test "run component code" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const test_component = struct {
        pub fn run(a: Allocator, message: Message) ![]u8 {
            var buf = try a.alloc(u8, 1);
            if (message.button) |btn| buf[0] = btn.getChar();
            return buf;
        }
    };

    var code_executor = GenericCodeExecutor(test_component).init(alloc);
    for (code_executor.pipe) |p| unix.close(p);
    code_executor.pipe = try unix.pipe();
    defer code_executor.deinit();

    var btn = Button.up;
    const message = Message.init(btn);

    code_executor.run(message);

    var buf: [1024]u8 = undefined;
    const len = try unix.read(code_executor.pipe[0], &buf);
    try testing.expectEqualSlices(u8, &.{btn.getChar()}, buf[0..len]);
}
