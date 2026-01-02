#!/system/bin/sh
# ==============================================================================
# 统一调度器 - F2FS 优化服务 (Ultimate Robust Edition)
# 架构: Bootloader (瞬时) -> Daemon (常驻) -> Worker (瞬时)
# ==============================================================================

# ==============================================================================
# PART 0: 共享初始化函数 (Shared Initialization Functions)
# ==============================================================================
# 这些函数可以被所有脚本（service.sh, webui.sh, action.sh）使用
# 通过 --source-only 模式加载

# SYNC: Busybox 探测路径 - 与 f2fsopt 保持一致
# 更新时请同步修改 f2fsopt 中的路径列表
readonly BUSYBOX_SEARCH_PATHS="
/data/adb/magisk/busybox
/data/adb/ksu/bin/busybox
/data/adb/ap/bin/busybox
/system/bin/busybox
"

# 0.1 路径解析函数
init_moddir() {
    _im_script="${1:-$0}"
    _im_dir=""
    
    # 处理符号链接
    if [ -L "$_im_script" ]; then
        _im_real=$(readlink -f "$_im_script" 2>/dev/null)
        if [ -n "$_im_real" ]; then
            _im_dir="${_im_real%/*}"
        else
            _im_dir="${_im_script%/*}"
        fi
    else
        _im_dir="${_im_script%/*}"
    fi
    
    # 确保绝对路径
    case "$_im_dir" in
        /*) MODDIR="$_im_dir" ;;
        *)  MODDIR="$(cd "$_im_dir" 2>/dev/null && pwd)" || MODDIR="/data/adb/modules/f2fs_optimizer" ;;
    esac
    
    [ -n "$MODDIR" ] && return 0 || return 1
}

# 0.2 Busybox 探测函数
init_busybox() {
    # 幂等性检查 - 如果已经找到可用的 Busybox，直接返回
    [ -n "$BB_PATH" ] && [ -x "$BB_PATH" ] && return 0
    
    BB_PATH=""
    _ib_p=""
    
    # 遍历预定义路径列表
    for _ib_p in $BUSYBOX_SEARCH_PATHS; do
        if [ -x "$_ib_p" ]; then
            BB_PATH="$_ib_p"
            export PATH="${BB_PATH%/*}:$PATH"
            return 0
        fi
    done
    
    # 动态回退 - 尝试通过 command -v 查找
    _ib_p=$(command -v busybox 2>/dev/null)
    if [ -n "$_ib_p" ] && [ -x "$_ib_p" ]; then
        BB_PATH="$_ib_p"
        export PATH="${BB_PATH%/*}:$PATH"
        return 0
    fi
    
    # 未找到 Busybox - 静默返回（此时 log_warn 尚未定义）
    return 1
}

# ==============================================================================
# PART 1: 角色分发 (Role Dispatcher)
# ==============================================================================
# 脚本入口分流：根据参数决定当前进程的角色
# 必须置于脚本最顶端，以实现最高效的短路执行

# 1.1 初始化模块路径（所有模式都需要）
init_moddir "$0" || { printf '致命错误: 无法初始化模块目录\n' >&2; exit 1; }

# 1.2 角色分发
case "${1:-}" in
    --worker)      __ROLE="worker" ;;  # Worker: 任务执行（由 Daemon/Cron 调用）
    --daemon)      __ROLE="daemon" ;;  # Daemon: 后台常驻调度
    --source-only) __ROLE="source" ;;  # Source: 配置加载（action.sh/webui.sh 使用）
    *)  # Bootloader: Magisk 入口，启动 Daemon 后立即退出
        chmod 755 "$MODDIR/service.sh" 2>/dev/null
        /system/bin/sh "$MODDIR/service.sh" --daemon >/dev/null 2>&1 &
        exit 0
        ;;
esac

# 1.3 初始化 Busybox（所有模式都需要，但 --source-only 模式下由调用脚本决定是否调用）
if [ "$__ROLE" != "source" ]; then
    init_busybox  # 失败时仅记录警告,不强制退出
fi

# 1.4 保存当前进程 PID（避免在子 Shell 中误用 $$）
readonly CURRENT_PID=$$

# ==============================================================================
# PART 2: 环境配置与健壮性函数库 (Shared Library)
# ==============================================================================

# 2.1 核心配置
TARGET_COMMAND="$MODDIR/f2fsopt"

# 调度模式: sleep (推荐) | cron (精准)
#   - sleep: 智能循环休眠，兼容性最好
#   - cron:  使用系统 crond，零开销运行
SCHEDULE_MODE="cron"

# 定时规则 (Cron表达式)
# Sleep 模式：计算下次执行时间
# Cron 模式：传递给 crond 调度
# 格式: 分 时 日 月 周
# 示例:
#   "0 */4 * * *"   - 每4小时执行一次（整点对齐）
#   "*/30 * * * *"  - 每30分钟执行一次
#   "0 3 * * *"     - 每天凌晨3点执行
#   "0 */2 * * *"   - 每2小时执行一次（整点对齐）
#   "*/15 * * * *"  - 每15分钟执行一次
CRON_EXP="0 */4 * * *"

# Sleep模式心跳间隔（秒，范围：60-7200）
SLEEP_HEARTBEAT="1800"

# 日志级别配置
#   NONE:  关闭信息和警告日志，仅记录错误日志（用于故障排查）
#   INFO:  记录所有日志（默认，推荐）
#   DEBUG: 调试模式（未来扩展）
# 注意: 错误日志始终记录，无法通过 NONE 关闭
LOG_MODE="INFO"

# 导出给子进程（f2fsopt）
export LOG_MODE

# 日志文件最大大小（512KB = 524288 字节）
MAX_LOG_SIZE="524288"
STATE_FILE="$MODDIR/scheduler.state"
LOCK_FILE="$MODDIR/run.lock"
SVC_PID_FILE="$MODDIR/service.pid"
LOG_FILE="$MODDIR/service.log"

# 2.2 依赖工具代理 (Robust Proxy)
export PATH="/system/bin:/system/xbin:/vendor/bin:/product/bin:$PATH"
export LC_ALL=C

# 声明必需工具
# 说明: 这些工具会通过 init_command_proxy 自动代理到 Busybox（如果可用）
readonly REQUIRED_TOOLS="stat readlink mkdir rm sleep date tail pgrep pkill crond tr sed grep tee netstat httpd timeout"

init_command_proxy() {
    # 基础检查 - BB_PATH 无效时静默返回失败
    [ -z "$BB_PATH" ] || [ ! -x "$BB_PATH" ] && return 1
    
    # 获取 Busybox 能力清单（echo 用于将换行符转为空格，确保 case 匹配正确）
    _icp_tool=""; _icp_bb_caps=" $(echo $("$BB_PATH" --list 2>/dev/null)) "
    
    # 验证能力清单获取成功
    [ -z "$_icp_bb_caps" ] && return 1
    
    # 动态代理: 仅代理 Busybox 确实支持的命令
    for _icp_tool in $REQUIRED_TOOLS; do
        case "$_icp_bb_caps" in 
            *" $_icp_tool "*) eval "$_icp_tool() { '$BB_PATH' $_icp_tool \"\$@\"; }" ;;
        esac
    done
    hash -r 2>/dev/null || true
    return 0
}
# 初始化代理
init_command_proxy

