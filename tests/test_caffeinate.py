#!/usr/bin/env python3
"""Actual Caffeinate service and quick-settings UI, with isolated device stubs."""
import json
import os
from pathlib import Path
from caffeinate_bus import PrivateLogind
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
WORK = Path(tempfile.mkdtemp(prefix='quickshell-caffeinate-test-'))
CONFIG = WORK / 'shell'
for directory, names in {
    'core': ['Theme', 'Metrics', 'Motion', 'Strings', 'Icons'],
    'components': ['ActionButton', 'PopupFrame', 'RevealSection', 'StatusSlider'],
    'popups': ['QuickSettingsPopup'],
    'modules/osd': ['LevelOsd'],
    'services': ['CaffeinateService', 'OsdService'],
}.items():
    target = CONFIG / directory
    target.mkdir(parents=True)
    entries = [f'module qs.{directory.replace("/", ".")}']
    for name in names:
        shutil.copy2(ROOT / directory / f'{name}.qml', target / f'{name}.qml')
        entries.append(f'{"singleton " if directory in ("core", "services") else ""}{name} 1.0 {name}.qml')
    (target / 'qmldir').write_text('\n'.join(entries) + '\n')

if baseline := os.environ.get('QS_QUICK_ICONS_BASELINE'):
    for name in ('popups/QuickSettingsPopup.qml', 'modules/osd/LevelOsd.qml'):
        shutil.copy2(Path(baseline) / name, CONFIG / name)

def stub(directory, name, body):
    (CONFIG / directory / f'{name}.qml').write_text('pragma Singleton\nimport QtQuick\nimport Quickshell\nSingleton {\n' + body + '\n}\n')
    with (CONFIG / directory / 'qmldir').open('a') as f:
        f.write(f'singleton {name} 1.0 {name}.qml\n')

stub('core', 'Settings', 'property bool reducedMotion: false\nproperty real surfaceOpacity: 0.9\nproperty real interactiveOpacity: 0')
stub('core', 'SurfaceManager', 'property int closed: 0\nfunction closeOn(screenName) { closed++; }\nfunction focusedScreenName() { return "caffeinate-test"; }')
stub('services', 'AudioService', '''property bool sourceMuted: false
property bool sourceAvailable: true
property bool available: true
property bool muted: false
property real volume: 0.4
property string errorMessage: ""
function toggleSourceMute() { sourceMuted = !sourceMuted; }
function toggleMute() { muted = !muted; } function setVolume(value) {}''')
stub('services', 'BrightnessService', '''property bool available: true
property real percentage: 50
property real sliderPercentage: 50
property string errorMessage: ""
function setPercentage(value) {}''')
stub('services', 'NetworkService', '''property bool available: true
property bool wifiEnabled: true
property string errorMessage: ""
function setWifiEnabled(value) {}''')
stub('services', 'BluetoothService', '''property bool available: true
property bool enabled: true
property string state: "ready"
property string errorMessage: ""
function setEnabled(value) {}''')
stub('services', 'NotificationService', 'property bool dnd: false\nfunction toggleDnd() { dnd = !dnd; }')
stub('services', 'ScreenshotService', 'property string errorMessage: ""\nfunction begin(mode, screenName) {}')
stub('services', 'LockService', 'property bool locked: false\nproperty bool releasing: false')
(WORK / 'runtime').mkdir(mode=0o700)
bus = PrivateLogind(WORK)
shutil.copytree(ROOT / 'integrations/SessionNative', CONFIG / 'integrations/SessionNative')
shutil.copy2(ROOT / 'tests/fixtures/caffeinate.qml', CONFIG / 'shell.qml')
env = dict(os.environ, QT_QPA_PLATFORM='offscreen', QT_QPA_PLATFORMTHEME='', NO_AT_BRIDGE='1',
           WAYLAND_DISPLAY='', HYPRLAND_INSTANCE_SIGNATURE='', DBUS_SESSION_BUS_ADDRESS=bus.address,
           DBUS_SYSTEM_BUS_ADDRESS=bus.address, QML_IMPORT_PATH=str(CONFIG / 'integrations'), XDG_RUNTIME_DIR=str(WORK / 'runtime'),
           XDG_CONFIG_HOME=str(WORK / 'config'), XDG_STATE_HOME=str(WORK / 'state'),
           XDG_CACHE_HOME=str(WORK / 'cache'), QS_CAFFEINATE_PROOF=str(WORK),
           PATH=os.environ['PATH'])
if display := os.environ.get('QS_CAFFEINATE_WAYLAND'):
    assert Path(display).is_absolute(), 'Use a private compositor socket by absolute path'
    env.update(QT_QPA_PLATFORM='wayland', WAYLAND_DISPLAY=display)
