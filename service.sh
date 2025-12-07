#!/system/bin/sh
# ==============================================================================
# 统一调度器 - Sleep/Cron 双引擎 (Source Guard Enabled)
# 描述: 该脚本作为守护进程运行，负责定时触发 f2fsopt 优化任务。
#       支持被其他脚本 source 以共享配置和函数。
# ==============================================================================

# ==============================================================================
# PART 1: 定义与配置 (Source 共享区域)
# ==============================================================================

# 1.1 路径计算
if [ -L "$0" ]; then
    _script_real=$(readlink -f "$0" 2>/dev/null)
    [ -n "$_script_real" ] && MODDIR="${_script_real%/*}" || MODDIR="${0%/*}"
else
    MODDIR="${0%/*}"
fi
# 确保绝对路径
case "$MODDIR" in /*) ;; *) MODDIR="$(cd "$MODDIR" 2>/dev/null && pwd)" || MODDIR="/data/adb/modules/${0##*/}" ;; esac

# 1.2 环境配置
export PATH="/system/bin:/system/xbin:/vendor/bin:/product/bin:$PATH"
export LC_ALL=C

# 查找 Busybox (供所有依赖脚本使用)
BB_PATH=""
for p in "/data/adb/magisk/busybox" "/data/adb/ksu/bin/busybox" "/data/adb/ap/bin/busybox" "/data/data/com.termux/files/usr/bin/busybox" "/sbin/.magisk/busybox" "/system/xbin/busybox" "/system/bin/busybox" "$(command -v busybox)"; do
    if [ -x "$p" ]; then 
        BB_PATH="$p"
        export PATH="${BB_PATH%/*}:$PATH"
        break
    fi
done

# 依赖工具列表
readonly REQUIRED_TOOLS="stat readlink mkdir rm sleep date tail pgrep pkill crond"

init_command_proxy() {
    if [ -z "$BB_PATH" ] || [ ! -x "$BB_PATH" ]; then return 1; fi
    
    local _tool _bb_caps
    
    _bb_caps=" $(echo $("$BB_PATH" --list 2>/dev/null)) "
    
    for _tool in $REQUIRED_TOOLS; do
        case "$_bb_caps" in 
            *" $_tool "*)
                eval "$_tool() { '$BB_PATH' $_tool \"\$@\"; }"
                ;;
            *)
                # Busybox 不支持 -> 跳过（回退系统命令）
                ;;
        esac
    done
    
    # 刷新 Shell 哈希表
    hash -r 2>/dev/null || true
}

# 执行代理初始化
init_command_proxy

# 1.3 核心配置变量
# 目标脚本
TARGET_COMMAND="$MODDIR/f2fsopt"

# 定时调度模式 sleep | cron
SCHEDULE_MODE="cron"

# 定时规则 (Cron表达式 (*/N | M */N | M H * * *))
# Sleep 模式支持的格式:
#   "*/N * * * *"  - 每N分钟 (如 "*/10 * * * *" = 每10分钟)
#   "0 */N * * *"  - 每N小时整点 (如 "0 */2 * * *" = 每2小时整点: 00:00, 02:00, 04:00...)
#   "M */N * * *"  - 每N小时M分 (如 "30 */2 * * *" = 每2小时的30分: 00:30, 02:30, 04:30...)
#   "M H * * *"    - 每天固定时间 (如 "30 02 * * *" = 每天02:30)
# Cron 模式支持完整 Cron 语法
CRON_EXP="0 */4 * * *"

SLEEP_HEARTBEAT="1800"             # Sleep 模式心跳 (秒)
LOG_MODE="INFO"                    # INFO | ERROR | NONE
MAX_LOG_SIZE="524288"              # 512KB
STATE_FILE="$MODDIR/scheduler.state"
LOCK_FILE="$MODDIR/run.lock"
SVC_PID_FILE="$MODDIR/service.pid" # 统一 PID 文件名
LOG_FILE="$MODDIR/service.log"

# 1.4 通用函数库

is_integer() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac }

log_msg() { [ "$LOG_MODE" != "NONE" ] && printf '%s I %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1"; }
log_warn() { [ "$LOG_MODE" != "NONE" ] && printf '%s W %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1"; }
log_err() { printf '%s E %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1"; }

# 进程清理
kill_by_pattern() {
    local _pattern="$1" _pid _killed=0

    # 策略 1: 使用 pgrep
    if command -v pgrep >/dev/null 2>&1; then
        for _pid in $(pgrep -f "$_pattern" 2>/dev/null); do
            [ "$_pid" = "$$" ] && continue
            log_msg "   - 终止进程(pgrep): $_pid"
            kill "$_pid" 2>/dev/null && _killed=1
        done
        [ "$_killed" -eq 1 ] && return 0
    fi

    # 策略 2: /proc 遍历
    local _p _cmd
    for _p in /proc/[0-9]*; do
        [ -d "$_p" ] || continue
        
        _pid="${_p##*/}"
        
        # 严格校验纯数字 (排除 /proc/8350_reg 等内核伪目录)
        case "$_pid" in *[!0-9]*) continue ;; esac
        [ "$_pid" = "$$" ] && continue
        
        read -r _cmd < "$_p/cmdline" 2>/dev/null || continue
        [ -z "$_cmd" ] && continue
        
        case "$_cmd" in
            *"$_pattern"*)
                log_msg "   - 终止进程(proc): $_pid"
                kill "$_pid" 2>/dev/null
                # 顽固进程延迟强杀
                [ -d "$_p" ] && { sleep 0.05; kill -9 "$_pid" 2>/dev/null; }
                ;;
        esac
    done
}

# 锁检查
is_locked() {
    if [ -f "$LOCK_FILE" ]; then
        local _pid _cmd
        read -r _pid < "$LOCK_FILE" 2>/dev/null
        if [ -n "$_pid" ] && is_integer "$_pid" && [ -d "/proc/$_pid" ]; then
            read -r _cmd < "/proc/$_pid/cmdline" 2>/dev/null
            case "$_cmd" in
                *"f2fsopt"*|*"service.sh"*)
                    return 0
                    ;;
            esac
        fi
        log_warn "清理失效锁 (PID: ${_pid:-null})"
        rm -f "$LOCK_FILE"
    fi
    return 1
}

# 原子写入状态
atomic_write_state() {
    echo "$1" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
}

# 日志轮替
check_log_size() {
    [ "$LOG_MODE" = "NONE" ] && return
    [ ! -f "$LOG_FILE" ] && return
    local _size
    if command -v stat >/dev/null 2>&1; then
        _size=$(stat -c%s "$LOG_FILE" 2>/dev/null)
    else
        _size=$(wc -c < "$LOG_FILE" 2>/dev/null)
    fi
    is_integer "$_size" || return
    if [ "$_size" -gt "$MAX_LOG_SIZE" ]; then
        local _tmp="${LOG_FILE}.tmp"
        if command -v tail >/dev/null 2>&1; then
            tail -n 200 "$LOG_FILE" > "$_tmp" 2>/dev/null
        else
            : > "$_tmp"
        fi
        # 原子替换（使用 mv 保证一致性）
        if [ -s "$_tmp" ]; then
            mv "$_tmp" "$LOG_FILE" 2>/dev/null
        else
            : > "$LOG_FILE"
        fi
        rm -f "$_tmp" 2>/dev/null
    fi
}

# ==============================================================================
# PART 2: Source Guard (源码守卫)
# ==============================================================================
if [ "${1:-}" = "--source-only" ]; then
    # 安全退出：函数中 return，脚本中 exit
    return 0 2>/dev/null || exit 0
fi

# ==============================================================================
# PART 3: 运行时逻辑 (仅守护进程执行)
# ==============================================================================

# 信号捕获
trap 'cleanup_scheduler' INT TERM

# 日志重定向
case "$LOG_MODE" in
    NONE) 
        exec > /dev/null 2>&1 
        ;;
    *)    
        _log_dir="${LOG_FILE%/*}"
        if [ ! -d "$_log_dir" ]; then
            mkdir -p "$_log_dir" 2>/dev/null || LOG_FILE="/dev/null"
        fi
        
        if ! touch "$LOG_FILE" 2>/dev/null; then
            exec > /dev/null 2>&1
        else
            exec >> "$LOG_FILE" 2>&1 || exec > /dev/null 2>&1
        fi
        ;;
