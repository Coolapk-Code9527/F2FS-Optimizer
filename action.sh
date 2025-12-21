#!/system/bin/sh
# ==============================================================================
# F2FS-Optimizer - 手动触发脚本
# 用途: 立即执行优化任务 + 自动恢复调度服务
# 参数: webui - 任务完成后启动 Web UI 配置界面（可选）
# ==============================================================================

# ==============================================================================
# PART 1: 加载依赖
# ==============================================================================

# 1. 最小化路径解析（仅用于定位 service.sh）
_action_script_dir="${0%/*}"
case "$_action_script_dir" in
    /*) SERVICE_SCRIPT="$_action_script_dir/service.sh" ;;
    *)  SERVICE_SCRIPT="$(cd "$_action_script_dir" 2>/dev/null && pwd)/service.sh" || SERVICE_SCRIPT="/data/adb/modules/f2fs_optimizer/service.sh" ;;
esac

# 2. 加载 service.sh 共享函数
if [ ! -f "$SERVICE_SCRIPT" ]; then
    printf '❌ 致命: 找不到 %s\n' "$SERVICE_SCRIPT" >&2
    exit 1
fi

. "$SERVICE_SCRIPT" --source-only

# 3. 调用共享初始化函数
init_moddir "$0" || { printf '❌ 致命: 无法初始化模块目录\n' >&2; exit 1; }
init_busybox || { printf '❌ 致命: 找不到 Busybox\n' >&2; exit 1; }

# 常量定义
F2FSOPT_LOCK_DIR="/data/local/tmp/f2fsopt.lock.d"
F2FSOPT_PID_FILE="$F2FSOPT_LOCK_DIR/pid"

# ==============================================================================
# Web UI 启动控制配置
# ==============================================================================

# Web UI 自动启动模式
# 说明: 控制手动触发任务后是否自动启动 Web UI 配置界面
# 可用值:
#   - true:  任务完成后自动启动 Web UI（适合需要频繁配置的用户）
#   - false: 永不自动启动 Web UI（适合仅需执行任务的场景）
#   - ask:   通过音量键交互式选择（推荐，灵活性最高）
# 默认值: ask
# 示例:
#   AUTO_START_WEBUI="true"   # 总是自动启动
#   AUTO_START_WEBUI="false"  # 从不启动
#   AUTO_START_WEBUI="ask"    # 每次询问（默认）
# 注意: 移除 readonly 以支持 Web UI 动态修改
AUTO_START_WEBUI="true"

# 音量键选择超时时间（秒）
# 说明: 当 AUTO_START_WEBUI="ask" 时，等待用户按键的最长时间
# 范围: 1-60 秒
# 默认值: 10 秒
# 超时后执行默认操作: 跳过 Web UI 启动
# 音量键操作:
#   [音量+] 启动 Web UI
#   [音量-] 跳过
#   [电源键] 退出脚本
# 示例:
#   WEBUI_PROMPT_TIMEOUT=5    # 5 秒超时（快速决策）
#   WEBUI_PROMPT_TIMEOUT=15   # 15 秒超时（充裕时间）
#   WEBUI_PROMPT_TIMEOUT=10   # 10 秒超时（默认）
# 注意: 移除 readonly 以支持 Web UI 动态修改
WEBUI_PROMPT_TIMEOUT=10

# ==============================================================================
# PART 2: 清理函数与信号处理
# ==============================================================================

# 清理函数：确保异常退出时资源被正确清理
_action_cleanup() {
    # 防止重复执行
    trap - EXIT INT TERM HUP QUIT ABRT
    
    # 清理锁文件
    [ -n "$LOCK_FILE" ] && rm -f "$LOCK_FILE" 2>/dev/null
    
    # 清理 f2fsopt 锁目录
    rm -rf "$F2FSOPT_LOCK_DIR" 2>/dev/null
    
    # 清理可能残留的临时文件
    rm -f "$MODDIR/module.prop.tmp" 2>/dev/null
}

# 注册信号处理 (包含 ABRT 信号)
trap '_action_cleanup' EXIT INT TERM HUP QUIT ABRT

# ==============================================================================
# PART 3: 本地函数 (覆盖/扩展 service.sh)
# ==============================================================================

# 重定义日志函数 (添加 [手动] 标记)
log_msg() {
    [ "$LOG_MODE" != "NONE" ] && printf '%s I %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG_FILE"
}

log_warn() {
    [ "$LOG_MODE" != "NONE" ] && printf '%s W %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG_FILE"
}

log_err() {
    printf '%s E %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG_FILE"
}

# UI 输出 (屏幕 + 日志)
ui_print() {
    _up_msg="$1"
    printf '- %s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$_up_msg"
    log_msg "[手动] $_up_msg"
    # 日志轮替
    command -v check_log_size >/dev/null 2>&1 && check_log_size
}

# ==============================================================================
# Web UI 启动控制函数
# ==============================================================================

# 验证配置变量的有效性
validate_webui_config() {
    _vwc_has_error=0
    
    # 验证 AUTO_START_WEBUI
    case "$AUTO_START_WEBUI" in
        true|false|ask) 
            # 有效值，无需操作
            ;;
        *)
            log_warn "[配置] AUTO_START_WEBUI 值无效 ($AUTO_START_WEBUI)，使用默认值 'ask'"
            AUTO_START_WEBUI="ask"
            _vwc_has_error=1
            ;;
    esac
    
    # 验证 WEBUI_PROMPT_TIMEOUT
    if ! is_integer "$WEBUI_PROMPT_TIMEOUT"; then
        log_warn "[配置] WEBUI_PROMPT_TIMEOUT 不是整数 ($WEBUI_PROMPT_TIMEOUT)，使用默认值 10"
        WEBUI_PROMPT_TIMEOUT=10
        _vwc_has_error=1
    elif [ "$WEBUI_PROMPT_TIMEOUT" -lt 1 ]; then
        log_warn "[配置] WEBUI_PROMPT_TIMEOUT 小于 1 ($WEBUI_PROMPT_TIMEOUT)，使用默认值 10"
        WEBUI_PROMPT_TIMEOUT=10
        _vwc_has_error=1
    elif [ "$WEBUI_PROMPT_TIMEOUT" -gt 60 ]; then
        log_warn "[配置] WEBUI_PROMPT_TIMEOUT 大于 60 ($WEBUI_PROMPT_TIMEOUT)，使用默认值 10"
        WEBUI_PROMPT_TIMEOUT=10
        _vwc_has_error=1
    fi
    
    return "$_vwc_has_error"
}

# 监听音量键事件（带超时）
wait_for_key_event() {
    _wfke_timeout="$1"
    
    log_msg "[音量键] 开始监听按键事件 [超时: ${_wfke_timeout}秒]"
    
    # 检查 timeout 命令是否存在
    if ! command -v timeout >/dev/null 2>&1; then
        log_warn "[音量键] 系统缺少 timeout 命令，跳过交互"
        return 0
    fi
    
    # 清空输入缓冲区（尝试性）
    if command -v stty >/dev/null 2>&1; then
        stty -echo -icanon min 1 time 0 2>/dev/null
    fi
    
    # 捕获按键事件
    _wfke_key_event=$(timeout "$_wfke_timeout" getevent -lqc 1 2>&1)
    _wfke_ret=$?
    
    # 恢复终端状态
    if command -v stty >/dev/null 2>&1; then
        stty sane 2>/dev/null
    fi
    
    printf '\n'
    
    # 调试输出
    if [ -n "$_wfke_key_event" ]; then
        log_msg "[音量键] 原始事件: $_wfke_key_event"
    else
        log_msg "[音量键] 未捕获到事件 (退出码: $_wfke_ret)"
    fi
    
    # 解析结果 - 参考 参考.sh 的简单匹配
    case "$_wfke_key_event" in
        *"KEY_VOLUMEUP"*|*"0073"*)
            log_msg "[音量键] 检测到音量+"
            return 1  # 信号 1: 启动 WebUI
            ;;
        *"KEY_POWER"*|*"0074"*)
            log_msg "[音量键] 检测到电源键"
            return 2  # 信号 2: 退出脚本
            ;;
        *"KEY_VOLUMEDOWN"*|*"0072"*)
            log_msg "[音量键] 检测到音量-"
            return 0  # 信号 0: 默认行为
            ;;
        *)
            if [ "$_wfke_ret" -eq 124 ]; then
                log_msg "[音量键] 等待超时"
            else
                log_msg "[音量键] 未检测到操作"
            fi
            return 0  # 默认行为
            ;;
    esac
}

# 显示音量键选择界面并处理用户输入
prompt_webui_choice() {
    ui_print ""
    ui_print "=============================="
    ui_print "是否启动 Web UI 配置界面？"
    ui_print ""
    ui_print "  [音量+] 启动 Web UI"
    ui_print "  [音量-] 跳过"
    ui_print "  [电源键] 退出脚本"
    ui_print ""
    ui_print "  超时时间: ${WEBUI_PROMPT_TIMEOUT} 秒"
    ui_print "  默认操作: 跳过"
    ui_print "=============================="
    
    # 检查 getevent 可用性
    if ! command -v getevent >/dev/null 2>&1; then
        ui_print "⚠️ getevent 命令不可用，跳过音量键选择"
        log_warn "[音量键] getevent 不可用，回退到默认行为"
        return 1
    fi
    
    # 等待按键（直接使用返回码）
    wait_for_key_event "$WEBUI_PROMPT_TIMEOUT"
    _pwc_choice=$?
    
    # 处理结果（基于返回码）
    case "$_pwc_choice" in
        1)
            ui_print ""
            ui_print "✅ 您选择了: 启动 Web UI"
            log_msg "[音量键] 用户选择启动 Web UI"
            return 0
            ;;
        2)
            ui_print ""
            ui_print "🚪 您选择了: 退出"
            log_msg "[音量键] 用户选择退出脚本"
            return 2
            ;;
        0|*)
            ui_print ""
            ui_print "✅ 执行默认操作: 跳过"
            log_msg "[音量键] 用户选择跳过或超时"
            return 1
            ;;
    esac
}

# 决策函数：根据配置和用户选择决定是否启动 Web UI
should_start_webui() {
    # 验证配置
    validate_webui_config
    
    case "$AUTO_START_WEBUI" in
        true)
            log_msg "[Web UI] 配置为自动启动"
            return 0
            ;;
        false)
            log_msg "[Web UI] 配置为不启动"
            return 1
            ;;
        ask)
            log_msg "[Web UI] 进入交互式选择"
            prompt_webui_choice
            return $?
            ;;
        *)
            # 不应该到达这里（validate_webui_config 已处理）
            log_err "[Web UI] 未知配置值，跳过启动"
            return 1
            ;;
    esac
}

# ==============================================================================
# PART 2.5: 参数处理
# ==============================================================================

# 检查是否为配置应用模式
_APPLY_CONFIG_MODE=false
if [ "$1" = "--apply-config" ]; then
    _APPLY_CONFIG_MODE=true
    log_msg "[配置应用] 配置应用模式启动"
fi

# ==============================================================================
# PART 3: 停止旧服务
# ==============================================================================

if [ "$_APPLY_CONFIG_MODE" = true ]; then
    # 配置应用模式：只重启服务，不停止
    ui_print "配置应用模式：重启调度服务..."
    
    # 3.1 停止调度器
    if [ -f "$SVC_PID_FILE" ]; then
        read -r _act_pid < "$SVC_PID_FILE" 2>/dev/null
        if [ -n "$_act_pid" ] && is_integer "$_act_pid" && [ -d "/proc/$_act_pid" ]; then
            ui_print "停止调度服务 [PID: $_act_pid]..."
            kill "$_act_pid" 2>/dev/null
            sleep 1
            [ -d "/proc/$_act_pid" ] && kill -9 "$_act_pid" 2>/dev/null
        fi
        rm -f "$SVC_PID_FILE"
    fi
    
    # 3.2 深度清理 (合并为单次调用，使用 OR 模式)
    if command -v pgrep >/dev/null 2>&1; then
        for _act_clean_pid in $(pgrep -f "crond -c $MODDIR/cron.d\|$MODDIR/service.sh" 2>/dev/null); do
            [ "$_act_clean_pid" != "$$" ] && kill "$_act_clean_pid" 2>/dev/null
        done
    else
        # 回退: 使用 kill_by_pattern (仅当 pgrep 不可用)
        kill_by_pattern "crond -c $MODDIR/cron.d"
        kill_by_pattern "$MODDIR/service.sh"
    fi
    
    # 3.3 重启服务
    ui_print "正在重启调度服务..."
    chmod 755 "$SERVICE_SCRIPT"
    /system/bin/sh "$SERVICE_SCRIPT" >/dev/null 2>&1 &
    
    # 等待服务启动
    sleep 3
    
    ui_print "✅ 调度服务已重启"
else
    # 普通模式：停止所有服务和任务
    ui_print "检查后台服务..."
    
    # 3.1 停止调度器
    if [ -f "$SVC_PID_FILE" ]; then
        read -r _act_pid < "$SVC_PID_FILE" 2>/dev/null
        if [ -n "$_act_pid" ] && is_integer "$_act_pid" && [ -d "/proc/$_act_pid" ]; then
            ui_print "停止调度服务 [PID: $_act_pid]..."
            kill "$_act_pid" 2>/dev/null
            sleep 1
            [ -d "/proc/$_act_pid" ] && kill -9 "$_act_pid" 2>/dev/null
        fi
        rm -f "$SVC_PID_FILE"
    fi
    
    # 3.2 停止正在运行的 f2fsopt 任务
    if [ -f "$F2FSOPT_PID_FILE" ]; then
        read -r _act_task_pid < "$F2FSOPT_PID_FILE" 2>/dev/null
        if [ -n "$_act_task_pid" ] && is_integer "$_act_task_pid" && [ -d "/proc/$_act_task_pid" ]; then
            ui_print "⚠️ 发现后台任务 [PID: $_act_task_pid]"
            ui_print "正在终止..."
            kill "$_act_task_pid" 2>/dev/null
            sleep 1
            [ -d "/proc/$_act_task_pid" ] && kill -9 "$_act_task_pid" 2>/dev/null
        fi
    fi
    
    # 3.3 深度清理残留进程
    ui_print "深度清理残留进程..."
    if command -v pgrep >/dev/null 2>&1; then
        for _act_clean_pid in $(pgrep -f "crond -c $MODDIR/cron.d\|$MODDIR/service.sh\|f2fsopt" 2>/dev/null); do
            [ "$_act_clean_pid" != "$$" ] && kill "$_act_clean_pid" 2>/dev/null
        done
    else
        # 回退: 使用 kill_by_pattern (仅当 pgrep 不可用)
        kill_by_pattern "crond -c $MODDIR/cron.d"
        kill_by_pattern "$MODDIR/service.sh"
        kill_by_pattern "f2fsopt"
    fi
    
    # 清理锁
    rm -rf "$F2FSOPT_LOCK_DIR" 2>/dev/null
    rm -f "$LOCK_FILE" 2>/dev/null
fi

# ==============================================================================
# PART 4: 执行任务
# ==============================================================================

# 检测模块状态
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

_act_ret=0
if [ -x "$TARGET_COMMAND" ]; then
    # 创建锁文件 (使用当前进程ID)
    if ! printf '%s\n' "$CURRENT_PID" > "$LOCK_FILE" 2>/dev/null; then
        ui_print "⚠️ 无法创建锁文件，跳过执行"
        exit 1
    fi
    
    # 执行任务
    if command -v tee >/dev/null 2>&1; then
        "$TARGET_COMMAND" 2>&1 < /dev/null | tee -a "$LOG_FILE"
        _act_ret=$?
    else
        "$TARGET_COMMAND" < /dev/null
        _act_ret=$?
    fi
    
    rm -f "$LOCK_FILE"
    
    # 更新状态
    if [ -n "$STATE_FILE" ]; then
        if ! atomic_write_state "$(date +%s)"; then
            ui_print "⚠️ 状态文件更新失败"
        fi
    fi
    
    printf '%s\n' "------------------------------"
    if [ "$_act_ret" -eq 0 ]; then
        ui_print "✅ 执行成功"
    else
        ui_print "❌ 执行失败 [Code: $_act_ret]"
        [ -n "$LOG_FILE" ] && printf '   日志: %s\n' "$LOG_FILE"
    fi
else
    ui_print "❌ 错误: 目标不可执行 ($TARGET_COMMAND)"
    _act_ret=1
fi

# ==============================================================================
# PART 5: 重启服务
# ==============================================================================

if [ "$_APPLY_CONFIG_MODE" = false ]; then
    # 普通模式：重启服务
    ui_print "正在重启调度服务..."
    chmod 755 "$SERVICE_SCRIPT"
    
    /system/bin/sh "$SERVICE_SCRIPT" >/dev/null 2>&1 &
    
    # 智能等待：最多 10 秒，每秒检查一次
    _act_wait_count=0
_act_max_wait=10
_act_service_ready=false

while [ "$_act_wait_count" -lt "$_act_max_wait" ]; do
    sleep 1
    _act_wait_count=$((_act_wait_count + 1))
    
    if [ -f "$SVC_PID_FILE" ]; then
        read -r _act_new_pid < "$SVC_PID_FILE" 2>/dev/null
        if [ -n "$_act_new_pid" ] && is_integer "$_act_new_pid" && [ -d "/proc/$_act_new_pid" ]; then
            _act_service_ready=true
            break
        fi
    fi
done

# 验证启动结果
if [ "$_act_service_ready" = true ]; then
    ui_print "✅ 服务已恢复 [PID: $_act_new_pid, 耗时: ${_act_wait_count}s]"
elif [ -f "$SVC_PID_FILE" ]; then
    read -r _act_new_pid < "$SVC_PID_FILE" 2>/dev/null
    ui_print "⚠️ 服务启动异常 [PID 文件存在但进程不存在]"
else
    ui_print "⚠️ 服务响应超时 [${_act_max_wait}秒内未创建 PID 文件]"
    ui_print "   提示: 系统可能正在开机初始化，请稍后重试"
fi

fi  # 结束 PART 5 的 if [ "$_APPLY_CONFIG_MODE" = false ]

printf '%s\n' "=============================="

# ==============================================================================
# PART 6: 启动 Web UI（可选）
# ==============================================================================

# 配置应用模式：跳过 Web UI 启动
if [ "$_APPLY_CONFIG_MODE" = true ]; then
    ui_print "配置应用完成"
    exit 0
fi

# 决策：是否启动 Web UI
should_start_webui
_ssw_ret=$?

case "$_ssw_ret" in
    0)
        # 用户选择启动或配置为自动启动
        ui_print "正在启动 Web UI..."
        ;;
    1)
        # 用户选择跳过或配置为不启动
        ui_print "跳过 Web UI 启动"
        ui_print ""
        ui_print "=============================="
        exit 0
        ;;
    2)
        # 用户选择退出脚本
        ui_print "用户选择退出，脚本结束"
        ui_print ""
        ui_print "=============================="
        exit 0
        ;;
esac

# 检查 webui.sh 是否存在
if [ ! -f "$MODDIR/webui.sh" ]; then
    ui_print "❌ 错误: 找不到 webui.sh"
    exit 1
fi

chmod 755 "$MODDIR/webui.sh" 2>/dev/null

# 后台启动 Web UI (非阻塞)
nohup /system/bin/sh "$MODDIR/webui.sh" >/dev/null 2>&1 &
_webui_pid=$!

# 智能等待：最多 5 秒，检查进程和端口
_webui_wait=0
_webui_max_wait=5
_webui_started=false

while [ "$_webui_wait" -lt "$_webui_max_wait" ]; do
    sleep 1
    _webui_wait=$((_webui_wait + 1))
    
    # 检查主进程是否存活
    if [ ! -d "/proc/$_webui_pid" ]; then
        ui_print "⚠️ Web UI 进程已退出，可能启动失败"
        ui_print "   提示: 检查 Busybox httpd 是否可用"
        break
    fi
    
    # 检查 httpd 是否启动（通过检查端口占用或端口文件）
    if command -v netstat >/dev/null 2>&1; then
        # 检查 9527-9546 端口范围
        if netstat -tuln 2>/dev/null | grep -q ':95[2-4][0-9] '; then
            _webui_started=true
            break
        fi
    fi
    
    # 回退：检查端口文件是否已创建
    if [ -f "$MODDIR/webui.port" ]; then
        _webui_started=true
        break
    fi
done

# 显示启动结果
if [ "$_webui_started" = true ]; then
    # 尝试读取实际端口
    _webui_port=""
    if [ -f "$MODDIR/webui.port" ]; then
        read -r _webui_port < "$MODDIR/webui.port" 2>/dev/null
    fi
    
    ui_print "✅ Web UI 已在后台启动 (耗时 ${_webui_wait}s)"
    ui_print "   请在浏览器中访问配置界面"
    if [ -n "$_webui_port" ] && is_integer "$_webui_port"; then
        ui_print "   地址: http://127.0.0.1:${_webui_port}"
    else
        ui_print "   地址: http://127.0.0.1:9527 (默认端口范围 9527-9546)"
    fi
elif [ -d "/proc/$_webui_pid" ]; then
    ui_print "⚠️ Web UI 进程运行中，但端口未就绪"
    ui_print "   提示: 可能需要更多时间初始化"
    ui_print "   默认端口范围: 9527-9546"
else
    ui_print "⚠️ Web UI 启动失败"
    ui_print "   提示: 请检查 service.log 或手动运行 webui.sh"
fi

ui_print ""
ui_print "=============================="
exit 0
