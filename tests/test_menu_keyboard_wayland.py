#!/usr/bin/env python3
"""Real menu shortcuts, focus and key input on private Wayland and D-Bus.

Only NotificationService uses its real API, on the private bus. Power,
authentication, audio, radio and inhibition are inert in-memory doubles.
"""
import argparse
import json
import os
from pathlib import Path
import re
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
    args = parser.parse_args()
    work = Path(tempfile.mkdtemp(prefix='qmenus-'))
    config = work / 'shell'
    for directory in ('core', 'components', 'modules/statusbar',
                      'modules/notifications', 'modules/bluetooth'):
        shutil.copytree(args.source / directory, config / directory)
    (config / 'popups').mkdir()
    popup_names = ['PowerPopup', 'BluetoothPopup', 'QuickSettingsPopup', 'QuickAudioControl']
    for name in popup_names:
        shutil.copy2(args.source / 'popups' / (name + '.qml'), config / 'popups' / (name + '.qml'))
    (config / 'popups/qmldir').write_text('module qs.popups\n' + ''.join(
        name + ' 1.0 ' + name + '.qml\n' for name in popup_names))
    services = config / 'services'
    services.mkdir()
    (services / 'qmldir').write_text('module qs.services\n')

    def service(name, body=None, singleton=True):
        if body is None:
            shutil.copy2(args.source / 'services' / (name + '.qml'), services / (name + '.qml'))
        else:
            (services / (name + '.qml')).write_text('pragma Singleton\nimport QtQuick\nimport Quickshell\n'
                'Singleton {\n' + body + '\n}\n')
        with (services / 'qmldir').open('a') as index:
            index.write(('singleton ' if singleton else '') + name + ' 1.0 ' + name + '.qml\n')

    service('ModuleActions')
    service('NotificationService')
    service('NotificationHistory', singleton=False)
    service('HyprlandService', '''function screenName(screen) { return screen ? screen.name : ""; }
        function hasFullscreen(screen) { return false; }''')
    service('AuthenticationService', 'property bool interactive: false')
    service('LockService', 'property bool locked: false; property bool releasing: false')
    service('ClipboardService', 'function rememberFocus() {}')
    service('SystemActions', '''property bool busy: false
        property string errorMessage: ""
        signal succeeded(string actionId)
        function available(action) { return true; }
        function execute(action) { throw new Error("Native smoke test must not execute power actions"); }''')
    service('ScreenshotService', '''property bool active: false
        property int generation: 0
        property string errorMessage: ""
        signal captureStarting(int token)
        function cancel() {}
        function holdCapture(owner, token) {}
        function releaseCapture(owner, token) {}
        function begin(mode, screen) {}''')
    service('BluetoothService', '''property bool available: true
        property bool enabled: true
        property string state: "ready"
        property string errorMessage: ""
        property string statusMessage: ""
        property bool pairingBusy: false
        property bool actionBusy: false
        property string pairingScreenName: ""
        property string managementPath: ""
        property string managementScreenName: ""
        property int connectedCount: 0
        property var devices: []
        property var adapters: []
        property var adapter: null
        property bool discovering: false
        function setEnabled(value) { enabled = value; }
        function acquirePopup(screen) {}
        function releasePopup(screen) {}
        function setDiscovery(screen, value) { discovering = value; }
        function closeManagement(screen) {}
        function cancelPairing() {}''')
    service('NetworkService', '''property bool available: true
        property bool wifiEnabled: true
        property var wiredDevice: null
        property string errorMessage: ""
        function setWifiEnabled(value) { wifiEnabled = value; }''')
    service('BrightnessService', '''property bool available: true
        property real percentage: 50
        property real sliderPercentage: percentage
        property string errorMessage: ""
        function setPercentage(value) { percentage = value; }''')
    service('AudioService', '''property bool available: true
        property bool sourceAvailable: true
        property bool muted: false
        property bool sourceMuted: false
        property real volume: 0.4
        property real sourceVolume: 0.6
        property string errorMessage: ""
        property var sinks: []; property var sources: []
        property var sink: null; property var source: null
        function toggleMute() { muted = !muted; }
        function toggleSourceMute() { sourceMuted = !sourceMuted; }
        function setVolume(value) { volume = value; }
        function setSourceVolume(value) { sourceVolume = value; }''')
    service('CaffeinateService', '''property bool active: false
        property string mode: "off"
        property string label: "Caffeinate"
        property string errorMessage: ""
        property var modes: [{id:"background", label:"Praca w tle", description:""}]
        function setMode(value) { mode = value; active = value !== "off"; }''')
    (config / 'scripts').mkdir()
    shutil.copy2(args.source / 'scripts/notification-state', config / 'scripts/notification-state')
    shutil.copytree(args.source / 'assets/sounds', config / 'assets/sounds')
    shutil.copy2(repository / 'tests/fixtures/menu-keyboard.qml', config / 'shell.qml')
    settings = work / 'config/quickshell-de/settings.json'
    settings.parent.mkdir(parents=True)
    settings.write_text(json.dumps({'schemaVersion': 1, 'leftModules': ['power'], 'centerModules': [],
        'rightModules': ['bluetooth', 'notifications', 'quickSettings'], 'notificationSoundEnabled': False}))
    runtime = work / 'r'
    runtime.mkdir(mode=0o700)
    parent_runtime = Path(os.environ['XDG_RUNTIME_DIR'])
    parent_socket = parent_runtime / 'hypr' / os.environ['HYPRLAND_INSTANCE_SIGNATURE'] / '.socket.sock'
    before_production = production_state(parent_socket)
    display = Path(os.environ['WAYLAND_DISPLAY'])
    if not display.is_absolute():
        display = parent_runtime / display
    bus_config = work / 'bus.conf'
    bus_config.write_text('<busconfig><type>session</type><listen>unix:tmpdir=/tmp</listen>'
        '<policy context="default"><allow send_destination="*"/><allow receive_sender="*"/>'
        '<allow own="*"/></policy></busconfig>')
    bus = comp = proc = None
    report = {'passed': False, 'work': str(work), 'baseline': args.baseline}
    try:
        bus = subprocess.Popen(['dbus-daemon', '--config-file=' + str(bus_config), '--nofork', '--print-address=1'],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        address = bus.stdout.readline().strip()
        assert address.startswith('unix:'), address
        env = dict(os.environ, XDG_RUNTIME_DIR=str(runtime), XDG_CONFIG_HOME=str(work / 'config'),
            XDG_CACHE_HOME=str(work / 'cache'), XDG_STATE_HOME=str(work / 'state'),
            XDG_DATA_HOME=str(work / 'data'), WAYLAND_DISPLAY=str(display), DISPLAY='',
            HYPRLAND_INSTANCE_SIGNATURE='', LIBSEAT_BACKEND='seatd', SEATD_SOCK=str(work / 'missing'),
            AQ_DRM_DEVICES=str(work / 'missing'), HYPRLAND_NO_SD_VARS='1', HYPRLAND_NO_SD_NOTIFY='1',
            HYPRLAND_NO_CRASHREPORTER='1', HYPRLAND_NO_RT='1', QT_QPA_PLATFORM='wayland',
            QT_QPA_PLATFORMTHEME='', NO_AT_BRIDGE='1', GSETTINGS_BACKEND='memory',
            DBUS_SESSION_BUS_ADDRESS=address, DBUS_SYSTEM_BUS_ADDRESS=address)
        for key in ('NOTIFY_SOCKET', 'LISTEN_FDS', 'LISTEN_PID', 'WAYLAND_SOCKET', 'QT_SCALE_FACTOR'):
            env.pop(key, None)
        compositor_config = work / 'hyprland.lua'
        ipc_script = work / 'menu-ipc'
        ipc_script.write_text('#!/bin/sh\nexport XDG_RUNTIME_DIR=' + str(runtime) + '\n'
            'export WAYLAND_DISPLAY=' + str(runtime / 'wayland-1') + '\n'
            'qs ipc -p ' + str(config) + ' call "$@" >> ' + str(work / 'binding.log') + ' 2>&1\n')
        ipc_script.chmod(0o700)
        compositor_config.write_text('''hl.monitor({output="WAYLAND-1", disabled=true})
hl.monitor({output="MENUS", mode="1280x900@60", position="0x0", scale=1})
hl.config({misc={disable_hyprland_logo=true,disable_splash_rendering=true,force_default_wallpaper=0},xwayland={enabled=false},input={resolve_binds_by_sym=true}})
''' + 'dofile(' + json.dumps(str(repository / 'config/menu-keybinds.lua')) + ')(hl.bind, '
            + json.dumps(str(ipc_script)) + ')\n')
        with (work / 'compositor.log').open('w') as comp_log, (work / 'shell.log').open('w') as shell_log:
            comp = subprocess.Popen(['Hyprland', '-c', str(compositor_config)], env=env, stdout=comp_log, stderr=comp_log)
            child = wait(lambda: next((runtime / 'hypr').glob('*/.socket.sock'), None))
            assert child.is_relative_to(runtime) and child != parent_socket
            assert ipc(child, 'output create headless MENUS').strip() == 'ok'
            wait(lambda: len(json.loads(ipc(child, 'j/monitors'))) == 1)
            assert not ipc(child, 'configerrors').strip()
            env.update(WAYLAND_DISPLAY=str(runtime / 'wayland-1'), HYPRLAND_INSTANCE_SIGNATURE=child.parent.name)
            proc = subprocess.Popen(['qs', '-p', str(config), '--no-color'], env=env, stdout=shell_log, stderr=shell_log)

            def call(method, *values):
                assert proc.poll() is None, (work / 'shell.log').read_text()
                response = subprocess.run(['qs', 'ipc', '--pid', str(proc.pid), 'call', 'menutest', method,
                    *[str(value).lower() for value in values]], env=env, capture_output=True, text=True, timeout=5)
                assert response.returncode == 0, response.stderr
                return response.stdout.strip()

            def state():
                return json.loads(call('state'))

            def keys(*values):
                subprocess.run(['wtype', *values], env=env, check=True, timeout=5)

            def shortcut(key):
                # The test compositor resolves symbols from wtype's keymap;
                # its temporary keycodes differ from a physical US keyboard.
                matches = [binding for binding in json.loads(ipc(child, 'j/binds'))
                    if binding['modmask'] == 65 and binding['key'].upper() == key.upper()]
                assert len(matches) == 1, matches
                keys('-M', 'logo', '-M', 'shift', '-k', key, '-m', 'shift', '-m', 'logo')

            def measure():
                def sample():
                    fields = Path(f'/proc/{proc.pid}/stat').read_text().rsplit(')', 1)[1].split()
                    return sum(map(int, fields[11:13])), int(fields[21]) * os.sysconf('SC_PAGE_SIZE') // 1024
                a = sample(); started = time.monotonic(); time.sleep(1); b = sample()
                return {'cpu_percent': round(100 * (b[0] - a[0]) / os.sysconf('SC_CLK_TCK') /
                    (time.monotonic() - started), 2), 'rss_kib': b[1]}

            wait(lambda: 'active' in state())
            subprocess.run(['notify-send', '-a', 'Menu test', '-t', '0', 'Test hjkl'], env=env, check=True)
            report['before'] = measure()
            report['cycle_rss_kib'] = []
            report['opening_frames'] = []
            for cycle in range(args.cycles):
                call('reduced', cycle % 2 == 1)
                call('focusApplication')
                wait(lambda: state()['applicationActive'])
                for key, surface in [('p', 'power'), ('n', 'notifications'), ('b', 'bluetooth'), ('q', 'quickSettings')]:
                    if cycle < 2:
                        call('beginFrames')
                    shortcut(key)
                    try:
                        wait(lambda: state()['active'] == surface)
                    except AssertionError:
                        report['failed_state'] = state()
                        report['bindings'] = json.loads(ipc(child, 'j/binds'))
                        report['binding_log'] = (work / 'binding.log').read_text() if (work / 'binding.log').exists() else 'not invoked'
                        raise
                    time.sleep(.3)
                    if cycle < 2:
                        frames = json.loads(call('endFrames'))
                        intervals = [b - a for a, b in zip(frames, frames[1:])]
                        assert frames, (surface, 'No rendered frames')
                        report['opening_frames'].append({'surface': surface, 'reduced_motion': cycle % 2 == 1,
                            'frames': len(frames), 'median_ms': statistics.median(intervals) if intervals else None,
                            'max_ms': max(intervals) if intervals else None})
                    if not args.baseline:
                        current = state()
                        assert current['panels'] == 1 and current['visualFocus'], current
                        if surface == 'power':
                            assert current['focused'] == current['lockLabel'], current
                            keys('j'); assert state()['focused'] == current['logoutLabel'], state()
                            keys('-k', 'Return'); wait(lambda: state()['confirmation'] == 'logout')
                            keys('-k', 'Escape'); wait(lambda: not state()['confirmation'])
                            assert state()['active'] == 'power', state()
                        elif surface == 'quickSettings':
                            assert current['focused'] == 'quickWifi', current
                            keys('ljh'); assert state()['focused'] == 'quickDnd', state()
                            keys('-k', 'Return'); assert state()['dnd'] != current['dnd'], state()
                        elif surface == 'notifications':
                            assert current['focused'] == 'notificationDnd', current
                            keys('/hjkl'); wait(lambda: state()['search'] == 'hjkl')
                            keys('-k', 'Escape'); wait(lambda: state()['focused'] == 'notificationDnd')
                        else:
                            keys('-k', 'Return')
                            assert state()['bluetoothEnabled'] != current['bluetoothEnabled'], state()
                            keys('-k', 'Return')
                            assert state()['bluetoothEnabled'] == current['bluetoothEnabled'], state()
                            keys('j'); assert state()['focused'] == 'pairNewDevice', state()
                    keys('-k', 'Escape')
                    wait(lambda: state()['active'] == '' and state()['panels'] == 0)
                    wait(lambda: state()['applicationActive'])
                report['cycle_rss_kib'].append(measure()['rss_kib'])
            # Repeated shortcut toggles, and switching directly between islands.
            shortcut('q'); wait(lambda: state()['active'] == 'quickSettings')
            shortcut('p'); wait(lambda: state()['active'] == 'power')
            shortcut('p'); wait(lambda: state()['active'] == '')
            report['after'] = measure()
            warnings = [line for line in (work / 'shell.log').read_text().splitlines()
                if re.search(r'WARN|ERROR|TypeError:|ReferenceError:|Binding loop', line)
                and not any(expected in line for expected in ('Failed to register with host portal',
                    'PulseAudioService: pa_context_connect() failed',
                    'QSoundEffect: playback of this format is not supported on the selected audio device'))]
            assert not warnings, warnings
            report.update(passed=True, cycles=args.cycles, warnings=warnings)
    finally:
        stop(proc); stop(comp); stop(bus)
        report['production_unchanged'] = before_production == production_state(parent_socket)
        (work / 'result.json').write_text(json.dumps(report, indent=2))
        print(json.dumps(report, indent=2), flush=True)
        assert report['production_unchanged']


if __name__ == '__main__':
    run()