# 2.3 辅助函数 (Robust Utils)

is_integer() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac }

# 读取 /proc/PID/cmdline 并转换 NULL 字节为空格
read_cmdline() {
    _rc_file="$1"
    [ ! -f "$_rc_file" ] && return 1
    
    # 策略 1: 使用 tr 命令（Busybox 代理或系统 tr）
    if command -v tr >/dev/null 2>&1; then
        tr '\0' ' ' < "$_rc_file" 2>/dev/null && return 0
    fi
    
    # 策略 2: 纯 POSIX shell 实现（零依赖回退）
    # 逐字节读取并替换 NULL 字节为空格
    _rc_result=""
    _rc_char=""
    while IFS= read -r -n 1 _rc_char || [ -n "$_rc_char" ]; do
        case "$_rc_char" in
            "") _rc_result="$_rc_result " ;;  # NULL 字节显示为空
            *) _rc_result="$_rc_result$_rc_char" ;;
        esac
    done < "$_rc_file" 2>/dev/null
    
    if [ -n "$_rc_result" ]; then
        printf '%s' "$_rc_result"
        return 0
    fi
    
    # 策略 3: 最终回退 - 返回原始内容（包含 NULL 字节）
    # 调用者需要使用放宽的匹配逻辑
    cat "$_rc_file" 2>/dev/null
}

# 日志配置验证
validate_log_mode() {
    _vlm_mode="$1"
    case "$_vlm_mode" in
        NONE|INFO|DEBUG) return 0 ;;
        *) return 1 ;;
    esac
}

# 获取有效的 LOG_MODE（带默认值）
get_log_mode() {
    _glm_mode="${LOG_MODE:-INFO}"
    if validate_log_mode "$_glm_mode"; then
        printf '%s' "$_glm_mode"
    else
        printf '%s' "INFO"
    fi
}

# 初始化日志输出（在守护进程启动时调用）
init_log_output() {
    if [ "$LOG_MODE" = "NONE" ]; then
        # 重定向到 /dev/null
        exec 2>/dev/null
        return 0
    fi
    
    # 确保日志目录存在
    _ilo_log_dir="${LOG_FILE%/*}"
    if [ ! -d "$_ilo_log_dir" ]; then
        if ! mkdir -p "$_ilo_log_dir" 2>/dev/null; then
            # 降级：无法创建目录，重定向到 /dev/null
            exec 2>/dev/null
            return 1
        fi
    fi
    
    # 尝试打开日志文件
    if ! touch "$LOG_FILE" 2>/dev/null; then
        # 降级：文件不可写，重定向到 /dev/null
        exec 2>/dev/null
        return 1
    fi
    
    # 重定向 stderr 到日志文件
    exec 2>> "$LOG_FILE" || {
        # 降级：重定向失败
        exec 2>/dev/null
        return 1
    }
    
    return 0
}

