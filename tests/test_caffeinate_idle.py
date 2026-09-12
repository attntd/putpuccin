#!/usr/bin/env python3
"""Validate idle action policy without dimming, blanking, locking or suspending."""
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest
from unittest.mock import patch

loader = importlib.machinery.SourceFileLoader('caffeinate_idle', str(Path(__file__).resolve().parents[1] / 'scripts/caffeinate-idle'))
spec = importlib.util.spec_from_loader(loader.name, loader)
helper = importlib.util.module_from_spec(spec)
loader.exec_module(helper)


class IdlePolicyTests(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory(prefix='caffeinate-idle-test-')
        self.addCleanup(self.work.cleanup)
        self.state = dict(active=False, preventDisplaySleep=False, preventLock=False, preventSleep=False)
        self.commands = []
        self.reply = None
        self.failure = None
        self.action_code = 0
        self.addCleanup(patch.stopall)
        patch.dict(os.environ, XDG_RUNTIME_DIR=self.work.name).start()
        patch.object(helper.subprocess, 'run', side_effect=self.command).start()

    def command(self, argv, **kwargs):
        if argv[0] == 'qs':
            self.assertEqual(argv[-3:], ['call', 'caffeinate', 'status'])
            self.assertGreater(kwargs['timeout'], 0)
            self.assertLessEqual(kwargs['timeout'], 1)
            if self.failure: raise self.failure
            return subprocess.CompletedProcess(argv, 0, self.reply if self.reply is not None else json.dumps(self.state))
        self.commands.append(argv)
        self.assertEqual(kwargs['timeout'], 5)
        return subprocess.CompletedProcess(argv, self.action_code)

    def event(self, name):
        with patch.object(helper.sys, 'argv', ['caffeinate-idle', name]):
            return helper.main()

    def test_three_modes_and_disabled_actions(self):
        # Expected visible effects from the user contract; no actual commands run.
        cases = [
            (False, False, False, False, ['brightnessctl', 'hyprctl', 'loginctl', 'systemctl']),
            (True, False, True, True, ['brightnessctl', 'hyprctl']),
            (True, True, True, True, []),
            (True, False, False, True, ['brightnessctl', 'hyprctl', 'loginctl']),
        ]
        for active, display, lock, sleep, expected in cases:
            with self.subTest(expected=expected):
                self.state = dict(active=active, preventDisplaySleep=display, preventLock=lock, preventSleep=sleep)
                self.commands.clear()
                for action in ['dim', 'display-off', 'lock', 'suspend']:
                    self.assertEqual(self.event(action), 0)
                self.assertEqual([argv[0] for argv in self.commands], expected)

    def test_lock_remains_available_when_shell_reply_is_bad(self):
        for reply in ('', 'null', '[]', 'not JSON', '{}', '{"active":true,"preventLock":"true"}', '{"active":false,"preventLock":true}'):
            with self.subTest(reply=reply):
                self.reply = reply
                self.commands.clear()
                self.assertEqual(self.event('lock'), 0)
                self.assertEqual(self.commands, [['loginctl', 'lock-session']])
        for failure in (FileNotFoundError(), subprocess.TimeoutExpired('qs', 1), subprocess.CalledProcessError(1, 'qs')):
            self.failure = failure
            self.commands.clear()
            self.assertEqual(self.event('lock'), 0)
            self.assertEqual(self.commands, [['loginctl', 'lock-session']])

    def test_skipped_dim_never_restores_stale_brightness(self):
        self.state = dict(active=True, preventDisplaySleep=True)
        self.event('dim')
        self.event('dim-resume')
        self.event('display-resume')
        self.assertEqual(self.commands, [['hyprctl', 'dispatch', 'hl.dsp.dpms({ action = "enable" })']])

    def test_empty_reply_during_reload_preserves_presentation(self):
        self.state = dict(active=True, preventDisplaySleep=True, preventLock=True, preventSleep=True)
        for action in ['dim', 'display-off', 'lock', 'suspend']:
            calls = []
            def transient(argv, **kwargs):
                if argv[0] == 'qs':
                    calls.append(argv)
                    if len(calls) == 1:
                        return subprocess.CompletedProcess(argv, 0, '')
                return self.command(argv, **kwargs)
            with patch.object(helper.subprocess, 'run', side_effect=transient):
                self.assertEqual(self.event(action), 0)
            self.assertEqual(len(calls), 2)
            self.assertEqual(self.commands, [])

    def test_explicit_reload_response_preserves_presentation(self):
        replies = iter(['Not ready to accept queries yet.\n', '',
                        json.dumps(dict(active=True, preventLock=True))])
        def reloading(argv, **kwargs):
            if argv[0] == 'qs':
                return subprocess.CompletedProcess(argv, 0, next(replies))
            return self.command(argv, **kwargs)
        with patch.object(helper.subprocess, 'run', side_effect=reloading):
            self.assertEqual(self.event('lock'), 0)
        self.assertEqual(self.commands, [])

    def test_reload_retries_have_one_total_deadline_and_do_not_prevent_lock(self):
        clock = [0.0]
        def advance(seconds): clock[0] += seconds
        def empty(argv, **kwargs):
            if argv[0] == 'qs':
                advance(min(.45, kwargs['timeout']))
                return subprocess.CompletedProcess(argv, 0, '')
            return self.command(argv, **kwargs)
        with patch.object(helper.time, 'monotonic', side_effect=lambda: clock[0]), \
             patch.object(helper.time, 'sleep', side_effect=advance), \
             patch.object(helper.subprocess, 'run', side_effect=empty):
            self.assertEqual(self.event('lock'), 0)
        self.assertAlmostEqual(clock[0], 3)
        self.assertEqual(self.commands, [['loginctl', 'lock-session']])

    def test_brightness_restored_once_even_when_mode_changes(self):
        self.event('dim')
        self.state = dict(active=True, preventDisplaySleep=True)
        self.event('display-resume')
        self.event('dim-resume')
        self.assertEqual(self.commands, [
            ['brightnessctl', '-s', 'set', '10%'],
            ['hyprctl', 'dispatch', 'hl.dsp.dpms({ action = "enable" })'],
            ['brightnessctl', '-r'],
        ])
        self.assertFalse((Path(self.work.name) / 'quickshell-caffeinate-dimmed').exists())

    def test_failed_dim_and_unknown_action(self):
        self.action_code = 1
        self.assertEqual(self.event('dim'), 1)
        self.assertEqual(self.event('dim-resume'), 0)
        self.assertEqual(self.commands, [['brightnessctl', '-s', 'set', '10%']])
        self.commands.clear()
        self.assertEqual(self.event('anything; echo invalid'), 2)
        self.assertEqual(self.commands, [])

    def test_activity_during_ipc_restores_after_dim_finishes(self):
        querying = threading.Event()
        resumed = threading.Event()
        release = threading.Event()
        original = self.command

        def delayed(argv, **kwargs):
            if argv[0] == 'qs':
                querying.set()
                self.assertTrue(release.wait(2))
            return original(argv, **kwargs)

        def resume():
            helper.dispatch('dim-resume')
            resumed.set()

        with patch.object(helper.subprocess, 'run', side_effect=delayed):
            dim = threading.Thread(target=helper.dispatch, args=('dim',))
            restore = threading.Thread(target=resume)
            dim.start()
            self.assertTrue(querying.wait(2))
            restore.start()
            self.assertFalse(resumed.wait(.05), 'Resume overtook the pending dim')
            release.set()
            dim.join(2)
            restore.join(2)
            self.assertFalse(dim.is_alive() or restore.is_alive())
        self.assertEqual(self.commands, [['brightnessctl', '-s', 'set', '10%'], ['brightnessctl', '-r']])


if __name__ == '__main__':
    unittest.main()
