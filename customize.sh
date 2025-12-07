##########################################################################################
#
# Magisk模块自定义安装脚本
#
##########################################################################################


##########################################################################################
# 替换列表
##########################################################################################


# 按以下格式构建替换列表
# 示例
REPLACE_EXAMPLE="
/system/app/YouTube
/system/app/Bloatware
"
#上面的替换列表将导致创建以下文件：
#$MODPATH/system/app/YouTube/.replace
#$MODPATH/system/app/Bloatware/.replace

# 在这里构建自定义替换列表
REPLACE="
"

##########################################################################################
# 安装前环境检测
##########################################################################################

# ============ 工具函数层 ============

# 命令可用性缓存（性能优化）
HAS_TIMEOUT=false
HAS_STAT=false

command -v timeout >/dev/null 2>&1 && HAS_TIMEOUT=true
command -v stat >/dev/null 2>&1 && HAS_STAT=true

# 整数验证
is_integer() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

# 安全读取文件首行（健壮版：完全抑制错误 + 变量清空）
read_first_line() {
    eval "$1=''"  # 先清空目标变量
    [ -r "$2" ] 2>/dev/null || return 1
    local _tmp_line=""
    read -r _tmp_line < "$2" 2>/dev/null || return 1
    eval "$1=\$_tmp_line"
}

# 路径解码：安全处理八进制转义序列（仅\040空格、\011Tab、\012换行）
decode_path() {
    local _path="$1" _out="" _c _oct
    
    # 快速路径：无转义直接返回
    case "$_path" in
        *\\[0-7][0-7][0-7]*) ;;
        *) printf '%s\n' "$_path"; return 0 ;;
    esac
    
    # 安全解析：仅处理常见八进制转义
    while [ -n "$_path" ]; do
        case "$_path" in
            \\[0-7][0-7][0-7]*)
                _oct="${_path#\\}"
                _oct="${_oct%%[!0-7]*}"
                _c="${_oct#[0-7]}"
                _c="${_c#[0-7]}"
                _oct="${_oct%"$_c"}"
                
                case "$_oct" in
                    040) _out="$_out " ;;      # 空格
                    011) _out="$_out	" ;;    # Tab
                    012) _out="$_out
" ;;                                           # 换行
                    *) _out="$_out\\$_oct" ;;  # 其他保留原样
                esac
                
                _path="${_path#\\$_oct}"
                ;;
            *\\*)
                _out="$_out${_path%%\\*}"
                _path="${_path#*\\}"
                ;;
            *)
                _out="$_out$_path"
                break
                ;;
        esac
    done
    printf '%s\n' "$_out"
}

# ============ 设备解析层 ============

# 解析设备路径：处理符号链接 (同步 f2fsopt 逻辑)
resolve_dev_path() {
    local _path="$1" _limit=10 _target _dir _out
    
    # 快速路径: readlink -f (如果支持)
    _out=$(readlink -f "$_path" 2>/dev/null)
    [ -e "$_out" ] && { printf '%s\n' "$_out"; return 0; }
    
    # 回退路径: 手动递归解析
    while [ -L "$_path" ] && [ "$_limit" -gt 0 ]; do
        # 策略 1: 优先使用 readlink
        _target=$(readlink "$_path" 2>/dev/null)
        
        # 策略 2: readlink 失败时回退到 ls -l（兼容性保护）
        if [ -z "$_target" ]; then
            local _ls_out=$(ls -l "$_path" 2>/dev/null)
            case "$_ls_out" in *" -> "*) _target="${_ls_out##* -> }" ;; *) break ;; esac
        fi
        
        _target="${_target## }"; _target="${_target%% }"
        [ -z "$_target" ] && break
        
        case "$_target" in 
            /*) _path="$_target" ;;
            *) 
                _dir="${_path%/*}"
                [ "$_dir" = "$_path" ] && _dir="."
                _path="$_dir/$_target"
            ;;
        esac
        _limit=$((_limit - 1))
    done
    
    # 简单的规范化 (移除 /./)
    while case "$_path" in */./*) true;; *) false;; esac; do
        _path="${_path%%/./*}/${_path#*/./}"
    done
    [ -e "$_path" ] && printf '%s\n' "$_path"
}