log_msg() { [ "$LOG_MODE" != "NONE" ] && printf '%s I %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >&2; }
log_warn() { [ "$LOG_MODE" != "NONE" ] && printf '%s W %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >&2; }
log_err() { printf '%s E %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >&2; }

# 深度进程清理 (Strategy 1 + Strategy 2)
kill_by_pattern() {
    _kbp_pattern="$1"; _kbp_pid=""; _kbp_killed=0

    # 策略 1: 使用 pgrep
    if command -v pgrep >/dev/null 2>&1; then
        for _kbp_pid in $(pgrep -f "$_kbp_pattern" 2>/dev/null); do
            [ "$_kbp_pid" = "$CURRENT_PID" ] && continue
            kill "$_kbp_pid" 2>/dev/null && _kbp_killed=1
        done
        return 0
    fi

    # 策略 2: 遍历 /proc (兜底 - 仅当 pgrep 不可用时)
    _kbp_p=""; _kbp_cmd=""
    for _kbp_p in /proc/[0-9]*; do
        [ -d "$_kbp_p" ] || continue
        _kbp_pid="${_kbp_p##*/}"
        case "$_kbp_pid" in *[!0-9]*) continue ;; esac
        [ "$_kbp_pid" = "$CURRENT_PID" ] && continue
        
        _kbp_cmd=$(read_cmdline "$_kbp_p/cmdline") || continue
        case "$_kbp_cmd" in
            *"$_kbp_pattern"*)
                kill "$_kbp_pid" 2>/dev/null
                # 顽固进程双重保障
                [ -d "$_kbp_p" ] && { sleep 0.1; kill -9 "$_kbp_pid" 2>/dev/null; }
                ;;
        esac
    done
}

# 锁机制 (防止重入)
is_locked() {
    _il_pid=""; _il_cmd=""
    if [ -f "$LOCK_FILE" ]; then
        read -r _il_pid < "$LOCK_FILE" 2>/dev/null
        # 验证锁持有者是否存活 (防止死锁)
        if [ -n "$_il_pid" ] && is_integer "$_il_pid" && [ -d "/proc/$_il_pid" ]; then
            _il_cmd=$(read_cmdline "/proc/$_il_pid/cmdline")
            # 使用精确路径匹配，防止误判其他模块的进程
            case "$_il_cmd" in 
                *"$MODDIR/f2fsopt"*|*"$MODDIR/service.sh"*) 
                    return 0 
                    ;; 
            esac
        fi
        # 锁已失效 (Stale Lock)，清理
        rm -f "$LOCK_FILE"
    fi
    return 1
}

# 原子状态写入
atomic_write_state() {
    if ! echo "$1" > "${STATE_FILE}.tmp" 2>/dev/null; then
        rm -f "${STATE_FILE}.tmp" 2>/dev/null
        return 1
    fi
    mv "${STATE_FILE}.tmp" "$STATE_FILE" 2>/dev/null
}

# 日志轮替 (Atomic)
check_log_size() {
    [ "$LOG_MODE" = "NONE" ] && return
    [ ! -f "$LOG_FILE" ] && return
    
    _cls_size=""
    if command -v stat >/dev/null 2>&1; then
        _cls_size=$(stat -c%s "$LOG_FILE" 2>/dev/null)
    else
        _cls_size=$(wc -c < "$LOG_FILE" 2>/dev/null) # Fallback
    fi
    
    case "$_cls_size" in *[!0-9]*) _cls_size=0 ;; esac
    
    if [ "$_cls_size" -gt "$MAX_LOG_SIZE" ]; then
        mv "$LOG_FILE" "${LOG_FILE}.bak" 2>/dev/null
        
        # 检测 tail 命令可用性
        if command -v tail >/dev/null 2>&1; then
            tail -n 200 "${LOG_FILE}.bak" > "$LOG_FILE" 2>/dev/null
        else
            # 回退: tail 不可用时直接清空日志文件
            : > "$LOG_FILE"
        fi
        
        rm "${LOG_FILE}.bak" 2>/dev/null
    fi
}

# ==============================================================================
# PART 3: 核心算法 (Core Algorithm) - 双模共享 (Sleep/Cron)
# ==============================================================================

# 全局标志：避免重复解析 Cron 配置
_CRON_PARSED=false

parse_cron_config() {
    # 如果已解析，直接返回（避免重复日志和性能开销）
    [ "$_CRON_PARSED" = true ] && return 0
    
    set -f; set -- $CRON_EXP; set +f
    _pcc_min="$1"; _pcc_hour="$2"; _pcc_step=""
    
    # 类型 A: 固定时间 (M H * * *)
    if is_integer "$_pcc_min" && is_integer "$_pcc_hour"; then
        SCHED_TYPE="fixed"; SCHED_V1="$_pcc_hour"; SCHED_V2="$_pcc_min"
        [ "$LOG_MODE" != "NONE" ] && log_msg "策略: 每天 ${_pcc_hour}:${_pcc_min} 固定执行"
        _CRON_PARSED=true
        return 0
    fi
    
    # 类型 B: 间隔 (*/N * * * *)
    case "$_pcc_min" in \*/[0-9]*)
        _pcc_step="${_pcc_min#*/}"
        if is_integer "$_pcc_step" && [ "$_pcc_step" -gt 0 ] 2>/dev/null && [ "$_pcc_hour" = "*" ]; then
            SCHED_TYPE="interval"; SCHED_V1=$((_pcc_step * 60))
            [ "$LOG_MODE" != "NONE" ] && log_msg "策略: 每 ${_pcc_step} 分钟执行"
            _CRON_PARSED=true
            return 0
        fi
    ;; esac
    
    # 类型 C: 对齐 (0 */N * * *)
    case "$_pcc_hour" in \*/[0-9]*)
        _pcc_step="${_pcc_hour#*/}"
        if is_integer "$_pcc_step" && [ "$_pcc_step" -gt 0 ] 2>/dev/null; then
            SCHED_TYPE="align"; SCHED_V1="$_pcc_step"
            [ "$LOG_MODE" != "NONE" ] && log_msg "策略: 每 ${_pcc_step} 小时 [整点对齐]"
            _CRON_PARSED=true
            return 0
        fi
    ;; esac
    
    # 默认回退
    SCHED_TYPE="align"; SCHED_V1=4
    [ "$LOG_MODE" != "NONE" ] && log_err "配置不支持: $CRON_EXP [默认每4小时]"
    _CRON_PARSED=true
    return 1
}

