# F2FS 深度优化 (F2FS-Optimizer)

> 极简、高效、以安全为优先的 Android 存储维护方案  
> 通过纯 Shell 脚本对 F2FS / MIFS / EXT4 分区执行智能 Trim 与 GC（垃圾回收），旨在降低碎片、延长闪存寿命并最小化系统干扰。

---

## 目录

- [快速概览](#快速概览)
- [要求与兼容性](#要求与兼容性)
- [快速开始](#快速开始)
- [调度与运行模式](#调度与运行模式)
- [WebUI 使用指南](#webui-使用指南)
- [配置参考](#配置参考)
- [常见问题与故障排查](#常见问题与故障排查)
- [安全与风险提示](#安全与风险提示)
- [开发者信息](#开发者信息)

---

## 快速概览

### 核心思想

- **双引擎调度**: Sleep 模式（零依赖）与 Cron 模式（精准定时）两种运行方式，可适配不同环境
- **智能感知策略**: 根据 F2FS `dirty_segments` 等指标判断是否需要 GC，避免无效操作
- **场景感知**: 支持亮屏跳过、仅充电运行、Turbo GC 等选项，减少对用户体验与电量的影响
- **纯 Shell 实现**: POSIX 兼容，兼容 Magisk / KernelSU / APatch 等模块化安装方式

### 主要功能

- 对 F2FS 执行 GC 优化（当脏段超过阈值时）
- 对 EXT4 执行 fstrim（Trim）
- 提供手动触发与自动调度两种运行方式
- Web UI 配置界面，支持图形化配置管理
- 输出详细日志并支持将执行结果回写到 Magisk 模块描述（可选）

### 设计原则

- **安全优先**: 保守的默认配置，保护闪存寿命
- **最小干扰**: 智能跳过健康分区，减少不必要的 IO 操作
- **零依赖**: Sleep 模式无需 Busybox，最大化兼容性
- **鲁棒性**: 完整的错误处理和多级回退机制

---

## 要求与兼容性

### 系统要求

- **Root 权限**: 必需（模块通过 Magisk / KernelSU / APatch 安装）
- **Android 版本**: 8.0+ (API 26+)
- **内核支持**: 需要内核支持 F2FS ioctl 或 fstrim 命令
- **通知功能**: 需要 Android 10+ (API 29+)，低版本系统会自动禁用通知

### 支持的文件系统

- **F2FS**: 完整支持（包括小米 MIFS 变体）
- **EXT4**: 支持 Trim 操作

### 可选依赖

- **Busybox**: Cron 模式必需，Sleep 模式可选

### 兼容性说明

- 不推荐与其他激进的 GC/Trim 模块并存（可能产生冲突）
- 部分内核的 `gc_urgent` 接口可能为只读
- SELinux 可能阻止某些 ioctl 调用

---

## 快速开始

### 安装步骤

1. 下载模块 ZIP 文件
2. 通过 Magisk Manager / KernelSU / APatch 管理器安装
3. **自动配置迁移**（如果检测到旧版本）：
   - 安装程序会自动提取旧版本配置
   - 验证配置值的合法性和安全性
   - 应用到新版本模块
   - 整个过程无需用户干预
4. 重启设备
5. 等待 2-3 分钟，调度器将自动启动

### 配置迁移说明

**自动迁移机制**（v2.0+）：

从 v2.0 开始，配置迁移完全自动化，无需用户交互。升级时：

1. **自动检测**：安装程序检测旧模块是否存在
2. **配置提取**：从旧版本文件中提取所有自定义配置
3. **安全验证**：
   - 过滤危险字符（防止命令注入）
   - 验证配置值类型和范围
   - 验证文件完整性
4. **应用配置**：将验证通过的配置应用到新版本
5. **错误处理**：验证失败的配置项使用默认值

**迁移的配置项**：
- **调度器配置**：调度模式（Sleep/Cron）、Cron 表达式、心跳间隔、日志模式、日志大小限制
- **优化器配置**：GC 阈值、Trim 超时、调试扫描、慢速挂载阈值、极慢阈值
- **WebUI 配置**：自动启动模式、提示超时

**安全保障**：
- 零依赖：纯 POSIX Shell 实现，不依赖 sed/awk 等外部工具
- 原子操作：使用临时文件 + 原子替换确保安全
- 完整性验证：修改后验证文件大小和可读性
- 自动恢复：失败时自动恢复备份文件

**兼容性**：
- ✅ Magisk v19.0-v20.3：在解压前完成配置迁移
- ✅ Magisk v20.4+：在 install_module 前提取配置，完成后应用
- ✅ KernelSU / APatch：使用 Magisk 兼容的安装流程

**注意事项**：
- 如果您修改过配置文件，升级时会自动保留您的设置
- 如果想使用新版本的默认配置，请在升级前删除旧模块
- 迁移失败的配置项会在安装日志中显示警告

### 验证安装

检查模块管理器中的模块描述栏，应显示类似：

```
🧹 Trim: 1.2GB ♻️ GC: 158 段 ⏱️ 耗时: 5s (上次运行)
```

如果显示 `[等待启用]⏳`，说明调度器尚未完成首次运行。

### 手动触发优化

#### 方法 1: 通过模块管理器

在模块卡片中点击 **"Action"（操作）** 按钮，会立即执行一次优化并显示实时日志。

#### 方法 2: 通过命令行

```bash
/data/adb/modules/f2fs_optimizer/action.sh
```

### 查看日志

主日志文件位于：

```bash
/data/adb/modules/f2fs_optimizer/service.log
```

日志包含：
- 调度器心跳信息
- 每次任务的详细输出
- 错误和警告信息
- 配置变更记录

查看日志：

```bash
cat /data/adb/modules/f2fs_optimizer/service.log
```

---

## 调度与运行模式

### Sleep 模式（默认）

**特点**:
- 零依赖：通过 Shell 循环与 `sleep` 实现周期性唤醒
- 兼容性好：对 Doze 模式和进程被杀的容忍度较高
- 智能心跳：可配置心跳间隔（默认 1800 秒 = 30 分钟）

**适用场景**:
- 没有 Busybox 或 Busybox 版本不完整
- 需要最大化兼容性
- 不需要精确的定时执行

### Cron 模式

**特点**:
- 依赖 Busybox 的 `crond`
- 支持完整 Cron 表达式
- 精确定时运行
- 零开销（由系统 crond 调度）

**适用场景**:
- 已安装完整的 Busybox
- 需要精确的定时执行（如每天凌晨 3 点）
- 希望减少后台进程开销

**Cron 表达式示例**:

```bash
"0 */4 * * *"    # 每 4 小时执行一次
"0 3 * * *"      # 每天凌晨 3 点执行
"*/30 * * * *"   # 每 30 分钟执行一次
```

### 常用场景配置

#### 仅充电时运行

避免在电池供电时增加写放大和耗电：

```bash
# 在 f2fsopt 中设置
ONLY_CHARGING=true
```

#### 亮屏时跳过

减少对前台用户体验的影响：

```bash
# 在 f2fsopt 中设置
STOP_ON_SCREEN_ON=true
```

#### Turbo GC 加速

在短时间内加快回收（可能带来短暂的 IO 高峰）：

```bash
# 在 f2fsopt 中设置
ENABLE_TURBO_GC=true
```

---

## WebUI 使用指南

### 概述

WebUI 提供轻量级的 Web 配置界面，支持：
- 实时查看模块状态
- 修改调度器和优化器配置
- 查看和清空日志
- 立即执行优化任务
- 重启调度服务

### 启动 WebUI

#### 方法 1: 手动触发后自动启动

执行 `action.sh` 后，根据配置自动启动或询问是否启动。

#### 方法 2: 直接启动

```bash
/data/adb/modules/f2fs_optimizer/webui.sh
```

启动后会显示访问地址，如：

```
✅ Web UI 已启动
📱 访问地址: http://127.0.0.1:9527
```

### WebUI 启动控制

模块支持三种 WebUI 启动模式，可在 `action.sh` 中配置：

#### 自动启动模式

```bash
AUTO_START_WEBUI="true"
```

任务完成后自动启动 WebUI，适合需要频繁配置的用户。

#### 永不启动模式

```bash
AUTO_START_WEBUI="false"
```

永不自动启动 WebUI，适合仅需执行任务的场景。

#### 交互式选择模式（默认）

```bash
AUTO_START_WEBUI="ask"
```

通过音量键选择是否启动，灵活性最高。

**音量键操作**:
- **[音量+]**: 启动 Web UI
- **[音量-]**: 跳过
- **[电源键]**: 退出脚本

**超时设置**:

```bash
WEBUI_PROMPT_TIMEOUT=10  # 默认 10 秒
```

超时后执行默认操作：跳过 WebUI 启动。

### WebUI 自动退出机制

为了节省资源，WebUI 会在无操作后自动退出：

- **默认超时**: 300 秒（5 分钟）
- **心跳检测**: 每 30 秒检测一次活动
- **可配置**: 在 `webui.sh` 中修改 `WEBUI_TIMEOUT` 和 `HEARTBEAT_SEC`

### 配置 WebUI 行为

编辑 `/data/adb/modules/f2fs_optimizer/action.sh`，修改头部的配置变量：

```bash
# WebUI 自动启动模式
readonly AUTO_START_WEBUI="ask"

# 音量键选择超时时间（秒）
readonly WEBUI_PROMPT_TIMEOUT=10
```

编辑 `/data/adb/modules/f2fs_optimizer/webui.sh`，修改 WebUI 运行参数：

```bash
# WebUI 无操作自动退出时间（秒）
WEBUI_TIMEOUT="${WEBUI_TIMEOUT:-300}"

# 心跳检测间隔（秒）
HEARTBEAT_SEC="${HEARTBEAT_SEC:-30}"
```

---

## 配置参考

### 调度器配置 (service.sh)

| 参数名 | 类型 | 默认值 | 范围 | 说明 |
|--------|------|--------|------|------|
| `SCHEDULE_MODE` | string | `"sleep"` | `sleep` / `cron` | 调度模式 |
| `CRON_EXP` | string | `"0 */4 * * *"` | Cron 表达式 | Cron 模式的执行时间（每 4 小时） |
| `SLEEP_HEARTBEAT` | integer | `1800` | 60-7200 | Sleep 模式心跳间隔（秒），默认 30 分钟 |
| `LOG_MODE` | string | `"INFO"` | `INFO` / `NONE` | 日志级别 |
| `MAX_LOG_SIZE` | integer | `524288` | 102400-1048576 | 最大日志文件大小（字节），默认 512KB |

**配置文件位置**: `/data/adb/modules/f2fs_optimizer/service.sh`

**修改方法**: 编辑文件头部的配置区域

**生效方式**: 修改后需要重启设备或手动重启调度器

#### 日志级别 (LOG_MODE) 详细说明

控制日志输出的详细程度：

- **INFO** (默认，推荐): 记录所有日志，包括信息、警告和错误
  - 适合日常使用和问题排查
  - 日志文件会记录优化器的所有操作
  
- **NONE**: 关闭信息和警告日志，仅记录错误日志
  - 适合不需要日志的场景，减少磁盘 IO
  - 错误日志始终记录，用于故障排查
  - 注意：错误日志无法关闭
  
- **DEBUG**: 调试模式（未来扩展）
  - 预留选项，当前与 INFO 行为相同

**查看日志**：
```bash
cat /data/adb/modules/f2fs_optimizer/service.log
```

**修改配置后重启服务**：
```bash
sh /data/adb/modules/f2fs_optimizer/action.sh --apply-config
```

### 优化器配置 (f2fsopt)

| 参数名 | 类型 | 默认值 | 范围 | 说明 |
|--------|------|--------|------|------|
| `ENABLE_MAGISK_UI` | boolean | `true` | `true` / `false` | 是否更新 Magisk 模块描述栏 |
| `ENABLE_NOTIFICATIONS` | boolean | `true` | `true` / `false` | 是否发送系统通知（需 Android 10+，低版本自动跳过） |
| `ENABLE_SMART_GC` | boolean | `true` | `true` / `false` | 智能 GC（基于脏段阈值），强烈建议开启 |
| `ENABLE_SMART_TRIM` | boolean | `true` | `true` / `false` | 智能 Trim（跳过健康分区） |
| `ENABLE_TURBO_GC` | boolean | `true` | `true` / `false` | 极速 GC 模式（加快回收速度） |
| `STOP_ON_SCREEN_ON` | boolean | `false` | `true` / `false` | 亮屏时是否中断任务 |
| `ONLY_CHARGING` | boolean | `false` | `true` / `false` | 是否仅在充电时运行 |
| `GC_DIRTY_MIN` | integer | `200` | 0-10000 | 脏段阈值（低于此值跳过 GC） |
| `GC_MAX_SEC` | integer | `500` | 10-3600 | GC 最大运行时长（秒） |
| `TRIM_TIMEOUT` | integer | `500` | 10-3600 | Trim 超时时间（秒） |

**配置文件位置**: `/data/adb/modules/f2fs_optimizer/f2fsopt`

**修改方法**: 编辑文件头部的配置区域

**生效方式**: 修改后立即生效，无需重启

### WebUI 配置 (action.sh, webui.sh)

| 参数名 | 类型 | 默认值 | 范围 | 说明 |
|--------|------|--------|------|------|
| `AUTO_START_WEBUI` | string | `"ask"` | `true` / `false` / `ask` | WebUI 自动启动模式 |
| `WEBUI_PROMPT_TIMEOUT` | integer | `10` | 1-60 | 音量键选择超时（秒） |
| `WEBUI_TIMEOUT` | integer | `300` | 60-3600 | WebUI 无操作自动退出时间（秒） |
| `HEARTBEAT_SEC` | integer | `30` | 10-300 | WebUI 心跳检测间隔（秒） |

**配置文件位置**: 
- `AUTO_START_WEBUI`, `WEBUI_PROMPT_TIMEOUT`: `/data/adb/modules/f2fs_optimizer/action.sh`
- `WEBUI_TIMEOUT`, `HEARTBEAT_SEC`: `/data/adb/modules/f2fs_optimizer/webui.sh`

**修改方法**: 编辑对应文件头部的配置区域

**生效方式**: 修改后立即生效，无需重启

### 配置建议

#### 保守配置（默认）

适合大多数用户，保护闪存寿命：

```bash
ENABLE_SMART_GC=true
GC_DIRTY_MIN=200
ENABLE_TURBO_GC=true
ONLY_CHARGING=false
```

#### 激进配置

适合追求性能的用户（风险自负）：

```bash
ENABLE_SMART_GC=false  # 每次都执行 GC
GC_DIRTY_MIN=50        # 降低阈值
ENABLE_TURBO_GC=true
ONLY_CHARGING=false
```

#### 省电配置

适合注重电量的用户：

```bash
ENABLE_SMART_GC=true
GC_DIRTY_MIN=300       # 提高阈值
ENABLE_TURBO_GC=false
ONLY_CHARGING=true     # 仅充电时运行
STOP_ON_SCREEN_ON=true # 亮屏时跳过
```

---

## 常见问题与故障排查

### 常见问题

#### Q1: 模块显示 "GC:💤健康" 是什么意思？

**说明**: 分区干净（`dirty_segments` < `GC_DIRTY_MIN`），模块为了保护闪存选择跳过 GC。

**这是正常且期望的行为**。智能 GC 会根据分区健康状况决定是否执行，避免不必要的写放大。

**如果希望强制执行 GC**:
```bash
# 临时禁用智能 GC
ENABLE_SMART_GC=false /data/adb/modules/f2fs_optimizer/f2fsopt
```

#### Q2: 手动执行显示 "Trim: 0B" 的原因？

**可能原因**:

1. **系统已启用 discard**: 删除文件时已自动 Trim，手动 Trim 无可回收空间
   - 检查方法: `mount | grep discard`
   - 这是正常现象，说明系统已优化

2. **F2FS 内部策略**: F2FS 的内部策略可能导致手动 fstrim 无明显回收
   - 更应关注 GC 操作而非 Trim

3. **SELinux 或内核限制**: 阻止 ioctl 调用
   - 检查日志: `cat /data/adb/modules/f2fs_optimizer/service.log`
   - 检查 dmesg: `dmesg | grep -i denied`

#### Q3: 日志中出现权限或 ioctl 错误？

**排查步骤**:

1. **确认 Root 权限**:
   ```bash
   id
   # 应显示 uid=0(root)
   ```

2. **检查 SELinux 策略**:
   ```bash
   getenforce
   # 如果是 Enforcing，可能阻止某些操作
   
   dmesg | grep -i avc | grep f2fs
   # 查看是否有 SELinux 拦截
   ```

3. **检查内核支持**:
   ```bash
   # 检查 F2FS 分区
   mount | grep f2fs
   
   # 检查 GC 接口
   ls -la /sys/fs/f2fs/*/gc_urgent
   ```

4. **查看详细日志**:
   ```bash
   cat /data/adb/modules/f2fs_optimizer/service.log | grep -i error
   ```

#### Q4: 更改配置后需要重启吗？

**取决于修改的文件**:

- **修改 f2fsopt**: 无需重启，下次任务生效
- **修改 service.sh（调度器逻辑）**: 建议重启设备，或手动重启调度器：
  ```bash
  # 停止调度器
  kill $(cat /data/adb/modules/f2fs_optimizer/service.pid)
  
  # 启动调度器
  /data/adb/modules/f2fs_optimizer/service.sh
  ```
- **修改 action.sh 或 webui.sh**: 无需重启，下次执行生效

### 故障排查清单

遇到问题时，按以下顺序排查：

1. **查看日志**:
   ```bash
   cat /data/adb/modules/f2fs_optimizer/service.log
   ```

2. **确认分区类型**:
   ```bash
   mount | grep /data
   # 应显示 f2fs 或 ext4
   ```

3. **检查 Busybox（Cron 模式）**:
   ```bash
   /data/adb/magisk/busybox --help
   # 或
   busybox --help
   ```

4. **查看 dmesg 错误**:
   ```bash
   dmesg | grep -i f2fs
   dmesg | grep -i denied
   ```

5. **检查模块状态**:
   ```bash
   # 检查调度器进程
   ps | grep service.sh
   
   # 检查 PID 文件
   cat /data/adb/modules/f2fs_optimizer/service.pid
   ```

6. **手动测试优化器**:
   ```bash
   # 直接运行优化器
   /data/adb/modules/f2fs_optimizer/f2fsopt
   ```

### 收集诊断信息

如需寻求帮助，请提供以下信息：

```bash
# 1. 模块日志
cat /data/adb/modules/f2fs_optimizer/service.log

# 2. 系统信息
uname -a
getprop ro.build.version.release

# 3. 分区信息
mount | grep -E "f2fs|ext4"

# 4. F2FS 状态（如果是 F2FS）
cat /sys/fs/f2fs/*/dirty_segments 2>/dev/null

# 5. dmesg 相关错误
dmesg | grep -i f2fs | tail -50
dmesg | grep -i denied | tail -50
```

---

## 安全与风险提示

### 安全性设计

- 本模块调用内核级 IOCTL 与 fstrim，理论上安全
- 使用保守的默认配置，保护闪存寿命
- 完整的错误处理和多级回退机制
- 智能跳过健康分区，避免不必要的操作

### 潜在风险

任何底层文件系统操作都有小概率风险：

- **数据损坏**: 极低概率，但理论上存在
- **性能影响**: GC 和 Trim 操作会短暂占用 IO 资源
- **电量消耗**: 频繁执行会增加耗电

### 建议措施

1. **数据备份**: 在重要数据上做常规备份（尤其在首次尝试或修改阈值时）
2. **保守配置**: 使用默认配置，不要过度激进
3. **监控日志**: 定期查看日志，了解模块运行状况
4. **避免冲突**: 不要与其他激进的 GC/Trim 模块并用

### 兼容性警告

**不应与以下类型的模块并用**:

- 其他 F2FS 优化模块
- 激进的 Trim 模块
- 自动 GC 模块

**原因**: 可能产生冲突、异常耗电或数据不一致。

### 问题报告

如遇疑难问题，请附上以下信息：

- `/data/adb/modules/f2fs_optimizer/service.log`
- `dmesg` 相关输出
- 设备型号和 Android 版本
- Root 框架类型和版本

---

## 开发者信息

### 项目架构

本项目采用纯 Shell 脚本实现，遵循 POSIX 标准，确保最大化兼容性。

**核心组件**:

- `f2fsopt`: 核心优化器，执行 Trim 和 GC 操作
- `service.sh`: 调度守护进程，支持 Sleep 和 Cron 双引擎
- `action.sh`: 手动触发脚本，支持 WebUI 启动控制
- `webui.sh`: 轻量级 Web 配置界面
- `customize.sh`: 安装时兼容性检测

**注意事项**:

- 请在提交 PR 前在 issue 中讨论实现方案
- 确保代码遵循 POSIX Shell 标准
- 添加必要的注释和文档
- 测试在不同设备和 Android 版本上的兼容性

### 代码规范

- **语言**: 纯 Shell 脚本，严格遵循 POSIX 标准
- **兼容性**: 确保在 Android Toybox/Busybox 环境下运行无误
- **错误处理**: 完整的 trap 清理逻辑和多级回退
- **性能**: 优先使用 Shell 内建命令，减少子进程开销

### 许可证

本项目保留原作者声明。详见仓库 LICENSE 文件。

### 更新源

```
https://raw.githubusercontent.com/Coolapk-Code9527/F2FS-Optimizer/main/update.json
```

### 作者

- **原作者**: 乄代号9527

---

**感谢使用 F2FS-Optimizer！如有问题或建议，欢迎提交 Issue。**
