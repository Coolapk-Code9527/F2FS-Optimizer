#!/system/bin/sh
# ==============================================================================
# F2FS-Optimizer - 轻量级 Web UI
# ==============================================================================

# ==============================================================================
# PART 0: 全局初始化
# ==============================================================================

# 1. 最小化路径解析（仅用于定位 service.sh）
_webui_script_dir="${0%/*}"
case "$_webui_script_dir" in
    /*) SERVICE_SCRIPT="$_webui_script_dir/service.sh" ;;
    *)  SERVICE_SCRIPT="$(cd "$_webui_script_dir" 2>/dev/null && pwd)/service.sh" || SERVICE_SCRIPT="/data/adb/modules/f2fs_optimizer/service.sh" ;;
esac

# 2. 加载 service.sh 共享函数
if [ ! -f "$SERVICE_SCRIPT" ]; then
    printf '致命错误: 找不到 service.sh\n' >&2
    exit 1
fi

. "$SERVICE_SCRIPT" --source-only

# 3. 调用共享初始化函数
init_moddir "$0" || { printf '致命错误: 无法初始化模块目录\n' >&2; exit 1; }
init_busybox || { printf '致命错误: 找不到 Busybox\n' >&2; exit 1; }

# 4. 角色分发 (单文件多态架构)
case "$1" in
    --lib-mode)    MODE="lib" ;;
    --daemon-mode) MODE="daemon" ;;
    *)             MODE="main" ;;
esac

# 4. 共享常量 (使用中间变量避免 $$ 被格式化工具处理)
_WEBUI_PID=$$
WEBUI_TMP_DIR="${MODDIR}/.webui_tmp"
WEBROOT="${WEBUI_TMP_DIR}/webroot_${_WEBUI_PID}"
LAST_ACCESS_FILE="${WEBUI_TMP_DIR}/access_${_WEBUI_PID}"
LOCK_DIR="${MODDIR}/.config_lock"
# WebUI 专用配置（可通过 API 修改）
WEBUI_TIMEOUT="${WEBUI_TIMEOUT:-300}"   # 默认 5 分钟无操作自动退出
HEARTBEAT_SEC="${HEARTBEAT_SEC:-30}"    # 心跳检测间隔（防止 Doze 僵死）

# 兼容性: 确保 TIMEOUT_SEC 使用 WEBUI_TIMEOUT
TIMEOUT_SEC="$WEBUI_TIMEOUT"


# ==============================================================================
# PART 1: 工具函数库 (所有模式共享)
# ==============================================================================

# 1.0 读取 /proc/PID/cmdline 并转换 NULL 字节为空格
read_cmdline() {
    _rc_file="$1"
    [ ! -f "$_rc_file" ] && return 1
    
    # 策略 1: 使用 tr 命令（继承自 service.sh 的 Busybox 代理或系统 tr）
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

# 1.1 配置值读取
get_config_value() {
    _gcv_file="$1"
    _gcv_key="$2"
    _gcv_line=""
    _gcv_val=""
    
    # 验证文件存在
    [ -f "$_gcv_file" ] || return 1
    
    # 逐行读取文件
    while IFS= read -r _gcv_line || [ -n "$_gcv_line" ]; do
        # 跳过空行
        [ -z "$_gcv_line" ] && continue
        
        # 跳过纯注释行
        case "$_gcv_line" in '#'*) continue ;; esac
        
        # 匹配配置键（支持 KEY=, readonly KEY=, export KEY=）
        case "$_gcv_line" in
            "${_gcv_key}="*|"readonly ${_gcv_key}="*|"export ${_gcv_key}="*)
                # 提取等号后的值
                _gcv_val="${_gcv_line#*=}"
                
                # 去除引号（双引号或单引号）
                case "$_gcv_val" in
                    \"*)
                        # 双引号包裹：去除首个双引号，然后去除到第一个双引号之间的内容
                        _gcv_val="${_gcv_val#\"}"
                        _gcv_val="${_gcv_val%%\"*}"
                        ;;
                    \'*)
                        # 单引号包裹：去除首个单引号，然后去除到第一个单引号之间的内容
                        _gcv_val="${_gcv_val#\'}"
                        _gcv_val="${_gcv_val%%\'*}"
                        ;;
                    *)
                        # 无引号：先去除行尾注释（仅当 # 前有空白时）
                        case "$_gcv_val" in
                            *[' 	']#*)
                                # 找到最后一个 "空白+#" 组合并去除之后的内容
                                while case "$_gcv_val" in *[' 	']#*) true;; *) false;; esac; do
                                    _gcv_val="${_gcv_val%%[' 	']#*}"
                                done
                                ;;
                        esac
                        
                        # 去除首尾空白字符
                        # 去除前导空白
                        while case "$_gcv_val" in [' 	']*) true;; *) false;; esac; do
                            _gcv_val="${_gcv_val#?}"
                        done
                        # 去除尾随空白
                        while case "$_gcv_val" in *[' 	']) true;; *) false;; esac; do
                            _gcv_val="${_gcv_val%?}"
                        done
                        ;;
                esac
                
                # 输出处理后的值
                printf '%s' "$_gcv_val"
                return 0
                ;;
        esac
    done < "$_gcv_file"
    
    # 键不存在
    return 1
}

# 1.2 JSON 字符串转义 (纯 Shell 实现)
json_escape() {
    _je_in="$1"; _je_out=""
    while [ -n "$_je_in" ]; do
        _je_char="${_je_in%"${_je_in#?}"}"; _je_in="${_je_in#?}"
        case "$_je_char" in
            '"')  _je_out="${_je_out}\\\"" ;;
            '\\') _je_out="${_je_out}\\\\" ;;
            *)    _je_out="${_je_out}${_je_char}" ;;
        esac
    done
    printf '%s' "$_je_out"
}

# 1.3 完整的锁获取函数
acquire_config_lock() {
    _acl_retry=0
    _acl_max_retry=3
    _acl_pid_file="$LOCK_DIR/pid"
    
    while [ "$_acl_retry" -lt "$_acl_max_retry" ]; do
        # 原子操作：mkdir 成功即获取锁
        if mkdir "$LOCK_DIR" 2>/dev/null; then
            # 成功获取锁，写入 PID
            if ! echo "$_WEBUI_PID" > "$_acl_pid_file" 2>/dev/null; then
                # PID 文件写入失败，清理锁目录
                rmdir "$LOCK_DIR" 2>/dev/null
                return 1
            fi
            return 0
        fi
        
        # 锁已存在，验证锁的有效性
        
        # 1. 验证 PID 文件完整性
        if [ ! -f "$_acl_pid_file" ]; then
            # PID 文件不存在，可能正在创建中，等待后重试
            sleep 1
            # 再次检查，如果仍然不存在，清理不完整的锁
            if [ ! -f "$_acl_pid_file" ]; then
                rmdir "$LOCK_DIR" 2>/dev/null
            fi
            _acl_retry=$((_acl_retry + 1))
            continue
        fi
        
        # 2. 读取并验证 PID
        _acl_pid=""
        read -r _acl_pid < "$_acl_pid_file" 2>/dev/null
        
        # 3. PID 格式验证
        if ! is_integer "$_acl_pid"; then
            # PID 格式无效，清理陈旧锁
            rm -rf "$LOCK_DIR" 2>/dev/null
            _acl_retry=$((_acl_retry + 1))
            continue
        fi
        
        # 4. 进程存活检查
        if [ ! -d "/proc/$_acl_pid" ]; then
            # 进程已死亡，清理陈旧锁
            rm -rf "$LOCK_DIR" 2>/dev/null
            _acl_retry=$((_acl_retry + 1))
            continue
        fi
        
        # 5. 精确匹配进程名
        _acl_cmd=$(read_cmdline "/proc/$_acl_pid/cmdline")
        case "$_acl_cmd" in
            *"/webui.sh"*|*"webui.sh"*)
                # 确实是 webui.sh 在运行，锁有效
                return 1
                ;;
            *)
                # PID 被复用，清理陈旧锁
                rm -rf "$LOCK_DIR" 2>/dev/null
                _acl_retry=$((_acl_retry + 1))
                continue
                ;;
        esac
    done
    
    # 重试耗尽
    return 1
}

# 1.4 释放配置锁
release_config_lock() {
    rm -rf "$LOCK_DIR" 2>/dev/null
}

# 1.5 原子配置写入
set_config_atomic() {
    _sca_file="$1"; _sca_key="$2"; _sca_val="$3"
    _sca_tmp="${_sca_file}.tmp.${_WEBUI_PID}"
    _sca_found=false; _sca_prefix=""
    [ ! -f "$_sca_file" ] && return 1
    
    # 使用新的锁获取函数
    if ! acquire_config_lock; then
        return 1
    fi
    while IFS= read -r _sca_line || [ -n "$_sca_line" ]; do
        case "$_sca_line" in
            "${_sca_key}="*|"readonly ${_sca_key}="*|"export ${_sca_key}="*)
                case "$_sca_line" in
                    "readonly ${_sca_key}="*) _sca_prefix="readonly " ;;
                    "export ${_sca_key}="*)   _sca_prefix="export " ;;
                    *)                         _sca_prefix="" ;;
                esac
                printf '%s%s="%s"\n' "$_sca_prefix" "$_sca_key" "$_sca_val"
                _sca_found=true ;;
            *) printf '%s\n' "$_sca_line" ;;
        esac
    done < "$_sca_file" > "$_sca_tmp"
    _sca_ret=1
    if [ -s "$_sca_tmp" ] && [ "$_sca_found" = true ]; then
        cat "$_sca_tmp" > "$_sca_file" 2>/dev/null && _sca_ret=0
    fi
    rm -f "$_sca_tmp" 2>/dev/null
    
    # 使用新的锁释放函数
    release_config_lock
    return $_sca_ret
}

# 1.4 sed 字符串转义 (用于配置值)
sed_escape() {
    _se_in="$1"; _se_out=""
    while [ -n "$_se_in" ]; do
        _se_char="${_se_in%"${_se_in#?}"}"; _se_in="${_se_in#?}"
        case "$_se_char" in
            '/') _se_out="${_se_out}\\/" ;;
            '\') _se_out="${_se_out}\\\\" ;;
            '&') _se_out="${_se_out}\\&" ;;
            *) _se_out="${_se_out}${_se_char}" ;;
        esac
    done
    printf '%s' "$_se_out"
}

# 1.5 使用 sed 的快速配置写入
set_config_atomic_fast() {
    _scaf_file="$1"; _scaf_key="$2"; _scaf_val="$3"
    _scaf_tmp="${_scaf_file}.tmp.${_WEBUI_PID}"
    _scaf_ret=1
    
    # 基础检查
    [ ! -f "$_scaf_file" ] && return 1
    [ -L "$_scaf_file" ] && return 1  # 安全：拒绝符号链接
    
    # 使用新的锁获取函数
    if ! acquire_config_lock; then
        return 1
    fi
    
    # 检测 sed 可用性
    _scaf_sed=""
    if command -v sed >/dev/null 2>&1; then
        _scaf_sed="sed"
    elif [ -n "$BB_PATH" ] && "$BB_PATH" --list 2>/dev/null | grep -q "^sed$"; then
        _scaf_sed="$BB_PATH sed"
    fi
    
    # 尝试使用 sed 实现
    if [ -n "$_scaf_sed" ]; then
        # 转义特殊字符
        _scaf_val_esc=$(sed_escape "$_scaf_val")
        
        # 构造 sed 命令：匹配三种格式并替换
        # 匹配: KEY=, readonly KEY=, export KEY=
        # 替换: 保留前缀，替换值
        if $_scaf_sed "/^\(readonly \|export \)\{0,1\}${_scaf_key}=/s/^\(\(readonly \|export \)\{0,1\}${_scaf_key}=\).*/\1\"${_scaf_val_esc}\"/" "$_scaf_file" > "$_scaf_tmp" 2>/dev/null; then
            # 验证：临时文件非空且包含目标键
            if [ -s "$_scaf_tmp" ] && grep -q "^.*${_scaf_key}=" "$_scaf_tmp" 2>/dev/null; then
                cat "$_scaf_tmp" > "$_scaf_file" 2>/dev/null && _scaf_ret=0
            fi
        fi
    fi
    
    # 清理临时文件
    rm -f "$_scaf_tmp" 2>/dev/null
    
    # 如果 sed 失败，回退到原实现
    if [ "$_scaf_ret" -ne 0 ]; then
        # 先释放锁，因为 set_config_atomic 会重新获取锁
        release_config_lock
        [ "$LOG_MODE" != "NONE" ] && webui_warn "sed 配置写入失败，回退到 Shell 实现: $_scaf_key"
        set_config_atomic "$_scaf_file" "$_scaf_key" "$_scaf_val"
        return $?
    fi
    
    # 使用新的锁释放函数
    release_config_lock
    return 0
}

