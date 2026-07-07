import json
import os
import subprocess
import sys
import tempfile
import unittest

SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "touch_activity.py")


def run_hook(state_file, payload):
    """把 payload 作为 stdin 喂给 touch_activity.py, 返回解析后的 cc.json(dict)。"""
    env = dict(os.environ)
    env["NOTCHREMINDER_STATE_FILE"] = state_file
    proc = subprocess.run(
        [sys.executable, SCRIPT],
        input=json.dumps(payload),
        text=True,
        capture_output=True,
        env=env,
    )
    assert proc.returncode == 0, f"hook exited {proc.returncode}: {proc.stderr}"
    with open(state_file) as f:
        return json.load(f)


class TouchActivityTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.state_file = os.path.join(self.tmp.name, "cc.json")

    def tearDown(self):
        self.tmp.cleanup()

    def test_session_start_sets_active_and_project_and_start(self):
        data = run_hook(self.state_file, {
            "hook_event_name": "SessionStart",
            "cwd": "/Users/chunhaixu/SoulApp",
            "session_id": "s1",
        })
        self.assertTrue(data["cc_active"])
        self.assertEqual(data["project"], "SoulApp")
        self.assertIn("session_start", data)
        self.assertIn("last_event", data)
        # ISO8601 带时区偏移(以 + 或 - 结尾的偏移段)
        self.assertRegex(data["session_start"], r"T\d{2}:\d{2}:\d{2}[+-]\d{2}:\d{2}$")

    def test_user_prompt_submit_updates_last_event_and_project(self):
        run_hook(self.state_file, {
            "hook_event_name": "SessionStart",
            "cwd": "/Users/chunhaixu/SoulApp",
            "session_id": "s1",
        })
        data = run_hook(self.state_file, {
            "hook_event_name": "UserPromptSubmit",
            "cwd": "/Users/chunhaixu/NotchReminder",
            "session_id": "s1",
        })
        self.assertTrue(data["cc_active"])
        self.assertEqual(data["project"], "NotchReminder")  # project 跟随最新 cwd

    def test_stop_keeps_active_and_bumps_last_event(self):
        run_hook(self.state_file, {
            "hook_event_name": "SessionStart",
            "cwd": "/Users/chunhaixu/SoulApp",
            "session_id": "s1",
        })
        data = run_hook(self.state_file, {
            "hook_event_name": "Stop",
            "cwd": "/Users/chunhaixu/SoulApp",
            "session_id": "s1",
        })
        self.assertTrue(data["cc_active"])
        self.assertIn("last_event", data)

    def test_session_end_flips_active_false(self):
        run_hook(self.state_file, {
            "hook_event_name": "SessionStart",
            "cwd": "/Users/chunhaixu/SoulApp",
            "session_id": "s1",
        })
        data = run_hook(self.state_file, {
            "hook_event_name": "SessionEnd",
            "cwd": "/Users/chunhaixu/SoulApp",
            "session_id": "s1",
        })
        self.assertFalse(data["cc_active"])

    def test_empty_stdin_does_not_crash(self):
        env = dict(os.environ)
        env["NOTCHREMINDER_STATE_FILE"] = self.state_file
        proc = subprocess.run(
            [sys.executable, SCRIPT],
            input="",
            text=True,
            capture_output=True,
            env=env,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)


if __name__ == "__main__":
    unittest.main()
