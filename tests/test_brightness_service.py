#!/usr/bin/env python3
"""Actual QML service and transition helper against a disposable backlight.

No host sysfs writes, logind, compositor, lockscreen or PAM are used.
"""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time


if os.environ.get('QS_BRIGHTNESS_PRIVATE_BUS') != '1':
    with tempfile.TemporaryDirectory(prefix='quickshell-brightness-bus-') as directory:
        conf = Path(directory) / 'bus.conf'
        conf.write_text('''<busconfig><type>session</type><listen>unix:tmpdir=/tmp</listen>
<policy context="default"><allow send_destination="*"/><allow receive_sender="*"/>
<allow own="*"/></policy></busconfig>''')
        raise SystemExit(subprocess.call(['dbus-run-session', '--config-file', str(conf),
            '--', sys.executable, __file__], env=dict(os.environ, QS_BRIGHTNESS_PRIVATE_BUS='1')))

root = Path(__file__).resolve().parents[1]
work = Path(tempfile.mkdtemp(prefix='quickshell-brightness-service-'))
config = work / 'shell'
for directory, names in {
    'core': ['Motion'],
    'services': ['BrightnessService', 'OsdService'],
}.items():
    target = config / directory
    target.mkdir(parents=True)
    for name in names:
        shutil.copy2(root / directory / (name + '.qml'), target / (name + '.qml'))
    (target / 'qmldir').write_text('module qs.' + directory + '\n' + ''.join(
        f'singleton {name} 1.0 {name}.qml\n' for name in names))


def stub(directory, name, body):
    (config / directory / (name + '.qml')).write_text(
        'pragma Singleton\nimport Quickshell\nSingleton {\n' + body + '\n}\n')
    with (config / directory / 'qmldir').open('a') as stream:
        stream.write(f'singleton {name} 1.0 {name}.qml\n')


stub('core', 'SurfaceManager', 'function focusedScreenName() { return "brightness-test"; }')
stub('services', 'AudioService', '''property bool available: false
property bool muted: false
property real volume: 0
property bool sourceAvailable: false
property bool sourceMuted: false
property real sourceVolume: 0''')
shutil.copy2(root / 'tests/fixtures/brightness-service.qml', config / 'shell.qml')
bin_dir = work / 'bin'
bin_dir.mkdir()
scripts = config / 'scripts'
scripts.mkdir()
shutil.copy2(root / 'scripts/brightness-transition', scripts / 'transition.py')
backlight = work / 'backlight' / 'test'
backlight.mkdir(parents=True)
(backlight / 'max_brightness').write_text('496')
(backlight / 'brightness').write_text('20')


def executable(path, body):
    path.write_text('#!/usr/bin/env python3\n' + body)
    path.chmod(0o755)


executable(bin_dir / 'brightnessctl', '''import os
from pathlib import Path
p = Path(os.environ['QS_BRIGHTNESS_FIXTURE']) / 'backlight' / 'test'
raw = int((p / 'brightness').read_text())
maximum = int((p / 'max_brightness').read_text())
print(f'test,backlight,{raw},{round(raw * 100 / maximum)}%,{maximum}')
''')
executable(bin_dir / 'udevadm', 'import signal\nsignal.pause()\n')
executable(scripts / 'brightness-transition', '''import os
from pathlib import Path
import sys
from transition import transition
work = Path(os.environ['QS_BRIGHTNESS_FIXTURE'])
with (work / 'requests').open('a') as log:
    log.write(' '.join(sys.argv[1:]) + '\\n')
def apply(raw):
    path = work / 'backlight' / 'test' / 'brightness'
    pending = path.with_suffix('.new')
    pending.write_text(str(raw))
    pending.replace(path)
    with (work / 'writes').open('a') as log:
        log.write(str(raw) + '\\n')
transition(sys.argv[1], float(sys.argv[2]), float(sys.argv[3]) / 1000,
    sys_root=work / 'backlight', apply=apply)
''')
runtime = work / 'runtime'
runtime.mkdir(mode=0o700)
env = dict(os.environ, QT_QPA_PLATFORM='offscreen', QT_QPA_PLATFORMTHEME='',
    WAYLAND_DISPLAY='', DISPLAY='', HYPRLAND_INSTANCE_SIGNATURE='',
    XDG_RUNTIME_DIR=str(runtime), XDG_CONFIG_HOME=str(work / 'config'),
    XDG_CACHE_HOME=str(work / 'cache'), XDG_STATE_HOME=str(work / 'state'),
    XDG_DATA_HOME=str(work / 'data'), DBUS_SYSTEM_BUS_ADDRESS=os.environ['DBUS_SESSION_BUS_ADDRESS'],
    QS_BRIGHTNESS_FIXTURE=str(work), PATH=str(bin_dir) + ':' + os.environ['PATH'])

