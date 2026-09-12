#!/usr/bin/env python3
"""Real FileView validation and atomic save, with a private bus and config."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

if os.environ.get('QS_SETTINGS_VALIDATION_PRIVATE') != '1':
    with tempfile.TemporaryDirectory(prefix='qs-settings-bus-') as folder:
        config = Path(folder) / 'bus.conf'
        config.write_text('<busconfig><type>session</type><listen>unix:tmpdir=/tmp</listen>'
            '<policy context="default"><allow send_destination="*"/>'
            '<allow receive_sender="*"/><allow own="*"/></policy></busconfig>')
        raise SystemExit(subprocess.call(['dbus-run-session', '--config-file', str(config), '--',
            sys.executable, __file__], env=dict(os.environ, QS_SETTINGS_VALIDATION_PRIVATE='1')))

root = Path(__file__).resolve().parents[1]
work = Path(tempfile.mkdtemp(prefix='quickshell-settings-validation-'))
shell = work / 'shell'
shell.mkdir()
shutil.copytree(root / 'core', shell / 'core')
(shell / 'core/qmldir').write_text('module qs.core\nsingleton Settings 1.0 Settings.qml\n')
(shell / 'shell.qml').write_text('''import QtQuick
import Quickshell
import Quickshell.Io
import qs.core
ShellRoot {
    IpcHandler {
        target: "test"
        function status(): string { return JSON.stringify({revision: Settings.revision,
            defaults: Settings.usingDefaults, error: Settings.errorMessage,
            height: Settings.barHeight, step: Settings.volumeStep, modules: Settings.rightModules,
            screenshotDirectory: Settings.screenshotDirectory, screenshotPaintCursor: Settings.screenshotPaintCursor}); }
        function saveValues(): void { Settings.barHeight = 55;
            Settings.screenshotDirectory = "/tmp/Zrzuty ekranu"; Settings.screenshotPaintCursor = true; Settings.save(); }
    }
}''')
config = work / 'config/quickshell-de'
config.mkdir(parents=True)
path = config / 'settings.json'
path.write_text('{')
runtime = work / 'runtime'
runtime.mkdir(mode=0o700)
env = dict(os.environ, QT_QPA_PLATFORM='offscreen', QT_QPA_PLATFORMTHEME='', WAYLAND_DISPLAY='',
    HYPRLAND_INSTANCE_SIGNATURE='', XDG_RUNTIME_DIR=str(runtime), XDG_CONFIG_HOME=str(work / 'config'),
    XDG_STATE_HOME=str(work / 'state'), XDG_CACHE_HOME=str(work / 'cache'))
log = (work / 'log').open('w')
process = subprocess.Popen(['qs', '-p', str(shell), '--no-color'], env=env, stdout=log, stderr=log)

def call(method='status'):
    reply = subprocess.run(['qs', 'ipc', '--pid', str(process.pid), 'call', 'test', method],
        env=env, capture_output=True, text=True, timeout=2)
    return json.loads(reply.stdout) if reply.returncode == 0 and reply.stdout.strip() else None

def wait_for(predicate):
    end = time.monotonic() + 5
    while time.monotonic() < end:
        state = call()
        if state and predicate(state):
            return state
        assert process.poll() is None, str(work)
        time.sleep(.05)
    raise AssertionError(str(work))

def write(value):
    path.write_text(value if isinstance(value, str) else json.dumps(value))

checks = []
try:
    first = wait_for(lambda state: bool(state['error']))
    assert first['defaults'] and first['height'] == 40 and first['revision'] == 0
    assert first['screenshotDirectory'] == '' and first['screenshotPaintCursor'] is False
    base = json.loads((root / 'config/settings.example.json').read_text())
    base.update(barHeight=52, volumeStep=10, screenshotDirectory='/tmp/Zrzuty "próba"', screenshotPaintCursor=True)
    write(base)
    valid = wait_for(lambda state: state['height'] == 52 and not state['error'])
    assert not valid['defaults']
    assert valid['screenshotDirectory'] == base['screenshotDirectory'] and valid['screenshotPaintCursor'] is True
    for invalid in ('{', dict(base, schemaVersion=2), dict(base, barHeight='bad', volumeStep=False),
            dict(base, barHeight=42.5), dict(base, wallpaperDirectory='relative'),
            dict(base, screenshotDirectory='relative'), dict(base, screenshotDirectory='/tmp/bad\x00path'),
            dict(base, screenshotDirectory='/tmp/bad\npath'), dict(base, screenshotPaintCursor='true'),
            dict(base, moduleOptions={'clock': {'expandOnHover': 'true'}}),
            dict(base, unknownOption=True), []):
        write(invalid)
        rejected = wait_for(lambda state: bool(state['error']))
        assert rejected['height'] == 52 and rejected['step'] == 10
        assert rejected['revision'] == valid['revision'] and not rejected['defaults']
        assert rejected['screenshotDirectory'] == base['screenshotDirectory'] and rejected['screenshotPaintCursor'] is True
        write(base)
        valid = wait_for(lambda state: not state['error'])
    checks.append('invalid initial file uses actual defaults; bad JSON/schema/types preserve last valid state')
    write({'schemaVersion': 1, 'rightModules': ['clock']})
    partial = wait_for(lambda state: state['height'] == 40 and state['modules'] == ['clock'])
    assert partial['step'] == 5
    assert partial['screenshotDirectory'] == '' and partial['screenshotPaintCursor'] is False
    checks.append('omitted optional values reset to defaults; complete file validation precedes application')
    write('{')
    wait_for(lambda state: bool(state['error']))
    # FileView uses a temporary file plus rename. Both the resulting JSON and
    # the public value must reflect root state, not an obsolete adapter.
    call('saveValues')
    end = time.monotonic() + 3
    while time.monotonic() < end:
        saved = json.loads(path.read_text())
        if saved.get('barHeight') == 55:
            break
        time.sleep(.05)
    assert saved['barHeight'] == 55 and saved['rightModules'] == ['clock']
    assert saved['screenshotDirectory'] == '/tmp/Zrzuty ekranu' and saved['screenshotPaintCursor'] is True
    wait_for(lambda state: state['height'] == 55 and not state['error'])
    write(dict(saved, volumeStep=8))
    final = wait_for(lambda state: state['step'] == 8)
    assert final['height'] == 55 and not final['error']
    assert final['screenshotDirectory'] == saved['screenshotDirectory'] and final['screenshotPaintCursor'] is True
    checks.append('save serializes current root state; subsequent live file reload remains functional')
    checks.append('screenshot defaults, absolute directory validation, cursor type, partial reset and atomic save verified')
    result = {'passed': True, 'checks': checks}
    (work / 'result.json').write_text(json.dumps(result, indent=2))
    print(json.dumps(result, indent=2)); print('Logs:', work)
finally:
    process.terminate(); process.wait(timeout=3); log.close()