calc_next_target() {
    _cnt_ts="$1"; _cnt_h="$2"; _cnt_m="$3"; _cnt_s="$4"
    
    # 输入参数验证
    if ! is_integer "$_cnt_ts" || ! is_integer "$_cnt_h" || ! is_integer "$_cnt_m" || ! is_integer "$_cnt_s"; then
        [ "$LOG_MODE" != "NONE" ] && log_err "calc_next_target: 无效的输入参数"
        return 1
    fi
    
    # 边界检查
    if [ "$_cnt_h" -lt 0 ] 2>/dev/null || [ "$_cnt_h" -gt 23 ] 2>/dev/null; then
        [ "$LOG_MODE" != "NONE" ] && log_err "calc_next_target: 小时值超出范围 (0-23): $_cnt_h"
        return 1
    fi
    if [ "$_cnt_m" -lt 0 ] 2>/dev/null || [ "$_cnt_m" -gt 59 ] 2>/dev/null; then
        [ "$LOG_MODE" != "NONE" ] && log_err "calc_next_target: 分钟值超出范围 (0-59): $_cnt_m"
        return 1
    fi
    if [ "$_cnt_s" -lt 0 ] 2>/dev/null || [ "$_cnt_s" -gt 59 ] 2>/dev/null; then
        [ "$LOG_MODE" != "NONE" ] && log_err "calc_next_target: 秒值超出范围 (0-59): $_cnt_s"
        return 1
    fi
    
    _cnt_passed=$((_cnt_h * 3600 + _cnt_m * 60 + _cnt_s))
    _cnt_today_start=$((_cnt_ts - _cnt_passed))
    
    case "$SCHED_TYPE" in
        "interval")
            _cnt_last=0
            [ -f "$STATE_FILE" ] && read -r _cnt_last < "$STATE_FILE" 2>/dev/null
            case "$_cnt_last" in *[!0-9]*) _cnt_last=0 ;; esac
            [ -z "$_cnt_last" ] && _cnt_last=$_cnt_ts
            [ "$_cnt_last" -gt "$_cnt_ts" ] 2>/dev/null && _cnt_last=$_cnt_ts
            
            # 验证 SCHED_V1 (间隔秒数)
            if ! is_integer "$SCHED_V1" || [ "$SCHED_V1" -le 0 ] 2>/dev/null; then
                [ "$LOG_MODE" != "NONE" ] && log_err "calc_next_target: 无效的间隔值: $SCHED_V1"
                echo "$_cnt_ts"
                return 1
            fi
            
            _cnt_next=$((_cnt_last + SCHED_V1))
            if [ "$_cnt_next" -le "$_cnt_ts" ] 2>/dev/null; then echo "$((_cnt_ts + 5))"; else echo "$_cnt_next"; fi
            ;;
        "align")
            _cnt_step="${SCHED_V1:-2}"
            # 除零保护 + 整数校验
            if ! is_integer "$_cnt_step" || [ "$_cnt_step" -eq 0 ] 2>/dev/null; then
                log_err "无效的对齐步长: ${_cnt_step}，使用当前时间"
                echo "$_cnt_ts"
                return 1
            fi
            # 步长范围检查 (1-24 小时)
            if [ "$_cnt_step" -lt 1 ] 2>/dev/null || [ "$_cnt_step" -gt 24 ] 2>/dev/null; then
                [ "$LOG_MODE" != "NONE" ] && log_err "calc_next_target: 对齐步长超出范围 (1-24): $_cnt_step"
                echo "$_cnt_ts"
                return 1
            fi
            _cnt_next_H=$(( ((_cnt_h / _cnt_step) + 1) * _cnt_step ))
            _cnt_offset=$((_cnt_next_H * 3600))
            echo "$((_cnt_today_start + _cnt_offset))"
            ;;
        "fixed")
            # 验证 SCHED_V1 (小时) 和 SCHED_V2 (分钟)
            if ! is_integer "$SCHED_V1" || ! is_integer "$SCHED_V2"; then
                [ "$LOG_MODE" != "NONE" ] && log_err "calc_next_target: 无效的固定时间值"
                echo "$_cnt_ts"
                return 1
            fi
            if [ "$SCHED_V1" -lt 0 ] 2>/dev/null || [ "$SCHED_V1" -gt 23 ] 2>/dev/null; then
                [ "$LOG_MODE" != "NONE" ] && log_err "calc_next_target: 固定小时超出范围 (0-23): $SCHED_V1"
                echo "$_cnt_ts"
                return 1
            fi
            if [ "$SCHED_V2" -lt 0 ] 2>/dev/null || [ "$SCHED_V2" -gt 59 ] 2>/dev/null; then
                [ "$LOG_MODE" != "NONE" ] && log_err "calc_next_target: 固定分钟超出范围 (0-59): $SCHED_V2"
                echo "$_cnt_ts"
                return 1
            fi
            _cnt_offset=$((SCHED_V1 * 3600 + SCHED_V2 * 60))
            _cnt_tar=$((_cnt_today_start + _cnt_offset))
            if [ "$_cnt_tar" -le "$_cnt_ts" ] 2>/dev/null; then echo "$((_cnt_tar + 86400))"; else echo "$_cnt_tar"; fi
            ;;
        *)
            [ "$LOG_MODE" != "NONE" ] && log_err "calc_next_target: 未知的调度类型: $SCHED_TYPE"
            echo "$_cnt_ts"
            return 1
            ;;
    esac
}

