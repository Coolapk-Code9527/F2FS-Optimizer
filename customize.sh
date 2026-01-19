##########################################################################################
#
# Magisk模块自定义安装脚本
#
##########################################################################################

##########################################################################################
# 完全控制安装流程
##########################################################################################

# 声明 SKIPUNZIP=1 跳过默认安装步骤
# 手动处理所有安装过程：解压、配置迁移、权限设置
SKIPUNZIP=1

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

# 命令可用性缓存
HAS_TIMEOUT=false
HAS_STAT=false

command -v timeout >/dev/null 2>&1 && HAS_TIMEOUT=true
command -v stat >/dev/null 2>&1 && HAS_STAT=true

# 整数验证
is_integer() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;  # 空字符串或包含非数字字符
        *) return 0 ;;             # 纯数字字符串
    esac
}

# 配置值提取函数
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
                                # 使用循环逐步去除，直到找不到 "空白+#" 模式
                                while case "$_gcv_val" in *[' 	']#*) true;; *) false;; esac; do
                                    _gcv_val="${_gcv_val%%[' 	']#*}"
                                done
                                ;;
                        esac
                        
                        # 去除首尾空白字符（使用更高效的方法）
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

# 验证 f2fsopt 文件完整性
verify_f2fsopt_integrity() {
    _vfi_file="$1"  # 接受文件路径作为参数
    _vfi_size=0
    
    # 检查文件存在
    [ -f "$_vfi_file" ] || return 1
    
    # 检查文件大小 (至少 10KB)
    if command -v stat >/dev/null 2>&1; then
        _vfi_size=$(stat -c%s "$_vfi_file" 2>/dev/null) || _vfi_size=0
    else
        _vfi_size=$(wc -c < "$_vfi_file" 2>/dev/null) || _vfi_size=0
    fi
    
    [ "$_vfi_size" -lt 10240 ] && return 2
    
    # 检查关键函数存在
    grep -q 'process_target()' "$_vfi_file" || return 3
    grep -q 'cleanup()' "$_vfi_file" || return 3
    grep -q 'acquire_lock()' "$_vfi_file" || return 3
    
    return 0
}

# 安全读取文件首行（抑制错误 + 变量清空）
read_first_line() {
    eval "$1=''"  # 先清空目标变量
    [ -r "$2" ] 2>/dev/null || return 1
    _rfl_tmp_line=""
    read -r _rfl_tmp_line < "$2" 2>/dev/null || return 1
    eval "$1=\$_rfl_tmp_line"
}

# 路径解码：安全处理八进制转义序列（仅\040空格、\011Tab、\012换行）
decode_path() {
    _dp_path="$1"; _dp_out=""; _dp_c=""; _dp_oct=""
    
    # 快速路径：无转义直接返回
    case "$_dp_path" in
        *\\[0-7][0-7][0-7]*) ;;
        *) printf '%s\n' "$_dp_path"; return 0 ;;
    esac
    
    # 安全解析：仅处理常见八进制转义
    while [ -n "$_dp_path" ]; do
        case "$_dp_path" in
            \\[0-7][0-7][0-7]*)
                _dp_oct="${_dp_path#\\}"
                _dp_oct="${_dp_oct%%[!0-7]*}"
                _dp_c="${_dp_oct#[0-7]}"
                _dp_c="${_dp_c#[0-7]}"
                _dp_oct="${_dp_oct%"$_dp_c"}"
                
                case "$_dp_oct" in
                    040) _dp_out="$_dp_out " ;;      # 空格
                    011) _dp_out="$_dp_out	" ;;    # Tab
                    012) _dp_out="$_dp_out
" ;;                                           # 换行
                    *) _dp_out="$_dp_out\\$_dp_oct" ;;  # 其他保留原样
                esac
                
                _dp_path="${_dp_path#\\$_dp_oct}"
                ;;
            *\\*)
                _dp_out="$_dp_out${_dp_path%%\\*}"
                _dp_path="${_dp_path#*\\}"
                ;;
            *)
                _dp_out="$_dp_out$_dp_path"
                break
                ;;
        esac
    done
    printf '%s\n' "$_dp_out"
}

# ============ 设备解析层 ============

# 解析设备路径：处理符号链接 (同步 f2fsopt 逻辑)
resolve_dev_path() {
    _rdp_path="$1"; _rdp_limit=10; _rdp_target=""; _rdp_dir=""; _rdp_out=""
    _rdp_initial_limit=10
    
    # 快速路径: readlink -f (如果支持)
    _rdp_out=$(readlink -f "$_rdp_path" 2>/dev/null)
    [ -e "$_rdp_out" ] && { printf '%s\n' "$_rdp_out"; return 0; }
    
    # 回退路径: 手动递归解析
    while [ -L "$_rdp_path" ] && [ "$_rdp_limit" -gt 0 ]; do
        # 策略 1: 优先使用 readlink
        _rdp_target=$(readlink "$_rdp_path" 2>/dev/null)
        
        # 策略 2: readlink 失败时回退到 ls -l（兼容性保护）
        if [ -z "$_rdp_target" ]; then
            _rdp_ls_out=$(ls -l "$_rdp_path" 2>/dev/null)
            case "$_rdp_ls_out" in *" -> "*) _rdp_target="${_rdp_ls_out##* -> }" ;; *) break ;; esac
        fi
        
        _rdp_target="${_rdp_target## }"; _rdp_target="${_rdp_target%% }"
        [ -z "$_rdp_target" ] && break
        
        case "$_rdp_target" in 
            /*) _rdp_path="$_rdp_target" ;;
            *) 
                _rdp_dir="${_rdp_path%/*}"
                [ "$_rdp_dir" = "$_rdp_path" ] && _rdp_dir="."
                _rdp_path="$_rdp_dir/$_rdp_target"
            ;;
        esac
        _rdp_limit=$((_rdp_limit - 1))
    done
    
    # 记录递归深度超限情况（用于调试）
    if [ -L "$_rdp_path" ] && [ "$_rdp_limit" -eq 0 ]; then
        # 递归深度达到限制，可能存在循环链接
        # 注意：在安装脚本中不输出日志，仅在调试时启用
        : # 占位符，生产环境不输出
    fi
    
    # 简单的规范化 (移除 /./)
    while case "$_rdp_path" in */./*) true;; *) false;; esac; do
        _rdp_path="${_rdp_path%%/./*}/${_rdp_path#*/./}"
    done
    [ -e "$_rdp_path" ] && printf '%s\n' "$_rdp_path"
}

