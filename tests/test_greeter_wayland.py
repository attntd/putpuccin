#!/usr/bin/env python3
"""Private native UI with fake greetd; never loads PAM or a lock service."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import socket
import struct
import subprocess
import tempfile
import time
from test_lockscreen_wayland import ipc, production_state, wait, stop


def run():
    parser = argparse.ArgumentParser()
    parser.add_argument('--bundle', type=Path, required=True)
    parser.add_argument('--test-module', type=Path, required=True)
    parser.add_argument('--cycles', type=int, default=20)
    parser.add_argument('--reader-cycles', type=int, default=None)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    work = Path(tempfile.mkdtemp(prefix='qgreeter-'))
    print('WORK', work, flush=True)
    shell = work / 'shell'
    shutil.copytree(args.bundle, shell)
    shutil.copy2(args.test_module / 'libgreetdclient.so', shell / 'integrations/GreeterNative/libgreetdclient.so')
    assert b'QUICKSHELL_GREETER_TEST_ONLY_PEER' in (shell / 'integrations/GreeterNative/libgreetdclient.so').read_bytes()
    (shell / 'shell.qml').write_text((root / 'tests/fixtures/greeter-wayland.qml').read_text())
    service = shell / 'GreeterService.qml'
    service.write_text(service.read_text().replace('id: root',
        'id: root\n    property var reviewWindows: []\n    property var reviewClient: client', 1))
    window = shell / 'GreeterWindow.qml'
    window.write_text(window.read_text().replace('id: window', 'id: window\n    Component.onCompleted: GreeterService.reviewWindows.push(window)', 1)
        .replace('id: view', 'id: view\n        objectName: "reviewView"', 1))
    avatar = shell / 'assets/avatars/alice.png'
    shutil.copy2(next((shell / 'assets/avatars').glob('*.png')), avatar)
    (shell / 'users').write_text('#!/usr/bin/python3\nimport json\nprint(json.dumps(' + repr({
        'version': 1, 'defaultUser': 'alice', 'users': [
            {'username': 'alice', 'displayName': 'Alicja', 'fingerprint': False, 'avatar': True},
            {'username': 'bob', 'displayName': 'Bartosz', 'fingerprint': True, 'avatar': False}]}) + '))\n')
    settings = shell / 'core/Settings.qml'
    settings.write_text(settings.read_text().replace('Singleton {', 'Singleton {\n    readonly property string lockAvatarPath: ' + json.dumps(str(avatar))))
    (shell / 'modules/lockscreen').mkdir(parents=True)
    shutil.copy2(root / 'modules/lockscreen/LockView.qml', shell / 'modules/lockscreen/LockView.qml')
    (shell / 'modules/lockscreen/qmldir').write_text('module qs.modules.lockscreen\nLockView 1.0 LockView.qml\n')
    assert not (shell / 'services').exists()
    assert not any('import Quickshell.Services.Pam' in path.read_text() for path in shell.rglob('*.qml'))
    runtime = work / 'r'; runtime.mkdir(mode=0o700)
    parent_runtime = Path(os.environ['XDG_RUNTIME_DIR'])
    parent = parent_runtime / 'hypr' / os.environ['HYPRLAND_INSTANCE_SIGNATURE'] / '.socket.sock'
    before_desktop = production_state(parent)
    host_failures = Path('/var/run/faillock') / os.environ['USER']
    def tally():
        return (hashlib.sha256(host_failures.read_bytes()).hexdigest(), host_failures.stat().st_mtime_ns) if host_failures.exists() else None
    before_tally = tally()
    display = Path(os.environ['WAYLAND_DISPLAY'])
    if not display.is_absolute(): display = parent_runtime / display
    env = dict(os.environ, XDG_RUNTIME_DIR=str(runtime), XDG_CONFIG_HOME=str(work / 'config'),
        XDG_CACHE_HOME=str(work / 'cache'), XDG_STATE_HOME=str(work / 'state'), XDG_DATA_HOME=str(work / 'data'),
        WAYLAND_DISPLAY=str(display), DISPLAY='', HYPRLAND_INSTANCE_SIGNATURE='',
        LIBSEAT_BACKEND='seatd', SEATD_SOCK=str(work / 'missing'), AQ_DRM_DEVICES=str(work / 'missing'),
        HYPRLAND_NO_SD_VARS='1', HYPRLAND_NO_SD_NOTIFY='1', HYPRLAND_NO_CRASHREPORTER='1', HYPRLAND_NO_RT='1',
        QT_QPA_PLATFORM='wayland', QT_QPA_PLATFORMTHEME='', NO_AT_BRIDGE='1', GSETTINGS_BACKEND='memory',
        GREETD_SOCK=str(work / 'greetd.sock'), QML_IMPORT_PATH=str(shell / 'integrations'))
    for key in ('NOTIFY_SOCKET', 'LISTEN_FDS', 'LISTEN_PID', 'WAYLAND_SOCKET', 'QT_SCALE_FACTOR'):
        env.pop(key, None)
    bus_config = work / 'bus.conf'
    bus_config.write_text('<busconfig><type>session</type><listen>unix:tmpdir=/tmp</listen>'
        '<policy context="default"><allow send_destination="*"/><allow receive_sender="*"/><allow own="*"/></policy></busconfig>')
    config = work / 'hyprland.lua'
    # Validate the production compositor settings too, without its session launcher.
    compositor_config = (args.bundle / 'hyprland.lua').read_text()
    launch_command = 'hl.exec_cmd("/usr/local/libexec/quickshell-greeter/ui")'
    assert compositor_config.count(launch_command) == 1, 'Unknown greeter launcher; refusing to start it'
    config.write_text(compositor_config.replace(launch_command, '') + '''
hl.monitor({output="WAYLAND-1", disabled=true})
hl.monitor({output="LOGIN-A", mode="1280x720@60", position="0x0", scale=1})
hl.monitor({output="LOGIN-B", mode="1440x900@60", position="1280x0", scale=1.2})
''')
    compositor = work / 'compositor'
    compositor.write_text((args.bundle / 'compositor').read_text().replace(
        '/usr/local/share/quickshell-greeter/hyprland.lua', str(config)))
    compositor.chmod(0o755)
    # The actual production watchdog launcher, with only its fixed config path
    # redirected to this private compositor. PAM and the production UI stay absent.
    env.pop('XDG_CURRENT_DESKTOP', None)
    pointer_source = work / 'pointer.c'
    # Virtual pointer coordinates refer to the entire 2480x750 logical layout.
    pointer_source.write_text((root / 'tests/fixtures/virtual-pointer.c').read_text().replace('1280u, 720u', '2480u, 750u'))
    pointer = work / 'pointer'
    flags = shlex.split(subprocess.check_output(['pkg-config', '--cflags', '--libs', 'wayland-client'], text=True))
    subprocess.run(['cc', '-O2', '-o', str(pointer), str(pointer_source), *flags], check=True)
    listener = socket.socket(socket.AF_UNIX); listener.bind(env['GREETD_SOCK']); listener.listen(1); listener.settimeout(10)
    bus = comp = proc = peer = None
    result = {'passed': False, 'work': str(work), 'checks': []}
    try:
        bus = subprocess.Popen(['dbus-daemon', '--config-file=' + str(bus_config), '--nofork', '--print-address=1'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        address = bus.stdout.readline().strip()
        env.update(DBUS_SESSION_BUS_ADDRESS=address, DBUS_SYSTEM_BUS_ADDRESS=address)
        with (work / 'compositor.log').open('w') as compositor_log, (work / 'shell.log').open('w') as shell_log:
            comp = subprocess.Popen(['start-hyprland', '--no-nixgl', '--path', str(compositor)],
                env=env, stdout=compositor_log, stderr=compositor_log)
            child = wait(lambda: next((runtime / 'hypr').glob('*/.socket.sock'), None))
            assert child != parent and child.is_relative_to(runtime)
            for name in ('LOGIN-A', 'LOGIN-B'): assert ipc(child, 'output create headless ' + name).strip() == 'ok'
            wait(lambda: len(json.loads(ipc(child, 'j/monitors'))) == 2)
            assert not ipc(child, 'configerrors').strip(), ipc(child, 'configerrors')
            env.update(WAYLAND_DISPLAY=str(runtime / 'wayland-1'), HYPRLAND_INSTANCE_SIGNATURE=child.parent.name)
            proc = subprocess.Popen(['qs', '-p', str(shell), '--no-color'], env=env, stdout=shell_log, stderr=shell_log)
            peer, _ = listener.accept(); peer.settimeout(3)
            def call(method, *args):
                assert proc.poll() is None, (work / 'shell.log').read_text()
                response = subprocess.run(['qs', 'ipc', '--pid', str(proc.pid), 'call', 'greetertest', method,
                    *[str(arg).lower() if isinstance(arg, bool) else str(arg) for arg in args]], env=env, capture_output=True, text=True, timeout=5)
                if response.returncode: raise RuntimeError(response.stderr)
                return response.stdout.strip()
            def state(): return json.loads(call('state'))
            def read_exact(size):
                data = b''
                while len(data) < size:
                    chunk = peer.recv(size - len(data)); assert chunk
                    data += chunk
                return data
            def receive(kind):
                value = json.loads(read_exact(struct.unpack('=I', read_exact(4))[0]))
                assert value['type'] == kind, value
                return value
            def reply(value):
                data = json.dumps(value).encode(); peer.sendall(struct.pack('=I', len(data)) + data)
            def prompt(style='secret', text='Password:'):
                reply({'type': 'auth_message', 'auth_message_type': style, 'auth_message': text})
            def click(point): subprocess.run([str(pointer), *map(str, map(round, point)), 'click'], env=env, check=True, timeout=5)
            def key(name): subprocess.run(['wtype', '-k', name], env=env, check=True, timeout=5)
            # Let the newly created virtual keyboard/keymap reach Qt before
            # sending its first key; the production keyboard already exists.
            def type_text(value): subprocess.run(['wtype', '-s', '100', value], env=env, check=True, timeout=5)
            def primary(): return next(window for window in state()['windows'] if window['screen'] == 'LOGIN-A')
            def capture(name, comparison=False):
                path = work / (name + '.png'); call('captureComparison' if comparison else 'capture', path)
                wait(lambda: path.exists() and path.read_bytes().endswith(b'IEND\xaeB`\x82')); return path
            def identical(a, b):
                result = subprocess.run(['magick', 'compare', '-metric', 'AE', str(a), str(b), 'null:'], capture_output=True, text=True)
                return result.returncode == 0
            def measure():
                def stats():
                    data = Path(f'/proc/{proc.pid}/stat').read_text().rsplit(')', 1)[1].split()
                    return sum(map(int, data[11:13])), int(data[21]) * os.sysconf('SC_PAGE_SIZE') // 1024
                a = stats(); start = time.monotonic(); time.sleep(1); b = stats()
                return {'cpu_percent': round(100 * (b[0] - a[0]) / os.sysconf('SC_CLK_TCK') / (time.monotonic() - start), 2), 'rss_kib': b[1]}
            wait(lambda: state()['available'] and len(state()['windows']) == 2)
            time.sleep(.6)
            # First input must work before any pointer event, on the surface
            # selected by the compositor (not necessarily the first output).
            initial = state()['windows']
            assert all(window['fieldVisible'] for window in initial)
            result['initial_input'] = initial
            type_text('first-input')
            result['typed_input'] = state()['windows']
            # Multiple windows can retain an active QML focus item; Wayland
            # chooses which surface receives this seat's actual key events.
            wait(lambda: sorted(window['length'] for window in state()['windows']) == [0, 11])
            key('Escape')
            wait(lambda: all(window['length'] == 0 for window in state()['windows']))
            result['checks'].append('typing works at startup without clicking on either output')
            for window in state()['windows']:
                assert window['hiddenCursor'] and window['frameSize'] == [320, 48]
                assert abs(window['groupCenter'] - window['height'] / 2) < .01
            result['layout'] = state()['windows']
            # The same final raster for the real LockView wrapper and greeter view.
            call('compare', False); time.sleep(.4); lock_image = capture('lock-view', True)
            call('compare', True); time.sleep(.4); login_image = capture('login-view', True)
            assert identical(lock_image, login_image)
            call('endComparison'); click(primary()['field']); type_text('synthetic-caret-test')
            time.sleep(.6); first = capture('caret-0')
            for index in range(1, 4):
                time.sleep(.4)
                assert identical(first, capture('caret-' + str(index)))
            key('Escape'); wait(lambda: primary()['length'] == 0)
            result['checks'].append('identical lock/greeter raster, fully hidden stable caret on both scales')
            result['before'] = measure()
            result['cycle_rss_kib'] = []
            for cycle in range(args.cycles):
                click(primary()['avatar']); wait(lambda: state()['picker'])
                if cycle % 2: key('Escape')
                else: key('Return')
                wait(lambda: not state()['picker'] and primary()['focused'])
                type_text('wrong-synthetic-secret'); key('Return')
                assert receive('create_session')['username'] == 'alice'
                prompt()
                assert receive('post_auth_message_response')['response'] == 'wrong-synthetic-secret'
                reply({'type': 'error', 'error_type': 'auth_error', 'description': 'Synthetic rejection'})
                receive('cancel_session'); reply({'type': 'success'})
                wait(lambda: state()['client'] == 'idle' and not state()['busy'])
                assert all(window['length'] == 0 for window in state()['windows'])
                result['cycle_rss_kib'].append(measure()['rss_kib'])
            result['after'] = measure()
            result['checks'].append(str(args.cycles) + ' picker and rejected-password cycles without automatic retry')
            # Keyboard user switch; Bob starts one fingerprint conversation.
            click(primary()['field']); key('Tab'); wait(lambda: state()['picker']); key('Down'); key('Return')
            wait(lambda: state()['user'] == 'bob' and not state()['picker'])
            assert receive('create_session')['username'] == 'bob'
            # Idle expiration renews only at the PAM cancellation boundary;
            # preserve typed characters and keep accepting input while ACK waits.
            result['reader_cycle_rss_kib'] = []
            reader_cycles = args.cycles if args.reader_cycles is None else args.reader_cycles
            for cycle in range(reader_cycles):
                prompt('info', 'Place your finger on the fingerprint reader')
                assert 'response' not in receive('post_auth_message_response')
                type_text('a')
                for attempt in range(2):
                    prompt('info', 'Weryfikacja przekroczyła czas oczekiwania')
                    assert 'response' not in receive('post_auth_message_response')
                    prompt('info', 'GREETER_FINGERPRINT_ERROR')
                    assert 'response' not in receive('post_auth_message_response')
                prompt('info', 'GREETER_FINGERPRINT_DONE')
                receive('cancel_session')
                assert not state()['busy'] and primary()['inputEnabled']
                type_text('b')
                assert primary()['length'] == 2 * (cycle + 1)
                reply({'type': 'success'})
                assert receive('create_session')['username'] == 'bob'
                result['reader_cycle_rss_kib'].append(measure()['rss_kib'])
            key('Escape')
            result['checks'].append(str(reader_cycles) + ' idle reader renewals without clicks or lost typing')
            # Enter stops renewal and releases the queued password to the next
            # secret prompt; the reader timeout is not a password failure.
            prompt('info', 'Place your finger on the fingerprint reader')
            assert 'response' not in receive('post_auth_message_response')
            type_text('synthetic-timeout-secret'); key('Return')
            for attempt in range(2):
                prompt('info', 'Verification timed out')
                assert 'response' not in receive('post_auth_message_response')
                prompt('info', 'GREETER_FINGERPRINT_ERROR')
                assert 'response' not in receive('post_auth_message_response')
            prompt('info', 'GREETER_FINGERPRINT_DONE')
            assert 'response' not in receive('post_auth_message_response')
            prompt()
            assert receive('post_auth_message_response')['response'] == 'synthetic-timeout-secret'
            reply({'type': 'error', 'error_type': 'auth_error', 'description': 'Synthetic rejection'})
            receive('cancel_session'); reply({'type': 'success'})
            wait(lambda: state()['client'] == 'idle' and not state()['busy'])
            call('fingerprint'); receive('create_session')
            prompt('info', 'Place your finger on the fingerprint reader')
            assert 'response' not in receive('post_auth_message_response')
            prompt('info', 'Weryfikacja przekroczyła czas oczekiwania')
            assert 'response' not in receive('post_auth_message_response')
            prompt('info', 'GREETER_FINGERPRINT_ERROR')
            assert 'response' not in receive('post_auth_message_response')
            assert state()['message'] != 'błąd czytnika', 'A timeout is not a device failure'
            # A device failure is shown inside the existing field, hidden as
            # soon as the first password character is typed, with no extra UI.
            prompt('info', 'GREETER_FINGERPRINT_ERROR')
            assert 'response' not in receive('post_auth_message_response')
            wait(lambda: primary()['errorVisible'] and primary()['errorText'] == 'błąd czytnika')
            prompt('info', 'GREETER_FINGERPRINT_DONE')
            assert 'response' not in receive('post_auth_message_response'), 'Device errors must not cause an idle retry'
            capture('reader-error')
            type_text('x'); wait(lambda: primary()['length'] == 1 and not primary()['errorVisible'])
            capture('reader-error-typing')
            key('Escape'); wait(lambda: primary()['errorVisible'])
            # Retry is in the same PAM transaction: queued passwords stay secret.
            prompt('info', 'Place your finger on the fingerprint reader')
            assert 'response' not in receive('post_auth_message_response')
            type_text('queued-synthetic-secret'); key('Return'); wait(lambda: state()['queued'] > 0)
            # A visible challenge may never receive a password queued for a secret challenge.
            prompt('visible', 'Synthetic visible challenge')
            wait(lambda: state()['echo'] and state()['queued'] == 0 and not state()['busy'])
            assert all(window['length'] == 0 for window in state()['windows'])
            call('choose', 0); receive('cancel_session'); reply({'type': 'success'})
            wait(lambda: state()['client'] == 'idle' and not state()['echo'])
            # Password success while switching users is stale and must not launch.
            click(primary()['field']); type_text('synthetic-secret'); key('Return'); receive('create_session')
            call('choose', 1); reply({'type': 'success'})
            receive('cancel_session'); reply({'type': 'success'})
            assert receive('create_session')['username'] == 'bob'
            assert not state()['accepted']
            # Simulated fingerprint success: only now may the allowlisted session launch.
            reply({'type': 'success'})
            launch = receive('start_session')
            assert launch['cmd'] == ['/usr/bin/uwsm', 'start', '-e', '-D', 'Hyprland', 'hyprland.desktop']
            assert all(window['fieldVisible'] and window['fingerprintVisible']
                       and not window['inputEnabled'] and window['length'] == 0
                       for window in state()['windows'])
            capture('login-success')
            reply({'type': 'success'}); wait(lambda: state()['client'] == 'launched')
            result['checks'].append('keyboard user switch, visible challenge secrecy, stale success rejection, fingerprint handoff')
            logs = (work / 'shell.log').read_text()
            assert 'synthetic-secret' not in logs and 'synthetic-caret-test' not in logs
            assert not re.search(r'ReferenceError|TypeError|Binding loop|Unable to assign|is not a type|ERROR:', logs), logs
            compositor_messages = (work / 'compositor.log').read_text()
            assert 'being launched without start-hyprland' not in compositor_messages
            assert 'Emergency mode tripped' not in compositor_messages
            assert 'XDG_CURRENT_DESKTOP' not in compositor_messages or 'externally' not in compositor_messages
            result['checks'].append('watchdog startup without warnings; reader error inside field disappears on typing')
            result['passed'] = True
    finally:
        stop(proc); stop(comp); stop(bus)
        if peer: peer.close()
        listener.close()
        result['desktop_unchanged'] = production_state(parent) == before_desktop
        result['host_faillock_unchanged'] = tally() == before_tally
        (work / 'result.json').write_text(json.dumps(result, indent=2))
        print(json.dumps(result, indent=2), flush=True)
        assert result['desktop_unchanged'] and result['host_faillock_unchanged']


if __name__ == '__main__': run()
