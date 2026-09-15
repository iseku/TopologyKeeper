# 🎵 TopologyKeeper

[![macOS](https://img.shields.io/badge/macOS-13.0%2B-blue.svg)](https://developer.apple.com/macos/) [![Swift](https://img.shields.io/badge/Swift-6.0-orange.svg)](https://swift.org/) [![Tests](https://img.shields.io/badge/Tests-253%20passed-brightgreen)]() [![License](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

**保持你的音频输出格式**：睡眠唤醒后 HDMI/eARC 设备回落到 `2ch` 时，自动恢复为预设的 「声道数 · 位深 · 采样率」，不再需要每次手动打开「MIDI」进行设置。

**声道交换**与 **LFE 混音**：修复多声道布局错乱与重低音声道缺失。



<p align="center">
  <img src="logo.png" alt="TopologyKeeper" width="100">
</p>

## 🚀 快速开始

1. 下载：`TopologyKeeper-0.1.0.dmg`（或对应版本）
2. 安装：打开DMG文件将`TopologyKeeper.app` 拖入 `Applications`
3. 启动：打开启动台，点击 `TopologyKeeper` 应用（系统状态栏出现图标，如出现麦克风授权提醒请确认）
4. 添加规则：点击状态栏图标 → 齿轮 → 「锁定规则」→ [+] 选择设备与目标格式

> 使用`声道交换` / `LFE 混音`前，先安装 [BlackHole](https://github.com/ExistentialAudio/BlackHole)：`brew install blackhole-16ch`，然后重启系统并把系统默认音频设备选择为 `BlackHole 16ch` 。



## ✨ 特性

- 🔄 **输出格式自动锁定** — 设备插拔、睡眠唤醒或格式被外部改动后，自动恢复预设格式
- 🔀 **声道交换** — 实时交换音频输出第 3 / 第 4 声道，修正「中置/低音炮」错误映射
- 🔉 **LFE 混音** — 将LFE声道按可调增益混入中置声道，为没有独立低音炮的音响补充低频
- ⚡ **实时处理** — 处理在实时音频回调中完成，非重采样、不写磁盘
- 🛠 **命令行工具 `tkctl`** — 无需 GUI 即可管理规则、查看状态



## 📦 自己编译

**环境要求**：macOS 13+ · Xcode CommandLineTools（无需完整 Xcode）

```bash
git clone https://github.com/iseku/TopologyKeeper.git
cd TopologyKeeper
Scripts/build_app.sh          # 构建应用
open Dist/TopologyKeeper.app  # 测试运行
```



## 🎮 使用

### 🔄 格式锁定

添加规则后一切自动进行：工具持续监听设备状态，只要当前格式 ≠ 预设值就自动恢复。

用于解决显示器外接HDMI/eARC音响时，MacOS不能自动切换至多声道输出格式的问题。

### 🔀 声道交换

自定义交换两个音频通道输出内容，用于解决因部分软件未遵循Apple音频输出布局规范，造成 C/LFE 颠倒的问题（如 Movist Pro、WOW、Wine/Crossover 中的游戏等）。

该功能保留LFE独立输出，适合配置了独立低音炮的使用场景。

### 🔉 LFE 混音

将LFE声道衰减后混入中置声道，增强低音效果。

用于解决未配置独立低音炮时LFE信号丢失的问题，本功能亦适用于C/LFE颠倒的问题，只是LFE不再独立输出。

⚡ 混音功能与声道交换功能互斥，启用其一自动停用另一个，可视自己的需求选择开启。

⚡ 经测试，声道交换和混音功能不影响原先声道布局正确的软件，不会额外引入声道错乱。

### 🛠 CLI命令

```bash
tkctl list                 # 列出输出设备
tkctl status 0             # 当前格式 vs 目标
tkctl seed 0 8 24 96000    # 为设备 0 写入规则
tkctl mix show             # LFE 混音配置与接线图
tkctl mix verify 3         # 客观验证（内置自测信号）
tkctl help                 # 全部命令
```



## 🤝 贡献

1. Fork 本仓库
2. 创建功能分支
3. 提交变更（请附带变更说明与测试结果）
4. 发起 Pull Request

## 📄 许可证

[MIT License](LICENSE)
