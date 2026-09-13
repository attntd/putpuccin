#!/usr/bin/env python3
"""Real bell clicks and keyboard focus on private Wayland and D-Bus.

Uses production StatusBar, SurfaceManager and NotificationService, with
synthetic notification text. No host authentication or devices are loaded.
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

from test_lockscreen_wayland import ipc as compositor_ipc, production_state, wait, stop


def run():
    parser = argparse.ArgumentParser()
    parser.add_argument('--cycles', type=int, default=20)
    parser.add_argument('--skip-colors', action='store_true', help='Reproduce the click failure before the appearance change')
    parser.add_argument('--skip-replies', action='store_true', help='Measure the shell before inline reply support')
    parser.add_argument('--source', default=str(Path(__file__).resolve().parents[1]))
    args = parser.parse_args()
    root = Path(args.source).resolve()
    work = Path(tempfile.mkdtemp(prefix='qbell-'))
    config = work / 'shell'
    for directory in ('core', 'components', 'modules/statusbar', 'modules/notifications'):
        shutil.copytree(root / directory, config / directory)
    (config / 'popups').mkdir()
    shutil.copy2(root / 'popups/CalendarPopup.qml', config / 'popups/CalendarPopup.qml')
    (config / 'popups/qmldir').write_text('module qs.popups\nCalendarPopup 1.0 CalendarPopup.qml\n')
    (config / 'services').mkdir()
    (config / 'services/qmldir').write_text('module qs.services\n')

    def service(name, body=None, singleton=True):
        target = config / 'services' / (name + '.qml')
        if body is None:
            shutil.copy2(root / 'services' / target.name, target)
        else:
            target.write_text('pragma Singleton\nimport QtQuick\nimport Quickshell\nSingleton {\n' + body + '\n}\n')
        with (config / 'services/qmldir').open('a') as index:
            index.write(('singleton ' if singleton else '') + name + ' 1.0 ' + target.name + '\n')

    service('ModuleActions')
    service('NotificationService')
    service('NotificationHistory', singleton=False)
    service('HyprlandService', '''property bool fullscreen: false
        function screenName(screen) { return screen ? screen.name : ""; }
        function hasFullscreen(screen) { return fullscreen; }''')
    service('AuthenticationService', 'property bool interactive: false')
    service('ScreenshotService', '''property bool active: false
        property int generation: 0
        signal captureStarting(int token)
        function cancel() {}
        function holdCapture(owner, token) {}
        function releaseCapture(owner, token) {}''')
    service('BluetoothService', '''property bool pairingBusy: false
        property string pairingScreenName: ""
        property string managementPath: ""
        property string managementScreenName: ""''')
    service('ClipboardService', 'function rememberFocus() {}')
    (config / 'scripts').mkdir()
    shutil.copy2(root / 'scripts/notification-state', config / 'scripts/notification-state')
    shutil.copytree(root / 'assets/sounds', config / 'assets/sounds')
    shutil.copy2(Path(__file__).parent / 'fixtures/notification-bell-wayland.qml', config / 'shell.qml')
    settings = work / 'config/quickshell-de/settings.json'
    settings.parent.mkdir(parents=True)
    settings.write_text(json.dumps({'schemaVersion': 1, 'leftModules': [], 'centerModules': [],
        'rightModules': ['notifications', 'clock'], 'notificationSoundEnabled': False,
        'notificationShowBadge': True, 'moduleOptions': {'notifications': {'primaryAction': 'activate'}}}))

    pointer = work / 'pointer'
    flags = shlex.split(subprocess.check_output(['pkg-config', '--cflags', '--libs', 'wayland-client'], text=True))
    subprocess.run(['cc', '-Wall', '-Wextra', '-O2', '-o', str(pointer),
        str(root / 'tests/fixtures/virtual-pointer.c'), *flags], check=True)
    bus_config = work / 'bus.conf'
    bus_config.write_text('<busconfig><type>session</type><listen>unix:tmpdir=/tmp</listen>'
        '<policy context="default"><allow send_destination="*"/><allow receive_sender="*"/>'
        '<allow own="*"/></policy></busconfig>')

    parent_runtime = Path(os.environ['XDG_RUNTIME_DIR'])
    parent_socket = parent_runtime / 'hypr' / os.environ['HYPRLAND_INSTANCE_SIGNATURE'] / '.socket.sock'
    before_production = production_state(parent_socket)
    runtime = work / 'r'
    runtime.mkdir(mode=0o700)
    display = Path(os.environ['WAYLAND_DISPLAY'])
    if not display.is_absolute():
        display = parent_runtime / display
    bus = comp = proc = monitor = None
    report = {'passed': False, 'work': str(work)}
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
        compositor_config.write_text('''hl.monitor({output="WAYLAND-1", disabled=true})
hl.monitor({output="BELL", mode="1280x720@60", position="0x0", scale=1})
hl.config({misc={disable_hyprland_logo=true,disable_splash_rendering=true,force_default_wallpaper=0},xwayland={enabled=false}})
''')
        with (work / 'compositor.log').open('w') as comp_log, (work / 'shell.log').open('w') as shell_log:
            comp = subprocess.Popen(['Hyprland', '-c', str(compositor_config)], env=env, stdout=comp_log, stderr=comp_log)
            child = wait(lambda: next((runtime / 'hypr').glob('*/.socket.sock'), None))
            assert child.is_relative_to(runtime) and child != parent_socket
            assert compositor_ipc(child, 'output create headless BELL').strip() == 'ok'
            wait(lambda: len(json.loads(compositor_ipc(child, 'j/monitors'))) == 1)
            assert not compositor_ipc(child, 'configerrors').strip()
            env.update(WAYLAND_DISPLAY=str(runtime / 'wayland-1'), HYPRLAND_INSTANCE_SIGNATURE=child.parent.name)
            proc = subprocess.Popen(['qs', '-p', str(config), '--no-color'], env=env, stdout=shell_log, stderr=shell_log)

            def call(method, *args):
                assert proc.poll() is None, (work / 'shell.log').read_text()
                values = [str(value).lower() if isinstance(value, bool) else str(value) for value in args]
                response = subprocess.run(['qs', 'ipc', '--pid', str(proc.pid), 'call', 'belltest', method, *values],
                    env=env, capture_output=True, text=True, timeout=5)
                assert response.returncode == 0, response.stderr
                return response.stdout.strip()

            def state():
                return json.loads(call('state'))

            def pointer_at(point, mode='click'):
                subprocess.run([str(pointer), *map(str, point), mode], env=env, check=True, timeout=5)

            def measure():
                def stats():
                    fields = Path(f'/proc/{proc.pid}/stat').read_text().rsplit(')', 1)[1].split()
                    return sum(map(int, fields[11:13])), int(fields[21]) * os.sysconf('SC_PAGE_SIZE') // 1024
                a = stats(); start = time.monotonic(); time.sleep(1); b = stats()
                return {'cpu_percent': round(100 * (b[0] - a[0]) / os.sysconf('SC_CLK_TCK')
                    / (time.monotonic() - start), 2), 'rss_kib': b[1]}

            def closed():
                wait(lambda: not state()['open'] and not state()['panel'] and state()['height'] == 40)

            def open_click():
                pointer_at(state()['bell'])
                time.sleep(.35)
                current = state()
                assert current['open'] and current['panel'] and current['height'] > 40, current
                return current

            def snapshot(name):
                current = state()
                call('capture', work / (name + '.png'))
                wait(lambda: (work / (name + '.png')).exists())
                report.setdefault('states', {})[name] = current
                return current

            wait(lambda: call('ready') == 'true')
            report['before'] = measure()
            snapshot('empty')
            open_click()
            pointer_at(state()['bell']); closed()
            if not args.skip_colors:
                current = state()
                assert current['color'] == current['text'] and not current['badge'], current
            subprocess.run(['notify-send', '-a', 'Bell test', '-t', '0', 'Powiadomienie testowe',
                'Treść wyłącznie z izolowanego testu.'], env=env, check=True, timeout=5)
            wait(lambda: state()['count'] == 1)
            current = snapshot('present')
            if not args.skip_colors:
                assert current['color'] == current['accent'] and not current['badge'], current
            open_click()
            wait(lambda: not state()['hasNew'])
            pointer_at(state()['bell']); closed()
            if not args.skip_colors:
                assert state()['color'] == state()['accent'], 'Reading must not reset the presence indicator'
            for present in (True, False):
                if not present:
                    call('clear')
                call('dnd', True)
                current = snapshot('dnd-present' if present else 'dnd-empty')
                assert current['color'] == current['red'] and current['icon'] == current['dndIcon']
                assert not current['badge']
                open_click(); pointer_at(state()['bell']); closed()
                call('dnd', False)
            if not args.skip_colors:
                assert state()['color'] == state()['text'] and state()['icon'] == state()['ordinaryIcon']
            subprocess.run(['notify-send', '-a', 'Bell test', '-t', '0', 'Wyszukiwanie testowe'],
                env=env, check=True, timeout=5)
            report['cycle_rss_kib'] = []
            for cycle in range(args.cycles):
                call('reduced', cycle >= args.cycles // 2)
                call('primary', 'activate' if cycle % 2 == 0 else 'openPopup')
                current = open_click()
                pointer_at(current['search'])
                subprocess.run(['wtype', 'test'], env=env, check=True, timeout=5)
                wait(lambda: state()['query'] == 'test' and state()['focused'])
                if cycle % 3 == 0:
                    subprocess.run(['wtype', '-k', 'Escape'], env=env, check=True, timeout=5)
                elif cycle % 3 == 1:
                    pointer_at((20, 650))
                else:
                    pointer_at(state()['bell'])
                closed()
                report['cycle_rss_kib'].append(measure()['rss_kib'])
            call('fullscreen', True)
            call('open'); time.sleep(.35)
            assert state()['open'] and state()['panel'], state()
            subprocess.run(['wtype', '-k', 'Escape'], env=env, check=True, timeout=5)
            closed(); call('fullscreen', False)
            report['after_bell_cycles'] = measure()
            if not args.skip_replies:
                call('reduced', False)
                signal_log = (work / 'reply-signals.log').open('w')
                monitor = subprocess.Popen(['dbus-monitor', '--session',
                    "type='signal',interface='org.freedesktop.Notifications'"],
                    env=env, stdout=signal_log, stderr=subprocess.DEVNULL)

                def replies():
                    return json.loads(call('replyState'))

                def card(uid):
                    return next((item for item in replies()['cards'] if item['uid'] == uid), None)

                def notify_reply(summary='Odpowiedź testowa', app='Reply test', reply=True, replaces=0,
                                 body='Wiadomość wyłącznie z izolowanego testu.'):
                    actions = ['inline-reply', 'Napisz odpowiedź…'] if reply else []
                    result = subprocess.check_output(['gdbus', 'call', '--session', '--dest',
                        'org.freedesktop.Notifications', '--object-path', '/org/freedesktop/Notifications',
                        '--method', 'org.freedesktop.Notifications.Notify', '--', app, str(replaces), '',
                        summary, body, json.dumps(actions), '{}', '-1'],
                        env=env, text=True, timeout=5)
                    nid = int(re.search(r'uint32 (\d+)', result)[1])
                    return wait(lambda: next((r['uid'] for r in replies()['records'] if r['serverId'] == nid), None))

                def open_reply(uid):
                    # The model is populated before the layer's first map and
                    # compositor animation; wait for the native click target.
                    time.sleep(.25)
                    pointer_at((20, 650), 'move')
                    pointer_at(wait(lambda: card(uid))['point'])
                    def focused_card():
                        current = card(uid)
                        return current if current and current['focused'] else None
                    try:
                        return wait(focused_card, timeout=2)
                    except AssertionError as error:
                        raise AssertionError({'reply': replies(), 'layers': compositor_ipc(child, 'j/layers')}) from error

                def type_text(text):
                    subprocess.run(['wtype', text], env=env, check=True, timeout=5)

                def escape():
                    subprocess.run(['wtype', '-k', 'Escape'], env=env, check=True, timeout=5)

                call('clear'); call('duration', 6000)
                uid = notify_reply(app='Signal', reply=False)
                pointer_at(wait(lambda: card(uid))['point']); time.sleep(.25)
                assert not card(uid)['editor'] and replies()['keyboard'] == replies()['none']
                call('clear')
                uid = notify_reply()
                assert replies()['keyboard'] == replies()['none'], 'Arrival stole keyboard focus'
                initial_height = wait(lambda: card(uid))['height']
                current = open_reply(uid)
                assert not current['sendEnabled'] and replies()['keyboard'] == replies()['exclusive']
                type_text('   ')
                wait(lambda: card(uid)['draft'] == '   ')
                assert not card(uid)['sendEnabled']
                escape(); wait(lambda: card(uid) and not card(uid)['editor'])
                assert not card(uid)['draft'] and not card(uid)['paused']

                open_reply(uid)
                draft = 'Zażółć gęślą jaźń 👋'
                type_text(draft); wait(lambda: card(uid)['draft'] == draft)
                assert card(uid)['height'] > initial_height and card(uid)['sendEnabled']
                call('captureReply', work / 'reply-toast.png')
                wait(lambda: (work / 'reply-toast.png').exists())
                # New toast delegates and history groups must not erase a reply.
                notify_reply('Druga aplikacja', app='Another application', reply=False)
                wait(lambda: card(uid) and card(uid)['focused'])
                assert card(uid)['draft'] == draft and card(uid)['paused']
                notify_reply('Zaktualizowana wiadomość', replaces=next(r['serverId'] for r in replies()['records'] if r['uid'] == uid))
                wait(lambda: card(uid)['summary'] == 'Zaktualizowana wiadomość')
                assert card(uid)['draft'] == draft and card(uid)['paused']
                pointer_at(card(uid)['send'])
                wait(lambda: 'NotificationReplied' in (work / 'reply-signals.log').read_text())
                assert draft in (work / 'reply-signals.log').read_text()
                wait(lambda: not card(uid))
                assert replies()['keyboard'] == replies()['none']
                assert 'ActionInvoked' not in (work / 'reply-signals.log').read_text()

                call('clear'); call('duration', 1000)
                uid = notify_reply()
                open_reply(uid); type_text('Nie znikaj')
                pointer_at((20, 650), 'move')
                time.sleep(1.2)
                assert card(uid)['draft'] == 'Nie znikaj' and card(uid)['paused']
                escape(); wait(lambda: not card(uid))
                call('clear'); call('duration', 60000)
                before_cancel = (work / 'reply-signals.log').read_text().count('member=NotificationReplied')
                uid = notify_reply()
                report['reply_cycle_rss_kib'] = []
                for cycle in range(args.cycles):
                    call('reduced', cycle >= args.cycles // 2)
                    open_reply(uid); type_text('Szkic ' + str(cycle))
                    if cycle % 2:
                        escape()
                    else:
                        time.sleep(.2)
                        pointer_at(card(uid)['cancel'])
                    wait(lambda: card(uid) and not card(uid)['editor'])
                    assert not card(uid)['draft'] and not card(uid)['paused']
                    assert replies()['keyboard'] == replies()['none']
                    report['reply_cycle_rss_kib'].append(measure()['rss_kib'])
                assert (work / 'reply-signals.log').read_text().count('member=NotificationReplied') == before_cancel

                open_reply(uid); type_text('Anulowane przez DND')
                call('dnd', True); wait(lambda: not replies()['toast'])
                assert replies()['keyboard'] == replies()['none']
                call('dnd', False); call('open'); time.sleep(.3)
                open_reply(uid)
                assert not card(uid)['draft'], 'Closed toast retained its draft in the center'
                type_text('Odpowiedź z centrum')
                notify_reply('Aktualizacja centrum', app='Another application', reply=False)
                wait(lambda: card(uid) and card(uid)['focused'])
                assert card(uid)['draft'] == 'Odpowiedź z centrum'
                escape(); wait(lambda: card(uid) and not card(uid)['editor'])
                assert state()['open'], 'First Escape should cancel only the reply'
                open_reply(uid); type_text('Wysłane przez Enter')
                subprocess.run(['wtype', '-k', 'Return'], env=env, check=True, timeout=5)
                wait(lambda: 'Wysłane przez Enter' in (work / 'reply-signals.log').read_text())
                wait(lambda: card(uid) and not card(uid)['editor'])
                assert not card(uid)['draft'] and state()['open']
                uid = notify_reply('Zamknięta przez nadawcę')
                open_reply(uid); type_text('Szkic przed zamknięciem')
                nid = next(r['serverId'] for r in replies()['records'] if r['uid'] == uid)
                subprocess.run(['gdbus', 'call', '--session', '--dest', 'org.freedesktop.Notifications',
                    '--object-path', '/org/freedesktop/Notifications', '--method',
                    'org.freedesktop.Notifications.CloseNotification', str(nid)],
                    env=env, check=True, capture_output=True, timeout=5)
                wait(lambda: card(uid) and not card(uid)['editor'])
                assert not card(uid)['draft'] and not card(uid)['available'] and state()['open'], (card(uid), state())
                escape(); closed()
                call('clear')
                uid = notify_reply('Długa wiadomość', body='Długa treść powiadomienia.\n' * 70)
                open_reply(uid)
                wait(lambda: 0 < card(uid)['input'][1] < card(uid)['cancel'][1] < 700)
                time.sleep(.3)
                assert 0 < card(uid)['input'][1] < card(uid)['cancel'][1] < 700, card(uid)
                escape(); wait(lambda: card(uid) and not card(uid)['editor'])
                call('open'); time.sleep(.3)
                open_reply(uid)
                wait(lambda: 0 < card(uid)['input'][1] < card(uid)['cancel'][1] < 700)
                time.sleep(.3)
                assert 0 < card(uid)['input'][1] < card(uid)['cancel'][1] < 700, card(uid)
                escape(); escape(); closed()
                time.sleep(.35)
                history = (work / 'state/quickshell-de/notifications.json').read_text()
                assert all(text not in history for text in (draft, 'Odpowiedź z centrum', 'Wysłane przez Enter', 'Szkic'))
                report['reply_checks'] = 'native focus, send/Enter, cancel/Escape, drafts across updates, pause, DND, center and private history'
                stop(monitor); signal_log.close()
            report['after'] = measure()
            warnings = [line for line in (work / 'shell.log').read_text().splitlines()
                if re.search(r'WARN|ERROR|TypeError:|ReferenceError:|Binding loop', line)
                and not any(expected in line for expected in ('Failed to register with host portal',
                    'PulseAudioService: pa_context_connect() failed',
                    # Quickshell 0.3.1 warns on a valid replacement containing
                    # the same inline-reply action (upstream notification.cpp).
                    'sent an action set with duplicate inline-reply actions.',
                    'QSoundEffect: playback of this format is not supported on the selected audio device'))]
            assert not warnings, warnings
            report.update(passed=True, cycles=args.cycles, warnings=warnings)
    finally:
        stop(monitor); stop(proc); stop(comp); stop(bus)
        report['production_unchanged'] = before_production == production_state(parent_socket)
        (work / 'result.json').write_text(json.dumps(report, indent=2))
        print(json.dumps(report, indent=2), flush=True)
        assert report['production_unchanged']


if __name__ == '__main__':
    run()