# 获取挂载点设备ID
get_mountinfo_id() {
    _gmi_target_mnt="$1"; _gmi_decoded_mnt=""
    [ -r "/proc/self/mountinfo" ] || return 1
    while read -r _gmi_id _gmi_par _gmi_devid _gmi_root _gmi_mnt _gmi_rest; do
        _gmi_decoded_mnt=$(decode_path "$_gmi_mnt")
        if [ "$_gmi_decoded_mnt" = "$_gmi_target_mnt" ]; then
            printf '%s\n' "$_gmi_devid"
            return 0
        fi
    done < /proc/self/mountinfo
    return 1
}

# 获取设备唯一指纹 (同步 f2fsopt)
get_device_fingerprint() {
    _gdf_path="$1"; _gdf_mnt="$2"; _gdf_real_path=""; _gdf_bname=""; _gdf_id=""
    
    _gdf_real_path=$(resolve_dev_path "$_gdf_path")
    
    # 优先级 1: Stat
    if [ "$HAS_STAT" = true ] && [ -e "$_gdf_real_path" ]; then
        _gdf_maj=""; _gdf_min=""; _gdf_stat_out=""; _gdf_maj_dec=""; _gdf_min_dec=""
        
        # 尝试使用 timeout（如果可用），否则直接执行
        if [ "$HAS_TIMEOUT" = true ]; then
            _gdf_stat_out=$(timeout 2 stat -L -c '%t %T' "$_gdf_real_path" 2>/dev/null)
            # 如果 timeout 失败（返回码 124 表示超时），回退到无 timeout 版本
            if [ $? -eq 124 ] 2>/dev/null; then
                _gdf_stat_out=$(stat -L -c '%t %T' "$_gdf_real_path" 2>/dev/null)
            fi
        else
            _gdf_stat_out=$(stat -L -c '%t %T' "$_gdf_real_path" 2>/dev/null)
        fi
        
        if [ -n "$_gdf_stat_out" ]; then
            _gdf_maj="${_gdf_stat_out%% *}"
            _gdf_min="${_gdf_stat_out##* }"
            
            # 验证十六进制格式
            case "$_gdf_maj$_gdf_min" in *[!0-9a-fA-F]*) ;; *)
                # 尝试十六进制转换（验证 Shell 兼容性）
                _gdf_maj_dec=$(printf '%d' "0x$_gdf_maj" 2>/dev/null) || _gdf_maj_dec=""
                _gdf_min_dec=$(printf '%d' "0x$_gdf_min" 2>/dev/null) || _gdf_min_dec=""
                
                # 仅在转换成功时返回
                if [ -n "$_gdf_maj_dec" ] && [ -n "$_gdf_min_dec" ]; then
                    printf "%d:%d" "$_gdf_maj_dec" "$_gdf_min_dec"
                    return 0
                fi
            ;; esac
        fi
    fi
    
    # 优先级 2: Mountinfo (回退)
    if [ -n "$_gdf_mnt" ]; then
        _gdf_id=$(get_mountinfo_id "$_gdf_mnt")
        [ -n "$_gdf_id" ] && { printf '%s\n' "$_gdf_id"; return 0; }
    fi
    
    # 优先级 3: Sysfs (二次回退)
    _gdf_bname="${_gdf_real_path##*/}"
    if [ -r "/sys/class/block/$_gdf_bname/dev" ]; then
        read -r _gdf_id < "/sys/class/block/$_gdf_bname/dev" 2>/dev/null
        _gdf_id="${_gdf_id%% *}"
        [ -n "$_gdf_id" ] && { printf '%s\n' "$_gdf_id"; return 0; }
    fi

    # 优先级 4: 路径哈希 (最后手段)
    printf '%s\n' "PATH:$_gdf_real_path"
}

# ============ F2FS检测层 ============

# 查找 F2FS sysfs 节点: 目录名 > 精确匹配 > 模糊匹配
find_f2fs_node() {
    _ffn_real_dev="$1"; _ffn_bname="${1##*/}"; _ffn_target_mm=""; _ffn_iname=""
    
    if [ -r "/sys/class/block/$_ffn_bname/dev" ]; then
        read_first_line _ffn_target_mm "/sys/class/block/$_ffn_bname/dev"
        _ffn_target_mm="${_ffn_target_mm%% *}"
    fi
    
    # 优先级 1: 目录名
    [ -d "/sys/fs/f2fs/$_ffn_bname" ] && { printf '%s\n' "/sys/fs/f2fs/$_ffn_bname"; return 0; }
    [ -d "/sys/fs/mifs/$_ffn_bname" ] && { printf '%s\n' "/sys/fs/mifs/$_ffn_bname"; return 0; }
    
    # 优先级 2: 精确匹配 dev_name
    for _ffn_base in /sys/fs/f2fs /sys/fs/mifs; do
        [ -d "$_ffn_base" ] || continue
        for _ffn_d in "$_ffn_base"/*; do
            [ -e "$_ffn_d" ] || continue
            [ -f "$_ffn_d/dev_name" ] || continue
            read_first_line _ffn_iname "$_ffn_d/dev_name"
            _ffn_iname="${_ffn_iname%% *}"
            [ "$_ffn_iname" = "$_ffn_bname" ] && { printf '%s\n' "$_ffn_d"; return 0; }
            [ "$_ffn_iname" = "/dev/block/$_ffn_bname" ] && { printf '%s\n' "$_ffn_d"; return 0; }
            if [ -n "$_ffn_target_mm" ]; then
                [ "$_ffn_iname" = "$_ffn_target_mm" ] && { printf '%s\n' "$_ffn_d"; return 0; }
            fi
        done
    done
    
    # 优先级 3: 模糊匹配 (增强安全性：仅匹配完整路径段)
    for _ffn_base in /sys/fs/f2fs /sys/fs/mifs; do
        [ -d "$_ffn_base" ] || continue
        for _ffn_d in "$_ffn_base"/*; do
            [ -e "$_ffn_d" ] || continue
            [ -f "$_ffn_d/dev_name" ] || continue
            read_first_line _ffn_iname "$_ffn_d/dev_name"
            case "$_ffn_iname" in 
                *"/${_ffn_bname}"|"${_ffn_bname}") printf '%s\n' "$_ffn_d"; return 0 ;; 
            esac
        done
    done
    
    return 1
}

# 路径过滤（统一黑名单配置）
is_path_ignored() {
    _ipi_path="$1"; _ipi_prefix=""
    _ipi_ignore_list="
/storage /mnt /apex /bionic /system /vendor /product /odm /dev /sys /proc
/acct /config /debug_ramdisk /data_mirror /linkerconfig /postinstall
/metadata /oem /lost+found /system_ext /vendor /my_product /odm /bin /sbin
/data/user_de /data/data /data/adb
"
    for _ipi_prefix in $_ipi_ignore_list; do
        case "$_ipi_path" in "$_ipi_prefix"|"${_ipi_prefix}"/*) return 0 ;; esac
    done
    return 1
}

# ============ 检测函数层 ============

# Layer 1: 基础环境检测
check_basic_env() {
    ui_print ""
    ui_print "▶ Layer 1: 基础环境检测"
    _cbe_passed=true
    
    # 检测1: Shell兼容性（算术扩展+参数扩展）
    _cbe_test_arith=""; _cbe_test_param=""; _cbe_test_str=""; _cbe_shell_ok=true
    
    # 测试算术扩展
    _cbe_test_arith=$(( 2 + 3 )) 2>/dev/null || _cbe_test_arith=""
    if [ "$_cbe_test_arith" != "5" ]; then
        _cbe_shell_ok=false
    fi
    
    # 测试参数扩展（使用已知字符串）
    _cbe_test_str="/path/to/file.txt"
    _cbe_test_param="${_cbe_test_str##*/}" 2>/dev/null || _cbe_test_param=""
    if [ "$_cbe_test_param" != "file.txt" ]; then
        _cbe_shell_ok=false
    fi
    
    if $_cbe_shell_ok; then
        ui_print "  ✅ Shell: POSIX兼容"
    else
        ui_print "  ❌ Shell: 不兼容（缺少算术/参数扩展）"
        _cbe_passed=false
    fi
    
    # 检测2: Android版本
    _cbe_api=$(getprop ro.build.version.sdk 2>/dev/null)
    if [ -n "$_cbe_api" ] && [ "$_cbe_api" -ge 21 ] 2>/dev/null; then
        ui_print "  ✅ Android: API $_cbe_api (兼容)"
    else
        ui_print "  ⚠️ Android: API ${_cbe_api:-未知} (未充分测试)"
    fi
    
    $_cbe_passed
}

