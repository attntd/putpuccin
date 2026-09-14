#!/usr/bin/env python3
"""Real QML service/popup; only the BlueZ model and native agent are doubled."""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
WORK = Path(tempfile.mkdtemp(prefix='qs-bluetooth-ui-'))
CONFIG = WORK / 'shell'
for directory, names in {
    'core': ['Theme', 'Metrics', 'Motion', 'Strings', 'Icons'],
    'components': ['ActionButton', 'PopupFrame', 'KeyboardNavigation', 'ToggleRow', 'PillSwitch', 'SectionTitle', 'EmptyState'],
    'services': ['BluetoothService'], 'popups': ['BluetoothPopup'],
    'modules/bluetooth': ['BluetoothDeviceList', 'PairingPrompt', 'DeviceDetails', 'DevicePicker'],
}.items():
    target = CONFIG / directory
    target.mkdir(parents=True)
    entries = ['module qs.' + directory.replace('/', '.')]
    for name in names:
        source = (ROOT / directory / (name + '.qml')).read_text()
        if name == 'BluetoothService':
            source = source.replace('import Quickshell.Bluetooth', 'import qs.audit').replace('import BluetoothNative', '')
        (target / (name + '.qml')).write_text(source)
        entries.append(('singleton ' if directory in ('core', 'services') else '') + name + ' 1.0 ' + name + '.qml')
    (target / 'qmldir').write_text('\n'.join(entries) + '\n')

def stub(directory, name, body, singleton=True):
    target = CONFIG / directory
    target.mkdir(exist_ok=True)
    (target / (name + '.qml')).write_text(('pragma Singleton\n' if singleton else '') +
        'import QtQuick\nimport Quickshell\n' + ('Singleton' if singleton else 'QtObject') + ' {\n' + body + '\n}\n')
    with (target / 'qmldir').open('a') as output:
        output.write(('singleton ' if singleton else '') + name + ' 1.0 ' + name + '.qml\n')

stub('core', 'Settings', 'property bool reducedMotion: false\nproperty real surfaceOpacity: 0.9\nproperty real interactiveOpacity: 0')
stub('core', 'SurfaceManager', 'function isOpen(surface, screen) { return true; }')
stub('audit', 'BluetoothAdapterState', 'enum Value { Disabled, Enabled, Enabling, Disabling, Blocked }')
stub('audit', 'BluetoothDeviceState', 'enum Value { Disconnected, Connected, Disconnecting, Connecting }')
stub('audit', 'Fixture', 'property var agent: null\nproperty var actions: null\nproperty bool holdAction: false\nproperty string nextPrompt: "confirmation"')
stub('audit', 'PairingAgent', '''id: root
    property bool busy: false
    property string devicePath: ""
    property string phase: ""
    property string prompt: ""
    property string code: ""
    property int entered: 0
    property int requestId: 0
    signal finished(string path, string error, string stage, bool paired)
    Component.onCompleted: Fixture.agent = root
    function start(path) {
        if (busy) return false;
        devicePath = path; busy = true; phase = "pairing";
        prompt = Fixture.nextPrompt;
        code = ["confirmation", "displayPin", "displayPasskey"].indexOf(prompt) >= 0 ? "000042" : "";
        requestId++;
        return true;
    }
    function complete(error, paired) {
        const path = devicePath; busy = false; devicePath = "";
        prompt = ""; code = ""; requestId++; phase = "";
        finished(path, error, "pairing", paired);
    }
    function respond(id, value) { if (id !== requestId) return false; complete("", true); return true; }
    function cancel() { if (busy) complete("canceled", false); }
''', singleton=False)
stub('audit', 'DeviceActions', '''id: root
    property bool busy: false
    property string devicePath: ""
    property string operation: ""
    property string value: ""
    property int calls: 0
    signal finished(string path, string operation, string error)
    Component.onCompleted: Fixture.actions = root
    function start(action, path, name) {
        if (busy) return false;
        calls++; devicePath = path; operation = action; value = name || ""; busy = true;
        if (!Fixture.holdAction) Qt.callLater(() => complete(""));
        return true;
    }
    function complete(error) {
        const path = devicePath, action = operation;
        const device = Bluetooth.devices.values.find(item => item.dbusPath === path);
        if (!error && device) {
            if (action === "rename") device.name = value || device.deviceName;
            if (action === "forget") Bluetooth.devices = {values: Bluetooth.devices.values.filter(item => item !== device)};
            if (action === "connect" || action === "disconnect") device.connected = action === "connect";
        }
        busy = false; devicePath = ""; operation = "";
        finished(path, action, error);
    }
''', singleton=False)
stub('audit', 'Bluetooth', '''id: bt
    property QtObject firstAdapter: QtObject {
        property string adapterId: "hci0"; property string dbusPath: "/org/bluez/hci0"; property string name: "Wbudowany"
        property bool enabled: true
        property int state: enabled ? BluetoothAdapterState.Enabled : BluetoothAdapterState.Disabled
        property bool discovering: false
    }
    property var defaultAdapter: firstAdapter
    property QtObject foreignAdapter: QtObject {
        property string adapterId: "hci1"; property string dbusPath: "/org/bluez/hci1"; property string name: "USB"
        property bool enabled: true; property bool discovering: false
        property int state: enabled ? BluetoothAdapterState.Enabled : BluetoothAdapterState.Disabled
    }
    property var adapters: ({values: [firstAdapter]})
    property QtObject saved: QtObject {
        property string name: "Słuchawki"; property string deviceName: "Słuchawki"
        property string address: "01:02:03:04:05:05"; property string dbusPath: "/org/bluez/hci0/dev_01_02_03_04_05_05"
        property var adapter: bt.firstAdapter
        property bool paired: true; property bool bonded: true; property bool connected: false
        property bool pairing: false; property int state: 0
        property bool batteryAvailable: false; property real battery: 0
    }
    property QtObject nearby: QtObject {
        property string name: "Klawiatura Bluetooth"; property string deviceName: name
        property string address: "01:02:03:04:05:06"; property string dbusPath: "/org/bluez/hci0/dev_01_02_03_04_05_06"
        property var adapter: bt.firstAdapter
        property bool paired: false; property bool bonded: false; property bool connected: false
        property bool pairing: false; property int state: 0
        property bool batteryAvailable: false; property real battery: 0
    }
    property QtObject foreign: QtObject {
        property var adapter: bt.foreignAdapter
        property string name: "Mysz USB"; property string deviceName: "Mysz USB"
        property string address: "01:02:03:04:05:07"; property string dbusPath: "/org/bluez/hci1/dev_01_02_03_04_05_07"
        property bool pairing: false; property int state: 0
        property bool batteryAvailable: false; property real battery: 0
        property bool paired: true; property bool bonded: true; property bool connected: false
    }
    property var devices: ({values: [saved, nearby, foreign]})
''')
shutil.copy2(ROOT / 'tests/fixtures/bluetooth.qml', CONFIG / 'shell.qml')
(WORK / 'runtime').mkdir(mode=0o700)
env = dict(os.environ, QT_QPA_PLATFORM='offscreen', QT_QPA_PLATFORMTHEME='', NO_AT_BRIDGE='1',
           WAYLAND_DISPLAY='', HYPRLAND_INSTANCE_SIGNATURE='', DBUS_SESSION_BUS_ADDRESS='unix:path=/nonexistent',
           DBUS_SYSTEM_BUS_ADDRESS='unix:path=/nonexistent', XDG_RUNTIME_DIR=str(WORK / 'runtime'),
           XDG_CONFIG_HOME=str(WORK / 'config'), XDG_STATE_HOME=str(WORK / 'state'), XDG_CACHE_HOME=str(WORK / 'cache'))