# 高级接口：获取下次运行时间（供 webui.sh 使用）
get_next_run_time() {
    # 动态读取最新的 CRON_EXP
    _gnrt_cron_exp=$(get_config_value "$MODDIR/service.sh" "CRON_EXP" 2>/dev/null)
    if [ -z "$_gnrt_cron_exp" ]; then
        # 读取失败，使用默认值
        _gnrt_cron_exp="0 */4 * * *"
    fi
    
    # 临时覆盖全局 CRON_EXP 变量（仅在此函数作用域内）
    _gnrt_old_cron_exp="$CRON_EXP"
    CRON_EXP="$_gnrt_cron_exp"
    
    # 强制重新解析配置（清除缓存）
    _CRON_PARSED=false
    
    # 获取当前时间数据
    _gnrt_time_data=$(date +'%s %H %M %S' 2>/dev/null)
    if [ -z "$_gnrt_time_data" ]; then
        [ "$LOG_MODE" != "NONE" ] && log_err "get_next_run_time: 时间获取失败"
        CRON_EXP="$_gnrt_old_cron_exp"  # 恢复原值
        return 1
    fi
    
    # 解析时间数据
    set -- $_gnrt_time_data
    _gnrt_ts="$1"; _gnrt_h="$2"; _gnrt_m="$3"; _gnrt_s="$4"
    
    # 标准化为整数（去除前导零，避免八进制解析）
    _gnrt_h="${_gnrt_h#0}"; _gnrt_h="${_gnrt_h#0}"; _gnrt_h="${_gnrt_h:-0}"
    _gnrt_m="${_gnrt_m#0}"; _gnrt_m="${_gnrt_m#0}"; _gnrt_m="${_gnrt_m:-0}"
    _gnrt_s="${_gnrt_s#0}"; _gnrt_s="${_gnrt_s#0}"; _gnrt_s="${_gnrt_s:-0}"
    
    # 解析 Cron 配置（设置 SCHED_TYPE/SCHED_V1/SCHED_V2）
    if ! parse_cron_config; then
        # 解析失败，返回安全默认值（当前时间 + 1 小时）
        CRON_EXP="$_gnrt_old_cron_exp"  # 恢复原值
        printf '%d' "$((_gnrt_ts + 3600))"
        return 1
    fi
    
    # 计算下次目标时间
    _gnrt_result=$(calc_next_target "$_gnrt_ts" "$_gnrt_h" "$_gnrt_m" "$_gnrt_s")
    
    # 恢复原 CRON_EXP 值（避免影响其他调用）
    CRON_EXP="$_gnrt_old_cron_exp"
    
    # 验证结果
    if [ -z "$_gnrt_result" ] || ! is_integer "$_gnrt_result"; then
        [ "$LOG_MODE" != "NONE" ] && log_err "get_next_run_time: 计算失败，使用默认值"
        # 回退：当前时间 + 1 小时
        printf '%d' "$((_gnrt_ts + 3600))"
        return 1
    fi
    
    # 返回计算结果
    printf '%d' "$_gnrt_result"
    return 0
}

# 公共函数：首次启动检查（统一 Sleep/Cron 行为）
run_first_time_check() {
    if [ ! -f "$STATE_FILE" ]; then
        log_msg "初始化: 首次安装，立即执行"
        
        if is_locked; then
            log_warn "首次任务跳过 - 锁存在"
            return 1
        fi
        
        # 写入锁
        if ! echo "$CURRENT_PID" > "$LOCK_FILE" 2>/dev/null; then
            log_err "无法创建锁文件: $LOCK_FILE"
            return 1
        fi
        
        # 更新状态
        if ! atomic_write_state "$(date +%s)"; then
            log_warn "状态文件更新失败"
        fi
        
        # 执行目标命令
        if [ -x "$TARGET_COMMAND" ]; then
            "$TARGET_COMMAND" < /dev/null >> "$LOG_FILE" 2>&1
            _rftc_ret=$?
            log_msg "<<< 首次任务完成 - Code: ${_rftc_ret}"
        else
            log_err "目标不存在: $TARGET_COMMAND"
        fi
        
        # 解锁
        rm -f "$LOCK_FILE" 2>/dev/null
        return 0
    fi
    return 1
}