# Layer 2: 依赖工具检测
check_dependencies() {
    ui_print ""
    ui_print "▶ Layer 2: 依赖工具检测"
    
    _cd_missing_critical=0
    _cd_missing_optional=0
    
    # 关键工具: fstrim
    if command -v fstrim >/dev/null 2>&1; then
        _cd_fstrim_help=$(fstrim --help 2>&1)
        case "$_cd_fstrim_help" in
            *"-v"*|*"--verbose"*)
                ui_print "  ✅ fstrim: 可用（支持详细输出）"
                ;;
            *)
                ui_print "  ✅ fstrim: 可用（基础版本）"
                ;;
        esac
    else
        ui_print "  ❌ fstrim: 缺失（核心功能）"
        _cd_missing_critical=$((_cd_missing_critical + 1))
    fi
    
    # 可选工具: timeout
    if command -v timeout >/dev/null 2>&1; then
        ui_print "  ✅ timeout: 可用"
    else
        ui_print "  ⚠️ timeout: 缺失（无超时保护）"
        _cd_missing_optional=$((_cd_missing_optional + 1))
    fi
    
    # Busybox检测 (使用统一路径列表)
    # SYNC: 与 service.sh 和 f2fsopt 保持一致
    _cd_bb_path=""
    for _cd_p in \
        "/data/adb/magisk/busybox" \
        "/data/adb/ksu/bin/busybox" \
        "/data/adb/ap/bin/busybox" \
        /data/adb/*/busybox \
        "/system/bin/busybox"; do
        
        # 跳过通配符未展开的情况
        case "$_cd_p" in *'*'*) continue ;; esac
        
        if [ -x "$_cd_p" ]; then
            _cd_bb_path="$_cd_p"
            break
        fi
    done
    
    # 动态回退
    if [ -z "$_cd_bb_path" ]; then
        _cd_p=$(command -v busybox 2>/dev/null)
        if [ -n "$_cd_p" ] && [ -x "$_cd_p" ]; then
            _cd_bb_path="$_cd_p"
        fi
    fi
    
    if [ -n "$_cd_bb_path" ]; then
        _cd_bb_ver=$("$_cd_bb_path" 2>&1 | head -n 1 2>/dev/null)
        ui_print "  ✅ Busybox: $_cd_bb_path"
        ui_print "      ${_cd_bb_ver}"
        
        # 检测 Busybox httpd 支持（WebUI 功能）
        # 使用 echo 将换行符转为空格,确保 case 匹配正确
        _cd_bb_list=" $(echo $("$_cd_bb_path" --list 2>/dev/null)) "
        case "$_cd_bb_list" in
            *" httpd "*)
                ui_print "      ├─ httpd: 支持 ✅ (WebUI 可用)"
                ;;
            *)
                ui_print "      ├─ httpd: 不支持 ⚠️ (WebUI 不可用)"
                _cd_missing_optional=$((_cd_missing_optional + 1))
                ;;
        esac
    else
        ui_print "  ⚠️ Busybox: 未找到（使用系统命令）"
        ui_print "      ├─ 部分功能可能受限 (Cron 模式, Web UI)"
        ui_print "      └─ WebUI 功能不可用"
        _cd_missing_optional=$((_cd_missing_optional + 1))
    fi
    
    [ "$_cd_missing_critical" -eq 0 ]
}

# Layer 3: 文件系统深度检测（完全复用f2fsopt逻辑）
check_filesystems_advanced() {
    ui_print ""
    ui_print "▶ Layer 3: 文件系统深度检测"
    ui_print "  (使用f2fsopt核心引擎)"
    
    _cfa_candidates=""; _cfa_unique_fps=""; _cfa_fp=""; _cfa_dev=""; _cfa_mnt=""; _cfa_type=""; _cfa_opts=""; _cfa_rest=""
    _cfa_mnt_decoded=""; _cfa_len=""; _cfa_count=0; _cfa_scan_count=0; _cfa_skip_count=0
    
    # 扫描 /proc/mounts
    while read -r _cfa_dev _cfa_mnt _cfa_type _cfa_opts _cfa_rest; do
        # 基础过滤
        case "$_cfa_dev" in /dev/block/*) ;; *) continue ;; esac
        case "$_cfa_type" in f2fs|mifs|ext4) ;; *) continue ;; esac
        case "$_cfa_opts" in *rw,*) ;; *) continue ;; esac
        
        # 路径解码
        _cfa_mnt_decoded=$(decode_path "$_cfa_mnt")
        _cfa_mnt_decoded="${_cfa_mnt_decoded%/}"
        [ -z "$_cfa_mnt_decoded" ] && _cfa_mnt_decoded="/"  # 保护根分区
        
        # 统一黑名单检查
        if is_path_ignored "$_cfa_mnt_decoded"; then
            _cfa_skip_count=$((_cfa_skip_count + 1))
            continue
        fi
        
        _cfa_scan_count=$((_cfa_scan_count + 1))
        
        # 6. 设备指纹获取
        _cfa_fp=$(get_device_fingerprint "$_cfa_dev" "$_cfa_mnt_decoded")
        [ -z "$_cfa_fp" ] && continue
        
        # 7. 记录候选
        _cfa_len=${#_cfa_mnt_decoded} 2>/dev/null || _cfa_len=100
        _cfa_candidates="$_cfa_candidates${_cfa_fp}|${_cfa_len}|${_cfa_dev}|${_cfa_mnt_decoded}|${_cfa_type}
"
        case " $_cfa_unique_fps " in
            *" $_cfa_fp "*) ;;
            *) _cfa_unique_fps="$_cfa_unique_fps $_cfa_fp" ;;
        esac
    done < /proc/mounts
    
    # 设备去重与分析
    _cfa_f2fs_count=0; _cfa_ext4_count=0; _cfa_final_targets=""
    
    # 保存原始 IFS 和 globbing 状态
    _cfa_old_ifs="$IFS"
    set -f
    
    # 外层循环 (默认 IFS)
    for _cfa_u_fp in $_cfa_unique_fps; do
        _cfa_best_len=99999; _cfa_best_line=""
        
        # 使用子 Shell 隔离 IFS 操作，避免污染父 Shell 环境
        _cfa_best_line=$(
            IFS='
'
            for _cfa_line in $_cfa_candidates; do
                # 在子 Shell 中解析管道分隔的字段
                IFS='|'
                set -- $_cfa_line
                _cfa_rid="$1"; _cfa_rlen="$2"; _cfa_rdev="$3"; _cfa_rmnt="$4"; _cfa_rtype="$5"
                
                if [ "$_cfa_rid" = "$_cfa_u_fp" ]; then
                    if [ "$_cfa_rlen" -lt "$_cfa_best_len" ] 2>/dev/null; then
                        _cfa_best_len="$_cfa_rlen"
                        printf '%s|%s|%s\n' "$_cfa_rdev" "$_cfa_rmnt" "$_cfa_rtype"
                    fi
                fi
            done | if command -v tail >/dev/null 2>&1; then
                tail -n 1
            else
                # 回退: 纯 Shell 实现获取最后一行
                _cfa_last=""
                while IFS= read -r _cfa_last_line || [ -n "$_cfa_last_line" ]; do
                    _cfa_last="$_cfa_last_line"
                done
                printf '%s\n' "$_cfa_last"
            fi
        )
        
        if [ -n "$_cfa_best_line" ]; then
            _cfa_final_targets="$_cfa_final_targets$_cfa_best_line
"
            _cfa_count=$((_cfa_count + 1))
            
            # 解析类型统计
            _cfa_rtype="${_cfa_best_line##*|}"
            case "$_cfa_rtype" in
                f2fs|mifs) _cfa_f2fs_count=$((_cfa_f2fs_count + 1)) ;;
                ext4) _cfa_ext4_count=$((_cfa_ext4_count + 1)) ;;
            esac
        fi
    done
    
    # 恢复原始 IFS 和 globbing 状态
    IFS="$_cfa_old_ifs"
    set +f
    
    # 结果输出
    ui_print "        ├─ 扫描统计: 处理 $_cfa_scan_count, 跳过 $_cfa_skip_count"
    ui_print "        ├─ 独立设备: $_cfa_count 个"
    ui_print "        ├─ F2FS/MIFS: $_cfa_f2fs_count 个"
    ui_print "        ├─ EXT4: $_cfa_ext4_count 个"
    ui_print "        └─ 目标分区:"
    
    if [ "$_cfa_count" -eq 0 ]; then
        ui_print "      ❌ 无可用分区"
        return 1
    fi
    
    # 详细列表（使用子 Shell 隔离 IFS 操作）
    (
        IFS='
'
        for _cfa_line in $_cfa_final_targets; do
            IFS='|'
            set -- $_cfa_line
            _cfa_dev="$1"; _cfa_mnt="$2"; _cfa_type="$3"
            [ -z "$_cfa_mnt" ] && continue
            ui_print "      · $_cfa_mnt [$_cfa_type]"
        done
    )
    
    ui_print "  ✅ 文件系统检测通过"
    return 0
}

# Layer 4: 内核接口深度检测
check_kernel_support_advanced() {
    ui_print ""
    ui_print "▶ Layer 4: 内核接口深度检测"
    
    _cksa_total_nodes=0; _cksa_writable_gc=0; _cksa_readonly_gc=0
    _cksa_node=""; _cksa_real_dev=""; _cksa_bname=""
    
    # 分析所有F2FS sysfs节点
    for _cksa_node in /sys/fs/f2fs/* /sys/fs/mifs/*; do
        [ -e "$_cksa_node" ] || continue
        [ -d "$_cksa_node" ] || continue
        [ -f "$_cksa_node/dirty_segments" ] || continue
        
        _cksa_total_nodes=$((_cksa_total_nodes + 1))
        
        # 检测GC可写性
        if [ -w "$_cksa_node/gc_urgent" ]; then
            _cksa_writable_gc=$((_cksa_writable_gc + 1))
            
            # 详细能力检测
            _cksa_has_sleep=false
            [ -f "$_cksa_node/gc_urgent_sleep_time" ] && _cksa_has_sleep=true
            
            # 读取设备名（可选信息，安全处理文件不存在的情况）
            _cksa_dev_name=""; _cksa_node_name="${_cksa_node##*/}"
            
            if [ -f "$_cksa_node/dev_name" ]; then
                # 使用 read_first_line 安全读取，自动处理文件不可读的情况
                if read_first_line _cksa_dev_name "$_cksa_node/dev_name"; then
                    # 清理空白字符
                    _cksa_dev_name="${_cksa_dev_name## }"
                    _cksa_dev_name="${_cksa_dev_name%% }"
                fi
            fi
            
            # 根据是否有设备名调整显示格式
            if [ -n "$_cksa_dev_name" ]; then
                ui_print "        ├─ 节点: ${_cksa_node_name} (${_cksa_dev_name})"
            else
                ui_print "        ├─ 节点: ${_cksa_node_name}"
            fi
            ui_print "        │        ├─ GC接口: 可写 ✅"
            if $_cksa_has_sleep; then
                ui_print "        │        └─ Turbo GC: 支持 ✅"
            else
                ui_print "        │        └─ Turbo GC: 不支持 ⚠️"
            fi
        else
            _cksa_readonly_gc=$((_cksa_readonly_gc + 1))
            ui_print "        ├─ 节点: ${_cksa_node##*/} (只读)"
        fi
    done
    
    if [ "$_cksa_total_nodes" -eq 0 ]; then
        ui_print "  ⚠️ 无F2FS sysfs节点 - GC功能不可用"
        ui_print "  → 将仅执行Trim操作"
    else
        ui_print "  ✅ 发现 $_cksa_total_nodes 个F2FS节点"
        ui_print "      · 可写: $_cksa_writable_gc 个"
        ui_print "      · 只读: $_cksa_readonly_gc 个"
    fi
    
    # StorageManager检测
    if command -v sm >/dev/null 2>&1; then
        _cksa_sm_test=""; _cksa_sm_ret=""
        _cksa_sm_test=$(sm list-disks 2>&1)
        _cksa_sm_ret=$?
        if [ "$_cksa_sm_ret" -eq 0 ] 2>/dev/null; then
            ui_print "  ✅ StorageManager: 可用（系统回退）"
        else
            ui_print "  ⚠️ StorageManager: 受限"
        fi
    else
        ui_print "  ⚠️ StorageManager: 不可用"
    fi
    
    return 0
}

