#!/usr/bin/env python3
"""CC 传感器 hook: 把活跃信号写进 ~/.notchreminder/cc.json(spec §5.2)。

4 个 hook 事件都调本脚本:
  SessionStart     -> cc_active=true, session_start=now, last_event=now, project=cwd 末段
  UserPromptSubmit -> last_event=now, project=cwd 末段(cc_active 保持 true)
  Stop             -> last_event=now(活跃心跳; cc_active 保持 true)
  SessionEnd       -> cc_active=false, last_event=now

纯传感器: 不做任何计时/判断/弹窗。失败静默(exit 0), 不阻断 CC。
"""
import json
import os
import sys
from datetime import datetime


def state_path():
    override = os.environ.get("NOTCHREMINDER_STATE_FILE")
    if override:
        return override
    return os.path.join(os.path.expanduser("~/.notchreminder"), "cc.json")


def now_iso():
    # 本地时区带偏移, 如 2026-07-07T15:34:50+08:00
    return datetime.now().astimezone().isoformat(timespec="seconds")


def load_state(path):
    try:
        with open(path) as f:
            st = json.load(f)
        return st if isinstance(st, dict) else {}
    except Exception:
        return {}


def atomic_write(path, obj):
    d = os.path.dirname(path)
    os.makedirs(d, exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(obj, f)
    os.replace(tmp, path)


def main():
    try:
        raw = sys.stdin.read()
        data = json.loads(raw) if raw.strip() else {}
    except Exception:
        data = {}
    if not isinstance(data, dict):
        data = {}

    event = data.get("hook_event_name", "")
    cwd = data.get("cwd", "") or ""
    project = os.path.basename(cwd.rstrip("/")) if cwd else None

    path = state_path()
    st = load_state(path)
    ts = now_iso()

    if event == "SessionStart":
        st["cc_active"] = True
        st["session_start"] = ts
        st["last_event"] = ts
        if project:
            st["project"] = project
    elif event == "UserPromptSubmit":
        st["cc_active"] = True
        st["last_event"] = ts
        if project:
            st["project"] = project
    elif event == "Stop":
        st["cc_active"] = True
        st["last_event"] = ts
    elif event == "SessionEnd":
        st["cc_active"] = False
        st["last_event"] = ts
    else:
        # 未知事件: 仅记一次心跳, 不改 cc_active。
        st["last_event"] = ts

    atomic_write(path, st)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        # 传感器失败不该阻断 CC。
        pass
    sys.exit(0)