# 获取挂载点设备ID
get_mountinfo_id() {
    local _target_mnt="$1" _decoded_mnt
    [ -r "/proc/self/mountinfo" ] || return 1
    while read -r _id _par _devid _root _mnt _rest; do
        _decoded_mnt=$(decode_path "$_mnt")
        if [ "$_decoded_mnt" = "$_target_mnt" ]; then
            printf '%s\n' "$_devid"
            return 0
        fi
    done < /proc/self/mountinfo
    return 1
}

# 获取设备唯一指纹 (同步 f2fsopt 优化版本)
get_device_fingerprint() {
    local _path="$1" _mnt="$2" _real_path _bname _id=""
    
    _real_path=$(resolve_dev_path "$_path")
    
    # 优先级 1: Stat
    if [ "$HAS_STAT" = true ] && [ -e "$_real_path" ]; then
        local _maj _min _stat_out
        if [ "$HAS_TIMEOUT" = true ]; then
            _stat_out=$(timeout 2 stat -L -c '%t %T' "$_real_path" 2>/dev/null)
        else
            _stat_out=$(stat -L -c '%t %T' "$_real_path" 2>/dev/null)
        fi
        if [ -n "$_stat_out" ]; then
            _maj="${_stat_out%% *}"
            _min="${_stat_out##* }"
            case "$_maj$_min" in *[!0-9a-fA-F]*) ;; *)
                printf "%d:%d" "0x$_maj" "0x$_min"
                return 0
            ;; esac
        fi
    fi
    
    # 优先级 2: Mountinfo (回退)
    if [ -n "$_mnt" ]; then
        _id=$(get_mountinfo_id "$_mnt")
        [ -n "$_id" ] && { printf '%s\n' "$_id"; return 0; }
    fi
    
    # 优先级 3: Sysfs (二次回退)
    _bname="${_real_path##*/}"
    if [ -r "/sys/class/block/$_bname/dev" ]; then
        read -r _id < "/sys/class/block/$_bname/dev" 2>/dev/null
        _id="${_id%% *}"
        [ -n "$_id" ] && { printf '%s\n' "$_id"; return 0; }
    fi

    # 优先级 4: 路径哈希 (最后手段)
    printf '%s\n' "PATH:$_real_path"
}

# ============ F2FS检测层 ============