esac

printf '%s\n' "========================================"
printf '%s I 调度器 启动 (PID: %s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$$"
printf '%s\n' "========================================"

# 3.2 运行时特有函数
cleanup_scheduler() {
    log_msg "服务停止"
    kill_by_pattern "crond -c $MODDIR/cron.d"
    rm -f "$LOCK_FILE" "$SVC_PID_FILE" "${STATE_FILE}.tmp" 2>/dev/null
    rm -f "$MODDIR/cron.d/root" 2>/dev/null
    rmdir "$MODDIR/cron.d" 2>/dev/null
    exit 0
}

# ... 调度逻辑 ...

# Cron表达式解析
parse_cron_config() {
    set -f; set -- $CRON_EXP; set +f
    local _min="$1"; local _hour="$2"

    # 类型 A: 固定时间
    if is_integer "$_min" && is_integer "$_hour"; then
        SCHED_TYPE="fixed"; SCHED_V1="$_hour"; SCHED_V2="$_min"
        log_msg "策略: 每天 ${_hour}:${_min} 固定执行"
        return 0
    fi
    # 类型 B: 间隔
    case "$_min" in \*/[0-9]*)
        local _step="${_min#*/}"
            if is_integer "$_step" && [ "$_step" -gt 0 ] && [ "$_hour" = "*" ]; then
            SCHED_TYPE="interval"; SCHED_V1=$((_step * 60))
            log_msg "策略: 每 ${_step} 分钟执行"
            return 0
        fi
    esac
    # 类型 C: 对齐
    case "$_hour" in \*/[0-9]*)
        local _step="${_hour#*/}"
        local _m_chk="${_min#0}"
        _m_chk="${_m_chk#0}"
        [ -z "$_m_chk" ] && _m_chk=0
        _m_chk=$(printf "%d" "$_m_chk" 2>/dev/null) || _m_chk=0
        if is_integer "$_step" && [ "$_step" -gt 0 ] && [ "$_m_chk" -eq 0 ] 2>/dev/null; then
            SCHED_TYPE="align"; SCHED_V1="$_step"
            log_msg "策略: 每 ${_step} 小时 (整点对齐)"
            return 0
        fi
    esac
    log_err "配置不支持: $CRON_EXP"
    return 1
}

# 计算下次执行时间戳
calc_next_target() {
    local _ts="$1" _h="$2" _m="$3" _s="$4"
    local _passed=$((_h * 3600 + _m * 60 + _s))
    local _today_start=$((_ts - _passed))
    
    case "$SCHED_TYPE" in
        "interval")
            local _last=0
            [ -f "$STATE_FILE" ] && read -r _last < "$STATE_FILE" 2>/dev/null
            
            # 未来时间视为无效（用户回调时间）
            if is_integer "$_last"; then
                if [ "$_last" -gt "$_ts" ]; then _last=$_ts; fi
            else
                _last=$_ts
            fi
            
            local _next=$((_last + SCHED_V1))
            # 滞后补偿
            if [ "$_next" -le "$_ts" ]; then printf '%s\n' "$((_ts + 5))"; else printf '%s\n' "$_next"; fi
            ;;
        "align")
            local _step="$SCHED_V1"
            # 除零保护
            if ! is_integer "$_step" || [ "$_step" -eq 0 ]; then
                printf '%s\n' "$_ts"  # 返回当前时间
                return 1
            fi
            local _next_H=$(( ((_h / _step) + 1) * _step ))
            local _offset=$((_next_H * 3600))
            printf '%s\n' "$((_today_start + _offset))"
            ;;
        "fixed")
            local _offset=$((SCHED_V1 * 3600 + SCHED_V2 * 60))
            local _tar=$((_today_start + _offset))
            if [ "$_tar" -le "$_ts" ]; then printf '%s\n' "$((_tar + 86400))"; else printf '%s\n' "$_tar"; fi
            ;;
    esac
}

# ==============================================================================
# 公共函数：首次启动与开机检测
# ==============================================================================

