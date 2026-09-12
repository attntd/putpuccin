#!/usr/bin/env python3
"""Exercise packaging, failed upgrades, atomic activation and rollback in /tmp."""
import hashlib
from contextlib import redirect_stderr, redirect_stdout
import importlib.machinery
import importlib.util
import io
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
loader = importlib.machinery.SourceFileLoader("qs_installer", str(ROOT / "scripts/install"))
spec = importlib.util.spec_from_loader(loader.name, loader)
installer = importlib.util.module_from_spec(spec)
loader.exec_module(installer)


def digest_tree(root):
    return {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in root.rglob("*") if path.is_file()}


class InstallationTests(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory(prefix="qs-install-test-")
        self.addCleanup(self.work.cleanup)
        self.base = Path(self.work.name)
        self.destination = self.base / "config with spaces/quickshell"
        self.backups = self.base / "backups"
        self.destination.parent.mkdir()
        self.settings = self.destination.parent / "quickshell-de/settings.json"
        self.settings.parent.mkdir()
        self.settings.write_text('{"personal": "keep exactly"}\n')

    def stage(self):
        stage = Path(tempfile.mkdtemp(prefix="stage-", dir=self.base))
        installer.package(ROOT, stage, self.destination)
        return stage

    def run_install(self, *options):
        return subprocess.run([
            sys.executable, str(ROOT / "scripts/install"), "--skip-build", "--skip-packages",
            "--destination", str(self.destination), "--backup-root", str(self.backups),
            *map(str, options),
        ], capture_output=True, text=True, timeout=60)

    def test_standalone_package_and_native_imports(self):
        stage = self.stage()
        self.assertTrue((stage / "modules/statusbar/StatusBar.qml").is_file())
        self.assertTrue(os.access(stage / "scripts/ssh-askpass", os.X_OK))
        self.assertTrue(os.access(stage / installer.LOCK_OBSERVER, os.X_OK))
        self.assertTrue((stage / installer.LOCK_OBSERVER.parent / "LICENSE").is_file())
        self.assertTrue((stage / "config/lock-fallback.conf").is_file())
        for name in ("tests", "docs", "plan", "inspirations", ".git", "scripts/dev-run",
                     "scripts/test-static", "scripts/build-native", "greeter",
                     "integrations/GreeterNative", "scripts/install-greeter"):
            self.assertFalse((stage / name).exists(), name)
        self.assertFalse(list(stage.rglob("*.cpp")))
        self.assertFalse(list(stage.rglob("*.c")))
        self.assertFalse(list(stage.rglob("*.pro")))
        self.assertFalse(list(stage.rglob("__pycache__")))
        self.assertIn(str(self.destination / "integrations"), (stage / "shell.qml").read_text())
        manifest = json.loads((stage / "integrations/browser-media/host/org.quickshell.browser_media.json").read_text())
        self.assertEqual(manifest["path"], str(self.destination / "integrations/browser-media/host/browser_media_host.py"))
        self.assertNotIn(str(ROOT), (stage / "shell.qml").read_text())
        installer.check_native_imports(stage)
        installer.check_lock_observer(stage)

    def test_invalid_lock_observer_is_rejected(self):
        stage = self.stage()
        observer = stage / installer.LOCK_OBSERVER
        observer.write_text("#!/bin/sh\nexit 1\n")
        with self.assertRaisesRegex(RuntimeError, "lock observer did not load"):
            installer.check_lock_observer(stage)

    def test_missing_lock_observer_keeps_existing_installation(self):
        project = self.base / "source"
        shutil.copytree(ROOT, project, ignore=shutil.ignore_patterns(
            ".git", ".dev", "audits", "inspirations", "__pycache__"))
        (project / installer.LOCK_OBSERVER).unlink()
        self.destination.mkdir()
        (self.destination / "shell.qml").write_text("// keep current shell\n")
        before = digest_tree(self.destination)
        args = ["install", "--skip-build", "--skip-packages", "--destination", str(self.destination),
                "--backup-root", str(self.backups)]
        with patch.object(installer, "ROOT", project), patch.object(sys, "argv", args):
            with self.assertRaises(FileNotFoundError):
                installer.main()
        self.assertEqual(digest_tree(self.destination), before)
        self.assertFalse(self.backups.exists())
        self.assertFalse(list(self.destination.parent.glob(".quickshell-stage-*")))

    def test_restore_before_lock_observer_remains_supported(self):
        legacy = self.stage()
        (legacy / installer.LOCK_OBSERVER).unlink()
        (legacy / "config/lock-fallback.conf").unlink()
        (legacy / "scripts/lock-screen").write_text("#!/bin/sh\nexit 1\n")
        before = digest_tree(legacy)
        result = self.run_install("--restore", legacy)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(digest_tree(self.destination), before)

    def test_upgrade_is_atomic_and_preserves_previous_files(self):
        self.destination.mkdir()
        (self.destination / "shell.qml").write_text("// old shell\n")
        (self.destination / "old-development-note").write_text("keep in backup\n")
        before = digest_tree(self.destination)
        stage = self.stage()
        expected = digest_tree(stage)
        done = threading.Event()
        failures = []

        def reader():
            while not done.is_set():
                try:
                    (self.destination / "shell.qml").read_bytes()
                except OSError as error:
                    failures.append(error)

        thread = threading.Thread(target=reader)
        thread.start()
        try:
            backup = installer.activate(stage, self.destination, self.backups)
        finally:
            done.set()
            thread.join(timeout=5)
        self.assertFalse(failures)
        self.assertEqual(digest_tree(backup), before)
        self.assertEqual(digest_tree(self.destination), expected)
        self.assertEqual(self.settings.read_text(), '{"personal": "keep exactly"}\n')

    def test_command_install_and_rollback_preserve_settings_and_source(self):
        source_before = {name: (ROOT / name).read_bytes() for name in (
            "shell.qml", "integrations/browser-media/host/org.quickshell.browser_media.json.in")}
        first = self.run_install()
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        (self.destination / "old-note").write_text("saved on rollback\n")
        before = digest_tree(self.destination)
        second = self.run_install()
        self.assertEqual(second.returncode, 0, second.stdout + second.stderr)
        backup = next(self.backups.glob("*/quickshell"))
        self.assertFalse((self.destination / "old-note").exists())
        rollback = self.run_install("--restore", backup)
        self.assertEqual(rollback.returncode, 0, rollback.stdout + rollback.stderr)
        self.assertEqual(digest_tree(self.destination), before)
        self.assertEqual(self.settings.read_text(), '{"personal": "keep exactly"}\n')
        for name, content in source_before.items():
            self.assertEqual((ROOT / name).read_bytes(), content)

    def test_missing_library_does_not_touch_existing_installation(self):
        project = self.base / "source"
        shutil.copytree(ROOT, project, ignore=shutil.ignore_patterns(
            ".git", ".dev", "audits", "inspirations", "__pycache__"))
        (project / "integrations/BluetoothNative/libbluetoothagent.so").unlink()
        self.destination.mkdir()
        (self.destination / "shell.qml").write_text("// keep current shell\n")
        before = digest_tree(self.destination)
        args = ["install", "--skip-build", "--skip-packages", "--destination", str(self.destination),
                "--backup-root", str(self.backups)]
        with patch.object(installer, "ROOT", project), patch.object(sys, "argv", args):
            with self.assertRaises(FileNotFoundError):
                installer.main()
        self.assertEqual(digest_tree(self.destination), before)
        self.assertFalse(self.backups.exists())
        self.assertFalse(list(self.destination.parent.glob(".quickshell-stage-*")))

    def test_dry_run_has_no_filesystem_effect(self):
        before = digest_tree(self.base)
        result = self.run_install("--dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(digest_tree(self.base), before)
        self.assertFalse(self.destination.exists())

    def test_rejects_symlinks_and_source_as_destination(self):
        self.destination.symlink_to(ROOT, target_is_directory=True)
        result = self.run_install()
        self.assertEqual(result.returncode, 2)
        result = self.run_install("--destination", ROOT)
        self.assertEqual(result.returncode, 2)

    def test_rejects_restore_for_different_destination(self):
        stage = self.base / "foreign-backup"
        stage.mkdir()
        installer.package(ROOT, stage, self.base / "other-config/quickshell")
        result = self.run_install("--restore", stage)
        self.assertEqual(result.returncode, 2)
        self.assertFalse(self.destination.exists())


    def test_build_uses_temporary_artifacts_and_preserves_source(self):
        artifacts = [Path("integrations") / module / library
                     for module, library in installer.NATIVE.items()] + [installer.LOCK_OBSERVER]
        source_before = {path: (ROOT / path).read_bytes() for path in artifacts}
        workspaces = []
        run = subprocess.run

        def run_with_fake_compiler(command, **kwargs):
            if command[-1] == str(ROOT / "scripts/build-native"):
                workspace = Path(kwargs["env"]["QS_BUILD_ROOT"])
                self.assertEqual(kwargs["env"]["TMPDIR"], str(workspace))
                self.assertNotEqual(workspace, ROOT)
                workspaces.append(workspace)
                for path in artifacts:
                    installer.copy_file(ROOT / path, workspace / path)
                (workspace / "compiler-output.o").write_bytes(b"temporary build output")
                return subprocess.CompletedProcess(command, 0)
            return run(command, **kwargs)

        args = ["install", "--skip-packages", "--destination", str(self.destination),
                "--backup-root", str(self.backups)]
        with patch.object(sys, "argv", args), patch.object(installer.subprocess, "run", run_with_fake_compiler):
            installer.main()
        self.assertEqual(len(workspaces), 1)
        self.assertFalse(workspaces[0].exists())
        self.assertFalse(list(self.destination.parent.glob(".quickshell-stage-*")))
        self.assertFalse((self.destination / "compiler-output.o").exists())
        self.assertFalse((self.destination / "integrations/GreeterNative").exists())
        for path, content in source_before.items():
            self.assertEqual((ROOT / path).read_bytes(), content)
            self.assertEqual((self.destination / path).read_bytes(), content)
        manifest = json.loads((self.destination / ".installed.json").read_text())
        self.assertEqual(manifest["source"], str(ROOT))
        self.assertNotIn(str(workspaces[0]), (self.destination / "README.md").read_text())

    def test_failed_or_interrupted_build_cleans_without_replacing_installation(self):
        self.destination.mkdir()
        (self.destination / "shell.qml").write_text("// keep installed shell\n")
        before = digest_tree(self.destination)
        args = ["install", "--skip-packages", "--destination", str(self.destination),
                "--backup-root", str(self.backups)]
        for error in (subprocess.CalledProcessError(1, "make"), KeyboardInterrupt()):
            with self.subTest(error=type(error).__name__):
                workspaces = []

                def fail_build(workspace):
                    workspaces.append(workspace)
                    (workspace / "partial.o").write_bytes(b"partial build")
                    raise error

                with patch.object(sys, "argv", args), patch.object(installer, "build_native", fail_build):
                    with self.assertRaises(type(error)):
                        installer.main()
                self.assertFalse(workspaces[0].exists())
                self.assertEqual(digest_tree(self.destination), before)
                self.assertFalse(self.backups.exists())

    def test_cleanup_failure_does_not_fail_completed_installation(self):
        stderr = io.StringIO()
        stdout = io.StringIO()
        leftovers = []
        rmtree = shutil.rmtree

        def fail_workspace_cleanup(path, *args, **kwargs):
            if Path(path).name.startswith("qs-install-"):
                leftovers.append(Path(path))
                raise PermissionError("simulated cleanup denial")
            return rmtree(path, *args, **kwargs)

        args = ["install", "--skip-packages", "--skip-build", "--destination", str(self.destination),
                "--backup-root", str(self.backups)]
        try:
            with patch.object(sys, "argv", args), patch.object(installer.shutil, "rmtree", fail_workspace_cleanup), \
                    redirect_stderr(stderr), redirect_stdout(stdout):
                installer.main()
            self.assertTrue((self.destination / ".installed.json").is_file())
            self.assertIn(f"Installed: {self.destination}", stdout.getvalue())
            self.assertEqual(len(leftovers), 1)
            command = stderr.getvalue().split("Cleanup command: ", 1)[1].strip()
            self.assertEqual(shlex.split(command), ["rm", "-rf", "--", str(leftovers[0])])
        finally:
            for path in leftovers:
                rmtree(path)

    def test_cleanup_command_quotes_path_and_preserves_original_error(self):
        stderr = io.StringIO()
        with redirect_stderr(stderr), patch.object(installer.shutil, "rmtree", side_effect=PermissionError("denied")):
            with self.assertRaisesRegex(RuntimeError, "original build failure"):
                with installer.temporary_directory(prefix="build 'quoted' $(touch marker) ", directory=self.base) as path:
                    (path / "partial.o").write_bytes(b"build output")
                    raise RuntimeError("original build failure")
        command = stderr.getvalue().split("Cleanup command: ", 1)[1].strip()
        self.assertEqual(shlex.split(command), ["rm", "-rf", "--", str(path)])
        subprocess.run(["sh", "-c", command], cwd=self.base, check=True)
        self.assertFalse(path.exists())
        self.assertFalse((self.base / "marker").exists())


class DependencyTests(unittest.TestCase):
    def setUp(self):
        for target, attribute, kwargs in (
            (installer.platform, "freedesktop_os_release", {"return_value": {"ID": "arch"}}),
            (installer.shutil, "which", {"side_effect": lambda name: "/usr/bin/" + name}),
        ):
            patcher = patch.object(target, attribute, **kwargs)
            patcher.start()
            self.addCleanup(patcher.stop)

    def test_required_packages_do_not_include_greeter(self):
        self.assertIn("uwsm", installer.ARCH_PACKAGES)
        self.assertTrue({"greetd", "greetd-agreety", "rust", "fprintd"}.isdisjoint(installer.ARCH_PACKAGES))

    def test_available_packages_need_no_transaction(self):
        with patch.object(installer, "missing_arch_packages", return_value=[]), \
                patch.object(installer.subprocess, "run") as run:
            installer.install_dependencies()
        run.assert_not_called()

    def test_missing_packages_use_full_upgrade_and_standard_confirmation(self):
        with patch.object(installer, "missing_arch_packages", side_effect=[["uwsm"], []]), \
                patch.object(installer.subprocess, "run") as run:
            installer.install_dependencies()
        run.assert_called_once_with(["sudo", "pacman", "-Syu", "--needed", "uwsm"], check=True)

    def test_dry_run_never_installs_packages(self):
        with patch.object(installer, "missing_arch_packages", return_value=["uwsm"]), \
                patch.object(installer.subprocess, "run") as run:
            installer.install_dependencies(dry_run=True)
        run.assert_not_called()

    def test_declined_package_transaction_is_not_success(self):
        with patch.object(installer, "missing_arch_packages", return_value=["uwsm"]), \
                patch.object(installer.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)):
            with self.assertRaisesRegex(RuntimeError, "still missing: uwsm"):
                installer.install_dependencies()


if __name__ == "__main__":
    unittest.main(verbosity=2)