# 查找 F2FS sysfs 节点: 目录名 > 精确匹配 > 模糊匹配
find_f2fs_node() {
    local _real_dev="$1" _bname="${1##*/}" _target_mm="" _iname
    
    if [ -r "/sys/class/block/$_bname/dev" ]; then
        read_first_line _target_mm "/sys/class/block/$_bname/dev"
        _target_mm="${_target_mm%% *}"
    fi
    
    # 优先级 1: 目录名
    [ -d "/sys/fs/f2fs/$_bname" ] && { printf '%s\n' "/sys/fs/f2fs/$_bname"; return 0; }
    [ -d "/sys/fs/mifs/$_bname" ] && { printf '%s\n' "/sys/fs/mifs/$_bname"; return 0; }
    
    # 优先级 2: 精确匹配 dev_name
    for _base in /sys/fs/f2fs /sys/fs/mifs; do
        [ -d "$_base" ] || continue
        for _d in "$_base"/*; do
            [ -e "$_d" ] || continue
            [ -f "$_d/dev_name" ] || continue
            read_first_line _iname "$_d/dev_name"
            _iname="${_iname%% *}"
            [ "$_iname" = "$_bname" ] && { printf '%s\n' "$_d"; return 0; }
            [ "$_iname" = "/dev/block/$_bname" ] && { printf '%s\n' "$_d"; return 0; }
            if [ -n "$_target_mm" ]; then
                [ "$_iname" = "$_target_mm" ] && { printf '%s\n' "$_d"; return 0; }
            fi
        done
    done
    
    # 优先级 3: 模糊匹配 (增强安全性：仅匹配完整路径段)
    for _base in /sys/fs/f2fs /sys/fs/mifs; do
        [ -d "$_base" ] || continue
        for _d in "$_base"/*; do
            [ -e "$_d" ] || continue
            [ -f "$_d/dev_name" ] || continue
            read_first_line _iname "$_d/dev_name"
            case "$_iname" in 
                *"/${_bname}"|"${_bname}") printf '%s\n' "$_d"; return 0 ;; 
            esac
        done
    done
    
    return 1
}

# 路径过滤（统一黑名单配置）
is_path_ignored() {
    local _path="$1" _prefix
    local _ignore_list="
/storage /mnt /apex /bionic /system /vendor /product /odm /dev /sys /proc
/acct /config /debug_ramdisk /data_mirror /linkerconfig /postinstall
/metadata /oem /lost+found /system_ext /vendor /my_product /odm /bin /sbin
/data/user_de /data/data /data/adb
"
    for _prefix in $_ignore_list; do
        case "$_path" in "$_prefix"|"${_prefix}"/*) return 0 ;; esac
    done
    return 1
}

# ============ 检测函数层 ============

# Layer 1: 基础环境检测
check_basic_env() {
    ui_print ""
    ui_print "▶ Layer 1: 基础环境检测"
    local _passed=true
    
    # 检测1: Shell兼容性（算术扩展+参数扩展）
    local _test_arith _test_param _test_str _shell_ok=true
    
    # 测试算术扩展
    _test_arith=$(( 2 + 3 )) 2>/dev/null || _test_arith=""
    if [ "$_test_arith" != "5" ]; then
        _shell_ok=false
    fi
    
    # 测试参数扩展（使用已知字符串）
    _test_str="/path/to/file.txt"
    _test_param="${_test_str##*/}" 2>/dev/null || _test_param=""
    if [ "$_test_param" != "file.txt" ]; then
        _shell_ok=false
    fi
    
    if $_shell_ok; then
        ui_print "  ✅ Shell: POSIX兼容"
    else
        ui_print "  ❌ Shell: 不兼容（缺少算术/参数扩展）"
        _passed=false
    fi
    
    # 检测2: Android版本
    local _api=$(getprop ro.build.version.sdk 2>/dev/null)
    if [ -n "$_api" ] && [ "$_api" -ge 21 ] 2>/dev/null; then
        ui_print "  ✅ Android: API $_api (兼容)"
    else
        ui_print "  ⚠️ Android: API ${_api:-未知} (未充分测试)"
    fi
    
    $_passed
}

# Layer 2: 依赖工具检测
check_dependencies() {
    ui_print ""
    ui_print "▶ Layer 2: 依赖工具检测"
    
    local _missing_critical=0
    local _missing_optional=0
    
    # 关键工具: fstrim
    if command -v fstrim >/dev/null 2>&1; then
        local _fstrim_help=$(fstrim --help 2>&1)
        case "$_fstrim_help" in
            *"-v"*|*"--verbose"*)
                ui_print "  ✅ fstrim: 可用（支持详细输出）"
                ;;
            *)
                ui_print "  ✅ fstrim: 可用（基础版本）"
                ;;
        esac
    else
        ui_print "  ❌ fstrim: 缺失（核心功能）"
        _missing_critical=$((_missing_critical + 1))
    fi
    
    # 可选工具: timeout
    if command -v timeout >/dev/null 2>&1; then
        ui_print "  ✅ timeout: 可用"
    else
        ui_print "  ⚠️ timeout: 缺失（无超时保护）"
        _missing_optional=$((_missing_optional + 1))
    fi
    
    # Busybox检测
    local _bb_path=""
    for _p in "/data/adb/magisk/busybox" "/data/adb/ksu/bin/busybox" "/data/adb/ap/bin/busybox" "/sbin/.magisk/busybox" "/system/xbin/busybox" "/system/bin/busybox" "$(command -v busybox)"; do
        if [ -x "$_p" ]; then
            _bb_path="$_p"
            break
        fi
    done
    
    if [ -n "$_bb_path" ]; then
        local _bb_ver=$("$_bb_path" 2>&1 | head -n 1 2>/dev/null)
        ui_print "  ✅ Busybox: $_bb_path"
        ui_print "      ${_bb_ver}"
    else
        ui_print "  ⚠️ Busybox: 未找到（使用系统命令）"
        _missing_optional=$((_missing_optional + 1))
    fi
    
    [ "$_missing_critical" -eq 0 ]
}

