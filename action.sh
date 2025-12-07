#!/system/bin/sh
# ==============================================================================
# 手动触发F2FS 优化任务 + 自动服务恢复
# ==============================================================================

# 模块目录
MODDIR=${0%/*}
SERVICE_SCRIPT="$MODDIR/service.sh"

# ==============================================================================
# 1. 加载统一配置与函数库 (Source Guard 模式)
# ==============================================================================

if [ ! -f "$SERVICE_SCRIPT" ]; then
    printf '❌ 致命: 找不到 %s\n' "$SERVICE_SCRIPT" >&2
    exit 1
fi

# 关键: 加载配置但不执行服务逻辑
. "$SERVICE_SCRIPT" --source-only

#重定义日志函数
log_msg() {
    [ "$LOG_MODE" != "NONE" ] && printf '%s I %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG_FILE"
}

log_warn() {
    [ "$LOG_MODE" != "NONE" ] && printf '%s W %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG_FILE"
}

log_err() {
    printf '%s E %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG_FILE"
}

# 本地 UI 输出函数（统一日志管理）
ui_print() {
    local _msg="$1"
    # 屏幕输出（带时间戳）
    printf '- %s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$_msg"
    # 日志输出：复用 service.sh 的 log_msg（自动处理 LOG_MODE）
    log_msg "[手动] $_msg"
    # 调用日志轮替（如果函数存在）
    command -v check_log_size >/dev/null 2>&1 && check_log_size
}

# ==============================================================================
# 2. 停止旧服务
# ==============================================================================

ui_print "检查后台服务..."

# 常量定义
readonly F2FSOPT_LOCK_DIR="/data/local/tmp/f2fsopt.lock.d"
readonly F2FSOPT_PID_FILE="$F2FSOPT_LOCK_DIR/pid"

# 2.1 停止调度器 (利用 shared SVC_PID_FILE)
if [ -f "$SVC_PID_FILE" ]; then
    read -r _pid < "$SVC_PID_FILE" 2>/dev/null
    if [ -n "$_pid" ] && is_integer "$_pid" && [ -d "/proc/$_pid" ]; then
        ui_print "停止调度服务 (PID: $_pid)..."
        kill "$_pid" 2>/dev/null
        # 简单等待
        sleep 1
        [ -d "/proc/$_pid" ] && kill -9 "$_pid" 2>/dev/null
    fi
    rm -f "$SVC_PID_FILE"
fi

# 2.2 深度清理 (利用 shared kill_by_pattern)
# 清理 crond
kill_by_pattern "crond -c $MODDIR/cron.d"
# 清理残留 service.sh (精准匹配本模块)
kill_by_pattern "$MODDIR/service.sh"


# 2.3 停止正在运行的任务 (f2fsopt)
# 第一步: 尝试通过 PID 文件优雅停止
if [ -f "$F2FSOPT_PID_FILE" ]; then
    read -r _task_pid < "$F2FSOPT_PID_FILE" 2>/dev/null
    if [ -n "$_task_pid" ] && is_integer "$_task_pid" && [ -d "/proc/$_task_pid" ]; then
        ui_print "⚠️ 发现后台任务 (PID: $_task_pid)"
        ui_print "正在终止..."
        kill "$_task_pid" 2>/dev/null
        sleep 1
        [ -d "/proc/$_task_pid" ] && kill -9 "$_task_pid" 2>/dev/null
    fi
fi

# 第二步: 全盘扫描特征码 (防止孤儿进程残留)
ui_print "深度清理残留进程..."
kill_by_pattern "f2fsopt"

# 清理锁目录 (会自动删除内部的 PID 文件)
rm -rf "$F2FSOPT_LOCK_DIR" 2>/dev/null

# 清理调度锁
rm -f "$LOCK_FILE"

# ==============================================================================
# 3. 执行任务
# ==============================================================================

# 检测模块状态（禁用/卸载/更新）
if [ -f "$MODDIR/disable" ] || [ -f "$MODDIR/remove" ] || [ -f "$MODDIR/update" ]; then
    ui_print ""
    ui_print "⚠️ 检测到模块操作标记"
    ui_print "模块可能正在被 禁用/卸载/更新"
    ui_print "为避免冲突，已取消执行"
    ui_print ""
    exit 0
fi

ui_print ">>> 启动优化任务"
printf '%s\n' "------------------------------"

if [ -x "$TARGET_COMMAND" ]; then
    echo "$$" > "$LOCK_FILE"
    
    # 执行任务：屏幕 + 日志
    if command -v tee >/dev/null 2>&1; then
        "$TARGET_COMMAND" 2>&1 < /dev/null | tee -a "$LOG_FILE"
        _ret=$?
    else
        "$TARGET_COMMAND" < /dev/null
        _ret=$?
    fi
    
    rm -f "$LOCK_FILE"
    
    # 更新状态
    if [ -n "$STATE_FILE" ]; then
        if ! atomic_write_state "$(date +%s)"; then
            ui_print "⚠️ 状态文件更新失败"
        fi
    fi
    
    printf '%s\n' "------------------------------"
    if [ "$_ret" -eq 0 ]; then
        ui_print "✅ 执行成功"
    else
        ui_print "❌ 执行失败 (Code: $_ret)"
        [ -n "$LOG_FILE" ] && printf '   日志: %s\n' "$LOG_FILE"
    fi
else
    ui_print "❌ 错误: 目标不可执行 ($TARGET_COMMAND)"
fi

# ==============================================================================
# 4. 重启服务
# ==============================================================================

ui_print "正在重启调度服务..."
chmod 755 "$SERVICE_SCRIPT"

# 启动守护进程 (无需参数，默认进入服务模式)
/system/bin/sh "$SERVICE_SCRIPT" >/dev/null 2>&1 &

sleep 2

# 验证启动
if [ -f "$SVC_PID_FILE" ]; then
    read -r _new_pid < "$SVC_PID_FILE" 2>/dev/null
    if [ -d "/proc/$_new_pid" ]; then
        ui_print "✅ 服务已恢复 (PID: $_new_pid)"
    else
        ui_print "⚠️ 服务启动异常"
    fi
else
    ui_print "⚠️ 服务响应超时"
fi

printf '%s\n' "=============================="