with (WORK / 'shell.log').open('w') as log:
    proc = subprocess.Popen(['qs', '-p', str(CONFIG), '--no-color'], env=env, stdout=log, stderr=log)
    def ipc(method, *args):
        result = subprocess.run(['qs', 'ipc', '--pid', str(proc.pid), 'call', 'bluetoothTest', method,
                                 *[str(arg).lower() if isinstance(arg, bool) else str(arg) for arg in args]],
                                env=env, text=True, capture_output=True, timeout=10)
        assert result.returncode == 0, (result.stderr, str(WORK))
        return result.stdout.strip()
    def measure():
        def sample():
            stat = (Path('/proc') / str(proc.pid) / 'stat').read_text().split()
            return int(stat[13]) + int(stat[14]), int(stat[23]) * os.sysconf('SC_PAGE_SIZE') // 1024
        ticks, _ = sample(); start = time.monotonic(); time.sleep(1)
        after, rss = sample()
        return dict(cpu_percent=round((after-ticks) / os.sysconf('SC_CLK_TCK') / (time.monotonic()-start)*100, 2), rss_kib=rss)
    try:
        for attempt in range(60):
            assert proc.poll() is None, (str(WORK), (WORK / 'shell.log').read_text())
            try:
                if ipc('ready') == 'true': break
            except AssertionError: pass
            time.sleep(.05)
        else: raise AssertionError((str(WORK), 'Startup timeout'))
        before = measure(); results = []; memory = []
        management = json.loads(ipc('management')); assert management['passed'], (management, str(WORK))
        picker = json.loads(ipc('picker')); assert picker['passed'], (picker, str(WORK))
        for prompt in ['pin', 'passkey', 'confirmation', 'authorization', 'service', 'displayPin', 'displayPasskey']:
            for cancel in [False, True]:
                result = json.loads(ipc('run', prompt, cancel)); results.append(result)
                assert result['passed'], (result, str(WORK))
        for cycle in range(20):
            result = json.loads(ipc('lifecycle')); assert result['passed'], (result, str(WORK))
            memory.append(measure()['rss_kib'])
        captures = {prompt: json.loads(ipc('capture', prompt, str(WORK / (prompt + '.png'))))
                    for prompt in ['confirmation', 'displayPasskey', 'pin', 'details', 'rename', 'forget', 'adapters', 'picker', 'picker-small']}
        after = measure()
        assert not re.search(r'WARN|ERROR|ReferenceError|TypeError|Binding loop', (WORK / 'shell.log').read_text()), (str(WORK), (WORK / 'shell.log').read_text())
        report = dict(passed=True, management=management, picker=picker, prompts=results, lifecycle_cycles=20, rss_cycles=memory,
                      before=before, after=after, captures=captures, artifacts=str(WORK))
        (WORK / 'result.json').write_text(json.dumps(report, indent=2)); print(json.dumps(report, indent=2))
    finally:
        proc.terminate(); proc.wait(timeout=3)