# 配置语法检测（在暂存目录中验证）
check_service_config() {
    _csc_dir="${1:-$STAGING_DIR}"  # 接受目录参数，默认为 STAGING_DIR
    
    ui_print "- 验证配置语法..."
    
    _csc_passed=true
    _csc_service_file="$_csc_dir/service.sh"
    
    if [ ! -f "$_csc_service_file" ]; then
        ui_print "  ! service.sh 文件不存在"
        return 1
    fi
    
    # 提取配置
    _csc_schedule_mode=$(get_config_value "$_csc_service_file" "SCHEDULE_MODE")
    _csc_cron_exp=$(get_config_value "$_csc_service_file" "CRON_EXP")
    
    # 检测 SCHEDULE_MODE
    case "$_csc_schedule_mode" in
        "sleep"|"cron")
            # 配置正确，静默通过
            ;;
        "")
            ui_print "  ! 调度模式未配置"
            ui_print "    → 请设置 SCHEDULE_MODE=\"sleep\" 或 \"cron\""
            _csc_passed=false
            ;;
        *)
            ui_print "  ! 调度模式无效: \"$_csc_schedule_mode\""
            ui_print "    → 仅支持: sleep 或 cron"
            _csc_passed=false
            ;;
    esac
    
    # 检测 CRON_EXP 语法
    if [ -z "$_csc_cron_exp" ]; then
        ui_print "  ! Cron表达式未配置"
        ui_print "    → 请设置 CRON_EXP"
        _csc_passed=false
    else
        if ! validate_cron_syntax "$_csc_cron_exp" "$_csc_schedule_mode"; then
            _csc_passed=false
        fi
    fi
    
    if $_csc_passed; then
        ui_print "  ✓ 配置语法正确"
    fi
    
    $_csc_passed
}

