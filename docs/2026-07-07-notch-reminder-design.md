# NotchReminder 设计方案

> 一个围绕 MacBook Pro 刘海渲染「类灵动岛」浮层的健康提醒工具，由 Claude Code 使用行为数据驱动触发时机。
>
> 日期：2026-07-07 · 状态：设计已确认，待转实施规划

---

## 1. 背景与目标

用户是重度 Claude Code 用户。基于对本机 `~/.claude/projects` 全量对话记录（4184 个 jsonl，1.5GB，2026-05-30 → 07-07）的分析，得到工作习惯画像，据此设计一个久坐/喝水/护眼/熬夜的健康提醒工具，展示在刘海周围的类灵动岛浮层上。

### 1.1 关键事实（已验证）

- **macOS 没有原生「灵动岛」**：那是 iPhone 的硬件+系统特性。但本机 MacBook Pro（Mac17,2 / M5 / macOS 26.5）**有物理刘海**，业界方案（NotchNook / Boring Notch）均是**在刘海周围自绘浮层**。本方案同此路径。
- **CC hook 机制真实可用**：本机 `~/.claude/settings.json` 确认存在 18 种 hook（`SessionStart / PostToolUse / Stop / SessionEnd / UserPromptSubmit …`），均可执行 shell 命令 → CC 插件可在这些事件点写状态文件驱动外部 App。
- **DynamicNotchKit 可作基座**：`MrKai77/DynamicNotchKit`，**MIT 许可**、**Swift Package**（非整个 App）、最低 macOS 13+（本机 26.5 ✓）、活跃维护（2026-04 v1.1.0）。现成 `DynamicNotchInfo(icon:title:description:)` + `await notch.expand()` 即一张提醒卡片。

## 2. 用户工作习惯画像（设计依据）

| 维度 | 结论 |
|---|---|
| 强度 | 日均活跃 9.4 小时/活跃天；近两周多日 12–14.6h，最长单日 14.6h |
| 久坐 | 74 段 ≥50min 不间断，其中 **58 段 ≥90min**，最长一段连续 **699 分钟（11.7h）** |
| 作息 | 双峰 + 晚高峰：10–11 点、13–17 点、19–21 点；深夜 23:00–02:00 仍活跃（00 点 6222 事件），深夜占比 7.9% |
| 午休 | 12 点有下凹但很浅，中午基本没真正离开 |
| 周末 | 周六日强度砍半，但仍在工作 |

**核心设计推论**：用户不是"偶尔久坐"，而是**大量 90 分钟以上不间断**。因此提醒不应是死板定时，而应**数据驱动**——盯住"连续活跃时长"再触发。四类提醒（久坐/喝水/护眼/熬夜）均有数据支撑。

## 3. 需求决策（已与用户确认）

| 决策项 | 选择 |
|---|---|
| 落地形态 | **刘海浮层 App + CC 插件** |
| 提醒类型 | 久坐起身、定时喝水、护眼远眺(20-20-20)、熬夜劝退（全要） |
| 计时口径 | **全局活跃为主 + CC 加成**（App 以系统活跃时长为主计时，CC 信号补强） |
| 技术基座 | 方案 A：自建菜单栏小 App + `import DynamicNotchKit`（而非 fork boring.notch，也非裸写 NSPanel） |
| 项目位置 | `~/NotchReminder` |

## 4. 架构总览

```
┌─────────────────────────┐        ┌──────────────────────────────┐
│  CC 插件 (notch-reminder) │  写→   │   NotchReminder.app (菜单栏常驻) │
│  .claude-plugin/hooks     │ ~/.notchreminder/cc.json │  ①计时引擎 ②提醒调度 ③刘海浮层 │
│  SessionStart/PostToolUse │──────▶│                              │
│  Stop/SessionEnd 写活跃信号 │        │  DynamicNotchKit 渲染卡片 → 刘海 │
└─────────────────────────┘        └──────────────────────────────┘
       "CC 加成信号"                    主计时 = 系统全局活跃 (idle time)
```

**核心解耦思想**：两个部件**不直接通信**，只通过一个 JSON 状态文件（`~/.notchreminder/cc.json`）握手。

- App 单独就能跑：全局久坐/喝水/护眼/熬夜全部生效。
- CC 插件只是往文件里补一条"正在高强度跑 CC + 当前项目名"的加成信号，让提醒文案更贴。
- 任一边挂了，另一边不受影响。

