"""Native pointer/focus regression, invoked by test_network_ui.py --prompt-wayland."""
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import time

from test_lockscreen_wayland import ipc as compositor_ipc, production_state, wait, stop


def run(root, work, config):
    def copy_types(directory, names):
        target = config / directory
        target.mkdir(parents=True, exist_ok=True)
        with (target / 'qmldir').open('a') as index:
            for name in names:
                shutil.copy2(root / directory / (name + '.qml'), target / (name + '.qml'))
                index.write(name + ' 1.0 ' + name + '.qml\n')

    copy_types('modules/statusbar', ['BarIsland', 'BarModuleHost', 'NetworkModule'])
    copy_types('components', ['BarButton'])
    for name, body in {
        'HyprlandService': 'function screenName(screen) { return "test-a"; }',
        'ModuleActions': 'function run(id, gesture, screen) {}',
    }.items():
        (config / 'services' / (name + '.qml')).write_text(
            'pragma Singleton\nimport Quickshell\nSingleton {' + body + '}\n')
        with (config / 'services/qmldir').open('a') as index:
            index.write('singleton ' + name + ' 1.0 ' + name + '.qml\n')
    for name, body in {
        'Settings': '''property int barHeight: 40
            property real barSurfaceOpacity: 0.9
            property int hoverCloseDelay: 300
            function option(id, key, fallback) { return fallback; }''',
        'SurfaceManager': '''property bool workspaceSwitcherVisible: false
            function activeSurface(screen) { return surface; }
            function notificationsPinned(screen) { return false; }''',
    }.items():
        file = config / 'core' / (name + '.qml')
        text = file.read_text()
        end = text.rfind('}')
        file.write_text(text[:end] + body + text[end:])
    (config / 'shell.qml').write_text('//@ pragma Env QML_IMPORT_PATH = '
        + str(root / 'integrations') + '\n'
        + (root / 'tests/fixtures/network-prompt-wayland.qml').read_text())
    pointer = work / 'pointer'
    flags = shlex.split(subprocess.check_output(['pkg-config', '--cflags', '--libs', 'wayland-client'], text=True))
    subprocess.run(['cc', '-Wall', '-Wextra', '-O2', '-o', str(pointer),
        str(root / 'tests/fixtures/virtual-pointer.c'), *flags], check=True)

    parent_runtime = Path(os.environ['XDG_RUNTIME_DIR'])
    parent_socket = parent_runtime / 'hypr' / os.environ['HYPRLAND_INSTANCE_SIGNATURE'] / '.socket.sock'
    before_production = production_state(parent_socket)
    runtime = work / 'r'
    runtime.mkdir(mode=0o700)
    display = Path(os.environ['WAYLAND_DISPLAY'])
    if not display.is_absolute():
        display = parent_runtime / display
    env = dict(os.environ, XDG_RUNTIME_DIR=str(runtime), XDG_CONFIG_HOME=str(work / 'config'),
        XDG_CACHE_HOME=str(work / 'cache'), XDG_STATE_HOME=str(work / 'state'),
        XDG_DATA_HOME=str(work / 'data'), WAYLAND_DISPLAY=str(display), DISPLAY='',
        HYPRLAND_INSTANCE_SIGNATURE='', LIBSEAT_BACKEND='seatd', SEATD_SOCK=str(work / 'missing'),
        AQ_DRM_DEVICES=str(work / 'missing'), HYPRLAND_NO_SD_VARS='1', HYPRLAND_NO_SD_NOTIFY='1',
        HYPRLAND_NO_CRASHREPORTER='1', HYPRLAND_NO_RT='1', QT_QPA_PLATFORM='wayland',
        QT_QPA_PLATFORMTHEME='', NO_AT_BRIDGE='1', GSETTINGS_BACKEND='memory',
        DBUS_SYSTEM_BUS_ADDRESS=os.environ['DBUS_SESSION_BUS_ADDRESS'])
    for key in ('NOTIFY_SOCKET', 'LISTEN_FDS', 'LISTEN_PID', 'WAYLAND_SOCKET'):
        env.pop(key, None)
    compositor_config = work / 'hyprland.lua'
    compositor_config.write_text('''hl.monitor({output="WAYLAND-1", disabled=true})
hl.monitor({output="PROMPT", mode="1280x720@60", position="0x0", scale=1})
hl.config({misc={disable_hyprland_logo=true,disable_splash_rendering=true,force_default_wallpaper=0},xwayland={enabled=false}})
''')
    comp = proc = None
    result = {'passed': False, 'work': str(work)}
    with (work / 'compositor.log').open('w') as comp_log, (work / 'shell.log').open('w') as shell_log:
        try:
            comp = subprocess.Popen(['Hyprland', '-c', str(compositor_config)], env=env, stdout=comp_log, stderr=comp_log)
            child = wait(lambda: next((runtime / 'hypr').glob('*/.socket.sock'), None))
            assert child.is_relative_to(runtime) and child != parent_socket
            assert compositor_ipc(child, 'output create headless PROMPT').strip() == 'ok'
            wait(lambda: len(json.loads(compositor_ipc(child, 'j/monitors'))) == 1)
            assert not compositor_ipc(child, 'configerrors').strip()
            env.update(WAYLAND_DISPLAY=str(runtime / 'wayland-1'), HYPRLAND_INSTANCE_SIGNATURE=child.parent.name)
            proc = subprocess.Popen(['qs', '-p', str(config), '--no-color'], env=env, stdout=shell_log, stderr=shell_log)

            def call(method, *args):
                assert proc.poll() is None, (work / 'shell.log').read_text()
                response = subprocess.run(['qs', 'ipc', '--pid', str(proc.pid), 'call', 'networkPrompt',
                    method, *map(str, args)], env=env, capture_output=True, text=True, timeout=5)
                assert response.returncode == 0, response.stderr
                return response.stdout.strip()

            def state():
                return json.loads(call('state'))

            def pointer_at(point, mode='click'):
                subprocess.run([str(pointer), *map(str, point), mode], env=env, check=True, timeout=5)

            def key(*args):
                subprocess.run(['wtype', *args], env=env, check=True, timeout=5)

            def open_form():
                call('open')
                wait(lambda: state()['row'])
                time.sleep(.25)
                pointer_at(state()['row'])
                wait(lambda: state()['input'])
                time.sleep(.25)
                pointer_at(state()['field'])
                return state()

            def closed():
                wait(lambda: not state()['open'] and not state()['input']
                    and not state()['scanning'] and state()['popupUsers'] == 0)

            def measure():
                def stats():
                    values = Path(f'/proc/{proc.pid}/stat').read_text().rsplit(')', 1)[1].split()
                    return sum(map(int, values[11:13])), int(values[21]) * os.sysconf('SC_PAGE_SIZE') // 1024
                a = stats(); start = time.monotonic(); time.sleep(1); b = stats()
                return {'cpu_percent': round(100 * (b[0] - a[0]) / os.sysconf('SC_CLK_TCK')
                    / (time.monotonic() - start), 2), 'rss_kib': b[1]}

            wait(lambda: call('ready') == 'true')
            call('close'); closed(); time.sleep(.3)
            result['before'] = measure()
            form = open_form()
            assert form['inputHeight'] == form['buttonHeight'] and form['inputHeight'] >= 32, form
            assert form['muted'] and form['buttonBorder'] == 0 and form['retained'], form
            key('short'); key('-k', 'Return')
            assert state()['input'] and state()['connections'] == 0
            key('-k', 'Escape'); closed()
            result['geometry'] = {key: form[key] for key in ('inputHeight', 'buttonHeight', 'muted', 'buttonBorder')}
            samples = []
            for cycle in range(20):
                form = open_form()
                assert form['empty'] and form['wifiEnabled']
                key('test-only-password')
                pointer_at((20, 650), 'move')
                time.sleep(.4)
                assert state()['open'] and state()['retained'], 'Pointer exit dismissed typed password'
                if cycle == 0:
                    call('capture', work / 'wifi-password.png')
                    wait(lambda: (work / 'wifi-password.png').exists())
                pointer_at((20, 650)); closed()
                assert state()['connections'] == 0 and state()['wifiEnabled']
                samples.append(measure()['rss_kib'])
                if cycle == 9:
                    call('reduced')
            result['cycle_rss_kib'] = samples
            result['after'] = measure()
            open_form(); key('test-only-password'); key('-k', 'Return')
            wait(lambda: state()['connections'] == 1 and not state()['input'])
            pointer_at((20, 650)); closed()
            result['checks'] = ['Equal field/button heights and muted border', 'Invalid Enter preserves form',
                'Escape cancels', '20 outside clicks discard password and stop scanning',
                'Pointer exit alone preserves typed password', 'Reopening clears input',
                'Reduced motion', 'Valid Enter submits exactly once to mock network']
            warnings = [line for line in (work / 'shell.log').read_text().splitlines()
                if re.search(r'WARN|ERROR|TypeError:|ReferenceError:|Binding loop', line)
                and 'Failed to register with host portal' not in line]
            assert not warnings, warnings
            assert 'test-only-password' not in (work / 'shell.log').read_text()
            result.update(passed=True, warnings=warnings)
        finally:
            stop(proc); stop(comp)
            result['production_unchanged'] = before_production == production_state(parent_socket)
            (work / 'prompt-result.json').write_text(json.dumps(result, indent=2))
            print(json.dumps(result, indent=2), flush=True)
            assert result['production_unchanged']