# Cron 表达式语法验证
validate_cron_syntax() {
    _vcs_exp="$1"; _vcs_mode="$2"
    
    # 解析五段式 Cron 表达式
    set -f; set -- $_vcs_exp; set +f
    _vcs_min="$1"; _vcs_hour="$2"; _vcs_day="$3"; _vcs_month="$4"; _vcs_dow="$5"
    
    if [ "$#" -ne 5 ]; then
        ui_print "  ❌ Cron表达式: 格式错误（需要5段）"
        ui_print "     → 当前: $_vcs_exp"
        ui_print "     → 示例: \"0 */4 * * *\""
        return 1
    fi
    
    # Sleep 模式专用格式验证
    if [ "$_vcs_mode" = "sleep" ]; then
        # 格式1: */N * * * * (每N分钟)
        case "$_vcs_min" in
            \*/[0-9]*)
                _vcs_step="${_vcs_min#*/}"
                if is_integer "$_vcs_step" && [ "$_vcs_step" -gt 0 ] 2>/dev/null && [ "$_vcs_step" -le 60 ] 2>/dev/null; then
                    if [ "$_vcs_hour" = "*" ] && [ "$_vcs_day" = "*" ] && [ "$_vcs_month" = "*" ] && [ "$_vcs_dow" = "*" ]; then
                        return 0
                    fi
                fi
                ;;
        esac
        
        # 格式2/3: M */N * * * (每N小时的M分)
        case "$_vcs_hour" in
            \*/[0-9]*)
                _vcs_step="${_vcs_hour#*/}"
                _vcs_m="${_vcs_min#0}"; _vcs_m="${_vcs_m#0}"; [ -z "$_vcs_m" ] && _vcs_m=0
                
                # 验证步长值（1-24）
                if ! is_integer "$_vcs_step"; then
                    ui_print "  ❌ Cron表达式: 小时步长必须是整数"
                    ui_print "     → 当前步长: $_vcs_step"
                    return 1
                fi
                if [ "$_vcs_step" -le 0 ] 2>/dev/null || [ "$_vcs_step" -gt 24 ] 2>/dev/null; then
                    ui_print "  ❌ Cron表达式: 小时步长超出范围 (1-24)"
                    ui_print "     → 当前步长: $_vcs_step"
                    return 1
                fi
                
                # 验证分钟值（0-59）
                if ! is_integer "$_vcs_m"; then
                    ui_print "  ❌ Cron表达式: 分钟值必须是整数"
                    ui_print "     → 当前分钟: $_vcs_min"
                    return 1
                fi
                if [ "$_vcs_m" -lt 0 ] 2>/dev/null || [ "$_vcs_m" -gt 59 ] 2>/dev/null; then
                    ui_print "  ❌ Cron表达式: 分钟值超出范围 (0-59)"
                    ui_print "     → 当前分钟: $_vcs_m"
                    return 1
                fi
                
                if [ "$_vcs_day" = "*" ] && [ "$_vcs_month" = "*" ] && [ "$_vcs_dow" = "*" ]; then
                    return 0
                fi
                ;;
        esac
        
        # 格式4: M H * * * (每天固定时间)
        if is_integer "$_vcs_min" && is_integer "$_vcs_hour"; then
            # 验证分钟范围（0-59）
            if [ "$_vcs_min" -lt 0 ] 2>/dev/null || [ "$_vcs_min" -gt 59 ] 2>/dev/null; then
                ui_print "  ❌ Cron表达式: 分钟值超出范围 (0-59)"
                ui_print "     → 当前分钟: $_vcs_min"
                return 1
            fi
            
            # 验证小时范围（0-23）
            if [ "$_vcs_hour" -lt 0 ] 2>/dev/null || [ "$_vcs_hour" -gt 23 ] 2>/dev/null; then
                ui_print "  ❌ Cron表达式: 小时值超出范围 (0-23)"
                ui_print "     → 当前小时: $_vcs_hour"
                return 1
            fi
            
            if [ "$_vcs_day" = "*" ] && [ "$_vcs_month" = "*" ] && [ "$_vcs_dow" = "*" ]; then
                return 0
            fi
        fi
        
        # Sleep 模式不支持的格式
        ui_print "  ❌ Cron表达式: Sleep模式不支持此格式"
        ui_print "     → 当前: $_vcs_exp"
        ui_print "     → 支持格式:"
        ui_print "       • \"*/N * * * *\"  (每N分钟)"
        ui_print "       • \"0 */N * * *\"  (每N小时整点)"
        ui_print "       • \"M */N * * *\"  (每N小时M分)"
        ui_print "       • \"M H * * *\"    (每天H:M)"
        return 1
    fi
    
    # Cron 模式：基础语法检查
    if [ "$_vcs_mode" = "cron" ]; then
        # 检查每段是否为有效字符
        _vcs_valid=true
        for _vcs_field in "$_vcs_min" "$_vcs_hour" "$_vcs_day" "$_vcs_month" "$_vcs_dow"; do
            case "$_vcs_field" in
                *[!0-9\*\-\,\/]*)
                    _vcs_valid=false
                    break
                    ;;
            esac
        done
        
        if $_vcs_valid; then
            return 0
        else
            ui_print "  ❌ Cron表达式: 包含非法字符"
            ui_print "     → 当前: $_vcs_exp"
            ui_print "     → 允许字符: 0-9 * - , /"
            return 1
        fi
    fi
    
    return 1
}