run_first_time_check() {
    if [ ! -f "$STATE_FILE" ]; then
        log_msg "初始化: 首次安装/重启，立即执行"
        if ! is_locked; then
            echo "$$" > "$LOCK_FILE"
            
            if ! atomic_write_state "$(date +%s)"; then
                log_warn "状态文件更新失败"
            fi
            
            "$TARGET_COMMAND" < /dev/null
            
            rm -f "$LOCK_FILE"
            log_msg "<<< 首次任务完成"
        else
            log_warn "首次任务跳过 (锁存在)"
        fi
    fi
}


# ==============================================================================
# Sleep 引擎主循环
# ==============================================================================

run_sleep_engine() {
    # 子Shell需重新注册信号捕获
    trap 'cleanup_scheduler' INT TERM

    # OOM 保护
    if [ -f /proc/self/oom_score_adj ]; then
        echo "-1000" > /proc/self/oom_score_adj 2>/dev/null
    fi

    # 解析配置（仅在未解析时执行，避免重复）
    if [ -z "$SCHED_TYPE" ]; then
        if ! parse_cron_config; then
            log_err "配置错误，默认每2小时"
            SCHED_TYPE="align"; SCHED_V1=2
        fi
    fi
    
    # 首次启动检查（仅在未执行时调用）
    run_first_time_check

    log_msg "Sleep 引擎就绪 (心跳间隔: ${SLEEP_HEARTBEAT}s)"

    while true; do
        check_log_size
        
        # 获取当前时间 (set -- 安全解析) + 错误处理
        local _time_data
        _time_data=$(date +'%s %H %M %S' 2>/dev/null)
        if [ -z "$_time_data" ]; then
            log_warn "时间获取失败，跳过本次调度"
            sleep 60
            continue
        fi
        set -- $_time_data
        local _NOW_TS="$1" _NOW_H="$2" _NOW_M="$3" _NOW_S="$4"
        
        # 八进制陷阱保护（强制十进制）
        _NOW_H=$(printf "%d" "$_NOW_H" 2>/dev/null) || _NOW_H=0
        _NOW_M=$(printf "%d" "$_NOW_M" 2>/dev/null) || _NOW_M=0
        _NOW_S=$(printf "%d" "$_NOW_S" 2>/dev/null) || _NOW_S=0
        
        # 计算下次运行时间
        local _next_run
        _next_run=$(calc_next_target "$_NOW_TS" "$_NOW_H" "$_NOW_M" "$_NOW_S")
        if ! is_integer "$_next_run"; then
            log_warn "时间计算失败，跳过本次调度"
            sleep 60
            continue
        fi
        local _wait_sec=$((_next_run - _NOW_TS))
        
        # 时间修正
        if [ "$_wait_sec" -le 0 ]; then
            [ "$_wait_sec" -lt -10 ] && log_warn "时间滞后 ${_wait_sec}s，校准中"
            sleep 5
            continue
        fi
        
        local _wait_min=$((_wait_sec / 60))
        log_msg "待机: 下次运行约 $_wait_min 分钟后 (等待 ${_wait_sec}s)"

        # 心跳休眠
        while [ "$_wait_sec" -gt 0 ]; do
            local _chunk=$SLEEP_HEARTBEAT
            [ "$_wait_sec" -lt "$SLEEP_HEARTBEAT" ] && _chunk="$_wait_sec"
            
            sleep "$_chunk"
            
            local _curr=$(date +%s)
            [ "$_curr" -ge "$_next_run" ] && break
            _wait_sec=$((_next_run - _curr))
        done

        # 触发执行
        log_msg ">>> 触发任务"
        
        if is_locked; then
            log_warn "任务被锁定，跳过"
            sleep 60
        else
            echo "$$" > "$LOCK_FILE"
            
            if ! atomic_write_state "$(date +%s)"; then
                log_warn "状态文件更新失败"
            fi
            
            if [ -x "$TARGET_COMMAND" ]; then
                "$TARGET_COMMAND" < /dev/null
                local _ret=$?
                log_msg "<<< 完成 (Code: $_ret)"
            else
                log_err "不可执行: $TARGET_COMMAND"
            fi
            
            rm -f "$LOCK_FILE"
        fi
        
        sleep 5
    done
}