# Layer 3: 文件系统深度检测（完全复用f2fsopt逻辑）
check_filesystems_advanced() {
    ui_print ""
    ui_print "▶ Layer 3: 文件系统深度检测"
    ui_print "  (使用f2fsopt核心引擎)"
    
    local _candidates="" _unique_fps="" _fp _dev _mnt _type _opts _rest
    local _mnt_decoded _len _count=0 _scan_count=0 _skip_count=0
    
    # 扫描 /proc/mounts
    while read -r _dev _mnt _type _opts _rest; do
        # 基础过滤
        case "$_dev" in /dev/block/*) ;; *) continue ;; esac
        case "$_type" in f2fs|mifs|ext4) ;; *) continue ;; esac
        case "$_opts" in *rw,*) ;; *) continue ;; esac
        
        # 路径解码
        _mnt_decoded=$(decode_path "$_mnt")
        _mnt_decoded="${_mnt_decoded%/}"
        [ -z "$_mnt_decoded" ] && _mnt_decoded="/"  # 保护根分区
        
        # 统一黑名单检查
        if is_path_ignored "$_mnt_decoded"; then
            _skip_count=$((_skip_count + 1))
            continue
        fi
        
        _scan_count=$((_scan_count + 1))
        
        # 6. 设备指纹获取
        _fp=$(get_device_fingerprint "$_dev" "$_mnt_decoded")
        [ -z "$_fp" ] && continue
        
        # 7. 记录候选
        _len=${#_mnt_decoded} 2>/dev/null || _len=100
        _candidates="$_candidates${_fp}|${_len}|${_dev}|${_mnt_decoded}|${_type}
"
        case " $_unique_fps " in
            *" $_fp "*) ;;
            *) _unique_fps="$_unique_fps $_fp" ;;
        esac
    done < /proc/mounts
    
    # 设备去重与分析
    local _f2fs_count=0 _ext4_count=0 _final_targets=""
    
    # 内存解析
    local _old_ifs="$IFS"
    set -f
    
    # 外层循环 (默认 IFS)
    for _u_fp in $_unique_fps; do
        local _best_len=99999 _best_line="" _dup_count=0
        
        # 内层循环 (换行分隔)
        IFS='
'
        for _line in $_candidates; do
            IFS='|'
            set -- $_line
            IFS='
'
            local _rid="$1" _rlen="$2" _rdev="$3" _rmnt="$4" _rtype="$5"
            
            if [ "$_rid" = "$_u_fp" ]; then
                _dup_count=$((_dup_count + 1))
                if [ "$_rlen" -lt "$_best_len" ] 2>/dev/null; then
                    _best_len="$_rlen"
                    _best_line="$_rdev|$_rmnt|$_rtype"
                fi
            fi
        done
        IFS="$_old_ifs"
        
        if [ -n "$_best_line" ]; then
            _final_targets="$_final_targets$_best_line
"
            _count=$((_count + 1))
            
            # 解析类型统计
            local _rtype="${_best_line##*|}"
            case "$_rtype" in
                f2fs|mifs) _f2fs_count=$((_f2fs_count + 1)) ;;
                ext4) _ext4_count=$((_ext4_count + 1)) ;;
            esac
        fi
    done
    
    # 结果输出
    ui_print "        ├─ 扫描统计: 处理 $_scan_count, 跳过 $_skip_count"
    ui_print "        ├─ 独立设备: $_count 个"
    ui_print "        ├─ F2FS/MIFS: $_f2fs_count 个"
    ui_print "        ├─ EXT4: $_ext4_count 个"
    ui_print "        └─ 目标分区:"
    
    if [ "$_count" -eq 0 ]; then
        ui_print "      ❌ 无可用分区"
        set +f
        IFS="$_old_ifs"
        return 1
    fi
    
    # 详细列表
    IFS='
'
    for _line in $_final_targets; do
        IFS='|'
        set -- $_line
        IFS='
'
        local _dev="$1" _mnt="$2" _type="$3"
        [ -z "$_mnt" ] && continue
        ui_print "      · $_mnt [$_type]"
    done
    
    set +f
    IFS="$_old_ifs"
    
    ui_print "  ✅ 文件系统检测通过"
    return 0
}

# Layer 4: 内核接口深度检测
check_kernel_support_advanced() {
    ui_print ""
    ui_print "▶ Layer 4: 内核接口深度检测"
    
    local _total_nodes=0 _writable_gc=0 _readonly_gc=0
    local _node _real_dev _bname
    
    # 分析所有F2FS sysfs节点
    for _node in /sys/fs/f2fs/* /sys/fs/mifs/*; do
        [ -e "$_node" ] || continue
        [ -d "$_node" ] || continue
        [ -f "$_node/dirty_segments" ] || continue
        
        _total_nodes=$((_total_nodes + 1))
        
        # 检测GC可写性
        if [ -w "$_node/gc_urgent" ]; then
            _writable_gc=$((_writable_gc + 1))
            
            # 详细能力检测
            local _has_sleep=false
            [ -f "$_node/gc_urgent_sleep_time" ] && _has_sleep=true
            
            # 读取设备名（可选信息）
            local _dev_name="" _node_name="${_node##*/}"
            
            if [ -f "$_node/dev_name" ]; then
                read_first_line _dev_name "$_node/dev_name"
                # 清理空白字符
                _dev_name="${_dev_name## }"
                _dev_name="${_dev_name%% }"
            fi
            
            # 根据是否有设备名调整显示格式
            if [ -n "$_dev_name" ]; then
                ui_print "        ├─ 节点: ${_node_name} (${_dev_name})"
            else
                ui_print "        ├─ 节点: ${_node_name}"
            fi
            ui_print "        │        ├─ GC接口: 可写 ✅"
            if $_has_sleep; then
                ui_print "        │        └─ Turbo GC: 支持 ✅"
            else
                ui_print "        │        └─ Turbo GC: 不支持 ⚠️"
            fi
        else
            _readonly_gc=$((_readonly_gc + 1))
            ui_print "        ├─ 节点: ${_node##*/} (只读)"
        fi
    done
    
    if [ "$_total_nodes" -eq 0 ]; then
        ui_print "  ⚠️ 无F2FS sysfs节点 - GC功能不可用"
        ui_print "  → 将仅执行Trim操作"
    else
        ui_print "  ✅ 发现 $_total_nodes 个F2FS节点"
        ui_print "      · 可写: $_writable_gc 个"
        ui_print "      · 只读: $_readonly_gc 个"
    fi
    
    # StorageManager检测
    if command -v sm >/dev/null 2>&1; then
        local _sm_test _sm_ret
        _sm_test=$(sm list-disks 2>&1)
        _sm_ret=$?
        if [ "$_sm_ret" -eq 0 ] 2>/dev/null; then
            ui_print "  ✅ StorageManager: 可用（系统回退）"
        else
            ui_print "  ⚠️ StorageManager: 受限"
        fi
    else
        ui_print "  ⚠️ StorageManager: 不可用"
    fi
    
    return 0
}