# 诊断报告
print_diagnosis() {
    _pd_fail="$1"; _pd_warn="$2"
    
    ui_print ""
    ui_print "════════════════════════════════"
    ui_print "      兼容性诊断报告"
    ui_print "════════════════════════════════"
    
    # 统计信息（简洁格式）
    ui_print "  检测结果统计:"
    ui_print "    · 失败: $_pd_fail 项"
    ui_print "    · 警告: $_pd_warn 项"
    ui_print ""
    
    # 综合评估
    if [ "$_pd_fail" -eq 0 ] 2>/dev/null && [ "$_pd_warn" -eq 0 ] 2>/dev/null; then
        ui_print "  🎉 完美兼容 - 推荐安装"
        ui_print "  预期: 所有功能完整可用"
    elif [ "$_pd_fail" -eq 0 ] 2>/dev/null; then
        ui_print "  ✅ 基本兼容 - 建议安装"
        ui_print "  预期: 核心功能可用"
        ui_print "  提示: 部分可选功能受限"
    else
        ui_print "  ❌ 不兼容 - 不建议安装"
        ui_print "  建议: 检查上方详细信息"
        ui_print "  操作: 解决致命问题后重试"
    fi
    
    ui_print "════════════════════════════════"
    ui_print ""
}

# 主检测函数
pre_install_check() {
    ui_print ""
    ui_print "════════════════════════════════"
    ui_print "      兼容性检测"
    ui_print "════════════════════════════════"
    
    # 初始化计数器（确保从0开始）
    _pic_fail_count=0
    _pic_warn_count=0
    _pic_layer_count=0
    
    # Layer 1: 基础环境（独立检测）
    _pic_layer_count=$((_pic_layer_count + 1))
    if ! check_basic_env; then
        _pic_fail_count=$((_pic_fail_count + 1))
    fi
    
    # Layer 2: 依赖工具（独立检测，不受 Layer 1 影响）
    _pic_layer_count=$((_pic_layer_count + 1))
    check_dependencies || _pic_warn_count=$((_pic_warn_count + 1))
    
    # Layer 3: 文件系统深度检测（独立检测）
    _pic_layer_count=$((_pic_layer_count + 1))
    if ! check_filesystems_advanced; then
        _pic_fail_count=$((_pic_fail_count + 1))
    fi
    
    # Layer 4: 内核接口深度检测（独立检测）
    _pic_layer_count=$((_pic_layer_count + 1))
    check_kernel_support_advanced || _pic_warn_count=$((_pic_warn_count + 1))
    
    # 注意: Layer 5-6 (静态文件和配置检测) 已移至解压后执行
    # 因为在此阶段文件还未解压，检测会失败
    
    # 验证计数器单调性（调试用）
    # 确保计数器只增不减
    if [ "$_pic_fail_count" -lt 0 ] 2>/dev/null || [ "$_pic_warn_count" -lt 0 ] 2>/dev/null; then
        ui_print "  ⚠️ 内部错误: 计数器异常"
    fi
    
    # 综合评估
    print_diagnosis "$_pic_fail_count" "$_pic_warn_count"
    
    # 返回检测结果（0=通过，1=失败）
    [ "$_pic_fail_count" -eq 0 ]
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
  set_perm "$MODPATH/webui.sh"        0 0 0755
  set_perm "$MODPATH/post-fs-data.sh" 0 0 0755
  set_perm "$MODPATH/f2fsopt"         0 0 0755
  set_perm "$MODPATH/uninstall.sh"    0 0 0755
  
#  ui_print "- 权限设置完成"
}


##########################################################################################
# 配置迁移逻辑
##########################################################################################

# ============ 配置迁移准备 ============

# 准备配置迁移：检测旧模块、比较版本、提取配置
prepare_config_migration() {
    # 检测旧模块路径（多路径尝试）
    OLD_MODPATH=""
    for _pcm_path in \
        "/data/adb/modules/$MODID" \
        "/data/adb/modules_update/$MODID"; do
        if [ -d "$_pcm_path" ]; then
            OLD_MODPATH="$_pcm_path"
            break
        fi
    done
    
    # 如果没有旧模块，跳过配置迁移
    if [ -z "$OLD_MODPATH" ]; then
        ui_print "- 全新安装"
        return 0
    fi
    
    # 读取新旧版本代码
    NEW_VERCODE=""
    OLD_VERCODE=""
    
    if [ -f "$TMPDIR/module.prop" ]; then
        NEW_VERCODE=$(grep '^versionCode=' "$TMPDIR/module.prop" 2>/dev/null | cut -d= -f2 | tr -d '\r\n')
    fi
    
    if [ -f "$OLD_MODPATH/module.prop" ]; then
        OLD_VERCODE=$(grep '^versionCode=' "$OLD_MODPATH/module.prop" 2>/dev/null | cut -d= -f2 | tr -d '\r\n')
    fi
    
    # 版本判断：仅在版本升级时迁移
    if [ -z "$NEW_VERCODE" ] || [ -z "$OLD_VERCODE" ]; then
        return 0
    fi
    
    if [ "$NEW_VERCODE" -le "$OLD_VERCODE" ] 2>/dev/null; then
        ui_print "- 重新安装（版本未变）"
        return 0
    fi
    
    # 显示升级信息
    NEW_VERSION=$(grep '^version=' "$TMPDIR/module.prop" 2>/dev/null | cut -d= -f2 | tr -d '\r\n')
    OLD_VERSION=$(grep '^version=' "$OLD_MODPATH/module.prop" 2>/dev/null | cut -d= -f2 | tr -d '\r\n')
    ui_print "- 升级安装: $OLD_VERSION → $NEW_VERSION"
    
    # 提取配置到缓存
    extract_old_config
}

