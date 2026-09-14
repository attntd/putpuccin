#!/usr/bin/env python3
"""Spotlight key input on private Wayland/D-Bus, synthetic apps/files/clipboard.

No desktop shell, native authentication, clipboard watcher or real user command
is started. Only the explicit terminal probe executes a fixed test shell script.
"""
import argparse
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import statistics
import subprocess
import tempfile
import time

from test_lockscreen_wayland import ipc, production_state, stop, wait


def run():
    repository = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser()
    parser.add_argument('--source', type=Path, default=repository)
    parser.add_argument('--baseline', action='store_true')
    parser.add_argument('--cycles', type=int, default=20)
    parser.add_argument('--cycles-only', action='store_true', help='Measure repeated opening/navigation without the feature matrix')
    args = parser.parse_args()
    work = Path(tempfile.mkdtemp(prefix='qlauncher-'))
    print('WORK', work, flush=True)
    pointer = work / 'pointer'
    flags = shlex.split(subprocess.check_output(['pkg-config', '--cflags', '--libs', 'wayland-client'], text=True))
    subprocess.run(['cc', '-Wall', '-Wextra', '-O2', '-o', str(pointer),
        str(repository / 'tests/fixtures/virtual-pointer.c'), *flags], check=True)
    config = work / 'shell'
    for directory in ('core', 'components'):
        shutil.copytree(args.source / directory, config / directory)
    for directory in ('popups', 'services', 'scripts', 'modules/launcher'):
        (config / directory).mkdir(parents=True, exist_ok=True)
    shutil.copy2(args.source / 'popups/LauncherPopup.qml', config / 'popups/LauncherPopup.qml')
    (config / 'popups/qmldir').write_text('module qs.popups\nLauncherPopup 1.0 LauncherPopup.qml\n')
    (config / 'services/qmldir').write_text('module qs.services\n')
    if not args.baseline:
        shutil.copytree(args.source / 'modules/launcher', config / 'modules/launcher', dirs_exist_ok=True)
        shutil.copy2(args.source / 'services/LauncherHistory.qml', config / 'services/LauncherHistory.qml')
        with (config / 'services/qmldir').open('a') as stream:
            stream.write('singleton LauncherHistory 1.0 LauncherHistory.qml\n')
        shutil.copy2(args.source / 'scripts/launcher-state', config / 'scripts/launcher-state')

    def stub(directory, name, body):
        (config / directory / (name + '.qml')).write_text('pragma Singleton\nimport QtQuick\nimport Quickshell\n'
            'Singleton {\n' + body + '\n}\n')
        with (config / directory / 'qmldir').open('a') as stream:
            stream.write('singleton ' + name + ' 1.0 ' + name + '.qml\n')

    stub('core', 'SurfaceManager', '''property bool detachedLauncherVisible: false
        property string detachedLauncherScreenName: ""
        function closeDetachedLauncher() { detachedLauncherVisible = false; }
        function closeLauncher(screen) { closeDetachedLauncher(); }''')
    stub('services', 'HyprlandService', 'function screenName(screen) { return screen ? screen.name : ""; }')
    stub('services', 'ClipboardService', '''property var entries: Array.from({length: 30}, (_, i) =>
            ({id:i, preview:"Launchertest clipboard " + i, binary:false}))
        property string pendingOperation: ""
        property string errorMessage: ""
        signal copied(int entryId)
        function rememberFocus() {}
        function copy(id) { copied(id); }
        function clear() { entries = []; }''')
    shutil.copy2(repository / 'tests/fixtures/launcher.qml', config / 'shell.qml')
    runtime = work / 'r'
    runtime.mkdir(mode=0o700)
    (work / 'home').mkdir()
    bindir = work / 'bin'
    bindir.mkdir()
    action = bindir / 'test-action'
    action.write_text('#!/usr/bin/python3\nimport json, os, sys\n'
        'with open(os.environ["QS_TEST_ACTIONS"], "a") as stream:\n'
        '    stream.write(json.dumps([os.path.basename(sys.argv[0]), *sys.argv[1:]]) + "\\n")\n')
    action.chmod(0o700)
    for name in ('xdg-open', 'kitty'):
        (bindir / name).symlink_to(action)
    applications = work / 'data/applications'
    applications.mkdir(parents=True)
    for index in range(30):
        (applications / f'launchertest{index:02}.desktop').write_text('[Desktop Entry]\nType=Application\n'
            f'Name=Launchertest App {index:02}\nExec={action} app{index:02}\n')
        (work / 'home' / f'Launchertest file {index:02}.txt').write_text('test fixture\n')
    settings = work / 'config/quickshell-de/settings.json'
    settings.parent.mkdir(parents=True)
    settings.write_text(json.dumps({'schemaVersion': 1}))
    parent_runtime = Path(os.environ['XDG_RUNTIME_DIR'])
    parent_socket = parent_runtime / 'hypr' / os.environ['HYPRLAND_INSTANCE_SIGNATURE'] / '.socket.sock'
    before_production = production_state(parent_socket)
    display = Path(os.environ['WAYLAND_DISPLAY'])
    if not display.is_absolute(): display = parent_runtime / display
    bus_config = work / 'bus.conf'
    bus_config.write_text('<busconfig><type>session</type><listen>unix:tmpdir=/tmp</listen>'
        '<policy context="default"><allow send_destination="*"/><allow receive_sender="*"/>'
        '<allow own="*"/></policy></busconfig>')
    bus = comp = proc = terminal = None
    report = {'passed': False, 'work': str(work), 'baseline': args.baseline, 'cycles_only': args.cycles_only}
    try:
        bus = subprocess.Popen(['dbus-daemon', '--config-file=' + str(bus_config), '--nofork', '--print-address=1'],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        address = bus.stdout.readline().strip()
        env = dict(os.environ, XDG_RUNTIME_DIR=str(runtime), XDG_CONFIG_HOME=str(work / 'config'),
            XDG_CACHE_HOME=str(work / 'cache'), XDG_STATE_HOME=str(work / 'state'),
            XDG_DATA_HOME=str(work / 'data'), XDG_DATA_DIRS=str(work / 'data'), HOME=str(work / 'home'),
            WAYLAND_DISPLAY=str(display), DISPLAY='', HYPRLAND_INSTANCE_SIGNATURE='',
            LIBSEAT_BACKEND='seatd', SEATD_SOCK=str(work / 'missing'), AQ_DRM_DEVICES=str(work / 'missing'),
            HYPRLAND_NO_SD_VARS='1', HYPRLAND_NO_SD_NOTIFY='1', HYPRLAND_NO_CRASHREPORTER='1',
            HYPRLAND_NO_RT='1', QT_QPA_PLATFORM='wayland', QT_QPA_PLATFORMTHEME='', NO_AT_BRIDGE='1',
            GSETTINGS_BACKEND='memory', DBUS_SESSION_BUS_ADDRESS=address, DBUS_SYSTEM_BUS_ADDRESS=address,
            PATH=str(bindir) + ':' + os.environ['PATH'], QS_TEST_ACTIONS=str(work / 'actions.jsonl'), SHELL='/bin/sh')
        for key in ('NOTIFY_SOCKET', 'LISTEN_FDS', 'LISTEN_PID', 'WAYLAND_SOCKET', 'QT_SCALE_FACTOR'):
            env.pop(key, None)
        binding = work / 'launcher-ipc'
        binding.write_text('#!/bin/sh\nexport WAYLAND_DISPLAY=' + shlex.quote(str(runtime / 'wayland-1'))
            + '\nexec qs ipc -p ' + shlex.quote(str(config)) + ' call launchertest toggle >> '
            + shlex.quote(str(work / 'binding.log')) + ' 2>&1\n')
        binding.chmod(0o700)
        compositor_config = work / 'hyprland.lua'
        compositor_config.write_text('''hl.monitor({output="WAYLAND-1", disabled=true})
hl.monitor({output="SEARCH-A", mode="1280x720@60", position="0x0", scale=1})
hl.monitor({output="SEARCH-B", mode="1440x900@60", position="1280x0", scale=1.2})
hl.config({misc={disable_hyprland_logo=true,disable_splash_rendering=true,force_default_wallpaper=0},xwayland={enabled=false},input={resolve_binds_by_sym=true}})
''' + 'hl.bind("SUPER + SPACE", hl.dsp.exec_cmd(' + json.dumps(str(binding)) + '))\n')
        with (work / 'compositor.log').open('w') as comp_log, (work / 'shell.log').open('w') as shell_log:
            comp = subprocess.Popen(['Hyprland', '-c', str(compositor_config)], env=env, stdout=comp_log, stderr=comp_log)
            child = wait(lambda: next((runtime / 'hypr').glob('*/.socket.sock'), None))
            assert child.is_relative_to(runtime) and child != parent_socket
            for output in ('SEARCH-A', 'SEARCH-B'):
                assert ipc(child, 'output create headless ' + output).strip() == 'ok'
            wait(lambda: len(json.loads(ipc(child, 'j/monitors'))) == 2)
            assert not ipc(child, 'configerrors').strip()
            env.update(WAYLAND_DISPLAY=str(runtime / 'wayland-1'), HYPRLAND_INSTANCE_SIGNATURE=child.parent.name)
            proc = subprocess.Popen(['qs', '-p', str(config), '--no-color'], env=env, stdout=shell_log, stderr=shell_log)

            def call(method, *values):
                assert proc.poll() is None, (work / 'shell.log').read_text()
                response = subprocess.run(['qs', 'ipc', '-p', str(config), 'call', 'launchertest', method,
                    *[str(value).lower() if isinstance(value, bool) else str(value) for value in values]],
                    env=env, capture_output=True, text=True, timeout=5)
                assert response.returncode == 0, response.stderr
                return response.stdout.strip()

            def state(): return json.loads(call('state'))
            def keys(*values):
                subprocess.run(['wtype', *values], env=env, check=True, timeout=5)
                time.sleep(.05)  # Deliver the final key through Wayland before the IPC assertion.
            def shortcut(): keys('-M', 'logo', '-k', 'space', '-m', 'logo')
            def opened(index=0):
                call('open', index)
                wait(lambda: state()['open'] and state()['focus'])
            def closed():
                call('close'); wait(lambda: not state()['open'])
            def settled():
                wait(lambda: not state()['filePending'])
                time.sleep(.25)
                return state()
            def measure():
                def sample():
                    fields = Path(f'/proc/{proc.pid}/stat').read_text().rsplit(')', 1)[1].split()
                    return sum(map(int, fields[11:13])), int(fields[21]) * os.sysconf('SC_PAGE_SIZE') // 1024
                a = sample(); started = time.monotonic(); time.sleep(1); b = sample()
                return {'cpu_percent': round(100 * (b[0] - a[0]) / os.sysconf('SC_CLK_TCK') /
                    (time.monotonic() - started), 2), 'rss_kib': b[1]}

            wait(lambda: not state()['open'])
            subprocess.run([str(pointer), '10', '10', 'move'], env=env, check=True, timeout=5)
            time.sleep(.5)
            report['before'] = measure()
            report['cycle_rss_kib'] = []
            report['frames'] = []
            for cycle in range(args.cycles):
                call('reduced', cycle % 2 == 1)
                shortcut()
                try:
                    wait(lambda: state()['open'] and state()['focus'])
                except AssertionError:
                    report['failed_state'] = state()
                    report['bindings'] = json.loads(ipc(child, 'j/binds'))
                    report['binding_log'] = (work / 'binding.log').read_text() if (work / 'binding.log').exists() else 'not invoked'
                    raise
                assert state()['count'] == 0 and state()['text'] == '', state()
                call('beginFrames')
                keys('Launchertest')
                current = settled()
                if not args.baseline:
                    assert current['count'] == 90 and current['bottom'] <= current['screenHeight'] - 25 + .1, current
                    assert abs(current['listHeight'] - 264) < .1 and abs(current['height'] - 336) < .1, current
                elif cycle == 0:
                    report['original_overflow_px'] = current['bottom'] - current['screenHeight']
                frames = json.loads(call('endFrames'))
                intervals = [b - a for a, b in zip(frames, frames[1:])]
                if cycle < 2:
                    report['frames'].append({'reduced': cycle % 2 == 1, 'count': len(frames),
                        'median_ms': statistics.median(intervals) if intervals else None,
                        'max_ms': max(intervals) if intervals else None})
                if not args.baseline:
                    keys('-k', 'Escape'); assert state()['navigating'] and state()['text'] == 'Launchertest', state()
                    keys('j'); assert state()['selected'] == 1, state()
                    keys('k'); assert state()['selected'] == 0, state()
                    keys('G'); assert state()['selected'] == 89 and state()['selectedVisible'], state()
                    keys('gg'); assert state()['selected'] == 0 and state()['selectedVisible'], state()
                    keys('-k', 'End'); assert state()['selected'] == 89, state()
                    keys('-k', 'Home'); assert state()['selected'] == 0, state()
                    keys('i'); assert state()['focus'], state()
                    keys('jk'); assert state()['text'].endswith('jk'), state()
                    keys('-k', 'Escape'); assert state()['open'], state()
                keys('-k', 'Escape'); wait(lambda: not state()['open'])
                report['cycle_rss_kib'].append(measure()['rss_kib'])
            report['after'] = measure()
            if not args.baseline and not args.cycles_only:
                opened(); keys('-k', 'Escape'); wait(lambda: not state()['open'])
                # Actual activations feed one MRU history, including duplicate promotion.
                for needle in ('Launchertest App 01', 'Launchertest App 02', 'Launchertest App 01',
                               'Launchertest file 01', 'Launchertest clipboard 29'):
                    opened(); keys(needle); settled(); keys('-k', 'Return'); wait(lambda: not state()['open'])
                opened(); keys(':'); current = settled()
                assert [row['kind'] for row in current['results']] == ['clipboard', 'file', 'application', 'application'], current
                for prefix, mode, count in [(':a', 'application', 2), (':A', 'application', 2),
                        (':f', 'file', 1), (':c', 'clipboard', 30), (':', 'recent', 4)]:
                    closed(); opened(); keys(prefix); settled()
                    assert state()['mode'] == mode and state()['count'] == count and not state()['chip'], state()
                    keys(' '); assert state()['chip'] == mode and state()['text'] == '', state()
                    keys('-k', 'Escape'); assert state()['navigating'], state()
                    keys('G'); assert state()['selected'] == count - 1, state()
                    keys('/'); assert state()['focus'], state()
                    keys('-k', 'BackSpace'); assert not state()['chip'] and state()['text'].lower() == prefix.lower(), state()
                closed(); opened(); keys(':a App 29'); current = settled()
                assert current['chip'] == 'application' and current['count'] == 1, current
                closed(); opened(); keys(':f file 29'); current = settled()
                assert current['chip'] == 'file' and current['count'] == 1, current
                # A literal prefix that is not a command stays ordinary searchable text.
                closed(); opened(); keys(':xyz'); settled(); assert state()['mode'] == '', state()
                keys('-k', 'Escape'); keys('jkx')
                assert state()['navigating'] and state()['text'] == ':xyz' and not state()['focus'], state()
                closed(); opened(); keys('Launchertest'); keys('-M', 'ctrl', '-k', 'a', '-m', 'ctrl', ':c ')
                current = settled(); assert current['count'] == 30 and not current['fileError'], current
                call('screenshot', str(work / 'spotlight.png')); wait(lambda: (work / 'spotlight.png').exists())
                # Commands are argv data up to the shell inside kitty; -q is removed there.
                commands = ["printf '%s' 'a; b $(literal)'", "-q printf '%s' 'background'", "-Q echo uppercase"]
                for command in commands:
                    closed(); opened(); keys(':! ' + command)
                    current = settled(); assert current['chip'] == 'command' and current['count'] == 1, current
                    keys('-k', 'Return'); wait(lambda: not state()['open'])
                actions = [json.loads(line) for line in (work / 'actions.jsonl').read_text().splitlines()]
                terminals = [action for action in actions if action[0] == 'kitty']
                assert terminals == [
                    ['kitty', '--hold', '-e', '/bin/sh', '-lc', commands[0]],
                    ['kitty', '--start-as=hidden', '-e', '/bin/sh', '-lc', commands[1][3:]],
                    ['kitty', '--start-as=hidden', '-e', '/bin/sh', '-lc', commands[2][3:]]], terminals
                # Both scaled screens and low placement remain bounded; rows scroll into view.
                for index in (0, 1):
                    for position in (.65, .1, .9):
                        call('position', position); opened(index); keys(':c'); settled()
                        current = state()
                        assert current['bottom'] <= current['screenHeight'] - 25 + .1, current
                        assert abs(current['listHeight'] - 264) < .1 and abs(current['height'] - 336) < .1, current
                        keys('-k', 'Escape'); keys('G'); assert state()['selectedVisible'], state()
                        closed()
                history_path = work / 'state/quickshell-de/launcher.json'
                wait(lambda: history_path.exists())
                saved = json.loads(history_path.read_text())
                assert [row['kind'] for row in saved['records']] == ['file', 'application', 'application'], saved
                assert history_path.stat().st_mode & 0o777 == 0o600
                stop(proc)
                proc = subprocess.Popen(['qs', '-p', str(config), '--no-color'], env=env, stdout=shell_log, stderr=shell_log)
                wait(lambda: not state()['open']); opened(); keys(':'); current = settled()
                assert current['count'] == 3, current
                closed()
                # Real kitty verifies foreground focus vs hidden execution on this private compositor.
                real_kitty = shutil.which('kitty')
                if real_kitty:
                    call('focusApplication'); wait(lambda: state()['applicationActive'])
                    for quiet in (False, True):
                        terminal = subprocess.Popen([real_kitty, '--config', 'NONE',
                            '--start-as=hidden' if quiet else '--hold', '-e', '/bin/sh', '-c',
                            'printf terminal-proof > "$1"; sleep 2', 'sh', str(work / 'terminal-proof')],
                            env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                        wait(lambda: (work / 'terminal-proof').exists())
                        if quiet:
                            assert state()['applicationActive'], state()
                            terminal.wait(timeout=8)
                        else:
                            wait(lambda: not state()['applicationActive'])
                        stop(terminal); terminal = None
                        (work / 'terminal-proof').unlink()
                        call('focusApplication'); wait(lambda: state()['applicationActive'])
            warnings = [line for line in (work / 'shell.log').read_text().splitlines()
                if re.search(r'WARN|ERROR|TypeError:|ReferenceError:|Binding loop', line)
                and not any(expected in line for expected in ('Failed to register with host portal',))]
            assert not warnings, warnings
            report.update(passed=True, cycles=args.cycles, warnings=warnings)
    finally:
        stop(terminal); stop(proc); stop(comp); stop(bus)
        report['production_unchanged'] = before_production == production_state(parent_socket)
        (work / 'result.json').write_text(json.dumps(report, indent=2))
        print(json.dumps(report, indent=2), flush=True)
        assert report['production_unchanged']


if __name__ == '__main__':
    run()