# 1.6 访问时间更新
touch_access() { date +%s > "$LAST_ACCESS_FILE" 2>/dev/null; }

# 1.7 操作日志记录 (写入 service.log，与 action.sh 保持统一)
webui_log() {
    [ "$LOG_MODE" != "NONE" ] && printf '%s I [WebUI] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG_FILE" 2>/dev/null
}

webui_warn() {
    [ "$LOG_MODE" != "NONE" ] && printf '%s W [WebUI] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG_FILE" 2>/dev/null
}

webui_err() {
    printf '%s E [WebUI] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG_FILE" 2>/dev/null
}

# 1.8 清理过期的执行记录
cleanup_old_executions() {
    _coe_now=$(date +%s)
    _coe_max_age=3600  # 1 小时
    _coe_max_count=10  # 最多保留 10 个
    
    # 清理超过 1 小时的文件
    for _coe_file in "$WEBUI_TMP_DIR"/execution_*.status; do
        [ ! -f "$_coe_file" ] && continue
        
        _coe_mtime=$(stat -c%Y "$_coe_file" 2>/dev/null)
        case "$_coe_mtime" in *[!0-9]*) continue ;; esac
        
        _coe_age=$((_coe_now - _coe_mtime))
        if [ "$_coe_age" -gt "$_coe_max_age" ]; then
            _coe_base="${_coe_file%.status}"
            rm -f "${_coe_base}.status" "${_coe_base}.log" "${_coe_base}.pid" 2>/dev/null
        fi
    done
    
    # 限制文件数量
    _coe_count=$(ls -1 "$WEBUI_TMP_DIR"/execution_*.status 2>/dev/null | wc -l)
    if [ "$_coe_count" -gt "$_coe_max_count" ]; then
        # 删除最旧的文件
        if command -v tail >/dev/null 2>&1; then
            ls -1t "$WEBUI_TMP_DIR"/execution_*.status 2>/dev/null | tail -n +$((_coe_max_count + 1)) | while read -r _coe_old; do
                _coe_base="${_coe_old%.status}"
                rm -f "${_coe_base}.status" "${_coe_base}.log" "${_coe_base}.pid" 2>/dev/null
            done
        else
            # 回退: 使用纯 Shell 实现跳过前 N 行
            _coe_skip=$((_coe_max_count))
            _coe_idx=0
            ls -1t "$WEBUI_TMP_DIR"/execution_*.status 2>/dev/null | while read -r _coe_old; do
                _coe_idx=$((_coe_idx + 1))
                if [ "$_coe_idx" -gt "$_coe_skip" ]; then
                    _coe_base="${_coe_old%.status}"
                    rm -f "${_coe_base}.status" "${_coe_base}.log" "${_coe_base}.pid" 2>/dev/null
                fi
            done
        fi
    fi
}

# 1.9 清理 WebUI 会话文件
cleanup_webui_session() {
    # 清理当前会话的执行记录
    rm -f "$WEBUI_TMP_DIR"/execution_*_${_WEBUI_PID}.* 2>/dev/null
}