**主计时口径**：App 用系统 idle time API（`CGEventSourceSecondsSinceLastEventType`，读"距上次任意键鼠输入过了多久"）。它只读**空闲时长**、不记录按键内容 → 大概率无需辅助功能权限（`待编码坐实`）。idle 超过 N 分钟 = 已休息 → 自动重置久坐计时。

## 5. 组件设计

### 5.1 CC 插件 — 纯传感器

标准 CC 插件，只干一件事：把活跃信号写进状态文件。不做任何计时/判断/弹窗。

```
cc-plugin/
├── .claude-plugin/plugin.json
└── hooks/
    ├── hooks.json               # 声明监听的 hook
    └── touch_activity.py        # 唯一逻辑（~30 行）
```

监听 4 个 hook，都调同一个脚本：

| Hook | 触发 | 动作 |
|---|---|---|
| `SessionStart` | CC 会话开启 | 写 `cc_active=true`、`session_start=now` |
| `UserPromptSubmit` | 发起一轮 | 更新 `last_event`、`project=<cwd 末段>` |
| `Stop` | 一轮答完 | 更新 `last_event`（活跃心跳） |
| `SessionEnd` | 会话结束 | 写 `cc_active=false` |

### 5.2 数据契约（唯一接口）

`~/.notchreminder/cc.json`：
```json
{
  "cc_active": true,
  "project": "SoulApp",
  "session_start": "2026-07-07T14:02:11+08:00",
  "last_event": "2026-07-07T15:34:50+08:00"
}
```

### 5.3 计时引擎 — idle 驱动状态机

App 每 ~10 秒采样一次系统 idle time，维护一组计时器。三个核心概念：

- **活跃**：`idle < 60s` → 各计时器累加。
- **真休息（重置事件）**：`idle ≥ 5min`（可配）→ 久坐计时器清零、记 `last_rest`。
- **CC 加成补活跃**：`cc_active=true` 且 `last_event` 在 90 秒内 → 即使无键鼠输入也算活跃（解决"盯着 CC 跑、手没动"被误判成休息的问题）。

四个计时器：

| 计时器 | 累加条件 | 归零/重置 |
|---|---|---|
| `sit`（久坐） | 活跃时累加 | 真休息(≥5min) → 清零 |
| `eye`（护眼） | 活跃时累加 | 每次弹护眼提醒后清零 |
| `water`（喝水） | 活跃时累加 | 每次弹喝水提醒后清零；真休息时暂停累加 |
| 熬夜 | 不用计时器，看墙上时钟（≥23:00 且当前活跃） | 按静默间隔防轰炸 |

引擎只跑一个采样循环 + 纯函数式"要不要触发"判断，无副作用、可单测。

### 5.4 四类提醒 — 默认阈值 + 分级打扰

默认阈值（全部可在菜单栏改）：

| 提醒 | 默认触发 | 依据 | 浮层样式 |
|---|---|---|---|
| 🧍 久坐起身 | 连续活跃 **50min** | 58 段 ≥90min，50min 在滑向 90min 深坑前拦一道；忽略后静默 15min 再补 | 强（带按钮，停留久） |
| 💧 喝水 | 累计工作 **60min** | 常规补水；真休息暂停累加 | 轻（一闪 ~4s 自动收） |
| 👀 护眼远眺 | 连续盯屏 **30min** | 标准 20-20-20 对深度专注太吵，放宽到 30min 提示远眺 20 秒 | 轻（一闪自动收） |
| 🌙 熬夜劝退 | 墙钟 **≥23:00 且活跃** | 23:00–02:00 仍高频；首弹温和，之后每 30min 仍在敲则语气渐强 | 强（停留久） |

文案示例（带 CC 加成的项目名）：
- 久坐：`🧍 连续 92 分钟了 · SoulApp 项目 / 起来走两步，眼睛也歇歇`
- 熬夜：`🌙 00:47 了 / 明天的你会感谢现在睡觉的你`

**分级打扰**：护眼/喝水高频 → "刘海一闪即收"轻样式，不打断思路；久坐/熬夜低频但重要 → 带按钮强样式。

**免打扰**：
- 检测全屏 App / 摄像头占用（演示、开会、看片）→ 自动静默，结束后补。
- 菜单栏一键"专注 1 小时"静音。
- 每类可单独关 + 调阈值。

### 5.5 菜单栏与交互

`LSUIElement` 菜单栏 App（无 Dock 图标、不抢焦点），开机自启用 `SMAppService`。

