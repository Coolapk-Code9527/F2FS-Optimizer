#!/system/bin/sh
# ==============================================================================
# 卸载清理脚本
# ==============================================================================

# 模块目录
MODDIR=${0%/*}

# 文件路径
PID_FILE="$MODDIR/service.pid"
STATE_FILE="$MODDIR/scheduler.state"
LOCK_FILE="$MODDIR/run.lock"
LOG_FILE="$MODDIR/service.log"
CRON_DIR="$MODDIR/cron.d"

# 整数验证
is_integer() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac }

log_msg() {
    printf '[Uninstall] %s\n' "$1" >&2
}

# ==============================================================================
# 查找 Busybox
# ==============================================================================
BB_PATH=""
for p in "/data/adb/magisk/busybox" "/data/adb/ksu/bin/busybox" "/data/adb/ap/bin/busybox" "/sbin/.magisk/busybox" "/system/xbin/busybox" "/system/bin/busybox" "$(command -v busybox)"; do
    if [ -x "$p" ]; then BB_PATH="$p"; break; fi
done

# 进程清理（统一策略：Busybox 优先，系统命令降级）
do_pkill() {
    local _pat="$1" _pid _cmd _killed=0
    
    # 策略 1: Busybox pkill（优先，更可靠）
    if [ -n "$BB_PATH" ] && [ -x "$BB_PATH" ]; then
        "$BB_PATH" pkill -f "$_pat" 2>/dev/null && return 0
    fi
    
    # 策略 2: 系统 pkill（降级）
    if command -v pkill >/dev/null 2>&1; then
        pkill -f "$_pat" 2>/dev/null && return 0
    fi
    
    # 策略 3: 纯 Shell 回退（兜底）
    for _p in /proc/[0-9]*; do
        [ -d "$_p" ] || continue
        
        _pid="${_p##*/}"
        
        # 严格校验纯数字 (排除 /proc/8350_reg 等内核伪目录)
        case "$_pid" in *[!0-9]*) continue ;; esac
        
        read -r _cmd < "$_p/cmdline" 2>/dev/null || continue
        [ -z "$_cmd" ] && continue
        
        case "$_cmd" in
            *"$_pat"*)
                kill "$_pid" 2>/dev/null && _killed=$((_killed + 1))
                ;;
        esac
    done
}

# ==============================================================================
# 清理调度器进程
# ==============================================================================
# 1. 停止主服务
if [ -f "$PID_FILE" ]; then
    _pid=""
    read -r _pid < "$PID_FILE" 2>/dev/null
    
    if [ -n "$_pid" ] && is_integer "$_pid" && [ -d "/proc/$_pid" ]; then
        _cmd=""
        read -r _cmd < "/proc/$_pid/cmdline" 2>/dev/null
        
        # 验证是否为服务进程 (cmdline 在 \0 处截断，仅获取进程名)
        case "$_cmd" in
            *"service.sh"*|*"crond"*)
                log_msg "终止调度器 (PID: $_pid)"
                kill -TERM "$_pid" 2>/dev/null
                
                _wait=0
                while [ -d "/proc/$_pid" ] && [ "$_wait" -lt 20 ]; do
                    sleep 0.1
                    _wait=$((_wait + 1))
                done
                
                if [ -d "/proc/$_pid" ]; then
                    log_msg "强制终止"
                    kill -9 "$_pid" 2>/dev/null
                fi
                ;;
            *)
                log_msg "跳过非服务进程 (PID: $_pid)"
                ;;
        esac
    fi
    rm -f "$PID_FILE" 2>/dev/null
fi

# 2. 停止所有正在运行的优化任务 (防止孤儿进程)
log_msg "停止所有 f2fsopt 任务..."
do_pkill "f2fsopt"

# ==============================================================================
# 清理 Crond 进程
# ==============================================================================
log_msg "清理 Crond..."
do_pkill "crond -c $CRON_DIR"

# ==============================================================================
# 清理并发锁
# ==============================================================================
_LOCK_DIR="/data/local/tmp/f2fsopt.lock.d"
_LOCK_PID_FILE="$_LOCK_DIR/pid"

if [ -f "$_LOCK_PID_FILE" ] || [ -d "$_LOCK_DIR" ]; then
    rm -f "$_LOCK_PID_FILE" 2>/dev/null
    rm -rf "$_LOCK_DIR" 2>/dev/null
    log_msg "并发锁已清理"
fi

# ==============================================================================
# 清理模块文件
# ==============================================================================
_cleaned=0

# 清理状态文件
if [ -f "$STATE_FILE" ]; then
    rm -f "$STATE_FILE" 2>/dev/null && _cleaned=$((_cleaned + 1))
fi

# 清理锁文件
if [ -f "$LOCK_FILE" ]; then
    rm -f "$LOCK_FILE" 2>/dev/null && _cleaned=$((_cleaned + 1))
fi

# 清理日志文件
if [ -f "$LOG_FILE" ]; then
    rm -f "$LOG_FILE" 2>/dev/null && _cleaned=$((_cleaned + 1))
fi

# 清理 Cron 目录
if [ -d "$CRON_DIR" ]; then
    rm -rf "$CRON_DIR" 2>/dev/null && _cleaned=$((_cleaned + 1))
fi

if [ "$_cleaned" -gt 0 ]; then
    log_msg "模块文件已清理 (${_cleaned} 项)"
fi

# ==============================================================================
# 清理唤醒锁
# ==============================================================================
if [ -w "/sys/power/wake_unlock" ]; then
    echo "f2fsopt_lck" > /sys/power/wake_unlock 2>/dev/null
fi

log_msg "✅ 清理完成"
exit 0
