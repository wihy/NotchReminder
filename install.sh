#!/usr/bin/env bash
set -euo pipefail

# NotchReminder 一键安装: 构建二进制 → 装 CC 插件 → 装开机自启 LaunchAgent。
# 幂等: 可重复运行。所有路径按本仓库固定位置写死。

REPO="$(cd "$(dirname "$0")" && pwd)"
BIN="$REPO/.build/release/NotchReminder"
PLUGIN_DIR="$REPO/cc-plugin"
STATE_DIR="$HOME/.notchreminder"
PLIST_SRC_LABEL="com.notchreminder.agent"
PLIST="$HOME/Library/LaunchAgents/$PLIST_SRC_LABEL.plist"
UID_NUM="$(id -u)"

echo "==> [1/5] 构建 release 二进制"
swift build -c release --package-path "$REPO"
if [ ! -x "$BIN" ]; then
  echo "错误: 构建后未找到可执行 $BIN" >&2
  exit 1
fi
echo "    产物: $BIN"

echo "==> [2/5] 准备状态目录 $STATE_DIR"
mkdir -p "$STATE_DIR"

echo "==> [3/5] 安装 CC 插件(本地 marketplace: notchreminder)"
# 先移除同名 marketplace 再加, 保证可重复运行(未安装时忽略报错)
claude plugin marketplace remove notchreminder >/dev/null 2>&1 || true
claude plugin marketplace add "$PLUGIN_DIR"
# 装并启用插件(user scope); 幂等: 已安装/已启用时下面命令会返回非零并打印提示,
# 这属正常(重复运行), 静默吞掉输出避免误报为失败。
claude plugin install notchreminder@notchreminder --scope user >/dev/null 2>&1 || true
claude plugin enable  notchreminder@notchreminder --scope user >/dev/null 2>&1 || true
echo "    CC 插件 notchreminder@notchreminder 已安装并启用(若已装则跳过; 重启 claude 会话后 hooks 生效)"

echo "==> [4/5] 安装开机自启 LaunchAgent"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$PLIST_SRC_LABEL</string>

    <key>ProgramArguments</key>
    <array>
        <string>$BIN</string>
    </array>

    <key>RunAtLoad</key>
    <true/>

    <key>KeepAlive</key>
    <dict>
        <key>Crashed</key>
        <true/>
    </dict>

    <key>ProcessType</key>
    <string>Interactive</string>

    <key>LimitLoadToSessionType</key>
    <string>Aqua</string>

    <key>StandardOutPath</key>
    <string>$STATE_DIR/agent.out.log</string>
    <key>StandardErrorPath</key>
    <string>$STATE_DIR/agent.err.log</string>
</dict>
</plist>
PLIST_EOF

# 改 plist 后必须先 bootout 再 bootstrap 才生效(未加载时忽略报错)
launchctl bootout "gui/$UID_NUM" "$PLIST" 2>/dev/null || true
launchctl bootstrap "gui/$UID_NUM" "$PLIST"
launchctl kickstart -k "gui/$UID_NUM/$PLIST_SRC_LABEL"

echo "==> [5/5] 完成"
echo ""
echo "验证:"
echo "  1) 菜单栏应出现 NotchReminder 图标(时钟)。若无, 看日志:"
echo "       cat $STATE_DIR/agent.err.log"
echo "  2) 查看 agent 运行状态:"
echo "       launchctl print gui/$UID_NUM/$PLIST_SRC_LABEL | head -20"
echo "  3) 重启 claude 会话后, 发起一轮对话, 应写出状态文件:"
echo "       cat $STATE_DIR/cc.json"
echo "  4) 卸载: $REPO/uninstall.sh"