with (work / 'shell.log').open('w') as log:
    proc = subprocess.Popen(['qs', '-p', str(config), '--no-color'], env=env, stdout=log, stderr=log)

    def ipc(target, method, *args):
        result = subprocess.run(['qs', 'ipc', '--pid', str(proc.pid), 'call', target, method,
            *map(str, args)], env=env, text=True, capture_output=True, timeout=5)
        assert result.returncode == 0, (result.stdout, result.stderr, str(work))
        return result.stdout.strip()

    def snapshot():
        return json.loads(ipc('brightnesstest', 'snapshot'))

    def wait_for(check, timeout=5):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            assert proc.poll() is None, (work / 'shell.log').read_text()
            try:
                value = check()
                if value:
                    return value
            except (AssertionError, json.JSONDecodeError):
                pass
            time.sleep(.02)
        raise AssertionError(('timeout', str(work), snapshot()))

    def settled(raw):
        def check():
            state = snapshot()
            return state if state['state'] == 'ready' and not state['pending'] and state['raw'] == raw else None
        return wait_for(check)

    def adjust(delta, raw):
        ipc('brightness', 'adjust', delta)
        return settled(raw)

    try:
        settled(20)
        minimum = adjust(-5, 5)
        assert minimum['percentage'] > 1 and round(minimum['percentage']) == 1, minimum
        off = adjust(-5, 0)
        assert off['percentage'] == off['slider'] == off['target'] == off['osd'] == 0, off
        assert off['osdKind'] == 'brightness', off
        adjust(-5, 0)
        restored = adjust(5, 5)
        assert restored['percentage'] > 0 and restored['osd'] > 0, restored

        ipc('brightness', 'set', 6)
        settled(30)
        ipc('brightnesstest', 'rapid')
        rapid = settled(5)
        time.sleep(.5)
        assert snapshot()['raw'] == 5 and not snapshot()['pending'], snapshot()

        for maximum, initial, minimum_raw in ((255, 30, 3), (10, 5, 1), (496, 20, 5)):
            (backlight / 'max_brightness').write_text(str(maximum))
            (backlight / 'brightness').write_text(str(initial))
            ipc('brightnesstest', 'refresh')
            settled(initial)
            adjust(-100, minimum_raw)
            adjust(-5, 0)
            adjust(5, minimum_raw)

        # Repeated zero/restoration must finish without a retry loop or a
        # stale helper restoring the previous nonzero target after exit.
        cycles = []
        for cycle in range(20):
            cycles.append([adjust(-5, 0)['raw'], adjust(5, 5)['raw']])
        ipc('brightness', 'set', 0)
        settled(0)
        request_count = len((work / 'requests').read_text().splitlines())
        ipc('brightnesstest', 'invalid')
        time.sleep(1)
        assert len((work / 'requests').read_text().splitlines()) == request_count, 'Idle retry loop or invalid command'
        final = snapshot()
        assert final['state'] == 'ready' and final['raw'] == 0 and not final['pending'] and not final['error'], final
        assert all(raw >= 0 for raw in map(int, (work / 'writes').read_text().splitlines()))
        assert not re.search(r'WARN scene|ReferenceError:|TypeError:|Binding loop', (work / 'shell.log').read_text())
        result = dict(passed=True, minimum=minimum, off=off, restored=restored,
            rapid=rapid, cycles=cycles, final=final)
        (work / 'result.json').write_text(json.dumps(result, indent=2))
        print(json.dumps(dict(artifacts=str(work), **result), indent=2))
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=3)