# 统一任务触发检查器
try_run_task() {
    _trt_source="$1"
    _trt_time_data=$(date +'%s %H %M %S' 2>/dev/null)
    if [ -z "$_trt_time_data" ]; then
        log_warn "[$_trt_source] 时间获取失败，跳过本次调度"
        return 1
    fi
    set -- $_trt_time_data
    _trt_NOW_TS="$1"; _trt_NOW_H="$2"; _trt_NOW_M="$3"; _trt_NOW_S="$4"
    
    _trt_NOW_H="${_trt_NOW_H#0}"; _trt_NOW_H="${_trt_NOW_H#0}"; _trt_NOW_H="${_trt_NOW_H:-0}"
    _trt_NOW_M="${_trt_NOW_M#0}"; _trt_NOW_M="${_trt_NOW_M#0}"; _trt_NOW_M="${_trt_NOW_M:-0}"
    _trt_NOW_S="${_trt_NOW_S#0}"; _trt_NOW_S="${_trt_NOW_S#0}"; _trt_NOW_S="${_trt_NOW_S:-0}"
    
    parse_cron_config
    _trt_next_run=$(calc_next_target "$_trt_NOW_TS" "$_trt_NOW_H" "$_trt_NOW_M" "$_trt_NOW_S")
    if [ -z "$_trt_next_run" ] || ! is_integer "$_trt_next_run"; then
        log_warn "[$_trt_source] 时间计算失败，跳过本次调度"
        return 1
    fi
    _trt_wait_sec=$((_trt_next_run - _trt_NOW_TS))

    if [ "$_trt_wait_sec" -le 0 ]; then
        if is_locked; then
            [ "$LOG_MODE" = "INFO" ] && log_msg "[$_trt_source] 锁定中 [跳过]"
            return 0
        else
            log_msg "[$_trt_source] 触发任务 >>>"
            if ! echo "$CURRENT_PID" > "$LOCK_FILE" 2>/dev/null; then
                log_warn "[$_trt_source] 无法创建锁文件，跳过"
                return 1
            fi
            atomic_write_state "$(date +%s)"
            
            # 同步执行目标命令，日志追加到文件
            if [ -x "$TARGET_COMMAND" ]; then
                # 同步执行，日志追加
                "$TARGET_COMMAND" < /dev/null >> "$LOG_FILE" 2>&1
                _trt_ret=$?
                log_msg "[$_trt_source] 完成 [Code: $_trt_ret]"
            else
                log_err "[$_trt_source] 目标不存在: $TARGET_COMMAND"
            fi
            
            rm -f "$LOCK_FILE"
            return 0
        fi
    else
        echo "$_trt_wait_sec"
        return 1
    fi
}

# ==============================================================================
# PART 4: Source Guard (源码守卫)
# ==============================================================================
if [ "$__ROLE" = "source" ]; then return 0 2>/dev/null || exit 0; fi

# ==============================================================================
# PART 5: Worker 逻辑 (任务执行层)
# ==============================================================================
# 仅当角色为 Worker 时执行此块（由 Daemon 或 Cron 调用）

if [ "$__ROLE" = "worker" ]; then
    # 根据 LOG_MODE 决定日志输出
    if [ "$LOG_MODE" = "NONE" ]; then
        # LOG_MODE=NONE: 重定向到 /dev/null（仅错误日志通过 log_err 输出）
        exec > /dev/null 2>&1
    else
        # LOG_MODE=INFO/DEBUG: 重定向到日志文件
        if [ -f "$LOG_FILE" ] || touch "$LOG_FILE" 2>/dev/null; then
            exec >> "$LOG_FILE" 2>&1 || exec > /dev/null 2>&1
        else
            exec > /dev/null 2>&1
        fi
    fi
    
    if [ -x "$TARGET_COMMAND" ]; then
        "$TARGET_COMMAND" < /dev/null
    else
        log_err "[错误] 目标命令不存在: $TARGET_COMMAND"
    fi
    exit 0
fi

# ==============================================================================
# PART 6: Daemon 逻辑 (守护进程主循环)
# ==============================================================================
# 仅当角色为 Daemon 时执行此块 (已被 Bootloader 放入后台)

trap 'cleanup_scheduler' EXIT INT TERM HUP QUIT ABRT

# 守护进程日志初始化 - 使用统一的 init_log_output 函数
init_log_output