# Layer 5: 配置语法检测
check_service_config() {
    ui_print ""
    ui_print "▶ Layer 5: 配置语法检测"
    
    local _passed=true
    local _service_file="$MODPATH/service.sh"
    
    if [ ! -f "$_service_file" ]; then
        ui_print "  ❌ service.sh 文件不存在"
        return 1
    fi
    
    local _schedule_mode="" _cron_exp="" _line
    
    # 提取配置（纯Shell内建，安全解析，支持注释和引号）
    while IFS= read -r _line || [ -n "$_line" ]; do
        # 1. 去除注释
        _line="${_line%%#*}"
        
        case "$_line" in
            *SCHEDULE_MODE=*)
                _val="${_line#*=}"
                # 提取引号内容
                case "$_val" in
                    *\"*\"*) _val="${_val#*\"}"; _val="${_val%%\"*}" ;;
                    *\'*\'*) _val="${_val#*\'}"; _val="${_val%%\'*}" ;;
                    *) 
                        # 纯Shell移除空白：删除首尾空格/Tab
                        while case "$_val" in [' 	']*) true;; *) false;; esac; do
                            _val="${_val#?}"
                        done
                        while case "$_val" in *[' 	']) true;; *) false;; esac; do
                            _val="${_val%?}"
                        done
                        ;;
                esac
                [ -n "$_val" ] && _schedule_mode="$_val"
                ;;
            *CRON_EXP=*)
                _val="${_line#*=}"
                case "$_val" in
                    *\"*\"*) _val="${_val#*\"}"; _val="${_val%%\"*}" ;;
                    *\'*\'*) _val="${_val#*\'}"; _val="${_val%%\'*}" ;;
                esac
                [ -n "$_val" ] && _cron_exp="$_val"
                ;;
        esac
    done < "$_service_file"
    
    # 检测 SCHEDULE_MODE
    case "$_schedule_mode" in
        "sleep"|"cron")
            ui_print "  ✅ 调度模式: $_schedule_mode"
            ;;
        "")
            ui_print "  ❌ 调度模式: 未配置"
            ui_print "     → 请设置 SCHEDULE_MODE=\"sleep\" 或 \"cron\""
            _passed=false
            ;;
        *)
            ui_print "  ❌ 调度模式: 无效值 \"$_schedule_mode\""
            ui_print "     → 仅支持: sleep 或 cron"
            _passed=false
            ;;
    esac
    
    # 检测 CRON_EXP 语法
    if [ -z "$_cron_exp" ]; then
        ui_print "  ❌ Cron表达式: 未配置"
        ui_print "     → 请设置 CRON_EXP"
        _passed=false
    else
        if validate_cron_syntax "$_cron_exp" "$_schedule_mode"; then
            ui_print "  ✅ Cron表达式: $_cron_exp"
        else
            _passed=false
        fi
    fi
    
    $_passed
}