# ==============================================================================
# PART 2: CGI 库模式 (Lib Mode)
# ==============================================================================
if [ "$MODE" = "lib" ]; then

    # 2.1 API: 获取调度器配置
    api_config_get() {
        touch_access
        printf 'Content-Type: application/json\r\n\r\n'
        _acg_sm=$(get_config_value "$MODDIR/service.sh" "SCHEDULE_MODE")
        _acg_ce=$(get_config_value "$MODDIR/service.sh" "CRON_EXP")
        _acg_lm=$(get_config_value "$MODDIR/service.sh" "LOG_MODE")
        _acg_sh=$(get_config_value "$MODDIR/service.sh" "SLEEP_HEARTBEAT")
        _acg_wt=$(get_config_value "$MODDIR/webui.sh" "WEBUI_TIMEOUT")
        _acg_hb=$(get_config_value "$MODDIR/webui.sh" "HEARTBEAT_SEC")
        [ -z "$_acg_sm" ] && _acg_sm="sleep"
        [ -z "$_acg_ce" ] && _acg_ce="0 */4 * * *"
        [ -z "$_acg_lm" ] && _acg_lm="INFO"
        [ -z "$_acg_sh" ] && _acg_sh="1800"
        [ -z "$_acg_wt" ] && _acg_wt="300"
        [ -z "$_acg_hb" ] && _acg_hb="30"
        _acg_sm=$(json_escape "$_acg_sm"); _acg_ce=$(json_escape "$_acg_ce")
        _acg_lm=$(json_escape "$_acg_lm"); _acg_sh=$(json_escape "$_acg_sh")
        _acg_wt=$(json_escape "$_acg_wt"); _acg_hb=$(json_escape "$_acg_hb")
        printf '{"schedule_mode":"%s","cron_exp":"%s","log_mode":"%s","sleep_heartbeat":"%s","webui_timeout":"%s","heartbeat_sec":"%s"}' \
            "$_acg_sm" "$_acg_ce" "$_acg_lm" "$_acg_sh" "$_acg_wt" "$_acg_hb"
    }

    # 2.2 API: 保存调度器配置
    api_config_set() {
        touch_access
        _acs_post=$(cat)
        _acs_t="${_acs_post#*\"schedule_mode\":\"}"; [ "$_acs_t" != "$_acs_post" ] && _acs_s="${_acs_t%%\"*}" || _acs_s=""
        _acs_t="${_acs_post#*\"cron_exp\":\"}"; [ "$_acs_t" != "$_acs_post" ] && _acs_c="${_acs_t%%\"*}" || _acs_c=""
        _acs_t="${_acs_post#*\"log_mode\":\"}"; [ "$_acs_t" != "$_acs_post" ] && _acs_l="${_acs_t%%\"*}" || _acs_l=""
        _acs_t="${_acs_post#*\"sleep_heartbeat\":\"}"; [ "$_acs_t" != "$_acs_post" ] && _acs_sh="${_acs_t%%\"*}" || _acs_sh=""
        _acs_t="${_acs_post#*\"webui_timeout\":\"}"; [ "$_acs_t" != "$_acs_post" ] && _acs_wt="${_acs_t%%\"*}" || _acs_wt=""
        _acs_t="${_acs_post#*\"heartbeat_sec\":\"}"; [ "$_acs_t" != "$_acs_post" ] && _acs_hb="${_acs_t%%\"*}" || _acs_hb=""
        
        # 白名单验证
        case "$_acs_s" in sleep|cron) ;; *) _acs_s="sleep" ;; esac
        case "$_acs_l" in NONE|INFO|DEBUG) ;; *) _acs_l="INFO" ;; esac
        
        printf 'Content-Type: application/json\r\n\r\n'
        _acs_ok=true
        _acs_err=""
        
        # CRON_EXP 后端验证 (5字段格式)
        if [ -n "$_acs_c" ]; then
            # 过滤危险字符
            _acs_c_safe=$(printf '%s' "$_acs_c" | tr -d '`$(){}[]|;&<>\\!#')
            # 验证 5 字段格式
            set -f; set -- $_acs_c_safe; set +f
            if [ "$#" -ne 5 ]; then
                _acs_ok=false
                _acs_err="cron_exp 格式错误: 需要 5 个字段 (分 时 日 月 周)"
            else
                # 验证各字段格式 (支持 *, */n, n, n-m)
                _acs_cron_valid=true
                for _acs_field in "$@"; do
                    case "$_acs_field" in
                        \*) ;;
                        \*/[0-9]*) ;;
                        [0-9]*-[0-9]*) ;;
                        [0-9]*) ;;
                        *) _acs_cron_valid=false; break ;;
                    esac
                done
                [ "$_acs_cron_valid" = false ] && {
                    _acs_ok=false
                    _acs_err="cron_exp 字段格式错误"
                }
            fi
            _acs_c="$_acs_c_safe"
        fi
        
        # SLEEP_HEARTBEAT 范围验证 (60-7200秒)
        if [ -n "$_acs_sh" ]; then
            if is_integer "$_acs_sh" && [ "$_acs_sh" -ge 60 ] 2>/dev/null && [ "$_acs_sh" -le 7200 ] 2>/dev/null; then
                : # 验证通过
            else
                _acs_ok=false
                _acs_err="sleep_heartbeat 必须为 60-7200 之间的数字"
            fi
        fi
        
        # WEBUI_TIMEOUT 范围验证 (60-3600秒)
        if [ -n "$_acs_wt" ]; then
            if is_integer "$_acs_wt" && [ "$_acs_wt" -ge 60 ] 2>/dev/null && [ "$_acs_wt" -le 3600 ] 2>/dev/null; then
                : # 验证通过
            else
                _acs_ok=false
                _acs_err="webui_timeout 必须为 60-3600 之间的数字"
            fi
        fi
        
        # HEARTBEAT_SEC 范围验证 (10-300秒)
        if [ -n "$_acs_hb" ]; then
            if is_integer "$_acs_hb" && [ "$_acs_hb" -ge 10 ] 2>/dev/null && [ "$_acs_hb" -le 300 ] 2>/dev/null; then
                : # 验证通过
            else
                _acs_ok=false
                _acs_err="heartbeat_sec 必须为 10-300 之间的数字"
            fi
        fi
        
        # 验证失败则返回错误
        if [ "$_acs_ok" = false ]; then
            webui_log "配置验证失败: $_acs_err"
            _acs_err=$(json_escape "$_acs_err")
            printf '{"success":false,"message":"验证失败: %s"}' "$_acs_err"
            return
        fi
        
        # 保存配置 (使用快速 sed 实现)
        _acs_saved=""
        if set_config_atomic_fast "$MODDIR/service.sh" "SCHEDULE_MODE" "$_acs_s" && \
           set_config_atomic_fast "$MODDIR/service.sh" "CRON_EXP" "$_acs_c" && \
           set_config_atomic_fast "$MODDIR/service.sh" "LOG_MODE" "$_acs_l"; then
            _acs_saved="mode=$_acs_s, cron=$_acs_c, log=$_acs_l"
            # 保存 SLEEP_HEARTBEAT (如果提供)
            if [ -n "$_acs_sh" ]; then
                if set_config_atomic_fast "$MODDIR/service.sh" "SLEEP_HEARTBEAT" "$_acs_sh"; then
                    _acs_saved="$_acs_saved, heartbeat=$_acs_sh"
                fi
            fi
            # 保存 WEBUI_TIMEOUT (如果提供)
            if [ -n "$_acs_wt" ]; then
                if set_config_atomic_fast "$MODDIR/webui.sh" "WEBUI_TIMEOUT" "$_acs_wt"; then
                    _acs_saved="$_acs_saved, webui_timeout=$_acs_wt"
                fi
            fi
            # 保存 HEARTBEAT_SEC (如果提供)
            if [ -n "$_acs_hb" ]; then
                if set_config_atomic_fast "$MODDIR/webui.sh" "HEARTBEAT_SEC" "$_acs_hb"; then
                    _acs_saved="$_acs_saved, heartbeat_sec=$_acs_hb"
                fi
            fi
            webui_log "配置已保存: $_acs_saved"
            printf '{"success":true,"message":"配置已保存","saved":{"schedule_mode":"%s","cron_exp":"%s","log_mode":"%s"}}' \
                "$_acs_s" "$_acs_c" "$_acs_l"
        else
            webui_log "配置保存失败"
            printf '{"success":false,"message":"保存失败"}'
        fi
    }

    # 2.3 API: 获取 f2fsopt 配置
    api_f2fsopt_config_get() {
        touch_access
        printf 'Content-Type: application/json\r\n\r\n'
        _afcg_gd=$(get_config_value "$MODDIR/f2fsopt" "GC_DIRTY_MIN")
        _afcg_gt=$(get_config_value "$MODDIR/f2fsopt" "GC_TURBO_SLEEP")
        _afcg_gs=$(get_config_value "$MODDIR/f2fsopt" "GC_SAFE_SLEEP")
        _afcg_gm=$(get_config_value "$MODDIR/f2fsopt" "GC_MAX_SEC")
        _afcg_tt=$(get_config_value "$MODDIR/f2fsopt" "TRIM_TIMEOUT")
        _afcg_ss=$(get_config_value "$MODDIR/f2fsopt" "STOP_ON_SCREEN_ON")
        _afcg_oc=$(get_config_value "$MODDIR/f2fsopt" "ONLY_CHARGING")
        _afcg_sc=$(get_config_value "$MODDIR/f2fsopt" "GC_STABLE_CNT")
        _afcg_gp=$(get_config_value "$MODDIR/f2fsopt" "GC_POLL")
        _afcg_esg=$(get_config_value "$MODDIR/f2fsopt" "ENABLE_SMART_GC")
        _afcg_est=$(get_config_value "$MODDIR/f2fsopt" "ENABLE_SMART_TRIM")
        _afcg_etg=$(get_config_value "$MODDIR/f2fsopt" "ENABLE_TURBO_GC")
        # 默认值处理
        [ -z "$_afcg_gd" ] && _afcg_gd="200"
        [ -z "$_afcg_gt" ] && _afcg_gt="50"
        [ -z "$_afcg_gs" ] && _afcg_gs="500"
        [ -z "$_afcg_gm" ] && _afcg_gm="500"
        [ -z "$_afcg_tt" ] && _afcg_tt="500"
        [ -z "$_afcg_ss" ] && _afcg_ss="false"
        [ -z "$_afcg_oc" ] && _afcg_oc="false"
        [ -z "$_afcg_sc" ] && _afcg_sc="8"
        [ -z "$_afcg_gp" ] && _afcg_gp="1"
        [ -z "$_afcg_esg" ] && _afcg_esg="true"
        [ -z "$_afcg_est" ] && _afcg_est="true"
        [ -z "$_afcg_etg" ] && _afcg_etg="true"
        # JSON 转义
        _afcg_gd=$(json_escape "$_afcg_gd"); _afcg_gt=$(json_escape "$_afcg_gt")
        _afcg_gs=$(json_escape "$_afcg_gs"); _afcg_gm=$(json_escape "$_afcg_gm")
        _afcg_tt=$(json_escape "$_afcg_tt"); _afcg_ss=$(json_escape "$_afcg_ss")
        _afcg_oc=$(json_escape "$_afcg_oc"); _afcg_sc=$(json_escape "$_afcg_sc")
        _afcg_gp=$(json_escape "$_afcg_gp"); _afcg_esg=$(json_escape "$_afcg_esg")
        _afcg_est=$(json_escape "$_afcg_est"); _afcg_etg=$(json_escape "$_afcg_etg")
        printf '{"gc_dirty_min":"%s","gc_turbo_sleep":"%s","gc_safe_sleep":"%s","gc_max_sec":"%s","trim_timeout":"%s","stop_on_screen":"%s","only_charging":"%s","gc_stable_cnt":"%s","gc_poll":"%s","enable_smart_gc":"%s","enable_smart_trim":"%s","enable_turbo_gc":"%s"}' \
            "$_afcg_gd" "$_afcg_gt" "$_afcg_gs" "$_afcg_gm" "$_afcg_tt" "$_afcg_ss" "$_afcg_oc" "$_afcg_sc" "$_afcg_gp" "$_afcg_esg" "$_afcg_est" "$_afcg_etg"
    }

    # 2.4 API: 保存 f2fsopt 配置
    api_f2fsopt_config_set() {
        touch_access
        _afcs_post=$(cat)
        _afcs_t="${_afcs_post#*\"gc_dirty_min\":\"}"; [ "$_afcs_t" != "$_afcs_post" ] && _afcs_gd="${_afcs_t%%\"*}" || _afcs_gd=""
        _afcs_t="${_afcs_post#*\"gc_turbo_sleep\":\"}"; [ "$_afcs_t" != "$_afcs_post" ] && _afcs_gt="${_afcs_t%%\"*}" || _afcs_gt=""
        _afcs_t="${_afcs_post#*\"gc_safe_sleep\":\"}"; [ "$_afcs_t" != "$_afcs_post" ] && _afcs_gs="${_afcs_t%%\"*}" || _afcs_gs=""
        _afcs_t="${_afcs_post#*\"gc_max_sec\":\"}"; [ "$_afcs_t" != "$_afcs_post" ] && _afcs_gm="${_afcs_t%%\"*}" || _afcs_gm=""
        _afcs_t="${_afcs_post#*\"trim_timeout\":\"}"; [ "$_afcs_t" != "$_afcs_post" ] && _afcs_tt="${_afcs_t%%\"*}" || _afcs_tt=""
        _afcs_t="${_afcs_post#*\"stop_on_screen\":\"}"; [ "$_afcs_t" != "$_afcs_post" ] && _afcs_ss="${_afcs_t%%\"*}" || _afcs_ss=""
        _afcs_t="${_afcs_post#*\"only_charging\":\"}"; [ "$_afcs_t" != "$_afcs_post" ] && _afcs_oc="${_afcs_t%%\"*}" || _afcs_oc=""
        _afcs_t="${_afcs_post#*\"gc_stable_cnt\":\"}"; [ "$_afcs_t" != "$_afcs_post" ] && _afcs_sc="${_afcs_t%%\"*}" || _afcs_sc=""
        _afcs_t="${_afcs_post#*\"gc_poll\":\"}"; [ "$_afcs_t" != "$_afcs_post" ] && _afcs_gp="${_afcs_t%%\"*}" || _afcs_gp=""
        _afcs_t="${_afcs_post#*\"enable_smart_gc\":\"}"; [ "$_afcs_t" != "$_afcs_post" ] && _afcs_esg="${_afcs_t%%\"*}" || _afcs_esg=""
        _afcs_t="${_afcs_post#*\"enable_smart_trim\":\"}"; [ "$_afcs_t" != "$_afcs_post" ] && _afcs_est="${_afcs_t%%\"*}" || _afcs_est=""
        _afcs_t="${_afcs_post#*\"enable_turbo_gc\":\"}"; [ "$_afcs_t" != "$_afcs_post" ] && _afcs_etg="${_afcs_t%%\"*}" || _afcs_etg=""
        printf 'Content-Type: application/json\r\n\r\n'
        _afcs_ok=true
        _afcs_err=""
        # 数值验证辅助函数 (内联)
        _afcs_is_num() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
        _afcs_is_bool() { case "$1" in true|false) return 0 ;; *) return 1 ;; esac; }
        # 范围验证函数: _afcs_in_range <value> <min> <max>
        _afcs_in_range() {
            _air_v="$1"; _air_min="$2"; _air_max="$3"
            _afcs_is_num "$_air_v" || return 1
            [ "$_air_v" -ge "$_air_min" ] 2>/dev/null && [ "$_air_v" -le "$_air_max" ] 2>/dev/null
        }
        # 原有配置写入 (带数值验证 + 范围检查，使用快速 sed 实现)
        if [ -n "$_afcs_gd" ]; then
            if _afcs_in_range "$_afcs_gd" 50 1000; then
                set_config_atomic_fast "$MODDIR/f2fsopt" "GC_DIRTY_MIN" "$_afcs_gd" || _afcs_ok=false
            else
                _afcs_ok=false; _afcs_err="gc_dirty_min 必须为 50-1000 之间的数字"
            fi
        fi
        if [ -n "$_afcs_gt" ]; then
            if _afcs_in_range "$_afcs_gt" 10 5000; then
                set_config_atomic_fast "$MODDIR/f2fsopt" "GC_TURBO_SLEEP" "$_afcs_gt" || _afcs_ok=false
            else
                _afcs_ok=false; _afcs_err="gc_turbo_sleep 必须为 10-5000 之间的数字"
            fi
        fi
        if [ -n "$_afcs_gs" ]; then
            if _afcs_in_range "$_afcs_gs" 100 10000; then
                set_config_atomic_fast "$MODDIR/f2fsopt" "GC_SAFE_SLEEP" "$_afcs_gs" || _afcs_ok=false
            else
                _afcs_ok=false; _afcs_err="gc_safe_sleep 必须为 100-10000 之间的数字"
            fi
        fi
        if [ -n "$_afcs_gm" ]; then
            if _afcs_in_range "$_afcs_gm" 60 3600; then
                set_config_atomic_fast "$MODDIR/f2fsopt" "GC_MAX_SEC" "$_afcs_gm" || _afcs_ok=false
            else
                _afcs_ok=false; _afcs_err="gc_max_sec 必须为 60-3600 之间的数字"
            fi
        fi
        if [ -n "$_afcs_tt" ]; then
            if _afcs_in_range "$_afcs_tt" 60 3600; then
                set_config_atomic_fast "$MODDIR/f2fsopt" "TRIM_TIMEOUT" "$_afcs_tt" || _afcs_ok=false
            else
                _afcs_ok=false; _afcs_err="trim_timeout 必须为 60-3600 之间的数字"
            fi
        fi
        if [ -n "$_afcs_ss" ]; then
            if _afcs_is_bool "$_afcs_ss"; then
                set_config_atomic_fast "$MODDIR/f2fsopt" "STOP_ON_SCREEN_ON" "$_afcs_ss" || _afcs_ok=false
            else
                _afcs_ok=false; _afcs_err="stop_on_screen 必须为 true 或 false"
            fi
        fi
        if [ -n "$_afcs_oc" ]; then
            if _afcs_is_bool "$_afcs_oc"; then
                set_config_atomic_fast "$MODDIR/f2fsopt" "ONLY_CHARGING" "$_afcs_oc" || _afcs_ok=false
            else
                _afcs_ok=false; _afcs_err="only_charging 必须为 true 或 false"
            fi
        fi
        # 配置写入 (带验证 + 范围检查，使用快速 sed 实现)
        if [ -n "$_afcs_sc" ]; then
            if _afcs_in_range "$_afcs_sc" 1 50; then
                set_config_atomic_fast "$MODDIR/f2fsopt" "GC_STABLE_CNT" "$_afcs_sc" || _afcs_ok=false
            else
                _afcs_ok=false; _afcs_err="gc_stable_cnt 必须为 1-50 之间的数字"
            fi
        fi
        if [ -n "$_afcs_gp" ]; then
            if _afcs_in_range "$_afcs_gp" 1 60; then
                set_config_atomic_fast "$MODDIR/f2fsopt" "GC_POLL" "$_afcs_gp" || _afcs_ok=false
            else
                _afcs_ok=false; _afcs_err="gc_poll 必须为 1-60 之间的数字"
            fi
        fi
        if [ -n "$_afcs_esg" ]; then
            if _afcs_is_bool "$_afcs_esg"; then
                set_config_atomic_fast "$MODDIR/f2fsopt" "ENABLE_SMART_GC" "$_afcs_esg" || _afcs_ok=false
            else
                _afcs_ok=false; _afcs_err="enable_smart_gc 必须为 true 或 false"
            fi
        fi
        if [ -n "$_afcs_est" ]; then
            if _afcs_is_bool "$_afcs_est"; then
                set_config_atomic_fast "$MODDIR/f2fsopt" "ENABLE_SMART_TRIM" "$_afcs_est" || _afcs_ok=false
            else
                _afcs_ok=false; _afcs_err="enable_smart_trim 必须为 true 或 false"
            fi
        fi
        if [ -n "$_afcs_etg" ]; then
            if _afcs_is_bool "$_afcs_etg"; then
                set_config_atomic_fast "$MODDIR/f2fsopt" "ENABLE_TURBO_GC" "$_afcs_etg" || _afcs_ok=false
            else
                _afcs_ok=false; _afcs_err="enable_turbo_gc 必须为 true 或 false"
            fi
        fi
        chmod 755 "$MODDIR/f2fsopt" 2>/dev/null
        if [ "$_afcs_ok" = true ]; then
            webui_log "f2fsopt 配置已保存"
            printf '{"success":true,"message":"f2fsopt 配置已保存"}'
        else
            webui_log "f2fsopt 配置保存失败: $_afcs_err"
            if [ -n "$_afcs_err" ]; then
                _afcs_err=$(json_escape "$_afcs_err")
                printf '{"success":false,"message":"保存失败: %s"}' "$_afcs_err"
            else
                printf '{"success":false,"message":"保存失败"}'
            fi
        fi
    }

    # 2.5 API: 获取 action.sh 配置
    api_action_config_get() {
        touch_access
        printf 'Content-Type: application/json\r\n\r\n'
        _aacg_asw=$(get_config_value "$MODDIR/action.sh" "AUTO_START_WEBUI")
        _aacg_wpt=$(get_config_value "$MODDIR/action.sh" "WEBUI_PROMPT_TIMEOUT")
        [ -z "$_aacg_asw" ] && _aacg_asw="ask"
        [ -z "$_aacg_wpt" ] && _aacg_wpt="10"
        _aacg_asw=$(json_escape "$_aacg_asw"); _aacg_wpt=$(json_escape "$_aacg_wpt")
        printf '{"auto_start_webui":"%s","webui_prompt_timeout":"%s"}' \
            "$_aacg_asw" "$_aacg_wpt"
    }

    # 2.6 API: 保存 action.sh 配置
    api_action_config_set() {
        touch_access
        _aacs_post=$(cat)
        _aacs_t="${_aacs_post#*\"auto_start_webui\":\"}"; [ "$_aacs_t" != "$_aacs_post" ] && _aacs_asw="${_aacs_t%%\"*}" || _aacs_asw=""
        _aacs_t="${_aacs_post#*\"webui_prompt_timeout\":\"}"; [ "$_aacs_t" != "$_aacs_post" ] && _aacs_wpt="${_aacs_t%%\"*}" || _aacs_wpt=""
        
        printf 'Content-Type: application/json\r\n\r\n'
        _aacs_ok=true
        _aacs_err=""
        
        # AUTO_START_WEBUI 枚举验证 (true/false/ask)
        if [ -n "$_aacs_asw" ]; then
            case "$_aacs_asw" in
                true|false|ask)
                    : # 验证通过
                    ;;
                *)
                    _aacs_ok=false
                    _aacs_err="auto_start_webui 必须为 true、false 或 ask"
                    ;;
            esac
        fi
        
        # WEBUI_PROMPT_TIMEOUT 范围验证 (1-60秒)
        if [ -n "$_aacs_wpt" ]; then
            if is_integer "$_aacs_wpt" && [ "$_aacs_wpt" -ge 1 ] 2>/dev/null && [ "$_aacs_wpt" -le 60 ] 2>/dev/null; then
                : # 验证通过
            else
                _aacs_ok=false
                _aacs_err="webui_prompt_timeout 必须为 1-60 之间的数字"
            fi
        fi
        
        # 验证失败则返回错误
        if [ "$_aacs_ok" = false ]; then
            webui_log "action.sh 配置验证失败: $_aacs_err"
            _aacs_err=$(json_escape "$_aacs_err")
            printf '{"success":false,"message":"验证失败: %s"}' "$_aacs_err"
            return
        fi
        
        # 保存配置 (使用快速 sed 实现)
        _aacs_saved=""
        _aacs_save_ok=true
        
        # 保存 AUTO_START_WEBUI (如果提供)
        if [ -n "$_aacs_asw" ]; then
            if set_config_atomic_fast "$MODDIR/action.sh" "AUTO_START_WEBUI" "$_aacs_asw"; then
                _aacs_saved="auto_start_webui=$_aacs_asw"
            else
                _aacs_save_ok=false
            fi
        fi
        
        # 保存 WEBUI_PROMPT_TIMEOUT (如果提供)
        if [ -n "$_aacs_wpt" ]; then
            if set_config_atomic_fast "$MODDIR/action.sh" "WEBUI_PROMPT_TIMEOUT" "$_aacs_wpt"; then
                [ -n "$_aacs_saved" ] && _aacs_saved="$_aacs_saved, "
                _aacs_saved="${_aacs_saved}webui_prompt_timeout=$_aacs_wpt"
            else
                _aacs_save_ok=false
            fi
        fi
        
        if [ "$_aacs_save_ok" = true ] && [ -n "$_aacs_saved" ]; then
            webui_log "action.sh 配置已保存: $_aacs_saved"
            printf '{"success":true,"message":"配置已保存","saved":{"auto_start_webui":"%s","webui_prompt_timeout":"%s"}}' \
                "$_aacs_asw" "$_aacs_wpt"
        else
            webui_log "action.sh 配置保存失败"
            printf '{"success":false,"message":"保存失败"}'
        fi
    }


    # 2.7 API: 获取状态
    api_status() {
        touch_access
        printf 'Content-Type: application/json\r\n\r\n'
        _as_st="已停止"; _as_lr="从未运行"; _as_ls="0 KB"
        if [ -f "$MODDIR/service.pid" ]; then
            read -r _as_pid < "$MODDIR/service.pid" 2>/dev/null
            # 验证进程存在且为服务相关进程
            if [ -n "$_as_pid" ] && is_integer "$_as_pid" && [ -d "/proc/$_as_pid" ]; then
                # 修复: 使用 read_cmdline 函数转换 NULL 字节为空格
                # /proc/PID/cmdline 使用 NULL 字节分隔参数，需要转换为空格才能正确匹配
                _as_cmd=$(read_cmdline "/proc/$_as_pid/cmdline")
                
                # 策略 1: 匹配 cmdline（最准确）
                if [ -n "$_as_cmd" ]; then
                    case "$_as_cmd" in
                        *"service.sh"*|*"crond"*)
                            _as_st="运行中 [PID: $_as_pid]"
                            ;;
                        *)
                            # 策略 2: 检查进程名（回退）
                            _as_proc_name=$(cat "/proc/$_as_pid/comm" 2>/dev/null)
                            case "$_as_proc_name" in
                                sh|crond)
                                    _as_st="运行中 [PID: $_as_pid]"
                                    ;;
                                *)
                                    # PID 被其他进程复用，清理陈旧的 PID 文件
                                    rm -f "$MODDIR/service.pid" 2>/dev/null
                                    _as_st="已停止"
                                    ;;
                            esac
                            ;;
                    esac
                else
                    # 策略 3: cmdline 读取失败，直接检查进程名
                    _as_proc_name=$(cat "/proc/$_as_pid/comm" 2>/dev/null)
                    case "$_as_proc_name" in
                        sh|crond)
                            _as_st="运行中 [PID: $_as_pid]"
                            ;;
                        *)
                            rm -f "$MODDIR/service.pid" 2>/dev/null
                            _as_st="已停止"
                            ;;
                    esac
                fi
            fi
        fi
        if [ -f "$MODDIR/scheduler.state" ]; then
            read -r _as_ts < "$MODDIR/scheduler.state" 2>/dev/null
            [ "$_as_ts" -gt 0 ] 2>/dev/null && _as_lr=$("$BB_PATH" date -d "@$_as_ts" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || "$BB_PATH" date '+%Y-%m-%d %H:%M:%S')
        fi
        if [ -f "$LOG_FILE" ]; then
            _as_sz=$("$BB_PATH" stat -c %s "$LOG_FILE" 2>/dev/null) || _as_sz=0
            [ "$_as_sz" -gt 0 ] 2>/dev/null && _as_ls="$((_as_sz / 1024)) KB"
        fi
        printf '{"service_status":"%s","last_run":"%s","log_size":"%s"}' "$_as_st" "$_as_lr" "$_as_ls"
    }

    # 2.6 API: 获取日志
    api_logs_get() {
        touch_access
        printf 'Content-Type: text/plain; charset=utf-8\r\n\r\n'
        if [ -f "$LOG_FILE" ]; then
            if command -v tail >/dev/null 2>&1; then
                "$BB_PATH" tail -n 200 "$LOG_FILE" 2>/dev/null || tail -n 200 "$LOG_FILE" 2>/dev/null || printf '日志读取失败\n'
            else
                # 回退: tail 不可用时读取整个文件
                cat "$LOG_FILE" 2>/dev/null || printf '日志读取失败\n'
            fi
        else
            printf '日志文件不存在: %s\n' "$LOG_FILE"
        fi
    }

    # 2.7 API: 执行操作
    api_action() {
        touch_access
        _aa_act="${REQUEST_URI##*/}"
        printf 'Content-Type: application/json\r\n\r\n'
        case "$_aa_act" in
            restart)
                # 仅重启调度服务 (service.sh)，不执行优化任务
                webui_log "服务重启请求"
                "$BB_PATH" pkill -f "service.sh --daemon" 2>/dev/null
                sleep 1
                /system/bin/sh "$MODDIR/service.sh" >/dev/null 2>&1 &
                
                # 智能等待：最多 10 秒，每秒检查一次
                _aa_wait_count=0
                _aa_max_wait=10
                _aa_service_ready=false
                
                while [ "$_aa_wait_count" -lt "$_aa_max_wait" ]; do
                    sleep 1
                    _aa_wait_count=$((_aa_wait_count + 1))
                    
                    if [ -f "$MODDIR/service.pid" ]; then
                        read -r _aa_new_pid < "$MODDIR/service.pid" 2>/dev/null
                        if [ -n "$_aa_new_pid" ] && is_integer "$_aa_new_pid" && [ -d "/proc/$_aa_new_pid" ]; then
                            _aa_service_ready=true
                            break
                        fi
                    fi
                done
                
                # 验证重启结果
                if [ "$_aa_service_ready" = true ]; then
                    webui_log "服务已重启 [PID: $_aa_new_pid, 耗时: ${_aa_wait_count}s]"
                    printf '{"success":true,"message":"调度服务已重启 (耗时 %ds)","new_pid":"%s"}' "$_aa_wait_count" "$_aa_new_pid"
                elif [ -f "$MODDIR/service.pid" ]; then
                    read -r _aa_new_pid < "$MODDIR/service.pid" 2>/dev/null
                    webui_log "服务重启异常 [PID 文件存在但进程不存在]"
                    printf '{"success":false,"message":"服务重启异常，请检查日志"}'
                else
                    webui_log "服务重启超时 [${_aa_max_wait}秒内未创建 PID 文件]"
                    printf '{"success":false,"message":"服务重启超时，系统可能正在初始化，请稍后手动检查"}'
                fi
                ;;
            run_now)
                # 同步执行 f2fsopt 优化任务，捕获输出和退出码
                webui_log "手动触发任务 - 开始"
                
                # 检查是否已有任务在运行 (检查 f2fsopt 的锁目录)
                _aa_lock_dir="/data/local/tmp/f2fsopt.lock.d"
                if [ -d "$_aa_lock_dir" ]; then
                    _aa_lock_pid=""
                    [ -f "$_aa_lock_dir/pid" ] && read -r _aa_lock_pid < "$_aa_lock_dir/pid" 2>/dev/null
                    if [ -n "$_aa_lock_pid" ] && [ -d "/proc/$_aa_lock_pid" ]; then
                        printf '{"success":false,"message":"任务正在运行中 [PID: %s]"}' "$_aa_lock_pid"
                        return
                    fi
                fi
                
                # 同步执行任务，输出同时写入日志文件
                _aa_start=$(date +%s)
                _aa_tmp_log="${WEBUI_TMP_DIR}/run_${_WEBUI_PID}"
                
                # 执行 f2fsopt 并将输出写入临时文件
                "$MODDIR/f2fsopt" > "$_aa_tmp_log" 2>&1
                _aa_ret=$?
                
                # 读取输出并追加到日志文件
                if [ -f "$_aa_tmp_log" ]; then
                    _aa_output=$(cat "$_aa_tmp_log" 2>/dev/null)
                    # 追加到日志文件（保留完整输出）
                    cat "$_aa_tmp_log" >> "$LOG_FILE" 2>/dev/null
                    rm -f "$_aa_tmp_log" 2>/dev/null
                else
                    _aa_output=""
                fi
                
                _aa_end=$(date +%s)
                _aa_duration=$((_aa_end - _aa_start))
                
                webui_log "手动触发任务 - 完成 [Code: $_aa_ret, 耗时: ${_aa_duration}s]"
                
                if [ "$_aa_ret" -eq 0 ]; then
                    printf '{"success":true,"message":"任务执行完成","duration":%d,"exit_code":%d}' "$_aa_duration" "$_aa_ret"
                else
                    # 转义输出中的特殊字符 (取前200字符)
                    _aa_msg=$(printf '%s' "$_aa_output" | head -c 200)
                    _aa_msg=$(json_escape "$_aa_msg")
                    printf '{"success":false,"message":"任务执行失败","duration":%d,"exit_code":%d,"detail":"%s"}' "$_aa_duration" "$_aa_ret" "$_aa_msg"
                fi
                ;;
            clear_log)
                if : > "$LOG_FILE" 2>/dev/null; then
                    webui_log "日志已清空"
                    printf '{"success":true,"message":"日志已清空"}'
                else
                    printf '{"success":false,"message":"清空失败"}'
                fi
                ;;
            *)
                printf '{"success":false,"message":"未知操作: %s"}' "$_aa_act"
                ;;
        esac
    }

    # 2.8 API: 计算下次执行时间 (辅助函数)
    calculate_next_run_time() {
        # 读取调度配置
        _cnrt_mode=$(get_config_value "$MODDIR/service.sh" "SCHEDULE_MODE")
        _cnrt_cron=$(get_config_value "$MODDIR/service.sh" "CRON_EXP")
        _cnrt_heartbeat=$(get_config_value "$MODDIR/service.sh" "SLEEP_HEARTBEAT")
        
        # 默认值
        [ -z "$_cnrt_mode" ] && _cnrt_mode="sleep"
        [ -z "$_cnrt_cron" ] && _cnrt_cron="0 */4 * * *"
        [ -z "$_cnrt_heartbeat" ] && _cnrt_heartbeat="1800"
        
        # 读取最后执行时间
        _cnrt_last_run=0
        if [ -f "$MODDIR/scheduler.state" ]; then
            read -r _cnrt_last_run < "$MODDIR/scheduler.state" 2>/dev/null
            case "$_cnrt_last_run" in *[!0-9]*) _cnrt_last_run=0 ;; esac
        fi
        
        # 获取当前时间
        _cnrt_now=$(date +%s 2>/dev/null)
        [ -z "$_cnrt_now" ] && _cnrt_now=0
        
        # 如果从未运行，返回当前时间（表示应该立即运行）
        if [ "$_cnrt_last_run" -eq 0 ]; then
            printf '%d' "$_cnrt_now"
            return 0
        fi
        
        # 解析 CRON 表达式
        set -f; set -- $_cnrt_cron; set +f
        _cnrt_min="$1"; _cnrt_hour="$2"
        
        # 类型 A: 固定时间 (M H * * *)
        if is_integer "$_cnrt_min" && is_integer "$_cnrt_hour"; then
            # 计算今天的目标时间
            _cnrt_today_start=$((_cnrt_now - (_cnrt_now % 86400)))
            _cnrt_target=$((_cnrt_today_start + _cnrt_hour * 3600 + _cnrt_min * 60))
            
            # 如果今天的时间已过，返回明天的时间
            if [ "$_cnrt_target" -le "$_cnrt_now" ]; then
                printf '%d' "$((_cnrt_target + 86400))"
            else
                printf '%d' "$_cnrt_target"
            fi
            return 0
        fi
        
        # 类型 B: 分钟间隔 (*/N * * * *)
        case "$_cnrt_min" in \*/[0-9]*)
            _cnrt_step="${_cnrt_min#*/}"
            if is_integer "$_cnrt_step" && [ "$_cnrt_step" -gt 0 ] 2>/dev/null; then
                _cnrt_interval=$((_cnrt_step * 60))
                printf '%d' "$((_cnrt_last_run + _cnrt_interval))"
                return 0
            fi
        ;; esac
        
        # 类型 C: 小时间隔 (0 */N * * *)
        case "$_cnrt_hour" in \*/[0-9]*)
            _cnrt_step="${_cnrt_hour#*/}"
            if is_integer "$_cnrt_step" && [ "$_cnrt_step" -gt 0 ] 2>/dev/null; then
                _cnrt_interval=$((_cnrt_step * 3600))
                printf '%d' "$((_cnrt_last_run + _cnrt_interval))"
                return 0
            fi
        ;; esac
        
        # 默认：使用心跳间隔
        printf '%d' "$((_cnrt_last_run + _cnrt_heartbeat))"
        return 0
    }
    
    # 2.9 API: 检测待生效的配置项 (辅助函数)
    detect_pending_changes() {
        # 注意：由于 f2fsopt 是瞬时执行的脚本，每次运行都会重新读取配置文件
        # 因此"待生效"的概念是指：配置文件已修改，但 f2fsopt 还未执行
        # 通过比较配置文件的修改时间和最后执行时间来判断
        
        _dpc_pending="[]"
        
        # 读取最后执行时间
        _dpc_last_run=0
        if [ -f "$MODDIR/scheduler.state" ]; then
            read -r _dpc_last_run < "$MODDIR/scheduler.state" 2>/dev/null
            case "$_dpc_last_run" in *[!0-9]*) _dpc_last_run=0 ;; esac
        fi
        
        # 如果从未运行，所有配置都是待生效
        if [ "$_dpc_last_run" -eq 0 ]; then
            printf '["f2fsopt","service.sh","action.sh"]'
            return 0
        fi
        
        # 检查各配置文件的修改时间
        _dpc_has_pending=false
        _dpc_pending_list=""
        
        # 检查 f2fsopt
        if [ -f "$MODDIR/f2fsopt" ]; then
            _dpc_mtime=$(stat -c %Y "$MODDIR/f2fsopt" 2>/dev/null)
            case "$_dpc_mtime" in *[!0-9]*) _dpc_mtime=0 ;; esac
            if [ "$_dpc_mtime" -gt "$_dpc_last_run" ] 2>/dev/null; then
                _dpc_has_pending=true
                _dpc_pending_list="\"f2fsopt\""
            fi
        fi
        
        # 检查 service.sh
        if [ -f "$MODDIR/service.sh" ]; then
            _dpc_mtime=$(stat -c %Y "$MODDIR/service.sh" 2>/dev/null)
            case "$_dpc_mtime" in *[!0-9]*) _dpc_mtime=0 ;; esac
            if [ "$_dpc_mtime" -gt "$_dpc_last_run" ] 2>/dev/null; then
                _dpc_has_pending=true
                [ -n "$_dpc_pending_list" ] && _dpc_pending_list="$_dpc_pending_list,"
                _dpc_pending_list="${_dpc_pending_list}\"service.sh\""
            fi
        fi
        
        # 检查 action.sh
        if [ -f "$MODDIR/action.sh" ]; then
            _dpc_mtime=$(stat -c %Y "$MODDIR/action.sh" 2>/dev/null)
            case "$_dpc_mtime" in *[!0-9]*) _dpc_mtime=0 ;; esac
            if [ "$_dpc_mtime" -gt "$_dpc_last_run" ] 2>/dev/null; then
                _dpc_has_pending=true
                [ -n "$_dpc_pending_list" ] && _dpc_pending_list="$_dpc_pending_list,"
                _dpc_pending_list="${_dpc_pending_list}\"action.sh\""
            fi
        fi
        
        if [ "$_dpc_has_pending" = true ]; then
            printf '[%s]' "$_dpc_pending_list"
        else
            printf '[]'
        fi
        return 0
    }
    
    # 2.10 API: 配置状态查询
    api_config_status() {
        touch_access
        printf 'Content-Type: application/json\r\n\r\n'
        
        # 读取上次运行时间
        _acs_last_run=0
        if [ -f "$MODDIR/scheduler.state" ]; then
            read -r _acs_last_run < "$MODDIR/scheduler.state" 2>/dev/null
            case "$_acs_last_run" in *[!0-9]*) _acs_last_run=0 ;; esac
        fi
        
        # 计算下次运行时间（简化版本）
        _acs_next_run=0
        _acs_now=$(date +%s)
        
        # 读取调度配置
        _acs_mode=$(get_config_value "$MODDIR/service.sh" "SCHEDULE_MODE")
        
        # 根据调度模式计算下次运行时间
        case "$_acs_mode" in
            cron)
                # Cron 模式：简单估算（假设每4小时执行一次）
                # 如果有上次运行时间，基于此计算
                if [ "$_acs_last_run" -gt 0 ]; then
                    # 假设间隔 4 小时 (14400 秒)
                    _acs_next_run=$((_acs_last_run + 14400))
                else
                    # 假设下次在 4 小时后
                    _acs_next_run=$((_acs_now + 14400))
                fi
                ;;
            sleep|*)
                # Sleep 模式：基于心跳间隔计算
                _acs_heartbeat=$(get_config_value "$MODDIR/service.sh" "SLEEP_HEARTBEAT")
                case "$_acs_heartbeat" in *[!0-9]*) _acs_heartbeat=1800 ;; esac
                [ "$_acs_heartbeat" -eq 0 ] && _acs_heartbeat=1800
                
                if [ "$_acs_last_run" -gt 0 ]; then
                    _acs_next_run=$((_acs_last_run + _acs_heartbeat))
                else
                    _acs_next_run=$((_acs_now + _acs_heartbeat))
                fi
                ;;
        esac
        
        # 判断配置是否同步
        _acs_synced="true"
        _acs_pending="false"
        
        # 如果上次运行时间早于配置修改时间，则配置待生效
        _acs_config_mtime=0
        if [ -f "$MODDIR/service.sh" ]; then
            _acs_config_mtime=$(stat -c%Y "$MODDIR/service.sh" 2>/dev/null)
            case "$_acs_config_mtime" in *[!0-9]*) _acs_config_mtime=0 ;; esac
        fi
        
        if [ "$_acs_last_run" -lt "$_acs_config_mtime" ]; then
            _acs_synced="false"
            _acs_pending="true"
        fi
        
        # 返回状态
        printf '{"synced":%s,"last_run":%d,"next_run":%d,"pending_changes":%s}' \
            "$_acs_synced" "$_acs_last_run" "$_acs_next_run" "$_acs_pending"
    }
    
    # 2.11 API: 立即执行触发
    api_trigger_immediate() {
        touch_access
        
        # 定期清理过期文件
        cleanup_old_executions
        
        printf 'Content-Type: application/json\r\n\r\n'
        
        # 生成执行 ID
        _ati_exec_id="exec_$(date +%s)_${_WEBUI_PID}"
        
        # 创建执行状态文件
        _ati_status_file="${WEBUI_TMP_DIR}/execution_${_ati_exec_id}.status"
        _ati_log_file="${WEBUI_TMP_DIR}/execution_${_ati_exec_id}.log"
        _ati_pid_file="${WEBUI_TMP_DIR}/execution_${_ati_exec_id}.pid"
        
        # 检查临时目录
        if [ ! -d "$WEBUI_TMP_DIR" ]; then
            mkdir -p "$WEBUI_TMP_DIR" 2>/dev/null || {
                printf '{"success":false,"message":"无法创建临时目录"}'
                return 1
            }
        fi
        
        # 写入初始状态
        if ! echo "running" > "$_ati_status_file" 2>/dev/null; then
            printf '{"success":false,"message":"无法创建状态文件"}'
            return 1
        fi
        
        # 后台执行 action.sh (配置应用模式)
        (
            # 记录开始时间
            _start=$(date +%s)
            
            # 确保 action.sh 有执行权限
            chmod 755 "$MODDIR/action.sh" 2>/dev/null
            
            # 执行 action.sh --apply-config
            /system/bin/sh "$MODDIR/action.sh" --apply-config > "$_ati_log_file" 2>&1
            _ret=$?
            
            # 记录结束时间
            _end=$(date +%s)
            _duration=$((_end - _start))
            
            # 更新状态
            if [ "$_ret" -eq 0 ]; then
                echo "completed:$_duration" > "$_ati_status_file" 2>/dev/null
            else
                echo "failed:$_ret:$_duration" > "$_ati_status_file" 2>/dev/null
            fi
            
            # 清理 PID 文件
            rm -f "$_ati_pid_file" 2>/dev/null
        ) &
        
        # 记录后台进程 PID
        echo "$!" > "$_ati_pid_file" 2>/dev/null
        
        # 返回执行 ID
        _ati_exec_id_esc=$(json_escape "$_ati_exec_id")
        printf '{"success":true,"execution_id":"%s"}' "$_ati_exec_id_esc"
    }
    
    # 2.12 API: 执行状态查询
    api_execution_status() {
        touch_access
        
        # 从查询字符串中提取 execution_id
        _aes_exec_id="${QUERY_STRING#*id=}"
        _aes_exec_id="${_aes_exec_id%%&*}"
        
        printf 'Content-Type: application/json\r\n\r\n'
        
        # 验证 execution_id
        if [ -z "$_aes_exec_id" ]; then
            printf '{"error":"missing_execution_id"}'
            return 1
        fi
        
        # 读取状态文件
        _aes_status_file="${WEBUI_TMP_DIR}/execution_${_aes_exec_id}.status"
        _aes_log_file="${WEBUI_TMP_DIR}/execution_${_aes_exec_id}.log"
        
        if [ ! -f "$_aes_status_file" ]; then
            printf '{"error":"execution_not_found"}'
            return 1
        fi
        
        # 读取状态
        _aes_status_raw=""
        read -r _aes_status_raw < "$_aes_status_file" 2>/dev/null
        
        # 解析状态 (格式: status[:exit_code][:duration])
        _aes_status="${_aes_status_raw%%:*}"
        _aes_exit_code=0
        _aes_duration=0
        
        case "$_aes_status_raw" in
            *:*:*)
                # failed:1:12 或 completed:0:12
                _aes_tmp="${_aes_status_raw#*:}"
                _aes_exit_code="${_aes_tmp%%:*}"
                _aes_duration="${_aes_tmp#*:}"
                ;;
            *:*)
                # failed:1 或 completed:12
                _aes_tmp="${_aes_status_raw#*:}"
                case "$_aes_status" in
                    failed) _aes_exit_code="$_aes_tmp" ;;
                    completed) _aes_duration="$_aes_tmp" ;;
                esac
                ;;
        esac
        
        # 读取日志尾部（最后 20 行）
        _aes_log_tail="[]"
        if [ -f "$_aes_log_file" ]; then
            # 使用临时文件存储 tail 输出
            _aes_tmp_tail="${WEBUI_TMP_DIR}/tail_${_aes_exec_id}"
            
            if command -v tail >/dev/null 2>&1; then
                tail -n 20 "$_aes_log_file" > "$_aes_tmp_tail" 2>/dev/null
            else
                # 回退: tail 不可用时读取整个文件
                cat "$_aes_log_file" > "$_aes_tmp_tail" 2>/dev/null
            fi
            
            # 读取日志并转换为 JSON 数组
            _aes_lines=""
            while IFS= read -r _aes_line || [ -n "$_aes_line" ]; do
                _aes_line_esc=$(json_escape "$_aes_line")
                if [ -z "$_aes_lines" ]; then
                    _aes_lines="\"$_aes_line_esc\""
                else
                    _aes_lines="$_aes_lines,\"$_aes_line_esc\""
                fi
            done < "$_aes_tmp_tail"
            
            rm -f "$_aes_tmp_tail" 2>/dev/null
            [ -n "$_aes_lines" ] && _aes_log_tail="[$_aes_lines]"
        fi
        
        # 返回状态
        printf '{"status":"%s","log_tail":%s,"exit_code":%d,"duration":%d}' \
            "$_aes_status" "$_aes_log_tail" "$_aes_exit_code" "$_aes_duration"
    }
    
    # 2.13 API: 取消执行
    api_cancel_execution() {
        touch_access
        
        # 从查询字符串中提取 execution_id
        _ace_exec_id="${QUERY_STRING#*id=}"
        _ace_exec_id="${_ace_exec_id%%&*}"
        
        printf 'Content-Type: application/json\r\n\r\n'
        
        # 验证 execution_id
        if [ -z "$_ace_exec_id" ]; then
            printf '{"success":false,"message":"缺少 execution_id"}'
            return 1
        fi
        
        # 读取 PID 文件
        _ace_pid_file="${WEBUI_TMP_DIR}/execution_${_ace_exec_id}.pid"
        
        if [ ! -f "$_ace_pid_file" ]; then
            printf '{"success":false,"message":"执行已完成或不存在"}'
            return 1
        fi
        
        # 读取 PID
        _ace_pid=""
        read -r _ace_pid < "$_ace_pid_file" 2>/dev/null
        
        # 验证 PID
        if [ -z "$_ace_pid" ] || ! is_integer "$_ace_pid"; then
            printf '{"success":false,"message":"无效的 PID"}'
            return 1
        fi
        
        # 终止进程
        if [ -d "/proc/$_ace_pid" ]; then
            kill "$_ace_pid" 2>/dev/null
            sleep 1
            [ -d "/proc/$_ace_pid" ] && kill -9 "$_ace_pid" 2>/dev/null
        fi
        
        # 更新状态
        _ace_status_file="${WEBUI_TMP_DIR}/execution_${_ace_exec_id}.status"
        echo "cancelled" > "$_ace_status_file" 2>/dev/null
        
        # 清理 PID 文件
        rm -f "$_ace_pid_file" 2>/dev/null
        
        printf '{"success":true,"message":"已取消执行"}'
    }

    # 2.14 CGI 路由
    cgi_router() {
        _cr_route="$QUERY_STRING"
        case "$_cr_route" in
            /api/config)
                [ "$REQUEST_METHOD" = "POST" ] && api_config_set || api_config_get ;;
            /api/f2fsopt_config)
                [ "$REQUEST_METHOD" = "POST" ] && api_f2fsopt_config_set || api_f2fsopt_config_get ;;
            /api/action_config)
                [ "$REQUEST_METHOD" = "POST" ] && api_action_config_set || api_action_config_get ;;
            /api/status) api_status ;;
            /api/config_status) api_config_status ;;
            /api/trigger_immediate) api_trigger_immediate ;;
            /api/execution_status*) api_execution_status ;;
            /api/cancel_execution*) api_cancel_execution ;;
            /api/logs) api_logs_get ;;
            /api/action/*) REQUEST_URI="$_cr_route"; api_action ;;
            *) printf 'Status: 404\r\nContent-Type: text/plain\r\n\r\n404 Not Found\n' ;;
        esac
    }
    
    cgi_router
    exit 0
fi


# ==============================================================================
# PART 3: 守护进程模式 (自动退出监控 + 心跳检测)
# ==============================================================================
if [ "$MODE" = "daemon" ]; then
    _dm_httpd_pid="$2"
    _dm_launcher_pid="$3"
    _dm_wait_sec="$TIMEOUT_SEC"
    
    # 守护进程清理函数
    _dm_cleanup() {
        trap - EXIT INT TERM HUP QUIT ABRT
        
        # 清理 httpd 进程（如果还存活）
        if [ -n "$_dm_httpd_pid" ] && [ -d "/proc/$_dm_httpd_pid" ]; then
            kill "$_dm_httpd_pid" 2>/dev/null
            sleep 0.5
            [ -d "/proc/$_dm_httpd_pid" ] && kill -9 "$_dm_httpd_pid" 2>/dev/null
        fi
        
        # 清理临时文件
        webui_log "守护进程清理: $WEBROOT"
        webui_log "守护进程清理: $LAST_ACCESS_FILE"
        rm -rf "$WEBROOT" "$LAST_ACCESS_FILE" 2>/dev/null
        
        # 清理会话执行记录
        cleanup_webui_session
        
        exit 0
    }
    trap '_dm_cleanup' EXIT INT TERM HUP QUIT ABRT
    
    # 初始化访问时间文件（防止首次启动立即超时）
    date +%s > "$LAST_ACCESS_FILE" 2>/dev/null
    
    while true; do
        # 智能分段休眠 (防止长时间 Sleep 导致进程僵死，与 service.sh 保持一致)
        _dm_chunk="$HEARTBEAT_SEC"
        [ "$_dm_wait_sec" -lt "$HEARTBEAT_SEC" ] 2>/dev/null && _dm_chunk="$_dm_wait_sec"
        sleep "$_dm_chunk"
        
        # 检查 httpd 进程是否存活
        if [ -n "$_dm_httpd_pid" ] && [ ! -d "/proc/$_dm_httpd_pid" ]; then
            webui_warn "httpd 进程已退出，守护进程终止"
            exit 0  # 触发 trap 清理
        fi
        
        # 超时检测
        if [ -f "$LAST_ACCESS_FILE" ]; then
            read -r _dm_last_ts < "$LAST_ACCESS_FILE" 2>/dev/null
            _dm_curr_ts=$(date +%s 2>/dev/null) || _dm_curr_ts=0
            if [ "$_dm_last_ts" -gt 0 ] 2>/dev/null && [ "$_dm_curr_ts" -gt 0 ] 2>/dev/null; then
                _dm_diff=$((_dm_curr_ts - _dm_last_ts))
                # 时间回拨保护
                [ "$_dm_diff" -lt 0 ] 2>/dev/null && { date +%s > "$LAST_ACCESS_FILE" 2>/dev/null; continue; }
                
                if [ "$_dm_diff" -gt "$TIMEOUT_SEC" ] 2>/dev/null; then
                    webui_log "$(printf '%d 分钟无操作，自动退出' "$((TIMEOUT_SEC / 60))")"
                    printf '\n%d 分钟无操作，自动退出\n' "$((TIMEOUT_SEC / 60))"
                    
                    # 通知主进程退出
                    [ -n "$_dm_launcher_pid" ] && [ -d "/proc/$_dm_launcher_pid" ] && kill -TERM "$_dm_launcher_pid" 2>/dev/null
                    
                    exit 0  # 触发 trap 清理
                fi
                
                # 更新剩余等待时间
                _dm_wait_sec=$(($TIMEOUT_SEC - _dm_diff))
            fi
        fi
    done
fi

# ==============================================================================
# PART 4: 启动器模式 (Main Mode)
# ==============================================================================

# 清理函数
cleanup() {
    trap - EXIT INT TERM HUP QUIT ABRT
    
    # 清理守护进程
    if [ -n "$DAEMON_PID" ] && [ -d "/proc/$DAEMON_PID" ]; then
        kill -TERM "$DAEMON_PID" 2>/dev/null
        sleep 0.5
        [ -d "/proc/$DAEMON_PID" ] && kill -9 "$DAEMON_PID" 2>/dev/null
    fi
    
    # 清理 httpd 进程
    if [ -n "$HTTPD_PID" ] && [ -d "/proc/$HTTPD_PID" ]; then
        kill -TERM "$HTTPD_PID" 2>/dev/null
        sleep 0.5
        [ -d "/proc/$HTTPD_PID" ] && kill -9 "$HTTPD_PID" 2>/dev/null
    fi
    
    # 清理当前实例的临时文件
    webui_log "清理临时文件: $WEBROOT"
    webui_log "清理访问时间戳: $LAST_ACCESS_FILE"
    rm -rf "$WEBROOT" "$LAST_ACCESS_FILE" 2>/dev/null
    
    # 清理端口信息文件
    rm -f "$MODDIR/webui.port" 2>/dev/null
    
    # 清理孤儿临时文件（可选）
    if [ -d "$WEBUI_TMP_DIR" ]; then
        _orphan_count=0
        for _tmp_item in "$WEBUI_TMP_DIR"/*; do
            [ ! -e "$_tmp_item" ] && continue
            # 提取 PID
            _tmp_pid="${_tmp_item##*_}"
            # 检查进程是否存在
            if [ -n "$_tmp_pid" ] && ! [ -d "/proc/$_tmp_pid" ]; then
                webui_log "清理孤儿文件: $_tmp_item [PID: $_tmp_pid]"
                rm -rf "$_tmp_item" 2>/dev/null && _orphan_count=$((_orphan_count + 1))
            fi
        done
        [ "$_orphan_count" -gt 0 ] && webui_log "已清理 $_orphan_count 个孤儿文件"
    fi
    
    printf '\nWeb UI 已停止\n'
    exit 0
}
trap cleanup EXIT INT TERM HUP QUIT ABRT

# 记录启动信息
webui_log "WebUI 启动 [PID: $_WEBUI_PID]"
webui_log "临时目录根: $WEBUI_TMP_DIR"
webui_log "Web 根目录: $WEBROOT"
webui_log "访问时间戳文件: $LAST_ACCESS_FILE"

# 端口探测
PORT=9527
while "$BB_PATH" netstat -tuln 2>/dev/null | "$BB_PATH" grep -q ":${PORT} "; do
    PORT=$((PORT + 1))
    [ "$PORT" -gt 9546 ] && { echo "无可用端口 (9527-9546)"; exit 1; }
done

# 准备环境
# 确保临时目录根存在
mkdir -p "$WEBUI_TMP_DIR" 2>/dev/null || {
    printf '❌ 错误: 无法创建临时目录根 %s\n' "$WEBUI_TMP_DIR" >&2
    printf '   提示: 检查模块目录权限\n' >&2
    exit 1
}

# 清理旧的同 PID 目录（防止冲突）
rm -rf "$WEBROOT" 2>/dev/null

# 创建 Web 根目录
mkdir -p "$WEBROOT/cgi-bin" || {
    printf '❌ 错误: 无法创建 Web 根目录 %s\n' "$WEBROOT" >&2
    exit 1
}

# 生成 CGI Shim
cat > "$WEBROOT/cgi-bin/api.sh" << CGISHIM
#!/system/bin/sh
MODDIR="${MODDIR}"
BB_PATH="${BB_PATH}"
LOG_FILE="${LOG_FILE}"
LOG_MODE="${LOG_MODE}"
. "\$MODDIR/webui.sh" --lib-mode
CGISHIM
chmod 755 "$WEBROOT/cgi-bin/api.sh"


# 复制静态 HTML 文件
_html_src="$MODDIR/webui/index.html"
if [ ! -f "$_html_src" ]; then
    printf '❌ 错误: 找不到 HTML 模板文件 %s\n' "$_html_src" >&2
    exit 1
fi

if ! cp "$_html_src" "$WEBROOT/index.html" 2>/dev/null; then
    printf '❌ 错误: 无法复制 HTML 文件到 %s\n' "$WEBROOT" >&2
    exit 1
fi

chmod 644 "$WEBROOT/index.html" 2>/dev/null


# 启动服务
date +%s > "$LAST_ACCESS_FILE"

# 启动 httpd
"$BB_PATH" httpd -f -h "$WEBROOT" -p "127.0.0.1:${PORT}" >/dev/null 2>&1 &
HTTPD_PID=$!

# 保存端口信息到文件（供 action.sh 读取）
printf '%s\n' "$PORT" > "$MODDIR/webui.port" 2>/dev/null

# 启动守护进程 (统一使用 _WEBUI_PID)
/system/bin/sh "$0" --daemon-mode "$HTTPD_PID" "$_WEBUI_PID" >/dev/null 2>&1 &
DAEMON_PID=$!

# 打开浏览器
URL="http://127.0.0.1:${PORT}"
command -v am >/dev/null 2>&1 && am start -a android.intent.action.VIEW -d "$URL" >/dev/null 2>&1

# 记录启动日志
webui_log "Web UI 已启动，端口: $PORT"

echo ""
echo "======================================"
echo "  F2FS-Optimizer - Web UI"
echo "======================================"
echo "  地址: $URL"
echo "  PID: $_MAIN_PID (HTTPD: $HTTPD_PID)"
echo "  ${TIMEOUT_SEC} 秒无操作自动退出"
echo "  按 Ctrl+C 手动停止"
echo "======================================"
echo ""

# 阻塞等待 httpd 结束
wait "$HTTPD_PID" 2>/dev/null