run_cron_engine() {
    log_msg "启动 Cron 引擎"
    
    # 检查 crond 可用性（代理层已处理 Busybox/系统命令选择）
    if ! command -v crond >/dev/null 2>&1; then
        log_err "crond 命令不可用，回退 Sleep 模式"
        run_sleep_engine
        return
    fi
    
    # 首次启动立即执行
    run_first_time_check
    
    # 预解析配置
    if ! parse_cron_config; then
        log_err "配置错误，回退 Sleep 模式"
        SCHED_TYPE="align"; SCHED_V1=2
    fi
    
    # 创建 Cron 配置目录（绝对路径）
    local _cron_dir="$MODDIR/cron.d"
    if ! mkdir -p "$_cron_dir" 2>/dev/null; then
        log_err "无法创建配置目录，回退 Sleep 模式"
        run_sleep_engine
        return
    fi
    
    # 确保目标命令是绝对路径
    local _abs_target="$TARGET_COMMAND"
    local _abs_log="$LOG_FILE"
    case "$_abs_target" in /*) ;; *) _abs_target="$MODDIR/$_abs_target" ;; esac
    case "$_abs_log" in /*) ;; *) _abs_log="$MODDIR/$_abs_log" ;; esac
    
    # 构建完整命令
    local _full_cmd="/system/bin/sh -c '$_abs_target >>$_abs_log 2>&1'"
    
    # 写入 Cron 配置
    local _cron_cfg="$_cron_dir/root"
    if ! printf '%s %s\n' "$CRON_EXP" "$_full_cmd" > "$_cron_cfg" 2>/dev/null; then
        log_err "配置写入失败，回退 Sleep 模式"
        run_sleep_engine
        return
    fi
    chmod 0600 "$_cron_cfg" 2>/dev/null
    
    # 配置验证
    if [ "$LOG_MODE" != "NONE" ]; then
        local _cfg_line
        read -r _cfg_line < "$_cron_cfg" 2>/dev/null
        log_msg "配置: ${_cfg_line}"
    fi
    
    # 停止旧 crond 进程
    kill_by_pattern "crond -c $_cron_dir"
    sleep 1
    
    # 启动 crond（代理层已处理 Busybox/系统命令选择）
    if ! crond -c "$_cron_dir" -b -L /dev/null 2>/dev/null; then
        log_err "crond 启动失败，回退 Sleep 模式"
        run_sleep_engine
        return
    fi
    
    # 检测进程启动（3次重试）
    local _retry=0 _crond_pid=""
    while [ "$_retry" -lt 3 ]; do
        sleep 1
        
        # 查找 crond 进程
        _crond_pid=""
        
        # 策略 1: 使用 pgrep
        if command -v pgrep >/dev/null 2>&1; then
            _crond_pid=$(pgrep -f "crond -c $_cron_dir" 2>/dev/null)
            # 提取第一行
            case "$_crond_pid" in
                *$'\n'*) _crond_pid="${_crond_pid%%$'\n'*}" ;;
            esac
            # 仅保留数字
            _crond_pid="${_crond_pid%%[!0-9]*}"
        fi
        
        # 策略 2: 回退到纯 Shell 遍历 /proc
        if [ -z "$_crond_pid" ]; then
            for _p in /proc/[0-9]*; do
                [ -d "$_p" ] || continue
                _p=${_p##*/}
                
                case "$_p" in *[!0-9]*) continue ;; esac
                
                read -r _cmd < "/proc/$_p/cmdline" 2>/dev/null || continue
                case "$_cmd" in
                    *"crond -c $_cron_dir"*)
                        _crond_pid="$_p"
                        break
                        ;;
                esac
            done
        fi
        
        if [ -n "$_crond_pid" ] && [ -d "/proc/$_crond_pid" ]; then
            log_msg "Crond 引擎已启动 (PID: $_crond_pid)"
            # 更新PID文件为crond进程，使action.sh能够管理Cron模式服务
            if ! echo "$_crond_pid" > "$SVC_PID_FILE" 2>/dev/null; then
                log_warn "PID文件写入失败: $SVC_PID_FILE"
            fi
            return 0
        fi
        _retry=$((_retry + 1))
    done
    
    # 启动失败，回退
    log_err "Crond 启动超时，回退 Sleep 模式"
    run_sleep_engine
}