# 从旧模块提取配置到缓存文件
extract_old_config() {
    CONFIG_CACHE="$TMPDIR/config.cache"
    : > "$CONFIG_CACHE" 2>/dev/null || return 1
    
    # 定义配置参数白名单
    _eoc_service_params="SCHEDULE_MODE CRON_EXP SLEEP_HEARTBEAT LOG_MODE MAX_LOG_SIZE"
    _eoc_f2fsopt_params="GC_DIRTY_MIN TRIM_TIMEOUT DEBUG_SCAN SLOW_MOUNT_THRESHOLD VERY_SLOW_THRESHOLD"
    _eoc_action_params="AUTO_START_WEBUI WEBUI_PROMPT_TIMEOUT"
    
    # 提取 service.sh 配置
    if [ -f "$OLD_MODPATH/service.sh" ]; then
        for _eoc_param in $_eoc_service_params; do
            _eoc_value=$(get_config_value "$OLD_MODPATH/service.sh" "$_eoc_param")
            if [ -n "$_eoc_value" ]; then
                printf '%s=%s\n' "$_eoc_param" "$_eoc_value" >> "$CONFIG_CACHE"
            fi
        done
    fi
    
    # 提取 f2fsopt 配置
    if [ -f "$OLD_MODPATH/f2fsopt" ]; then
        for _eoc_param in $_eoc_f2fsopt_params; do
            _eoc_value=$(get_config_value "$OLD_MODPATH/f2fsopt" "$_eoc_param")
            if [ -n "$_eoc_value" ]; then
                printf '%s=%s\n' "$_eoc_param" "$_eoc_value" >> "$CONFIG_CACHE"
            fi
        done
    fi
    
    # 提取 action.sh 配置
    if [ -f "$OLD_MODPATH/action.sh" ]; then
        for _eoc_param in $_eoc_action_params; do
            _eoc_value=$(get_config_value "$OLD_MODPATH/action.sh" "$_eoc_param")
            if [ -n "$_eoc_value" ]; then
                printf '%s=%s\n' "$_eoc_param" "$_eoc_value" >> "$CONFIG_CACHE"
            fi
        done
    fi
    
    return 0
}



# ============ 模块解压 ============

# 解压模块文件到暂存目录
extract_module() {
    STAGING_DIR="$TMPDIR/staging"
    
    # 清理并创建暂存目录
    rm -rf "$STAGING_DIR" 2>/dev/null
    mkdir -p "$STAGING_DIR" || {
        ui_print "! 无法创建暂存目录"
        return 1
    }
    
    # 解压模块文件（排除 META-INF，静默输出）
    ui_print "- 解压模块文件..."
    if ! unzip -o "$ZIPFILE" -x 'META-INF/*' -d "$STAGING_DIR" >/dev/null 2>&1; then
        ui_print "! 解压失败"
        return 1
    fi
    
    # 设置默认权限
    set_perm_recursive "$STAGING_DIR" 0 0 0755 0644
    
    return 0
}


# ============ 配置应用 ============

# 应用配置迁移
apply_config_migration() {
    # 如果没有缓存，跳过
    [ ! -f "$CONFIG_CACHE" ] && return 0
    
    MIGRATED=0
    
    ui_print "- 应用配置迁移..."
    
    # 批量应用到每个文件
    _acm_count=$(apply_configs_batch "$STAGING_DIR/service.sh")
    MIGRATED=$((MIGRATED + _acm_count))
    
    _acm_count=$(apply_configs_batch "$STAGING_DIR/f2fsopt")
    MIGRATED=$((MIGRATED + _acm_count))
    
    _acm_count=$(apply_configs_batch "$STAGING_DIR/action.sh")
    MIGRATED=$((MIGRATED + _acm_count))
    
    # 显示结果（仅在有迁移时显示）
    if [ "$MIGRATED" -gt 0 ]; then
        ui_print "  ✓ 已迁移 $MIGRATED 项配置"
    fi
}

# 批量配置应用函数
apply_configs_batch() {
    _acb_file="$1"
    _acb_tmp="${_acb_file}.tmp"
    _acb_applied=0
    _acb_line=""
    _acb_param=""
    _acb_new_val=""
    _acb_replaced=0
    _acb_prefix=""
    _acb_old_val=""
    
    # 验证目标文件存在
    if [ ! -f "$_acb_file" ]; then
        echo "0"
        return 0
    fi
    
    # 创建临时文件
    if ! : > "$_acb_tmp" 2>/dev/null; then
        echo "0"
        return 0
    fi
    
    # 预加载缓存到内存
    _acb_cache_content=""
    if [ -f "$CONFIG_CACHE" ]; then
        _acb_cache_content=$(cat "$CONFIG_CACHE" 2>/dev/null)
    fi
    
    # 逐行处理文件
    while IFS= read -r _acb_line || [ -n "$_acb_line" ]; do
        _acb_replaced=0
        
        # 跳过空行和注释行（防止误匹配）
        case "$_acb_line" in
            ''|'#'*|' #'*|'	#'*)
                printf '%s\n' "$_acb_line" >> "$_acb_tmp"
                continue
                ;;
        esac
        
        # 精确匹配配置行（仅匹配有效的配置赋值）
        case "$_acb_line" in
            readonly\ [A-Z_]*=*|export\ [A-Z_]*=*|[A-Z_]*=*)
                # 提取参数名（处理 readonly/export 前缀）
                _acb_prefix=""
                _acb_param=""
                
                case "$_acb_line" in
                    readonly\ *)
                        _acb_prefix="readonly "
                        _acb_param="${_acb_line#readonly }"
                        _acb_param="${_acb_param%%=*}"
                        ;;
                    export\ *)
                        _acb_prefix="export "
                        _acb_param="${_acb_line#export }"
                        _acb_param="${_acb_param%%=*}"
                        ;;
                    *)
                        _acb_prefix=""
                        _acb_param="${_acb_line%%=*}"
                        ;;
                esac
                
                # 去除参数名首尾空白
                while case "$_acb_param" in [' 	']*) true;; *) false;; esac; do
                    _acb_param="${_acb_param#?}"
                done
                while case "$_acb_param" in *[' 	']) true;; *) false;; esac; do
                    _acb_param="${_acb_param%?}"
                done
                
                # 验证参数名格式（仅大写字母和下划线）
                case "$_acb_param" in
                    ''|*[!A-Z_]*)
                        # 无效参数名，保持原样
                        printf '%s\n' "$_acb_line" >> "$_acb_tmp"
                        continue
                        ;;
                esac
                
                # 从内存缓存中查找新值
                _acb_new_val=""
                case "$_acb_cache_content" in
                    *"${_acb_param}="*)
                        # 提取匹配行
                        _acb_cache_line="${_acb_cache_content#*${_acb_param}=}"
                        _acb_cache_line="${_acb_cache_line%%
