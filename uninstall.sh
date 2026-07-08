#!/usr/bin/env bash
set -uo pipefail

# NotchReminder 卸载: 停 + 删 LaunchAgent → 卸 CC 插件 + 移除 marketplace。
# 幂等: 各步未安装时忽略报错。默认保留 ~/.notchreminder(状态/日志); 传 --purge 一并删除。

PLIST_SRC_LABEL="com.notchreminder.agent"
PLIST="$HOME/Library/LaunchAgents/$PLIST_SRC_LABEL.plist"
STATE_DIR="$HOME/.notchreminder"
UID_NUM="$(id -u)"
PURGE=0
[ "${1:-}" = "--purge" ] && PURGE=1

echo "==> [1/3] 停止并移除 LaunchAgent"
launchctl bootout "gui/$UID_NUM" "$PLIST" 2>/dev/null || true
rm -f "$PLIST"
echo "    已 bootout 并删除 $PLIST"

echo "==> [2/3] 卸载 CC 插件与本地 marketplace"
claude plugin uninstall notchreminder@notchreminder --scope user >/dev/null 2>&1 || true
claude plugin marketplace remove notchreminder >/dev/null 2>&1 || true
echo "    CC 插件 notchreminder 已移除(重启 claude 会话后 hooks 失效)"

echo "==> [3/3] 状态目录"
if [ "$PURGE" -eq 1 ]; then
  rm -rf "$STATE_DIR" || true
  echo "    已删除 $STATE_DIR(--purge)"
else
  echo "    保留 $STATE_DIR(如需一并删除, 重跑: $0 --purge)"
fi

echo "==> 卸载完成。二进制在 .build/ 内, git clean -xdf 可清理构建产物。"