# ==============================================================================
# 入口逻辑
# ==============================================================================


if [ -f "$SVC_PID_FILE" ]; then
    read -r _old_pid < "$SVC_PID_FILE" 2>/dev/null
    if [ -n "$_old_pid" ] && is_integer "$_old_pid" && [ -d "/proc/$_old_pid" ] && [ "$_old_pid" != "$$" ]; then
        # 验证进程类型：仅清理 service.sh 或 crond 进程（支持Cron模式）
        if grep -q "service.sh" "/proc/$_old_pid/cmdline" 2>/dev/null || grep -q "crond -c" "/proc/$_old_pid/cmdline" 2>/dev/null; then
            log_msg "清理旧实例 (PID: $_old_pid)"
            kill "$_old_pid" 2>/dev/null
            sleep 1
            [ -d "/proc/$_old_pid" ] && kill -9 "$_old_pid" 2>/dev/null
        else
            log_warn "跳过非服务进程 (PID: $_old_pid)"
        fi
    fi
fi

_pid_dir="${SVC_PID_FILE%/*}"
if [ ! -d "$_pid_dir" ]; then
    mkdir -p "$_pid_dir" 2>/dev/null || {
        log_err "无法创建目录: $_pid_dir"
        exit 1
    }
fi

if ! echo "$$" > "$SVC_PID_FILE" 2>/dev/null; then
    log_err "无法写入PID文件: $SVC_PID_FILE"
    exit 1
fi

# 开机清理锁
rm -f "$LOCK_FILE"

# 启动延迟：区分开机启动和手动重启
if [ -r "/proc/uptime" ]; then
    read -r _uptime _ < /proc/uptime 2>/dev/null
    _uptime=${_uptime%%.*}
else
    _uptime=0
fi
is_integer "$_uptime" || _uptime=0

if [ "$_uptime" -lt 300 ]; then
    # 开机场景：系统运行时间 < 5分钟
    
    if [ "$(getprop sys.boot_completed)" = "1" ]; then
        log_msg "检测到系统已就绪（uptime: ${_uptime}s），快速启动..."
        sleep 3
    else
        log_msg "检测到开机启动（uptime: ${_uptime}s），等待系统稳定..."
        
        # 等待开机完成 (最多120秒)
        _cnt=0
        until [ "$(getprop sys.boot_completed)" = "1" ] || [ "$_cnt" -ge 60 ]; do
            sleep 2
            _cnt=$((_cnt + 1))
        done
        
        if [ "$_cnt" -ge 60 ]; then
            log_warn "等待开机超时，强制启动"
        else
            log_msg "开机广播已接收，额外缓冲 30秒 以待系统平稳..."
            sleep 30
        fi
    fi
else
    # 手动重启场景：系统已运行 > 5分钟
    log_msg "检测到手动重启（uptime: ${_uptime}s），快速启动..."
fi

if [ ! -f "$TARGET_COMMAND" ]; then
    log_err "未找到目标: $TARGET_COMMAND"
    exit 1
fi

if ! chmod 755 "$TARGET_COMMAND" 2>/dev/null; then
    log_warn "无法设置执行权限"
fi

# 启动引擎
case "$SCHEDULE_MODE" in
    "cron") 
        run_cron_engine 
        exit 0
        ;;
    *)      
        # Sleep 模式: 后台运行，并更新PID文件为真实服务进程
        run_sleep_engine &
        _bg_pid=$!
        
        # 检测 PID 文件写入
        if ! echo "$_bg_pid" > "$SVC_PID_FILE" 2>/dev/null; then
            log_err "无法写入PID文件: $SVC_PID_FILE"
            kill "$_bg_pid" 2>/dev/null
            exit 1
        fi
        log_msg "Sleep 引擎已启动 (PID: $_bg_pid)"
        exit 0
        ;;
esac

log_err "引擎意外退出"
exit 1
