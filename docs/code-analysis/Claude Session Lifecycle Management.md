# Claude Session Lifecycle Management

## 前言

`ralph_loop.sh`是执行ralph循环的脚本，它里存在维护Claude Session的逻辑，**实现 Claude API 的“会话连续性”**。



## 运作方式

### 如何使用已存在的Claude Code会话

在`build_claude_command`函数中，有这样的语句：

```shell
    # Add session continuity flag
    if [[ "$CLAUDE_USE_CONTINUE" == "true" ]]; then
        CLAUDE_CMD_ARGS+=("--continue")
    fi
```

**CLAUDE_SESSION_FILE：**`CLAUDE_SESSION_FILE="$RALPH_DIR/.claude_session_id"`

- **作用**：如果 `.claude_session_id` 文件存在，就给 `claude` 命令加上 `--continue` 参数。
- **关键点**：`claude` CLI 工具内部会**自动读取其默认会话文件**（通常位于 `～/.config/claude/session_id` 或类似位置），而 **`--continue` 参数的作用是告诉 CLI “请使用上一次的会话上下文”**。
- **脚本的巧妙设计**：脚本**并不关心 Claude CLI 内部如何管理 session_id**，它只是用 `.claude_session_id` 这个“哨兵文件”（sentinel file）来标记“我们希望启用会话延续”。只要这个文件存在，就加 `--continue`；如果不存在，就不加，从而开启新会话。

> ✅ 所以，“传递会话”的动作体现在：**通过检测文件是否存在，决定是否传入 `--continue` 参数**。



### Ralph的Claude Session文件什么时候创建？

`save_claude_session`函数内，读取本次AI的返回结果里面的session id，将其保存到 `.claude_session_id` 文件中。

**函数调用路径：**`main -> execute_claude_code -> save_claude_session`。



### 什么时候清理Ralph的Claude Session文件？

清理Claude Session文件，意味着不再使用已存在的会话，**下列情况会清理：**

1. **Claude Session文件过期**：当这个文件的修改时间超过x小时，删除这个文件。默认24小时，可通过命令行参数指定。
1. **Claude Session文件为空。**
1. **发生异常导致断路器打开**：函数调用路径是`main -> reset_session`，重置原因是**circuit_breaker_open**。
1. **项目完成**：函数调用路径是`main -> reset_session`，重置原因是**project_complete**。
1. **断路器跳闸**：函数调用路径是`main -> reset_session`，重置原因是**circuit_breaker_trip**。
1. **通过脚本参数`--reset-circuit`清理**：函数调用路径是`reset_session`，重置原因是**manual_circuit_reset**
1. **通过脚本参数`--reset-session`清理**：函数调用路径是`reset_session`，重置原因是**manual_reset_flag**。
8. **trap cleanup SIGINT SIGTERM**：函数调用路径是`trap -> 发现终端信号 -> cleanup -> reset_session`，重置原因是**manual_interrupt**。
   1. **SIGINT**：用户按下 Ctrl+C 时发送的中断信号。
   2. **SIGTERM**：系统发送的终止信号（如 kill 命令）。



**reset_session**函数清理Claude Session的方式：`rm -f "$CLAUDE_SESSION_FILE" 2>/dev/null`。