with (WORK / 'shell.log').open('w') as log:
    proc = subprocess.Popen(['qs', '-p', str(CONFIG), '--no-color'], env=env, stdout=log, stderr=log)
    def ipc(target, method, *args):
        result = subprocess.run(['qs', 'ipc', '--pid', str(proc.pid), 'call', target, method,
                                 *[str(arg).lower() if isinstance(arg, bool) else str(arg) for arg in args]],
                                env=env, text=True, capture_output=True, timeout=30)
        assert result.returncode == 0, (result.stdout, result.stderr, str(WORK))
        return result.stdout.strip()
    def status(): return json.loads(ipc('caffeinate', 'status'))
    def wait_for(check, timeout=5):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            assert proc.poll() is None, str(WORK)
            try:
                if value := check(): return value
            except (AssertionError, json.JSONDecodeError): pass
            time.sleep(.025)
        raise AssertionError(('timeout', str(WORK), (WORK / 'shell.log').read_text()[-4000:]))
    def measure():
        def sample():
            values = (Path('/proc') / str(proc.pid) / 'stat').read_text().split()
            return int(values[13]) + int(values[14]), int(values[23]) * os.sysconf('SC_PAGE_SIZE') // 1024
        ticks, _ = sample()
        start = time.monotonic()
        time.sleep(1)
        after, rss = sample()
        return dict(cpu_percent=round((after-ticks)/os.sysconf('SC_CLK_TCK')/(time.monotonic()-start)*100, 2), rss_kib=rss)
    try:
        wait_for(lambda: ipc('caffeinatetest', 'ready') == 'true')
        if os.environ.get('QS_QUICK_TILES_ONLY') == '1':
            def alpha_image(path):
                data = path.read_bytes()
                assert data[:16] == b'\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR'
                size = struct.unpack('>II', data[16:24])
                pixels = subprocess.run(['magick', 'png:-', '-alpha', 'extract', '-depth', '8', 'gray:-'],
                    input=data, capture_output=True, check=True, timeout=10).stdout
                assert len(pixels) == size[0] * size[1]
                return size, pixels
            before = measure()
            tiles = json.loads(ipc('caffeinatetest', 'tiles'))
            silhouettes = {}
            for name in tiles['iconHeights']:
                on_size, on = alpha_image(WORK / (name + '-on.png'))
                off_size, off = alpha_image(WORK / (name + '-off.png'))
                if on_size != off_size:
                    silhouettes[name] = dict(onSize=on_size, offSize=off_size, passed=False)
                    continue
                width, height = on_size
                # Compare the symbol itself, ignoring its state color and the
                # diagonal band where a 2 px slash plus antialiasing may appear.
                moved = added = foreground = 0
                for y in range(height):
                    for x in range(width):
                        a, b = on[y * width + x], off[y * width + x]
                        scale = height / tiles['iconHeights'][name]
                        diagonal = abs((x + .5 - width / 2) / scale
                            - (y + .5 - height / 2) / scale) <= 3
                        foreground += a > 128
                        moved += not diagonal and abs(a - b) > 8
                        added += diagonal and b - a > 8
                silhouettes[name] = dict(changedOutsideSlash=moved, addedSlashPixels=added,
                    foregroundPixels=foreground, passed=moved == 0 and added >= 5 and foreground >= 10)
            result = dict(artifacts=str(WORK), before=before, after=measure(), silhouettes=silhouettes, **tiles)
            result['passed'] = tiles['passed'] and all(item['passed'] for item in silhouettes.values())
            if 'osd-volume' in tiles['iconHeights']:
                result['sameVolumeGlyph'] = all(alpha_image(WORK / ('volume-' + state + '.png'))
                    == alpha_image(WORK / ('osd-volume-' + state + '.png')) for state in ('on', 'off'))
                result['passed'] = result['passed'] and result['sameVolumeGlyph']
            (WORK / 'tiles-result.json').write_text(json.dumps(result, indent=2))
            print(json.dumps(result, indent=2), flush=True)
            assert result['passed'], 'Quick-settings icon silhouette or content moved while toggling'
            assert not re.search(r'WARN scene|ReferenceError:|TypeError:|Binding loop', (WORK / 'shell.log').read_text())
            sys.exit(0)
        before = measure()
        memory = []
        for cycle in range(int(os.environ.get('QS_CAFFEINATE_CYCLES', 20))):
            result = json.loads(ipc('caffeinatetest', 'run', cycle % 2 == 1))
            assert result['passed'], (result, str(WORK))
            memory.append(int((Path('/proc') / str(proc.pid) / 'stat').read_text().split()[23]) * os.sysconf('SC_PAGE_SIZE') // 1024)
        after = measure()
        failures = {}
        for behavior in ('fail', 'timeout', 'missing', 'malformed'):
            (WORK / 'behavior').write_text(behavior)
            ipc('caffeinate', 'setMode', 'background')
            failures[behavior] = wait_for(lambda: (s if not s['busy'] and s['error'] else None) if (s := status()) else None, 5)
            assert not failures[behavior]['active'] and failures[behavior]['mode'] == 'off'
            (WORK / 'behavior').write_text('ready')
            ipc('caffeinate', 'setMode', 'presentation')
            wait_for(lambda: status()['active'])
            ipc('caffeinate', 'setEnabled', False)
            wait_for(lambda: not status()['busy'])
        (WORK / 'behavior').write_text('slow')
        rapid = json.loads(ipc('caffeinatetest', 'rapid'))
        assert rapid['passed'], (rapid, str(WORK))
        (WORK / 'behavior').write_text('ready')
        assert ipc('caffeinatetest', 'screenshot') == 'true'
        time.sleep(.2)
        assert (WORK / 'modes.png').exists()
        warnings = re.findall(r'^.*(?:WARN scene|ReferenceError:|TypeError:|Binding loop|Failed to load configuration).*$', (WORK / 'shell.log').read_text(), re.M)
        assert not warnings, (warnings, str(WORK))
        result = dict(passed=True, before=before, after=after, rss_per_cycle_kib=memory, failures=failures)
        (WORK / 'result.json').write_text(json.dumps(result, indent=2))
        print(json.dumps(dict(artifacts=str(WORK), **result), indent=2))
    finally:
        proc.terminate()
        try: proc.wait(timeout=3)
        except subprocess.TimeoutExpired: proc.kill(); proc.wait()
        bus.close()