```
● NotchReminder
─────────────────────────
 当前：连续工作 92min · SoulApp        (只读状态行)
 下次久坐提醒：8min 后
─────────────────────────
 ☕️ 我起身了        (手动重置久坐计时)
 🔕 专注 1 小时      (临时全静音)
─────────────────────────
 ✓ 久坐  ✓ 喝水  ✓ 护眼  ✓ 熬夜   (四个开关)
 ⚙️ 设置…            (阈值滑块 / 开机自启 / 样式)
 退出
```

- 设置窗：4 类阈值滑块 + 开关、开机自启、样式偏好，存 `UserDefaults`。
- 强样式浮层：`起身5分钟`=snooze 并记真休息意图；`知道了`=收起。
- 轻样式浮层：无按钮，几秒自动收。
- 首启引导：一屏说明 →（若 idle API 需要）请求权限 → 提示装 CC 插件带一键命令。

## 6. 目录结构

```
NotchReminder/                     # ~/NotchReminder
├── app/                           # Swift 菜单栏 App
│   ├── Package.swift              # 依赖 DynamicNotchKit (SPM)
│   ├── App.swift                  # @main · LSUIElement · 菜单栏
│   ├── ActivityMonitor.swift      # 系统 idle 采样
│   ├── ReminderEngine.swift       # ★4 计时器状态机 + 触发判断（纯函数，可单测）
│   ├── CCSignalReader.swift       # 读 ~/.notchreminder/cc.json
│   ├── NotchPresenter.swift       # 封装 DynamicNotchKit 强/轻样式
│   ├── Settings.swift / MenuBar.swift
│   └── Tests/ReminderEngineTests.swift
├── cc-plugin/                     # CC 插件（可 symlink 进 ~/.claude/plugins）
│   └── .claude-plugin/plugin.json · hooks/{hooks.json,touch_activity.py}
└── docs/                          # 设计 spec + README
```

## 7. 分阶段交付（每阶段独立可验证）

| 阶段 | 内容 | ✅ 验证点 |
|---|---|---|
| **0 骨架** | 工程 + DynamicNotchKit + 菜单栏"测试提醒" | 点一下，刘海真的弹出卡片 |
| **1 引擎+久坐** | idle 采样 + `sit` 计时器（测试期阈值调 1min） | 连敲到点自动弹；离开 5min 回来计数归零；`ReminderEngine` 单测通过 |
| **2 另外三类** | 喝水/护眼/熬夜 + 分级样式 + 全屏静默 | 四类各自按规则触发；演示时不打扰 |
| **3 CC 加成** | 插件写信号 + App 读 | 跑 CC 提醒带项目名；盯 CC 不动键鼠不被误判休息 |
| **4 打磨** | 设置窗 + 开机自启 + 首启引导 | 重启后自起；阈值可调 |

**核心可测性**：`ReminderEngine` 是纯函数状态机——喂"时间戳 + idle 序列"跑单元测试，不用真等 50 分钟。阶段 1/2 可 TDD。

## 8. 待验证 / 风险项（feasibility 标签）

| 项 | 标签 | 说明 |
|---|---|---|
| idle 计时是否需要辅助功能权限 | `待编码坐实` | 优先用 `CGEventSourceSecondsSinceLastEventType`（读 idle，通常无需辅助功能权限）；不足再考虑 IOKit HIDIdleTime / input monitoring |
| DynamicNotchKit 是否有 auto-hide API | `待编码坐实` | README 未明确；计划 `expand()` 后延时 `hide()`，不行则退回自绘 |
| 全屏/摄像头占用检测 | `待验证` | 演示/会议静默需坐实检测 API（`NSWorkspace` 全屏态 / 摄像头占用信号） |
| CC 插件安装分发 | `已验证机制` | 放 `~/.claude/plugins` 或做 marketplace；hook 机制本机已确认可用 |

## 9. 非目标（YAGNI，本版不做）

- 今日健康仪表盘 / 周报统计（虽然数据能力已具备，属另一功能，留 v2）。
- 音乐控制 / 电池 / 文件 shelf 等 boring.notch 式通用刘海功能。
- 跨设备同步、云端。

---

## 附：数据来源

- [MrKai77/DynamicNotchKit](https://github.com/MrKai77/DynamicNotchKit)（基座，MIT）
- [TheBoredTeam/boring.notch](https://github.com/TheBoredTeam/boring.notch) · [jackson-storm/DynamicNotch](https://github.com/jackson-storm/DynamicNotch) · [Ebullioscopic/Atoll](https://github.com/Ebullioscopic/Atoll)（备选参考）
- 工作习惯画像：本机 `~/.claude/projects` 全量分析（脚本 `/tmp/cc_habits.py`）