# 清理旧实例（防止多实例并发）
if [ -f "$SVC_PID_FILE" ]; then
    _old_pid=""
    read -r _old_pid < "$SVC_PID_FILE" 2>/dev/null
    
    # 日志记录：读取到的 PID
    [ "$LOG_MODE" != "NONE" ] && [ -n "$_old_pid" ] && log_msg "检测到 PID 文件 [PID: $_old_pid]"
    
    if [ -n "$_old_pid" ] && is_integer "$_old_pid" && [ -d "/proc/$_old_pid" ] && [ "$_old_pid" != "$CURRENT_PID" ]; then
        # 验证进程类型：必须包含模块绝对路径，防止误杀其他模块
        _old_cmd=$(read_cmdline "/proc/$_old_pid/cmdline")
        
        # 日志记录：cmdline 内容（用于诊断）
        [ "$LOG_MODE" != "NONE" ] && log_msg "进程 cmdline: $_old_cmd"
        
        case "$_old_cmd" in
            *"$MODDIR/service.sh"*|*"crond"*" -c $MODDIR"*|*"crond -c $MODDIR"*)
                log_msg "清理旧实例 [PID: $_old_pid, 匹配: 本模块进程]"
                kill "$_old_pid" 2>/dev/null
                sleep 1
                # 顽固进程强杀
                if [ -d "/proc/$_old_pid" ]; then
                    log_warn "进程未响应 SIGTERM，使用 SIGKILL [PID: $_old_pid]"
                    kill -9 "$_old_pid" 2>/dev/null
                fi
                ;;
            *)
                # 检测到 PID 复用，记录详细信息
                log_warn "跳过非本模块进程 [PID: $_old_pid]"
                log_warn "  -> 可能的 PID 复用场景"
                log_warn "  -> 进程 cmdline: $_old_cmd"
                log_warn "  -> 清理过期的 PID 文件"
                rm -f "$SVC_PID_FILE" 2>/dev/null
                ;;
        esac
    elif [ -n "$_old_pid" ] && is_integer "$_old_pid" && [ ! -d "/proc/$_old_pid" ]; then
        # 进程已不存在，清理过期的 PID 文件
        log_msg "旧进程已不存在 [PID: $_old_pid]，清理 PID 文件"
        rm -f "$SVC_PID_FILE" 2>/dev/null
    elif [ -n "$_old_pid" ] && ! is_integer "$_old_pid"; then
        # PID 文件包含无效值
        log_warn "PID 文件包含无效值: $_old_pid，清理 PID 文件"
        rm -f "$SVC_PID_FILE" 2>/dev/null
    fi
fi

# 写入 PID (关键: action.sh 依赖此文件来停止服务)
_pid_dir="${SVC_PID_FILE%/*}"
if [ ! -d "$_pid_dir" ]; then
    mkdir -p "$_pid_dir" 2>/dev/null || {
        log_err "❌ 无法创建PID目录: $_pid_dir"
        exit 1
    }
fi

if ! echo "$CURRENT_PID" > "$SVC_PID_FILE" 2>/dev/null; then
    log_err "❌ 无法写入PID文件: $SVC_PID_FILE [磁盘满/权限不足]"
    exit 1
fi

# 配置验证
validate_service_config() {
    # 验证 SCHEDULE_MODE
    case "$SCHEDULE_MODE" in
        sleep|cron) ;;
        *)
            log_err "致命错误: SCHEDULE_MODE=$SCHEDULE_MODE 无效，必须是 sleep 或 cron"
            exit 1
            ;;
    esac
    
    # 验证 LOG_MODE
    if ! validate_log_mode "$LOG_MODE"; then
        log_warn "LOG_MODE=$LOG_MODE 无效，使用默认值 INFO"
        LOG_MODE="INFO"
    fi
}

# 在 Daemon 启动前调用验证函数
validate_service_config

log_msg "=== 守护进程启动 [PID: $CURRENT_PID, Mode: $SCHEDULE_MODE] ==="

# 健壮性: 智能开机等待（区分开机/手动场景）
wait_for_boot() {
    # 读取系统运行时间
    _wfb_uptime=0
    if [ -r "/proc/uptime" ]; then
        read -r _wfb_uptime _ < /proc/uptime 2>/dev/null
        _wfb_uptime=${_wfb_uptime%%.*}  # 提取整数部分
    fi
    case "$_wfb_uptime" in *[!0-9]*) _wfb_uptime=0 ;; esac
    
    if [ "$_wfb_uptime" -lt 300 ] 2>/dev/null; then
        # 开机场景：系统运行时间 < 5分钟
        if [ "$(getprop sys.boot_completed 2>/dev/null)" = "1" ]; then
            log_msg "检测到系统已就绪 [uptime: ${_wfb_uptime}s]，快速启动"
            sleep 3
        else
            log_msg "检测到开机启动 [uptime: ${_wfb_uptime}s]，等待系统稳定"
            
            _wfb_cnt=0
            until [ "$(getprop sys.boot_completed 2>/dev/null)" = "1" ] || [ "$_wfb_cnt" -ge 60 ] 2>/dev/null; do
                sleep 2
                _wfb_cnt=$((_wfb_cnt + 1))
            done
            
            if [ "$_wfb_cnt" -ge 60 ] 2>/dev/null; then
                log_warn "等待开机超时，强制启动"
            else
                log_msg "开机广播已接收，额外缓冲 30秒"
                sleep 30
            fi
        fi
    else
        # 手动重启场景：系统已运行 > 5分钟
        log_msg "检测到手动重启 [uptime: ${_wfb_uptime}s]，快速启动"
    fi
}
wait_for_boot

# 开机清理锁（防止异常退出遗留的锁文件）
rm -f "$LOCK_FILE"

cleanup_scheduler() {
    trap - EXIT INT TERM HUP QUIT ABRT  # 防止递归调用
    
    log_msg "服务停止，清理资源"
    
    # 清理 crond 进程
    kill_by_pattern "crond -c $MODDIR/cron.d"
    
    # 清理文件资源
    rm -f "$LOCK_FILE" "$SVC_PID_FILE" "${STATE_FILE}.tmp" 2>/dev/null
    
    # 清理 Cron 配置
    rm -f "$MODDIR/cron.d/root" 2>/dev/null
    rmdir "$MODDIR/cron.d" 2>/dev/null
    
    exit 0
}

# --- 引擎实现 ---

