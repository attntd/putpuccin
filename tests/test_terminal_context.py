#!/usr/bin/env python3
"""Exercise SSH argument parsing and foreground detection with synthetic /proc."""
from importlib.machinery import SourceFileLoader
from importlib.util import module_from_spec, spec_from_loader
from pathlib import Path
import tempfile
import unittest
import sys
import json

script = Path(__file__).resolve().parents[1] / "scripts/terminal-context"
loader = SourceFileLoader("terminal_context", str(script))
spec = spec_from_loader(loader.name, loader)
context = module_from_spec(spec)
sys.dont_write_bytecode = True
loader.exec_module(context)


class TerminalContextTests(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory()
        self.addCleanup(self.work.cleanup)
        self.proc = Path(self.work.name)
        self.process(1, "kitty", ["kitty"], children=[2])
        self.process(2, "fish", ["fish"], tty=10, group=2, foreground=3, children=[3])
        self.process(3, "ssh", ["ssh", "attntd@radiodev"], tty=10, group=3, foreground=3)

    def process(self, pid, comm, argv, tty=0, group=1, foreground=-1, children=(), parent=1):
        p = self.proc / str(pid)
        p.mkdir(exist_ok=True)
        (p / "comm").write_text(comm)
        (p / "stat").write_text(f"{pid} ({comm}) S {parent} {group} 1 {tty} {foreground} 0 0")
        (p / "cmdline").write_bytes(b"\0".join(a.encode() for a in argv) + b"\0")
        (p / "task" / str(pid)).mkdir(parents=True, exist_ok=True)
        (p / "task" / str(pid) / "children").write_text(" ".join(map(str, children)))
        if not (p / "cwd").is_symlink():
            (p / "cwd").symlink_to("/local/project")

    def resolve(self):
        return context.terminal_context(1, self.proc, "laptop")

    def test_destinations(self):
        for argv, expected in [
            (["ssh", "user@host"], "host"),
            (["/usr/bin/ssh", "-vp2222", "-i", "/a key", "-J", "jump", "host"], "host"),
            (["ssh", "-o", "ProxyCommand=ssh jump nc %h %p", "host", "ls"], "host"),
            (["kitten", "ssh", "--kitten=cwd=/tmp", "--kitten", "env=A=B", "radiodev"], "radiodev"),
            (["kitty", "+kitten", "ssh", "mediarr"], "mediarr"),
            (["ssh", "--", "ssh://user@[2001:db8::1]:2222"], "2001:db8::1"),
        ]:
            with self.subTest(argv=argv):
                self.assertEqual(context.ssh_destination(argv), expected)

    def test_non_sessions_and_invalid_arguments(self):
        for args in [["ssh", "-N", "host"], ["ssh", "-G", "host"],
                     ["ssh", "-O", "check", "host"], ["ssh", "-W", "host:22", "jump"], ["ssh", "-p"],
                     ["kitten", "clipboard", "host"], ["scp", "host:file", "."],
                     ["ssh", "<b>host</b>"], ["ssh", "host\nname"],
                     ["ssh", "ssh://[invalid"], []]:
            with self.subTest(args=args):
                self.assertIsNone(context.ssh_destination(args))

    def test_remote_does_not_report_local_cwd(self):
        self.assertEqual(self.resolve(), {"host": "radiodev", "remote": True, "cwd": "", "command": "ssh"})

    def test_local_foreground_ignores_background_ssh(self):
        self.process(2, "fish", ["fish"], tty=10, group=2, foreground=2, children=[3])
        self.process(3, "ssh", ["ssh", "remote"], tty=10, group=3, foreground=2)
        self.assertEqual(self.resolve(), {"host": "laptop", "remote": False, "cwd": "/local/project", "command": "fish"})

    def test_kitten_ssh_without_local_shell(self):
        self.process(1, "kitty", ["kitty"], children=[3])
        self.process(3, "kitten", ["kitten", "ssh", "mediarr"], tty=10, group=3, foreground=3)
        self.assertEqual(self.resolve()["host"], "mediarr")

    def test_multiple_tabs_do_not_guess_host(self):
        self.process(1, "kitty", ["kitty"], children=[2, 4])
        self.process(4, "fish", ["fish"], tty=11, group=4, foreground=4)
        self.assertEqual(self.resolve(), {"host": "", "remote": True, "cwd": "", "command": ""})

    def test_multiple_tabs_on_same_host(self):
        self.process(1, "kitty", ["kitty"], children=[2, 4])
        self.process(4, "kitten", ["kitten", "ssh", "radiodev"], tty=11, group=4, foreground=4)
        self.assertEqual(self.resolve()["host"], "radiodev")

    def test_ssh_exits(self):
        self.process(2, "fish", ["fish"], tty=10, group=2, foreground=2)
        self.assertEqual(self.resolve()["host"], "laptop")

    def test_proxy_command_keeps_destination(self):
        self.process(3, "ssh", ["ssh", "radiodev"], tty=10, group=3, foreground=3, children=[4], parent=2)
        self.process(4, "ssh", ["ssh", "jump", "nc", "radiodev", "22"], tty=10, group=3, foreground=3, parent=3)
        self.assertEqual(self.resolve()["host"], "radiodev")

    def test_foreground_command_ignores_helpers(self):
        self.process(3, "codex", ["/usr/bin/codex"], tty=10, group=3, foreground=3, children=[4])
        self.process(4, "rg", ["rg", "pattern"], tty=10, group=3, foreground=3, parent=3)
        self.assertEqual(self.resolve()["command"], "codex")

    def test_node_cli_name(self):
        self.process(3, "node", ["node", "/usr/lib/codex/bin/codex.js"], tty=10, group=3, foreground=3)
        self.assertEqual(self.resolve()["command"], "codex")

    def test_multiple_local_tabs_do_not_guess_command(self):
        self.process(3, "codex", ["codex"], tty=10, group=3, foreground=3)
        self.process(1, "kitty", ["kitty"], children=[2, 4])
        self.process(4, "fish", ["fish"], tty=11, group=4, foreground=4)
        self.assertEqual(self.resolve()["command"], "")

    def test_missing_terminal(self):
        with self.assertRaises(ProcessLookupError):
            context.terminal_context(999, self.proc, "laptop")

    def kitty_metadata(self, windows, start="1234"):
        stat = self.proc / "1/stat"
        fields = stat.read_text().rsplit(")", 1)[1].split()
        fields.extend(["0"] * (20 - len(fields)))
        fields[19] = "1234"
        stat.write_text("1 (kitty) " + " ".join(fields))
        directory = self.proc / "quickshell-de-terminal"
        directory.mkdir(exist_ok=True)
        (directory / "1.json").write_text(json.dumps({"start": start, "windows": windows}))

    def test_kitty_remote_full_path_and_command(self):
        record = {"title": "core", "host": "radiology-dev", "cwd": "/home/attntd/ristu/core", "command": "codex"}
        self.kitty_metadata([record])
        self.assertEqual(context.kitty_context(1, "⠋ core", self.proc, self.proc), record)

    def test_kitty_metadata_rejects_reused_pid(self):
        self.kitty_metadata([{"title": "core", "cwd": "/old", "host": "old", "command": "codex"}], start="old")
        self.assertIsNone(context.kitty_context(1, "core", self.proc, self.proc))

    def test_kitty_selects_matching_os_window(self):
        windows = [{"title": title, "cwd": path, "host": "host", "command": "fish"}
                   for title, path in [("one", "/one"), ("two", "/two")]]
        self.kitty_metadata(windows)
        self.assertEqual(context.kitty_context(1, "two", self.proc, self.proc)["cwd"], "/two")
        self.assertIsNone(context.kitty_context(1, "unknown", self.proc, self.proc))


if __name__ == "__main__":
    unittest.main()