# Cron 表达式语法验证
validate_cron_syntax() {
    local _exp="$1" _mode="$2"
    
    # 解析五段式 Cron 表达式
    set -f; set -- $_exp; set +f
    local _min="$1" _hour="$2" _day="$3" _month="$4" _dow="$5"
    
    if [ "$#" -ne 5 ]; then
        ui_print "  ❌ Cron表达式: 格式错误（需要5段）"
        ui_print "     → 当前: $_exp"
        ui_print "     → 示例: \"0 */4 * * *\""
        return 1
    fi
    
    # Sleep 模式专用格式验证
    if [ "$_mode" = "sleep" ]; then
        # 格式1: */N * * * * (每N分钟)
        case "$_min" in
            \*/[0-9]*)
                local _step="${_min#*/}"
                if is_integer "$_step" && [ "$_step" -gt 0 ] 2>/dev/null && [ "$_step" -le 60 ] 2>/dev/null; then
                    if [ "$_hour" = "*" ] && [ "$_day" = "*" ] && [ "$_month" = "*" ] && [ "$_dow" = "*" ]; then
                        return 0
                    fi
                fi
                ;;
        esac
        
        # 格式2/3: M */N * * * (每N小时的M分)
        case "$_hour" in
            \*/[0-9]*)
                local _step="${_hour#*/}"
                local _m="${_min#0}"; _m="${_m#0}"; [ -z "$_m" ] && _m=0
                if is_integer "$_step" && [ "$_step" -gt 0 ] 2>/dev/null && [ "$_step" -le 24 ] 2>/dev/null; then
                    if is_integer "$_m" && [ "$_m" -ge 0 ] 2>/dev/null && [ "$_m" -le 59 ] 2>/dev/null; then
                        if [ "$_day" = "*" ] && [ "$_month" = "*" ] && [ "$_dow" = "*" ]; then
                            return 0
                        fi
                    fi
                fi
                ;;
        esac
        
        # 格式4: M H * * * (每天固定时间)
        if is_integer "$_min" && is_integer "$_hour"; then
            if [ "$_min" -ge 0 ] 2>/dev/null && [ "$_min" -le 59 ] 2>/dev/null; then
                if [ "$_hour" -ge 0 ] 2>/dev/null && [ "$_hour" -le 23 ] 2>/dev/null; then
                    if [ "$_day" = "*" ] && [ "$_month" = "*" ] && [ "$_dow" = "*" ]; then
                        return 0
                    fi
                fi
            fi
        fi
        
        # Sleep 模式不支持的格式
        ui_print "  ❌ Cron表达式: Sleep模式不支持此格式"
        ui_print "     → 当前: $_exp"
        ui_print "     → 支持格式:"
        ui_print "       • \"*/N * * * *\"  (每N分钟)"
        ui_print "       • \"0 */N * * *\"  (每N小时整点)"
        ui_print "       • \"M */N * * *\"  (每N小时M分)"
        ui_print "       • \"M H * * *\"    (每天H:M)"
        return 1
    fi
    
    # Cron 模式：基础语法检查
    if [ "$_mode" = "cron" ]; then
        # 检查每段是否为有效字符
        local _valid=true
        for _field in "$_min" "$_hour" "$_day" "$_month" "$_dow"; do
            case "$_field" in
                *[!0-9\*\-\,\/]*)
                    _valid=false
                    break
                    ;;
            esac
        done
        
        if $_valid; then
            return 0
        else
            ui_print "  ❌ Cron表达式: 包含非法字符"
            ui_print "     → 当前: $_exp"
            ui_print "     → 允许字符: 0-9 * - , /"
            return 1
        fi
    fi
    
    return 1
}