# 引擎 1: Sleep (默认 - 推荐)
run_sleep_engine() {
    log_msg "启动 Sleep 模式 [Heartbeat: ${SLEEP_HEARTBEAT}s]"
    
    # 首次安装统一处理
    run_first_time_check
    
    # 预解析配置（parse_cron_config 内部有缓存机制，避免重复解析）
    parse_cron_config
    
    while true; do
        check_log_size
        _rse_wait_info=$(try_run_task "Sleep")
        _rse_wait_sec=0
        if is_integer "$_rse_wait_info"; then _rse_wait_sec="$_rse_wait_info"; fi
        
        if [ "$_rse_wait_sec" -gt 0 ] 2>/dev/null; then
            # 可读性日志：显示等待时间
            _rse_wait_min=$((_rse_wait_sec / 60))
            log_msg "待机: 下次运行约 ${_rse_wait_min} 分钟后..."
            
            # 智能分段休眠 (防止长时间 Sleep 导致进程僵死)
            while [ "$_rse_wait_sec" -gt 0 ] 2>/dev/null; do
                _rse_chunk=$SLEEP_HEARTBEAT
                [ "$_rse_wait_sec" -lt "$SLEEP_HEARTBEAT" ] 2>/dev/null && _rse_chunk="$_rse_wait_sec"
                sleep "$_rse_chunk"
                break # 醒来后强制重算时间，应对系统休眠偏差
            done
        else
            sleep 5
        fi
    done
}

# 引擎 2: Cron (系统定时 - 可选)
run_cron_engine() {
    if ! command -v crond >/dev/null 2>&1; then
        log_err "Crond 缺失，回退 Sleep"
        run_sleep_engine
        return
    fi
    log_msg "启动 Cron 模式"
    
    # 首次安装统一处理
    run_first_time_check
    
    _rce_cron_dir="$MODDIR/cron.d"
    mkdir -p "$_rce_cron_dir" 2>/dev/null
    
    # 构造命令: 调用本脚本的 Worker 角色，保持逻辑统一
    # 这样 Cron 触发时，也走 Worker 逻辑，享受统一的锁和日志管理
    _rce_cmd="/system/bin/sh $MODDIR/service.sh --worker"
    
    echo "$CRON_EXP $_rce_cmd" > "$_rce_cron_dir/root"
    chmod 0600 "$_rce_cron_dir/root"
    
    kill_by_pattern "crond -c $_rce_cron_dir"
    crond -c "$_rce_cron_dir" -b -L /dev/null
    
    # 检测进程启动（3次重试）
    _rce_retry=0; _rce_crond_pid=""
    while [ "$_rce_retry" -lt 3 ] 2>/dev/null; do
        sleep 1
        
        # 每次循环重置变量（防止残留值干扰）
        _rce_crond_pid=""
        
        # 策略 1: 使用 pgrep
        if command -v pgrep >/dev/null 2>&1; then
            _rce_crond_pid=$(pgrep -f "crond -c $_rce_cron_dir" 2>/dev/null)
            # 提取第一行（处理多匹配）
            case "$_rce_crond_pid" in
                *$'\n'*) _crond_pid="${_crond_pid%%$'\n'*}" ;;
            esac
            # 仅保留数字（清理异常字符）
            _rce_crond_pid="${_rce_crond_pid%%[!0-9]*}"
        fi
        
        # 策略 2: 回退到纯 Shell 遍历 /proc
        if [ -z "$_rce_crond_pid" ]; then
            _rce_p=""; _rce_pcmd=""
            for _rce_p in /proc/[0-9]*; do
                [ -d "$_rce_p" ] || continue
                _rce_p=${_rce_p##*/}
                
                case "$_rce_p" in *[!0-9]*) continue ;; esac
                
                _rce_pcmd=$(read_cmdline "/proc/$_rce_p/cmdline") || continue
                case "$_rce_pcmd" in
                    *"crond"*" -c $_rce_cron_dir"*|*"crond -c $_rce_cron_dir"*)
                        _rce_crond_pid="$_rce_p"
                        break
                        ;;
                esac
            done
        fi
        
        # 找到有效 PID，立即返回
        if [ -n "$_rce_crond_pid" ] && [ -d "/proc/$_rce_crond_pid" ]; then
            log_msg "Crond 引擎已启动 [PID: $_rce_crond_pid]"
            # 更新 PID 文件为 crond 进程，使 action.sh 能够管理 Cron 模式服务
            if ! echo "$_rce_crond_pid" > "$SVC_PID_FILE" 2>/dev/null; then
                log_warn "PID 文件写入失败: $SVC_PID_FILE"
            fi
            
            # Cron 模式设计哲学：托管给系统 crond，守护进程退出
            log_msg "Cron 引擎已托管，守护进程退出"
            
            # 禁用 trap，避免 cleanup_scheduler 删除 PID 文件
            # Cron 模式下，PID 文件指向 crond 进程，必须保留
            trap - EXIT INT TERM HUP QUIT ABRT
            
            exit 0
        fi
        
        _rce_retry=$((_rce_retry + 1))
    done
    
    # 启动失败，回退
    log_err "Crond 启动超时，回退 Sleep 模式"
    run_sleep_engine
}

# 权限修正
chmod 755 "$TARGET_COMMAND" 2>/dev/null

# 启动引擎
case "$SCHEDULE_MODE" in
    "cron") run_cron_engine ;;
    *)       run_sleep_engine ;;
esac
