```markdown
# F2FS 深度优化 (F2FS-Optimizer)

> 极简、高效、以安全为优先的 Android 存储维护方案  
> 通过纯 Shell 脚本对 F2FS / MIFS / EXT4 分区执行智能 Trim 与 GC（垃圾回收），旨在降低碎片、延长闪存寿命并最小化系统干扰。

---

目录
- 快速概览
- 要求与兼容性
- 快速开始（安装与运行）
- 使用说明（手动触发、查看日志）
- 调度与运行模式
- 主要配置项（说明与建议）
- 常见问题与故障排查
- 安全与风险提示
- 开发者信息、贡献与许可证

---

## 快速概览

核心思想：
- 双引擎调度：Sleep（零依赖）与 Cron（需要 Busybox）两种运行模式，可适配不同环境。
- 智能感知策略：根据 F2FS `dirty_segments` 等指标判断是否需要 GC，避免无效操作。
- 场景感知：支持亮屏跳过、仅充电运行、Turbo GC 等选项，减少对用户体验与电量的影响。
- 纯 Shell 实现，兼容 Magisk / KernelSU / APatch 等模块化安装方式。

主要功能：
- 对 F2FS 执行 GC 优化（当脏段超过阈值时）
- 对 EXT4 执行 fstrim（Trim）
- 提供手动触发与自动调度两种运行方式
- 输出详细日志并支持将执行结果回写到 Magisk 模块描述（可选）

---

## 要求与兼容性

- Root 权限：必需（模块通常通过 Magisk 安装）
- 兼容性：F2FS、MIFS（小米）、EXT4
- 可选依赖：Busybox（若使用 Cron 模式）
- 建议设备：Android 8.0+（核心操作依赖内核支持的 ioctl/fstrim）
- 不推荐与其他激进的 GC/Trim 模块并存

---

## 快速开始（安装与生效）

1. 把模块放入 Magisk 模块目录或通过 Magisk/KernelSU 管理器刷入。
2. 重启设备。
3. 等待 2–3 分钟，调度器将自动启动。

检查状态（模块管理器描述栏）示例：
> 🧹 Trim: 1.2GB ♻️ GC: 158 段 ⏱️ 耗时: 5s (上次运行)

手动触发：
- 在模块卡片点击 “Action”（操作）会立即执行一次优化并显示实时日志。
- 也可以在终端运行 /data/adb/modules/f2fs_optimizer/action.sh（视安装路径而定）。

查看日志：
- 主日志：/data/adb/modules/f2fs_optimizer/service.log
- 日志包含调度器心跳、每次任务的详细输出与错误信息。

---

## 调度与运行模式

- Sleep 模式（默认）
  - 零依赖：通过 Shell 循环与 sleep 实现周期性唤醒。
  - 优点：兼容性好，对 Doze、被杀的容忍度较高。
- Cron 模式
  - 依赖 Busybox 的 crond；支持完整 Cron 表达式，适合精确定时运行。

常用场景配置：
- 仅充电运行：避免在电池供电时增加写放大
- 亮屏跳过：减少对前台用户体验的影响
- Turbo GC：在短时间内加快回收（可能带来短暂的 IO 高峰）

---

## 主要配置项（简化说明）

配置位置分两类：调度器（service.sh）与核心参数（f2fsopt）。

重要变量（示例 / 建议）：
- SCHEDULE_MODE = "sleep"        # "sleep" 或 "cron"
- CRON_EXP = "*/20 * * * *"      # Cron 表达式（cron 模式生效）
- SLEEP_HEARTBEAT = 300          # Sleep 模式心跳（秒）
- LOG_MODE = "INFO"              # INFO / ERROR / NONE
- ENABLE_MAGISK_UI = true        # 将结果回写至模块描述栏
- ENABLE_SMART_GC = true         # 根据 dirty_segments 智能跳过不必要的 GC（强烈建议开启）
- ENABLE_SMART_TRIM = false      # 若启用会跳过健康分区的 Trim
- ONLY_CHARGING = false          # 是否仅在充电时运行
- STOP_ON_SCREEN_ON = false      # 亮屏时是否中断任务
- ENABLE_TURBO_GC = true         # 加速 GC 的短暂模式
- GC_DIRTY_MIN = 200             # 脏段阈值（低于此值则认为健康，不触发 GC）
- GC_MAX_SEC = 500               # GC 最大运行时长（秒）
- TRIM_TIMEOUT = 500             # Trim 超时时间（秒）

注：默认配置为“保守优先”，以保护闪存寿命为主。如需更激进的清理，可调整阈值，但风险自负。

---

## 常见问题与故障排查

Q1: 模块显示 "GC:💤健康"？
- 说明：分区干净（dirty_segments < GC_DIRTY_MIN），模块为了保护闪存选择跳过 GC，这是正常且期望的行为。

Q2: 手动执行显示 "Trim: 0B"？
- 原因一：系统已启用 discard，删除文件时已自动 Trim。
- 原因二：F2FS 的内部策略可能导致手动 fstrim 无明显回收（更应关注 GC）。
- 原因三：SELinux 或内核限制阻止 ioctl 调用（检查日志和 dmesg）。

Q3: 日志中出现权限或 ioctl 错误？
- 检查：模块是否在 root 下运行、SELinux 策略是否阻塞、内核是否支持相应 ioctl。
- 可在终端运行并观察 dmesg / logcat 或 service.log 中的报错。

Q4: 更改配置后需重启吗？
- 修改 f2fsopt：无需重启，下次任务生效。
- 修改 service.sh（调度器逻辑）：建议重启或手动重启调度器进程（例如 kill 并让模块重启）。

故障排查清单（快速）：
1. 查看 /data/adb/modules/f2fs_optimizer/service.log
2. 确认分区类型（mount | grep /data）
3. 检查是否有 Busybox（当使用 cron 时）
4. 查看 dmesg 是否有 SELinux 拦截或 ioctl 错误

---

## 安全与风险提示

- 本模块调用内核级 IOCTL 与 fstrim，理论上安全，但任何底层文件系统操作都有小概率风险。
- 建议：在重要数据上做常规备份（尤其在首次尝试或修改阈值时）。
- 不要与其他激烈的 GC/Trim 模块并用（可能产生冲突与异常耗电）。
- 如遇疑难，请附上 /data/adb/modules/f2fs_optimizer/service.log 与相关 dmesg 输出以便排查。

---

## 开发者与贡献

- 贡献方式：欢迎问题、PR 与改进建议。请在提交 PR 前在 issue 讨论实现方案。
- 代码风格：纯 Shell，尽量保持兼容性与健壮的错误处理。
- 建议新增：自动化单元测试（模拟挂载/未挂载）、更详细的日志等级控制与更细粒度的回退策略（遇到异常自动回到安全模式）。

---

## 许可

参见仓库 LICENSE 文件（保留原作者声明）。
```
