#!/system/bin/sh
# ==============================================================================
# 卸载清理脚本
# ==============================================================================

# 初始化模块目录（支持符号链接、相对路径、回退机制）
_uninstall_script="$0"
_uninstall_dir=""

# 1. 处理符号链接
if [ -L "$_uninstall_script" ]; then
    _uninstall_real=$(readlink -f "$_uninstall_script" 2>/dev/null)
    if [ -n "$_uninstall_real" ]; then
        _uninstall_dir="${_uninstall_real%/*}"
    else
        _uninstall_dir="${_uninstall_script%/*}"
    fi
else
    _uninstall_dir="${_uninstall_script%/*}"
fi

# 2. 确保绝对路径
case "$_uninstall_dir" in
    /*) MODDIR="$_uninstall_dir" ;;
    *)  MODDIR="$(cd "$_uninstall_dir" 2>/dev/null && pwd)" || MODDIR="/data/adb/modules/f2fs_optimizer" ;;
esac

# 3. 验证 MODDIR 有效性
if [ -z "$MODDIR" ] || [ ! -d "$MODDIR" ]; then
    printf '[Uninstall] 错误: 无法初始化模块目录\n' >&2
    exit 1
fi

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
# SYNC: Busybox 探测路径 - 与 service.sh 和 f2fsopt 保持一致
BB_PATH=""
_p=""

# 遍历预定义路径列表
for _p in \
    "/data/adb/magisk/busybox" \
    "/data/adb/ksu/bin/busybox" \
    "/data/adb/ap/bin/busybox" \
    "/system/bin/busybox"; do
    
    if [ -x "$_p" ]; then
        BB_PATH="$_p"
        break
    fi
done

# 动态回退 - 尝试通过 command -v 查找
if [ -z "$BB_PATH" ]; then
    _p=$(command -v busybox 2>/dev/null)
    if [ -n "$_p" ] && [ -x "$_p" ]; then
        BB_PATH="$_p"
    fi
fi

# 进程清理（统一策略：Busybox 优先，系统命令降级）
do_pkill() {
    _dpk_pat="$1"; _dpk_pid=""; _dpk_cmd=""; _dpk_killed=0
    
    # 策略 1: Busybox pkill（优先，更可靠）
    if [ -n "$BB_PATH" ] && [ -x "$BB_PATH" ]; then
        "$BB_PATH" pkill -f "$_dpk_pat" 2>/dev/null && return 0
    fi
    
    # 策略 2: 系统 pkill（降级）
    if command -v pkill >/dev/null 2>&1; then
        pkill -f "$_dpk_pat" 2>/dev/null && return 0
    fi
    
    # 策略 3: 纯 Shell 回退（兜底）
    for _dpk_p in /proc/[0-9]*; do
        [ -d "$_dpk_p" ] || continue
        
        _dpk_pid="${_dpk_p##*/}"
        
        # 严格校验纯数字 (排除 /proc/8350_reg 等内核伪目录)
        case "$_dpk_pid" in *[!0-9]*) continue ;; esac
        
        # 使用 Busybox tr 或回退到 cat
        if [ -n "$BB_PATH" ]; then
            # 使用 echo 将换行符转为空格,确保 case 匹配正确
            _dpk_bb_list=" $(echo $("$BB_PATH" --list 2>/dev/null)) "
            case "$_dpk_bb_list" in
                *" tr "*)
                    _dpk_cmd=$("$BB_PATH" tr '\0' ' ' < "$_dpk_p/cmdline" 2>/dev/null) || continue
                    ;;
                *)
                    if command -v tr >/dev/null 2>&1; then
                        _dpk_cmd=$(tr '\0' ' ' < "$_dpk_p/cmdline" 2>/dev/null) || continue
                    else
                        _dpk_cmd=$(cat "$_dpk_p/cmdline" 2>/dev/null) || continue
                    fi
                    ;;
            esac
        elif command -v tr >/dev/null 2>&1; then
            _dpk_cmd=$(tr '\0' ' ' < "$_dpk_p/cmdline" 2>/dev/null) || continue
        else
            _dpk_cmd=$(cat "$_dpk_p/cmdline" 2>/dev/null) || continue
        fi
        [ -z "$_dpk_cmd" ] && continue
        
        case "$_dpk_cmd" in
            *"$_dpk_pat"*)
                kill "$_dpk_pid" 2>/dev/null && _dpk_killed=$((_dpk_killed + 1))
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
        # 使用 Busybox tr 或回退到 cat
        if [ -n "$BB_PATH" ]; then
            # 使用 echo 将换行符转为空格,确保 case 匹配正确
            _bb_list=" $(echo $("$BB_PATH" --list 2>/dev/null)) "
            case "$_bb_list" in
                *" tr "*)
                    _cmd=$("$BB_PATH" tr '\0' ' ' < "/proc/$_pid/cmdline" 2>/dev/null)
                    ;;
                *)
                    if command -v tr >/dev/null 2>&1; then
                        _cmd=$(tr '\0' ' ' < "/proc/$_pid/cmdline" 2>/dev/null)
                    else
                        _cmd=$(cat "/proc/$_pid/cmdline" 2>/dev/null)
                    fi
                    ;;
            esac
        elif command -v tr >/dev/null 2>&1; then
            _cmd=$(tr '\0' ' ' < "/proc/$_pid/cmdline" 2>/dev/null)
        else
            _cmd=$(cat "/proc/$_pid/cmdline" 2>/dev/null)
        fi
        
        # 验证是否为服务进程（使用精确路径匹配）
        case "$_cmd" in
            *"$MODDIR/service.sh"*|*"crond"*" -c $MODDIR"*|*"crond -c $MODDIR"*)
                log_msg "终止调度器 [PID: $_pid, 匹配: 本模块进程]"
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
                log_msg "跳过非本模块进程 [PID: $_pid]"
                ;;
        esac
    fi
    rm -f "$PID_FILE" 2>/dev/null
fi

# 2. 停止所有正在运行的优化任务 (防止孤儿进程)
log_msg "停止所有 f2fsopt 任务..."
do_pkill "$MODDIR/f2fsopt"

# 3. 停止 WebUI 相关进程
log_msg "停止 WebUI 进程..."
do_pkill "$MODDIR/webui.sh"
do_pkill "httpd.*f2fs_webui"

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

# 清理 WebUI 临时文件
_webui_cleaned=0

# 清理模块目录下的 WebUI 临时文件
_webui_tmp_dir="$MODDIR/.webui_tmp"
if [ -d "$_webui_tmp_dir" ]; then
    rm -rf "$_webui_tmp_dir" 2>/dev/null && {
        _webui_cleaned=$((_webui_cleaned + 1))
        log_msg "WebUI 临时目录已清理: $_webui_tmp_dir"
    }
fi



if [ "$_webui_cleaned" -gt 0 ]; then
    log_msg "WebUI 临时文件已清理 [${_webui_cleaned} 项]"
    _cleaned=$((_cleaned + _webui_cleaned))
fi

if [ "$_cleaned" -gt 0 ]; then
    log_msg "模块文件已清理 [${_cleaned} 项]"
fi

# ==============================================================================
# 清理唤醒锁
# ==============================================================================
if [ -w "/sys/power/wake_unlock" ]; then
    echo "f2fsopt_lck" > /sys/power/wake_unlock 2>/dev/null
fi

log_msg "✅ 清理完成"
exit 0
