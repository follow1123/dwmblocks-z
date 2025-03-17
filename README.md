## 一个 dwm 的状态栏

使用 zig 重写的 [dwmblocks-async](https://github.com/UtkarshVerma/dwmblocks-async)

dwm 窗口管理器需要配合 [statuscmd](https://dwm.suckless.org/patches/statuscmd/) 这个补丁使用

### 编译

需要 `zig 0.13.0`

```bash
zig build -Doptimize=ReleaseFast

ln -s ./scripts ~/.local/share/dwmblocks
```

### 组件

#### 脚本组件

环境变量

* `BLOCK_BUTTON` - 按键数字，在窗口管理器处设置
* `CALLER_PID` - 程序的 pid
* `BLOCK_SHOW_ALL` - 一个标识，某些组件默认不显示内容，可以通过这个表示显示
* `update_block_[block_name]` - 一个用于不同脚本之间通信的预计，类似：`kill -35 1324324`，脚本内使用 `eval $update_block_aaa` 执行

#### 代码组件

固定结构

```zig
const std = @import("std");
const log = std.log;

const Allocator = std.mem.Allocator;
const Button = @import("../block.zig").Button;
const Message = @import("../block.zig").Message;

/// 组件初始化时调用，只调用一次
pub fn init(alloc: Allocator) !void {
    // 初始化代码
}

/// 程序退出时调用，只调用一次
pub fn deinit(alloc: Allocator) !void {
    // 结束相关代码
}

/// 使用 run 方法内的 allocator 分配的内存可以不用释放
/// 调用结束后由 CodeExecutor 统一释放
pub fn run(alloc: Allocator, message: Message) !?[]u8 {
    // 执行代码
}
```
