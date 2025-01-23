const X11 = @This();

const std = @import("std");
const log = std.log;

const x11 = @cImport({
    @cInclude("X11/Xlib.h");
});

const XError = error{
    XOpenDisplayError,
};

display: *x11.Display,
root_window: x11.Window,

pub fn init() XError!X11 {
    const dpy = x11.XOpenDisplay(null) orelse {
        log.err("cannot open x display", .{});
        return XError.XOpenDisplayError;
    };
    return .{
        .display = dpy,
        .root_window = x11.DefaultRootWindow(dpy),
    };
}

pub fn deinit(self: X11) void {
    if (x11.XCloseDisplay(self.display) != 0) {
        log.err("cannot close x display", .{});
    }
}

pub fn setRoot(self: X11, text: [*]const u8) void {
    _ = x11.XStoreName(self.display, self.root_window, text);
    _ = x11.XFlush(self.display);
}
