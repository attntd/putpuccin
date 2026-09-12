#!/usr/bin/env python3
"""Real helper/Hyprlock on a disposable compositor; never lock the host session.

SIGUSR1 is used only to close the test's own Hyprlock between lifecycle cycles.
PAM is redirected to a verified private deny-only service before Hyprlock starts;
the host user's faillock file is read-only monitored throughout the test.
"""
import argparse
import json
import os
from pathlib import Path
import selectors
import shutil
import signal
import subprocess
import sys
import tempfile
import time

from test_lockscreen_wayland import ipc, production_state, stop, wait
from lock_fallback_pam import build_isolation, check_isolation, host_tally_path, snapshot_tally, tally_report, validate_binary

ROOT = Path(__file__).resolve().parents[1]


def run():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--hyprlock", default=shutil.which("hyprlock"), type=Path)
    args = parser.parse_args()
    assert args.hyprlock and args.hyprlock.is_file(), "Pass a verified Hyprlock binary with --hyprlock"
    if "LD_PRELOAD" in os.environ:
        raise RuntimeError("Refusing a globally preloaded test environment")
    binary_digest = validate_binary(args.hyprlock)
    tally = host_tally_path()
    tally_before = snapshot_tally(tally)  # Must be readable before any locker.
    real_qs = shutil.which("qs")
    work = Path(tempfile.mkdtemp(prefix="qs-lfb-"))
    runtime = work / "r"
    runtime.mkdir(mode=0o700)
    pam_directory, pam_library, pam_probe = build_isolation(work)
    shell = work / "config/quickshell"
    for name in ("scripts/lock-screen", "integrations/LockObserver/lock-observer", "config/lock-fallback.conf"):
        target = shell / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / name, target)
    (shell / "shell.qml").write_text("import Quickshell\nScope {}\n")
    binaries = work / "bin"
    binaries.mkdir()
    # Write this launcher only after the PAM probe succeeds, before starting
    # any compositor or helper. The preload exists solely in Hyprlock's exec.
    (binaries / "qs").write_text("#!" + sys.executable + "\nimport os,sys,time\n"
        + "if os.environ.get('QS_TEST_HANG_IPC'): time.sleep(30)\n"
        + f"os.execv({real_qs!r}, [{real_qs!r}]+sys.argv[1:])\n")
    for path in binaries.iterdir():
        path.chmod(0o755)
    parent_runtime = Path(os.environ["XDG_RUNTIME_DIR"])
    parent = parent_runtime / "hypr" / os.environ["HYPRLAND_INSTANCE_SIGNATURE"] / ".socket.sock"
    display = Path(os.environ["WAYLAND_DISPLAY"])
    if not display.is_absolute():
        display = parent_runtime / display
    before = production_state(parent)
    config = work / "hyprland.lua"
    config.write_text('''hl.monitor({ output = "WAYLAND-1", disabled = true })
hl.monitor({ output = "FALLBACK-A", mode = "1280x720@60", position = "0x0", scale = 1 })
hl.monitor({ output = "FALLBACK-B", mode = "1440x900@60", position = "1280x0", scale = 1.2 })
hl.config({ misc = { disable_hyprland_logo = true, disable_splash_rendering = true, force_default_wallpaper = 0 }, animations = { enabled = false }, xwayland = { enabled = false } })
''')
    env = dict(os.environ, PATH=str(binaries) + ":" + os.environ["PATH"],
               XDG_RUNTIME_DIR=str(runtime), XDG_CONFIG_HOME=str(work / "config"),
               XDG_CACHE_HOME=str(work / "cache"), XDG_STATE_HOME=str(work / "state"),
               WAYLAND_DISPLAY=str(display), DISPLAY="", HYPRLAND_INSTANCE_SIGNATURE="",
               LIBSEAT_BACKEND="seatd", SEATD_SOCK=str(work / "missing"), AQ_DRM_DEVICES=str(work / "missing"),
               HYPRLAND_NO_SD_VARS="1", HYPRLAND_NO_SD_NOTIFY="1", HYPRLAND_NO_CRASHREPORTER="1",
               HYPRLAND_NO_RT="1", GSETTINGS_BACKEND="memory", QT_QPA_PLATFORM="wayland",
               QT_QPA_PLATFORMTHEME="", NO_AT_BRIDGE="1")
    for key in ("NOTIFY_SOCKET", "LISTEN_FDS", "LISTEN_PID", "WAYLAND_SOCKET"):
        env.pop(key, None)
    probe_env = dict(env, WAYLAND_DISPLAY=str(runtime / "wayland-1"))
    pam_digest = check_isolation(pam_directory, pam_library, pam_probe, probe_env)
    if snapshot_tally(tally) != tally_before:
        raise RuntimeError("Host faillock state changed during private PAM preflight")
    (binaries / "hyprlock").write_text(
        "#!" + sys.executable + "\nimport errno,hashlib,json,os,stat,sys\nfrom pathlib import Path\n"
        + f"library=Path({str(pam_library)!r})\n"
        + f"binary=Path({str(args.hyprlock.resolve())!r})\n"
        + "if binary.stat().st_mode & (stat.S_ISUID|stat.S_ISGID): raise SystemExit(125)\n"
        + "try:\n capabilities=os.getxattr(binary,'security.capability')\nexcept OSError as error:\n if error.errno not in (errno.ENODATA,errno.ENOTSUP): raise\n capabilities=b''\n"
        + "if capabilities: raise SystemExit(125)\n"
        + f"if hashlib.sha256(binary.read_bytes()).hexdigest() != {binary_digest!r}: raise SystemExit(125)\n"
        + f"if hashlib.sha256(library.read_bytes()).hexdigest() != {pam_digest!r}: raise SystemExit(125)\n"
        + f"if Path({str(pam_directory / 'system-auth')!r}).read_text() != {(pam_directory / 'system-auth').read_text()!r}: raise SystemExit(125)\n"
        + f"if os.environ.get('XDG_RUNTIME_DIR') != {str(runtime)!r}: raise SystemExit(125)\n"
        + f"if os.environ.get('WAYLAND_DISPLAY') != {str(runtime / 'wayland-1')!r}: raise SystemExit(125)\n"
        + "if 'LD_PRELOAD' in os.environ: raise SystemExit(125)\n"
        + f"with Path({str(work / 'fallback.jsonl')!r}).open('a') as log: "
        + "log.write(json.dumps({'pid':os.getpid(),'argv':sys.argv[1:]})+'\\n')\n"
        + f"child_env=dict(os.environ,LD_PRELOAD=str(library),LD_BIND_NOW='1',QS_TEST_PAM_DIRECTORY={str(pam_directory)!r})\n"
        + f"os.execve({str(args.hyprlock.resolve())!r}, [{str(args.hyprlock.resolve())!r}]+sys.argv[1:], child_env)\n")
    (binaries / "hyprlock").chmod(0o755)
    processes = []
    result = dict(work=str(work), passed=False, checks=[], host_tally_before=tally_report(tally_before))
    print("WORK", work, flush=True)

    def launch(command, logfile):
        with (work / logfile).open("w") as log:
            process = subprocess.Popen(command, env=env, stdout=log, stderr=log)
        processes.append(process)
        return process

    def invocations():
        path = work / "fallback.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def unchanged_tally():
        if snapshot_tally(tally) != tally_before:
            raise RuntimeError("Host faillock state changed; aborting the test")

    def hook_used(pid):
        for line in (pam_directory / "hook-used").read_text().splitlines():
            if line.split() == ["pam_start_confdir", str(pid), "0"]:
                return True
        return False

    def secure():
        observer = subprocess.Popen([str(shell / "integrations/LockObserver/lock-observer")],
                                    env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            with selectors.DefaultSelector() as selector:
                selector.register(observer.stdout, selectors.EVENT_READ)
                assert selector.select(2), "No initial observer state"
                state = observer.stdout.readline().strip()
                assert state in ("ready locked", "ready unlocked"), (state, observer.poll())
                return state == "ready locked"
        finally:
            stop(observer)

    def live(pid):
        try:
            return Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[0] != "Z"
        except FileNotFoundError:
            return False

    def own_observers():
        expected = shell / "integrations/LockObserver/lock-observer"
        found = []
        for entry in Path("/proc").iterdir():
            if not entry.name.isdecimal():
                continue
            try:
                if (entry / "comm").read_text().strip() != "lock-observer":
                    continue
                if (entry / "exe").readlink() == expected and live(int(entry.name)):
                    found.append(int(entry.name))
            except (FileNotFoundError, ProcessLookupError, PermissionError):
                continue
        return found

    def helper():
        started = time.monotonic()
        completed = subprocess.run([str(shell / "scripts/lock-screen")], env=env,
                                   capture_output=True, text=True, timeout=6)
        elapsed = round((time.monotonic() - started) * 1000, 2)
        assert completed.returncode == 0, (elapsed, completed.stdout, completed.stderr)
        assert secure(), "Helper exited successfully without compositor secure"
        assert not own_observers(), "Helper left its own Wayland observer running"
        wait(lambda: hook_used(invocations()[-1]["pid"]), timeout=2)
        unchanged_tally()
        return elapsed

    def assert_test_locker(pid):
        # Guard every signal: it must target the copied-config locker on this
        # exact private display. No process search or host locker is involved.
        cmdline = Path(f"/proc/{pid}/cmdline").read_bytes().split(b"\0")
        environ = Path(f"/proc/{pid}/environ").read_bytes().split(b"\0")
        assert os.fsencode(shell / "config/lock-fallback.conf") in cmdline
        assert os.fsencode("WAYLAND_DISPLAY=" + env["WAYLAND_DISPLAY"]) in environ
        assert str(runtime) in env["WAYLAND_DISPLAY"]
        assert os.fsencode("LD_PRELOAD=" + str(pam_library)) in environ
        assert os.fsencode("QS_TEST_PAM_DIRECTORY=" + str(pam_directory)) in environ
        assert hook_used(pid), "Test Hyprlock did not call isolated pam_start_confdir"

    def release():
        pid = invocations()[-1]["pid"]
        assert_test_locker(pid)
        os.kill(pid, signal.SIGUSR1)
        wait(lambda: not secure())
        # Native unlock precedes process teardown. A later cycle must not hide
        # an old locker behind the helper's flock wait or call that a clean exit.
        wait(lambda: not live(pid), timeout=5)
        assert not own_observers(), "Unlock check left its own observer running"
        unchanged_tally()

    try:
        bus = subprocess.Popen(["dbus-daemon", "--session", "--nofork", "--print-address=1"],
                               env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        processes.append(bus)
        address = bus.stdout.readline().strip()
        assert address.startswith("unix:"), address
        env.update(DBUS_SYSTEM_BUS_ADDRESS=address, DBUS_SESSION_BUS_ADDRESS=address)
        comp = launch(["Hyprland", "-c", str(config)], "compositor.log")
        child = wait(lambda: next((runtime / "hypr").glob("*/.socket.sock"), None))
        assert child.is_relative_to(runtime) and child != parent
        for output in ("FALLBACK-A", "FALLBACK-B"):
            assert ipc(child, "output create headless " + output).strip() == "ok"
        wait(lambda: len(json.loads(ipc(child, "j/monitors"))) == 2)
        assert not ipc(child, "configerrors").strip()
        env.update(WAYLAND_DISPLAY=str(runtime / "wayland-1"), HYPRLAND_INSTANCE_SIGNATURE=child.parent.name)
        assert not secure()
        result["without_shell_ms"] = helper()
        result["checks"].append("Real Hyprlock fallback secures both outputs while no Quickshell instance exists")
        result["checks"].append("Every test Hyprlock uses verified private pam_start_confdir; invalid isolation refuses to start")
        pid = invocations()[-1]["pid"]
        assert_test_locker(pid)
        status = Path(f"/proc/{pid}/status").read_text()
        assert "Uid:\t" + "\t".join([str(os.getuid())] * 4) in status
        assert "CapEff:\t0000000000000000" in status
        limits = Path(f"/proc/{pid}/limits").read_text()
        assert any(line.startswith("Max core file size") and line.split()[4:6] == ["0", "0"]
                   for line in limits.splitlines()), limits
        result["checks"].append("Fallback runs as the session user with no effective capabilities and core limit zero")
        calls_before = len(invocations())
        result["already_locked_ms"] = helper()
        assert len(invocations()) == calls_before
        result["checks"].append("Already secured session succeeds without creating another locker")

        def stats():
            values = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()
            return int(values[11]) + int(values[12]), int(values[21]) * os.sysconf("SC_PAGE_SIZE") // 1024
        initial = stats()
        started = time.monotonic()
        time.sleep(2)
        final = stats()
        result["fallback_idle"] = dict(cpu_percent=round((final[0] - initial[0]) / os.sysconf("SC_CLK_TCK")
                                                       / (time.monotonic() - started) * 100, 2), rss_kib=final[1])
        release()
        env["QS_TEST_HANG_IPC"] = "1"
        result["hung_ipc_ms"] = helper()
        assert 1200 <= result["hung_ipc_ms"] < 3000
        env.pop("QS_TEST_HANG_IPC")
        release()
        result["checks"].append("Hung IPC reaches a real independent fallback within the sleep-delay budget")
        cycles = []
        for _ in range(20):
            cycles.append(helper())
            release()
        result["twenty_cycles_ms"] = cycles
        assert not any(live(item["pid"]) for item in invocations())
        result["checks"].append("20 native lock/unlock cycles confirm each fallback PID exited and leave no own observers running")
        helper()
        pid = invocations()[-1]["pid"]
        assert_test_locker(pid)
        os.kill(pid, signal.SIGKILL)
        wait(lambda: not live(pid))
        assert secure(), "Locker crash must not unlock Wayland"
        calls_before = len(invocations())
        result["after_locker_crash_ms"] = helper()
        assert len(invocations()) == calls_before
        result["checks"].append("SIGKILL of the test locker keeps the compositor locked; helper does not claim recovery of authentication UI")
        result["passed"] = True
    finally:
        for item in invocations():
            try:
                assert_test_locker(item["pid"])
                os.kill(item["pid"], signal.SIGKILL)
            except (ProcessLookupError, FileNotFoundError):
                pass
        for process in reversed(processes):
            stop(process)
        after = production_state(parent)
        tally_after = snapshot_tally(tally)
        result["production_unchanged"] = after == before
        result["host_tally_after"] = tally_report(tally_after)
        result["host_tally_unchanged"] = tally_after == tally_before
        result["isolated_pam_hook_pids"] = sorted({int(line.split()[1]) for line in
            (pam_directory / "hook-used").read_text().splitlines() if line.split()[2] == "0"})
        if after != before or tally_after != tally_before:
            result["passed"] = False
        (work / "result.json").write_text(json.dumps(result, indent=2) + "\n")
        print(json.dumps(result, indent=2), flush=True)
        assert after == before, (before, after)
        assert tally_after == tally_before, "Host faillock state changed during the test"


if __name__ == "__main__":
    run()