*}"
                        
                        # 验证是否为精确匹配（防止部分匹配）
                        case "$_acb_cache_content" in
                            *"
${_acb_param}="*|"${_acb_param}="*)
                                _acb_new_val="$_acb_cache_line"
                                ;;
                        esac
                        ;;
                esac
                
                if [ -n "$_acb_new_val" ]; then
                    # 提取原值（用于保留格式）
                    _acb_old_val="${_acb_line#*=}"
                    
                    # 判断原值是否有引号
                    case "$_acb_old_val" in
                        \"*\"|\'*\')
                            # 原值有引号，保留引号格式
                            case "$_acb_old_val" in
                                \"*\") printf '%s%s="%s"\n' "$_acb_prefix" "$_acb_param" "$_acb_new_val" >> "$_acb_tmp" ;;
                                \'*\') printf "%s%s='%s'\n" "$_acb_prefix" "$_acb_param" "$_acb_new_val" >> "$_acb_tmp" ;;
                            esac
                            ;;
                        *)
                            # 原值无引号，保持无引号格式
                            printf '%s%s=%s\n' "$_acb_prefix" "$_acb_param" "$_acb_new_val" >> "$_acb_tmp"
                            ;;
                    esac
                    
                    _acb_applied=$((_acb_applied + 1))
                    _acb_replaced=1
                fi
                ;;
        esac
        
        # 如果未替换，保持原样
        if [ "$_acb_replaced" = "0" ]; then
            printf '%s\n' "$_acb_line" >> "$_acb_tmp"
        fi
    done < "$_acb_file"
    
    # 验证临时文件完整性（根据文件类型设置不同阈值）
    if [ ! -f "$_acb_tmp" ]; then
        echo "0"
        return 0
    fi
    
    _acb_size=$(wc -c < "$_acb_tmp" 2>/dev/null) || _acb_size=0
    _acb_min_size=1024
    
    # 根据文件名设置最小大小阈值
    case "$_acb_file" in
        */service.sh) _acb_min_size=10240 ;;  # service.sh 至少 10KB
        */f2fsopt)    _acb_min_size=10240 ;;  # f2fsopt 至少 10KB
        */action.sh)  _acb_min_size=5120 ;;   # action.sh 至少 5KB
        *)            _acb_min_size=1024 ;;   # 其他文件至少 1KB
    esac
    
    if [ "$_acb_size" -lt "$_acb_min_size" ] 2>/dev/null; then
        rm -f "$_acb_tmp"
        echo "0"
        return 0
    fi
    
    # 原子替换
    if mv "$_acb_tmp" "$_acb_file" 2>/dev/null; then
        echo "$_acb_applied"
        return 0
    else
        rm -f "$_acb_tmp"
        echo "0"
        return 1
    fi
}


# ============ 最终部署 ============

# 最终部署：验证并移动到最终位置
finalize_installation() {
    ui_print "- 验证模块完整性..."
    
    # 验证关键文件存在
    _fi_missing=0
    for _fi_file in f2fsopt service.sh action.sh webui.sh post-fs-data.sh uninstall.sh; do
        if [ ! -f "$STAGING_DIR/$_fi_file" ]; then
            ui_print "  ! 缺失: $_fi_file"
            _fi_missing=$((_fi_missing + 1))
        fi
    done
    
    if [ "$_fi_missing" -gt 0 ]; then
        ui_print "! 缺失 $_fi_missing 个关键文件"
        return 1
    fi
    
    # 验证 f2fsopt 完整性（大小 + 关键函数）
    if ! verify_f2fsopt_integrity "$STAGING_DIR/f2fsopt"; then
        ui_print "! f2fsopt 文件验证失败"
        return 1
    fi
    
    # 验证 service.sh 大小
    _fi_size=$(wc -c < "$STAGING_DIR/service.sh" 2>/dev/null) || _fi_size=0
    if [ "$_fi_size" -lt 10240 ] 2>/dev/null; then
        ui_print "! service.sh 文件大小异常 ($_fi_size 字节)"
        return 1
    fi
    
    ui_print "  ✓ 文件完整性验证通过"
    
    # 删除旧的 MODPATH
    rm -rf "$MODPATH" 2>/dev/null
    
    # 移动暂存目录到最终位置
    ui_print "- 部署模块文件..."
    if ! mv "$STAGING_DIR" "$MODPATH" 2>/dev/null; then
        ui_print "! 无法移动模块到最终位置"
        return 1
    fi
    
    # 设置最终权限
    ui_print "- 设置文件权限..."
    set_perm_recursive "$MODPATH" 0 0 0755 0644
    
    # 设置可执行权限
    set_perm "$MODPATH/service.sh"      0 0 0755
    set_perm "$MODPATH/action.sh"       0 0 0755
    set_perm "$MODPATH/webui.sh"        0 0 0755
    set_perm "$MODPATH/post-fs-data.sh" 0 0 0755
    set_perm "$MODPATH/f2fsopt"         0 0 0755
    set_perm "$MODPATH/uninstall.sh"    0 0 0755
    
    ui_print "  ✓ 部署完成"
    
    return 0
}

# ============ 清理 ============

# 清理临时文件
cleanup_temp_files() {
    rm -f "$CONFIG_CACHE" 2>/dev/null
    rm -rf "$STAGING_DIR" 2>/dev/null
}


# ============ 主控制流程 ============

# 主安装流程
main_install() {
    # Phase 1: 兼容性检测
    if ! pre_install_check; then
        ui_print ""
        ui_print "══════════════════════════"
        ui_print "⚠️ 兼容性检测未通过"
        ui_print "══════════════════════════"
        ui_print ""
        abort "❌ 安装已取消 - 设备不兼容"
    fi
    
    # Phase 2: 配置迁移准备
    prepare_config_migration || {
        ui_print "  ⚠️ 配置提取失败，将使用默认配置"
    }
    
    # Phase 3: 解压新模块
    if ! extract_module; then
        abort "❌ 模块解压失败"
    fi
    
    # Phase 3.5: 配置语法检测
    check_service_config "$STAGING_DIR" || {
        ui_print "  ⚠️ 配置语法检测失败，但不影响安装"
    }
    
    # Phase 4: 配置应用
    apply_config_migration || {
        ui_print "  ⚠️ 配置应用失败，将使用默认配置"
        # 重新解压使用默认配置
        extract_module || abort "❌ 模块解压失败"
    }
    
    # Phase 5: 最终部署
    if ! finalize_installation; then
        abort "❌ 模块部署失败"
    fi
    
    # Phase 6: 清理
    cleanup_temp_files
    
    ui_print ""
    ui_print "════════════════════════════════"
    ui_print "✅ 模块安装完成"
    ui_print "════════════════════════════════"
    ui_print ""
}

##########################################################################################
# 执行主安装流程
##########################################################################################

# 调用主安装函数
main_install