# 诊断报告
print_diagnosis() {
    local _fail="$1" _warn="$2"
    
    ui_print ""
    ui_print "╔══════════════════════════╗"
    
    if [ "$_fail" -eq 0 ] 2>/dev/null && [ "$_warn" -eq 0 ] 2>/dev/null; then
        ui_print "║  🎉 完美兼容 - 推荐安装        "
        ui_print "║  预期: 所有功能完整可用            "
    elif [ "$_fail" -eq 0 ] 2>/dev/null; then
        ui_print "║  ✅ 基本兼容 - 建议安装            "
        ui_print "║  警告项: $_warn 个                    "
        ui_print "║  预期: 核心功能可用                "
    else
        ui_print "║  ❌ 不兼容 - 不建议安装            "
        ui_print "║  致命问题: $_fail 个                  "
        ui_print "║  建议: 检查设备环境                "
    fi
    
    ui_print "╚══════════════════════════╝"
    ui_print ""
}

# 主检测函数
pre_install_check() {
    ui_print "╔══════════════════════════╗"
    ui_print "║   兼容性检测           "
    ui_print "╚══════════════════════════╝"
    
    local _fail_count=0
    local _warn_count=0
    
    # Layer 1: 基础环境
    if ! check_basic_env; then
        _fail_count=$((_fail_count + 1))
    fi
    
    # Layer 2: 依赖工具
    check_dependencies || _warn_count=$((_warn_count + 1))
    
    # Layer 3: 文件系统深度检测
    if ! check_filesystems_advanced; then
        _fail_count=$((_fail_count + 1))
    fi
    
    # Layer 4: 内核接口深度检测
    check_kernel_support_advanced || _warn_count=$((_warn_count + 1))
    
    # Layer 5: 配置语法检测
    if ! check_service_config; then
        _fail_count=$((_fail_count + 1))
    fi
    
    # 综合评估
    print_diagnosis "$_fail_count" "$_warn_count"
    
    [ "$_fail_count" -eq 0 ]
}

##########################################################################################
# 权限设置
##########################################################################################


set_permissions() {
#  ui_print "- 正在设置权限..."
  
  # 默认规则: 目录755, 文件644
  set_perm_recursive "$MODPATH" 0 0 0755 0644
  
  # 核心脚本与服务脚本赋予可执行权限
  set_perm "$MODPATH/service.sh"      0 0 0755
  set_perm "$MODPATH/action.sh"       0 0 0755
  set_perm "$MODPATH/post-fs-data.sh" 0 0 0755
  set_perm "$MODPATH/f2fsopt"         0 0 0755
  set_perm "$MODPATH/uninstall.sh"    0 0 0755
  
#  ui_print "- 权限设置完成"
}


##########################################################################################
# 安装流程集成
##########################################################################################

# 执行安装前检测
if ! pre_install_check; then
    ui_print ""
    ui_print "══════════════════════════"
    ui_print "⚠️ 兼容性检测未通过，刷入部分功能可能不可用"
    ui_print ""
    ui_print "建议操作："
    ui_print "  1. 确认存在F2FS/EXT4分区"
    ui_print "  2. 查看上方详细检测结果"
    ui_print ""
#    ui_print "如需强制安装，请修改customize.sh"
    ui_print "══════════════════════════"
    ui_print ""
    
#    abort "❌ 安装已取消 - 设备不兼容"
fi

ui_print ""
# ui_print "✅ 兼容性检测通过，继续安装..."
ui_print ""

# 您可以添加更多功能来协助您的自定义脚本代码









