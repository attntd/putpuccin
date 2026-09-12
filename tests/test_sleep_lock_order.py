#!/usr/bin/env python3
"""Real hypridle/native lock against private Wayland and login1 inhibitor FDs.

The only login1 service this test can reach is a private double. All sleep
signals are synthetic, idle actions are disabled, and lock/unlock IPC addresses
the test process by PID on a disposable compositor.
"""
import argparse
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import tempfile
import time

from test_lockscreen_wayland import ipc, production_state, stop, wait

ROOT = Path(__file__).resolve().parents[1]


def run():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--hypridle-config', type=Path,
                        default=Path.home() / '.config/hypr/hypridle.conf')
    parser.add_argument('--with-lock-helper', action='store_true',
                        help='Also test the real built lock-screen/LockObserver integration')
    args = parser.parse_args()
    # Validate the integration, but never execute any host idle/DPMS actions.
    production_config = args.hypridle_config.read_text()
    assert re.search(r'^\s*inhibit_sleep\s*=\s*3\s*$', production_config, re.M)
    assert re.search(r'^\s*before_sleep_cmd\s*=\s*loginctl lock-session\s*$',
                     production_config, re.M)
    assert re.search(r'^\s*lock_cmd\s*=\s*~/.config/quickshell/scripts/lock-screen\s*$',
                     production_config, re.M)
    # Hyprland embeds its long instance signature in Unix socket paths.
    work = Path(tempfile.mkdtemp(prefix='qs-sleep-'))
    runtime = work / 'r'
    runtime.mkdir(mode=0o700)
    shell = work / 'config/quickshell'
    shell.mkdir(parents=True)
    shutil.copy2(ROOT / 'tests/fixtures/sleep-lock.qml', shell / 'shell.qml')
    if args.with_lock_helper:
        for name in ('scripts/lock-screen', 'integrations/LockObserver/lock-observer',
                     'config/lock-fallback.conf'):
            target = shell / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / name, target)
    parent_runtime = Path(os.environ['XDG_RUNTIME_DIR'])
    parent = parent_runtime / 'hypr' / os.environ['HYPRLAND_INSTANCE_SIGNATURE'] / '.socket.sock'
    display = Path(os.environ['WAYLAND_DISPLAY'])
    if not display.is_absolute():
        display = parent_runtime / display
    before = production_state(parent)
    config = work / 'hyprland.lua'
    config.write_text('''hl.monitor({ output = "WAYLAND-1", disabled = true })
hl.monitor({ output = "SLEEP-LOCK", mode = "1280x720@60", position = "0x0", scale = 1 })
hl.config({ misc = { disable_hyprland_logo = true, disable_splash_rendering = true, force_default_wallpaper = 0 }, animations = { enabled = false }, xwayland = { enabled = false } })
''')
    env = dict(os.environ, XDG_RUNTIME_DIR=str(runtime), XDG_CONFIG_HOME=str(work / 'config'),
               XDG_CACHE_HOME=str(work / 'cache'), XDG_STATE_HOME=str(work / 'state'),
               WAYLAND_DISPLAY=str(display), DISPLAY='', HYPRLAND_INSTANCE_SIGNATURE='',
               LIBSEAT_BACKEND='seatd', SEATD_SOCK=str(work / 'missing'),
               AQ_DRM_DEVICES=str(work / 'missing'), HYPRLAND_NO_SD_VARS='1',
               HYPRLAND_NO_SD_NOTIFY='1', HYPRLAND_NO_CRASHREPORTER='1', HYPRLAND_NO_RT='1',
               GSETTINGS_BACKEND='memory', QT_QPA_PLATFORM='wayland', QT_QPA_PLATFORMTHEME='',
               NO_AT_BRIDGE='1')
    for key in ('NOTIFY_SOCKET', 'LISTEN_FDS', 'LISTEN_PID', 'WAYLAND_SOCKET'):
        env.pop(key, None)
    bus = mock = comp = qs = idle = None
    processes = []
    result = dict(work=str(work), passed=False, checks=[])

    def launch(command, logfile):
        with (work / logfile).open('w') as log:
            proc = subprocess.Popen(command, env=env, stdout=log, stderr=log)
        processes.append(proc)
        return proc

    def leases():
        return json.loads((work / 'leases.json').read_text())

    def prepare(sleeping):
        subprocess.run(['busctl', '--address=' + env['DBUS_SYSTEM_BUS_ADDRESS'], 'call',
                        'org.freedesktop.login1', '/org/freedesktop/login1',
                        'org.quickshell.test.Sleep', 'Prepare', 'b', str(sleeping).lower()],
                       env=env, check=True, capture_output=True, timeout=3)

    def call(method, *values):
        assert qs.poll() is None, (work / 'shell.log').read_text()
        command = ['qs', 'ipc', '--pid', str(qs.pid), 'call', 'sleepLockTest', method]
        command += [str(value).lower() for value in values]
        r = subprocess.run(command, env=env, capture_output=True, text=True, timeout=3)
        if r.returncode:
            raise RuntimeError(r.stderr)
        return r.stdout.strip()

    def locked(value):
        call('setLocked', value)
        wait(lambda: json.loads(call('status'))['secure'] == value)

    def marker():
        return work / 'request.json'

    def start_idle(mode, name, failure=False, real_helper=False):
        marker().unlink(missing_ok=True)
        request = work / 'lock-request.py'
        request.write_text('import json,time\nfrom pathlib import Path\n'
                           + f'Path({str(marker())!r}).write_text(json.dumps('
                           + f'{{"ns":time.monotonic_ns(),"exit_code":{1 if failure else 0}}}))\n'
                           + f'raise SystemExit({1 if failure else 0})\n')
        if real_helper:
            request.write_text('import json,time,subprocess\nfrom pathlib import Path\n'
                               + f'r=subprocess.run([{str(shell / "scripts/lock-screen")!r}], '
                               + 'capture_output=True,text=True,timeout=6)\n'
                               + f'Path({str(marker())!r}).write_text(json.dumps('
                               + '{"ns":time.monotonic_ns(),"exit_code":r.returncode,'
                               + '"stdout":r.stdout,"stderr":r.stderr}))\n'
                               + 'raise SystemExit(r.returncode)\n')
        path = work / f'{name}.conf'
        path.write_text('general {\n'
                        + f'    inhibit_sleep = {mode}\n'
                        + '    before_sleep_cmd = loginctl lock-session\n'
                        + '    after_sleep_cmd = /usr/bin/true\n'
                        + '    lock_cmd = ' + shlex.join(['/usr/bin/python3', str(request)]) + '\n'
                        + '}\nlistener {\n    timeout = 86400\n    on-timeout = /usr/bin/true\n}\n')
        proc = launch(['hypridle', '-c', str(path)], f'{name}.log')
        wait(lambda: leases()['active'])
        assert proc.poll() is None, (work / f'{name}.log').read_text()
        return proc

    def stop_idle(proc):
        stop(proc)
        wait(lambda: not leases()['active'])

    def measure(proc):
        def sample():
            stat = Path(f'/proc/{proc.pid}/stat').read_text().rsplit(')', 1)[1].split()
            return int(stat[11]) + int(stat[12]), int(stat[21]) * os.sysconf('SC_PAGE_SIZE') // 1024
        ticks, rss = sample()
        started = time.monotonic()
        time.sleep(1)
        end_ticks, end_rss = sample()
        return dict(cpu_percent=round((end_ticks - ticks) / os.sysconf('SC_CLK_TCK')
                                      / (time.monotonic() - started) * 100, 2), rss_kib=end_rss,
                    fds=len(list(Path(f'/proc/{proc.pid}/fd').iterdir())))

    try:
        bus = subprocess.Popen(['dbus-daemon', '--session', '--nofork', '--print-address=1'],
                               env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        processes.append(bus)
        address = bus.stdout.readline().strip()
        assert address.startswith('unix:'), address
        env.update(DBUS_SYSTEM_BUS_ADDRESS=address, DBUS_SESSION_BUS_ADDRESS=address)
        mock = launch(['/usr/bin/python3', str(ROOT / 'tests/fixtures/sleep-lock-logind.py'),
                       str(work)], 'logind.log')
        wait(lambda: (work / 'leases.json').exists())
        comp = launch(['Hyprland', '-c', str(config)], 'compositor.log')
        child = wait(lambda: next((runtime / 'hypr').glob('*/.socket.sock'), None))
        assert child.is_relative_to(runtime) and child != parent
        assert ipc(child, 'output create headless SLEEP-LOCK').strip() == 'ok'
        wait(lambda: len(json.loads(ipc(child, 'j/monitors'))) == 1)
        assert not ipc(child, 'configerrors').strip()
        env.update(WAYLAND_DISPLAY=str(runtime / 'wayland-1'),
                   HYPRLAND_INSTANCE_SIGNATURE=child.parent.name)
        qs = launch(['qs', '-p', str(shell), '--no-color'], 'shell.log')
        wait(lambda: not json.loads(call('status'))['secure'])

        idle = start_idle(2, 'auto-before')
        result['idle_before'] = measure(idle)
        prepare(True)
        wait(lambda: marker().exists())
        wait(lambda: not leases()['active'])
        assert not json.loads(call('status'))['secure']
        result['checks'].append('Old auto mode releases the inhibitor while the session is unsecured')
        stop_idle(idle)

        idle = start_idle(3, 'lock-notify-after')
        result['idle_after'] = measure(idle)
        identity = leases()['active'][0]
        prepare(True)
        wait(lambda: marker().exists())
        time.sleep(.3)
        assert json.loads(marker().read_text())['exit_code'] == 0
        assert leases()['active'] == [identity]
        assert not json.loads(call('status'))['secure']
        result['checks'].append('Successful lock-command exit without native secure keeps the same inhibitor FD')
        secure_request_ns = time.monotonic_ns()
        locked(True)
        wait(lambda: not leases()['active'])
        release = next(event for event in leases()['events']
                       if event['event'] == 'release' and event['id'] == identity)
        assert release['ns'] >= secure_request_ns
        result['native_lock_to_release_ms'] = round((release['ns'] - secure_request_ns) / 1e6, 2)
        log = (work / 'lock-notify-after.log').read_text()
        assert 'inhibiting until the wayland session gets locked' in log
        assert log.index('Wayland session got locked') < log.index('Releasing the sleep inhibitor!')
        result['checks'].append('Native compositor lock notification precedes actual inhibitor FD closure')
        prepare(False)
        assert not leases()['active']  # Already secured on resume.
        locked(False)
        wait(lambda: leases()['active'])
        assert leases()['active'][0] != identity
        result['checks'].append('Unlock obtains a fresh inhibitor for the next sleep request')

        cycles = []
        result['cycles_before'] = measure(idle)
        for index in range(20):
            identity = leases()['active'][0]
            marker().unlink(missing_ok=True)
            prepare(True)
            wait(lambda: marker().exists())
            assert leases()['active'] == [identity]
            started = time.monotonic_ns()
            locked(True)
            wait(lambda: not leases()['active'])
            event = next(event for event in leases()['events']
                         if event['event'] == 'release' and event['id'] == identity)
            elapsed_ms = round((event['ns'] - started) / 1e6, 2)
            prepare(False)
            locked(False)
            wait(lambda: leases()['active'])
            fds = len(list(Path(f'/proc/{idle.pid}/fd').iterdir()))
            assert fds == result['cycles_before']['fds'], (index, fds, result['cycles_before'])
            cycles.append(dict(lock_to_release_ms=elapsed_ms, fds=fds))
        result['repeat_lock_to_release_ms'] = cycles
        result['cycles_after'] = measure(idle)
        result['checks'].append('Twenty further sleep/lock/resume/unlock cycles keep the ordering and stable FD count')
        stop_idle(idle)

        idle = start_idle(3, 'lock-command-failed', failure=True)
        identity = leases()['active'][0]
        prepare(True)
        wait(lambda: marker().exists())
        assert json.loads(marker().read_text())['exit_code'] == 1
        start = time.monotonic()
        time.sleep(5.2)
        assert leases()['active'] == [identity]
        assert not json.loads(call('status'))['secure']
        result['failed_command_fd_held_seconds'] = round(time.monotonic() - start, 2)
        result['checks'].append('A failed command never fabricates secure or releases the FD, even after 5 seconds; real logind can ignore delay FDs at its limit')
        stop_idle(idle)

        if args.with_lock_helper:
            idle = start_idle(3, 'real-lock-helper', real_helper=True)
            identity = leases()['active'][0]
            prepare(True)
            wait(lambda: marker().exists(), timeout=7)
            outcome = json.loads(marker().read_text())
            assert outcome['exit_code'] == 0, outcome
            assert json.loads(call('status'))['secure']
            wait(lambda: not leases()['active'])
            event = next(event for event in leases()['events']
                         if event['event'] == 'release' and event['id'] == identity)
            request = next(event for event in reversed(leases()['events'])
                           if event['event'] == 'prepare' and event['sleeping'])
            result['helper_e2e'] = dict(
                prepare_to_fd_release_ms=round((event['ns'] - request['ns']) / 1e6, 2),
                prepare_to_helper_success_ms=round((outcome['ns'] - request['ns']) / 1e6, 2),
                exit_code=outcome['exit_code'])
            result['checks'].append('Real lock-screen and LockObserver confirm the private native lock after loginctl/hypridle dispatch')
            prepare(False)
            locked(False)
            wait(lambda: leases()['active'])
            stop_idle(idle)

        (work / 'deny-inhibit').touch()
        idle = launch(['hypridle', '-c', str(work / 'lock-notify-after.conf')], 'inhibit-denied.log')
        wait(lambda: 'Failed to inhibit sleep' in (work / 'inhibit-denied.log').read_text())
        assert not leases()['active']
        result['checks'].append('Denied Inhibit is reported and cannot be mistaken for an active delay')
        assert all(event['what'] == 'sleep' and event['mode'] == 'delay'
                   for event in leases()['events'] if event['event'] == 'acquire')
        result['passed'] = True
    finally:
        # The compositor is disposable; no production unlock or sleep is sent.
        for process in reversed(processes):
            stop(process)
        result['production_before'] = before
        result['production_after'] = production_state(parent)
        result['production_monitors_unchanged'] = before == result['production_after']
        if (work / 'leases.json').exists():
            result['lease_evidence'] = leases()
        (work / 'result.json').write_text(json.dumps(result, indent=2))
        print(json.dumps({key: value for key, value in result.items()
                          if key not in ('lease_evidence', 'production_before', 'production_after')}, indent=2))
        assert result['production_monitors_unchanged']


if __name__ == '__main__':
    run()
