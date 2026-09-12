#!/usr/bin/env python3
"""Test packaging and installation transactions in temporary paths, without root/PAM."""
import hashlib
from importlib.machinery import SourceFileLoader
from importlib.util import module_from_spec, spec_from_loader
import json
import os
import runpy
from pathlib import Path
import shutil
import subprocess
import tempfile
import stat
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import tomllib

ROOT = Path(__file__).resolve().parents[1]
HYPRLAND = shutil.which('Hyprland')
loader = SourceFileLoader('install_greeter', str(ROOT / 'scripts/install-greeter'))
install = module_from_spec(spec_from_loader(loader.name, loader)); loader.exec_module(install)


class InstallationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='qs-greeter-install-test-')
        self.addCleanup(self.temporary.cleanup)
        self.work = Path(self.temporary.name)
        self.bundle = self.work / 'bundle'
        artwork = self.work / 'artwork'; artwork.write_bytes(b'synthetic-test-image')
        with patch.object(install.pwd, 'getpwall', return_value=[SimpleNamespace(pw_uid=1000, pw_name='alice')]):
            install.package(self.bundle, 'alice', artwork, {'alice': artwork}, {'alice'})
        paths = {'DESTINATION': 'share/greeter', 'EXECUTABLES': 'libexec/greeter', 'CONFIG': 'etc/greetd/config.toml',
            'PAM': 'etc/pam.d/quickshell-greeter', 'DROPIN': 'etc/systemd/system/greetd.service.d/quickshell.conf',
            'DISPLAY_MANAGER': 'etc/systemd/system/display-manager.service', 'BACKUPS': 'backups'}
        for key, value in paths.items():
            replacement = patch.object(install, key, self.work / value)
            replacement.start(); self.addCleanup(replacement.stop)
        for name, kwargs in [('geteuid', {'return_value': 0}), ('chown', {'return_value': None})]:
            replacement = patch.object(install.os, name, **kwargs); replacement.start(); self.addCleanup(replacement.stop)
        replacement = patch.object(install.pwd, 'getpwnam', return_value=SimpleNamespace(pw_uid=999))
        replacement.start(); self.addCleanup(replacement.stop)
        replacement = patch.object(install.shutil, 'which', side_effect=lambda name: '/usr/bin/' + name)
        replacement.start(); self.addCleanup(replacement.stop)
        install.PAM.parent.mkdir(parents=True)
        self.commands = []

    def command(self, command, **kwargs):
        self.commands.append(command)
        return subprocess.CompletedProcess(command, 1 if 'is-enabled' in command else 0)

    def rehash(self):
        manifest = {str(path.relative_to(self.bundle)): hashlib.sha256(path.read_bytes()).hexdigest()
                    for path in self.bundle.rglob('*') if path.is_file() and path != self.bundle / 'manifest.json'}
        (self.bundle / 'manifest.json').write_text(json.dumps(manifest))

    def test_package_is_separate_and_production_only(self):
        files = install.check_bundle(self.bundle)
        self.assertFalse(any(name.startswith(('services/', 'tests/', 'assets/pam/')) for name in files))
        self.assertNotIn('/home/', (self.bundle / 'shell.qml').read_text())
        self.assertTrue((self.bundle / 'users').stat().st_mode & 0o111)
        self.assertNotIn('IpcHandler', (self.bundle / 'shell.qml').read_text())
        self.assertNotIn('Quickshell.Services.Pam', ''.join(path.read_text() for path in self.bundle.rglob('*.qml')))

    def test_upgrade_removes_obsolete_helpers_and_uses_vendor_daemon(self):
        install.EXECUTABLES.mkdir(parents=True)
        for name in ('desktop', 'retire', 'greetd'):
            (install.EXECUTABLES / name).write_text('obsolete helper')
        install.DROPIN.parent.mkdir(parents=True)
        previous = '[Service]\nExecStart=\nExecStart=/obsolete/greetd\nEnvironment=OLD_HANDOFF=1\n'
        install.DROPIN.write_text(previous)
        with patch.object(install.subprocess, 'run', side_effect=self.command):
            install.activate(self.bundle)
            self.assertEqual({p.name for p in install.EXECUTABLES.iterdir()}, {'session', 'ui', 'compositor'})
            self.assertEqual(install.DROPIN.read_text(), '[Service]\nLimitCORE=0\nUMask=0077\n')
            self.assertFalse(any('restart' in c or 'stop' in c or '--now' in c for c in self.commands))
            backup = next(install.BACKUPS.iterdir())
            install.restore_files(backup, json.loads((backup / 'previous.json').read_text()))
        self.assertEqual(install.DROPIN.read_text(), previous)
        self.assertEqual({p.name for p in install.EXECUTABLES.iterdir()}, {'desktop', 'retire', 'greetd'})

    def verify_compositor_config(self, config):
        runtime = self.work / 'hyprland-runtime'
        runtime.mkdir(mode=0o700)
        environment = os.environ.copy()
        environment.update({
            'XDG_RUNTIME_DIR': str(runtime),
            'XDG_CONFIG_HOME': str(runtime / 'config'),
            'XDG_STATE_HOME': str(runtime / 'state'),
            'XDG_CACHE_HOME': str(runtime / 'cache'),
            'XDG_DATA_HOME': str(runtime / 'data'),
            'HYPRLAND_NO_CRASHREPORTER': '1',
            'HYPRLAND_NO_SD_NOTIFY': '1',
            'HYPRLAND_NO_SD_VARS': '1',
        })
        result = subprocess.run(
            [HYPRLAND, '--verify-config', '-c', str(config)],
            env=environment, capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    @unittest.skipUnless(HYPRLAND, 'Hyprland is required to validate its Lua API')
    def test_packaged_compositor_config_loads_with_installed_hyprland(self):
        self.verify_compositor_config(self.bundle / 'hyprland.lua')

    @unittest.skipUnless(HYPRLAND, 'Hyprland is required to validate its Lua API')
    def test_ui_handoff_uses_a_supported_dispatcher(self):
        with patch('subprocess.run') as command, patch('resource.setrlimit'), patch.object(os, 'umask'):
            runpy.run_path(str(self.bundle / 'ui'), run_name='__main__')
        exit_command = command.call_args.args[0]
        self.assertEqual(exit_command[:2], ['/usr/bin/hyprctl', 'dispatch'])
        # Binding validates the real dispatcher without executing it or contacting
        # a running compositor. The UI subprocesses above are all mocked.
        config = self.work / 'handoff.lua'
        config.write_text('hl.bind("SUPER + Q", ' + exit_command[2] + ')\n')
        self.verify_compositor_config(config)

    def test_session_uses_watchdog_and_discards_foreign_desktop_environment(self):
        runtime = self.work / 'runtime'; runtime.mkdir(mode=0o700)
        socket = str(self.work / 'fake-greetd.sock')
        real_stat = os.stat
        def fake_stat(path, *args, **kwargs):
            if str(path) == socket: return SimpleNamespace(st_mode=stat.S_IFSOCK)
            return real_stat(path, *args, **kwargs)
        with patch.dict(os.environ, {'XDG_RUNTIME_DIR': str(runtime), 'GREETD_SOCK': socket,
                'XDG_CURRENT_DESKTOP': 'foreign', 'LD_PRELOAD': '/untrusted',
                'QML_IMPORT_PATH': '/untrusted', 'XDG_SEAT': 'seat0', 'XDG_VTNR': '1'}), \
                patch('pwd.getpwuid', return_value=SimpleNamespace(pw_name='greeter', pw_dir='/')), \
                patch.object(os, 'geteuid', return_value=os.getuid()), patch.object(os, 'stat', side_effect=fake_stat), \
                patch('resource.setrlimit'), patch.object(os, 'umask'), patch.object(os, 'execve') as execute:
            runpy.run_path(str(self.bundle / 'session'), run_name='__main__')
        path, command, environment = execute.call_args.args
        self.assertEqual(path, '/usr/bin/dbus-run-session')
        self.assertEqual(command, ['dbus-run-session', '--', '/usr/bin/start-hyprland',
            '--no-nixgl', '--path', '/usr/local/libexec/quickshell-greeter/compositor'])
        for key in ('XDG_CURRENT_DESKTOP', 'LD_PRELOAD', 'QML_IMPORT_PATH', 'DBUS_SESSION_BUS_ADDRESS'):
            self.assertNotIn(key, environment)
        self.assertEqual(environment['XDG_SESSION_DESKTOP'], 'quickshell-greeter')
        self.assertEqual(environment['XDG_SEAT'], 'seat0')

    def test_compositor_refuses_recovery_and_invalid_config(self):
        launch = runpy.run_path(str(self.bundle / 'compositor'))['main']
        with patch('subprocess.run') as verify, patch.object(os, 'execv') as execute:
            with self.assertRaises(SystemExit): launch(['--watchdog-fd', '4', '--safe-mode'])
            verify.assert_not_called(); execute.assert_not_called()
            with self.assertRaises(SystemExit): launch(['--config', '/untrusted'])
            verify.assert_not_called(); execute.assert_not_called()
        read, write = os.pipe()
        try:
            with patch('subprocess.run', return_value=SimpleNamespace(returncode=1)), patch.object(os, 'execv') as execute:
                with self.assertRaises(SystemExit): launch(['--watchdog-fd', str(write)])
                execute.assert_not_called()
            with patch('subprocess.run', return_value=SimpleNamespace(returncode=0)) as verify, patch.object(os, 'execv') as execute:
                launch(['--watchdog-fd', str(write)])
                self.assertIn('--verify-config', verify.call_args.args[0])
                self.assertEqual(execute.call_args.args[1], ['Hyprland', '--watchdog-fd', str(write),
                    '-c', '/usr/local/share/quickshell-greeter/hyprland.lua'])
        finally:
            os.close(read); os.close(write)

    def test_test_transport_is_rejected_even_with_valid_checksum(self):
        (self.bundle / 'integrations/GreeterNative/libgreetdclient.so').write_bytes(b'QUICKSHELL_GREETER_TEST_ONLY_PEER')
        self.rehash()
        with self.assertRaisesRegex(ValueError, 'test or unrecognized'): install.check_bundle(self.bundle)

    def test_unknown_nested_manifest_is_rejected(self):
        (self.bundle / 'core/manifest.json').write_text('{}')
        with self.assertRaisesRegex(ValueError, 'Unexpected file'): install.check_bundle(self.bundle)

    def test_symlink_and_checksum_tampering_are_rejected(self):
        avatar = self.bundle / 'assets/avatars/alice.png'; avatar.unlink(); avatar.symlink_to('/etc/passwd')
        with self.assertRaisesRegex(ValueError, 'symlinks'): install.check_bundle(self.bundle)
        avatar.unlink(); avatar.write_text('tampered')
        with self.assertRaisesRegex(ValueError, 'checksum'): install.check_bundle(self.bundle)

    def test_install_enables_without_starting_and_restores_previous_files(self):
        install.CONFIG.parent.mkdir(parents=True)
        install.CONFIG.write_text('previous configuration\n')
        with patch.object(install.subprocess, 'run', side_effect=self.command):
            install.activate(self.bundle)
            self.assertEqual(install.CONFIG.read_bytes(), (self.bundle / 'greetd.toml').read_bytes())
            self.assertIn(['systemctl', 'enable', 'greetd.service'], self.commands)
            self.assertFalse(any('--now' in command or 'start' in command or 'restart' in command for command in self.commands))
            for path in install.DESTINATION.rglob('*'):
                self.assertEqual(path.stat().st_mode & 0o022, 0)
            backup = next(install.BACKUPS.iterdir())
            install.restore_files(backup, json.loads((backup / 'previous.json').read_text()))
        self.assertEqual(install.CONFIG.read_text(), 'previous configuration\n')
        self.assertFalse(install.DESTINATION.exists())
        self.assertFalse(install.PAM.exists())

    def test_failed_activation_rolls_back_automatically(self):
        install.CONFIG.parent.mkdir(parents=True)
        install.CONFIG.write_text('previous configuration\n')
        def failure(command, **kwargs):
            self.commands.append(command)
            if 'enable' in command: raise subprocess.CalledProcessError(1, command)
            return subprocess.CompletedProcess(command, 1 if 'is-enabled' in command else 0)
        with patch.object(install.subprocess, 'run', side_effect=failure):
            with self.assertRaises(subprocess.CalledProcessError): install.activate(self.bundle)
        self.assertEqual(install.CONFIG.read_text(), 'previous configuration\n')
        self.assertFalse(install.DESTINATION.exists())
        self.assertFalse(install.PAM.exists())

    def test_policy_guards_fingerprint_and_preserves_password_policy(self):
        config = tomllib.loads((self.bundle / 'greetd.toml').read_text())
        self.assertNotIn('initial_session', config)
        self.assertFalse(config['general']['source_profile'])
        self.assertEqual(config['general']['service'], 'quickshell-greeter')
        self.assertEqual(config['default_session']['user'], 'greeter')
        self.assertEqual(config['default_session']['service'], 'greetd')
        import re
        auth = [re.match(r'auth\s+(\[[^\]]+\]|\w+)\s+(\S+)(?:\s+(.*))?', line).groups()
            for line in (self.bundle / 'pam.conf').read_text().splitlines() if line.startswith('auth ')]
        fp = next(index for index, line in enumerate(auth) if line[1] == 'pam_fprintd.so')
        self.assertEqual({line[1] for line in auth[:fp]}, {'pam_nologin.so', 'pam_shells.so', 'pam_faillock.so'})
        self.assertTrue(all(line[0] == 'requisite' for line in auth[:fp]))
        self.assertEqual(sum(line[1] == 'pam_fprintd.so' for line in auth), 2)
        self.assertTrue(all(line[2] == 'max-tries=1 timeout=4' for line in auth if line[1] == 'pam_fprintd.so'))
        self.assertEqual(auth[-1], ('include', 'system-auth', None))
        self.assertEqual(auth[-2], ('[success=ignore default=die]',
            '/usr/local/share/quickshell-greeter/integrations/GreeterNative/pam_greeter_gate.so', None))


if __name__ == '__main__': unittest.main(verbosity=2)
