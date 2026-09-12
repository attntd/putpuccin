#!/usr/bin/env python3
"""Measure first submitted screenshot frame and GUI stalls on a private shell.

Uses the physical display, private D-Bus/runtime, opens and cancels overlays.
Does not export screenshots, touch the clipboard or reload production.
"""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import socket
import statistics
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def replace(text, old, new):
    assert text.count(old) == 1, (old, text.count(old))
    return text.replace(old, new)


def prepare(work, variant):
    config = work / 'shell'
    for part in ('core', 'services', 'components', 'scripts', 'modules/screenshot'):
        (config / part).mkdir(parents=True)
    core = ['Theme', 'Metrics', 'Icons', 'Strings', 'Motion']
    for name in core:
        shutil.copy2(ROOT / f'core/{name}.qml', config / f'core/{name}.qml')
    (config / 'core/qmldir').write_text('module qs.core\n' + ''.join(
        f'singleton {name} 1.0 {name}.qml\n' for name in core + ['Settings']))
    (config / 'core/Settings.qml').write_text('''pragma Singleton
import Quickshell
Singleton {
 property bool screenshotPaintCursor: false
 property string screenshotDirectory: ""
 property real surfaceOpacity: 0.8
 property real interactiveOpacity: 0
}
''')
    (config / 'services/qmldir').write_text('module qs.services\nsingleton ScreenshotService 1.0 ScreenshotService.qml\nsingleton LockService 1.0 LockService.qml\n')
    (config / 'services/LockService.qml').write_text('pragma Singleton\nimport Quickshell\nSingleton { property bool locked: false; property bool releasing: false }\n')
    shutil.copy2(ROOT / 'components/ActionButton.qml', config / 'components/ActionButton.qml')
    (config / 'components/qmldir').write_text('module qs.components\nActionButton 1.0 ActionButton.qml\n')
    shutil.copy2(ROOT / 'scripts/screenshot-action', config / 'scripts/screenshot-action')
    for path in (ROOT / 'modules/screenshot').iterdir():
        if path.is_file():
            shutil.copy2(path, config / 'modules/screenshot' / path.name)

    shutil.copytree(ROOT / 'integrations/ScreenshotNative', config / 'integrations/ScreenshotNative')
    service = (ROOT / 'services/ScreenshotService.qml').read_text()
    service = replace(service, '    id: root\n', '''    id: root
    property double auditEpoch: 0
    function audit(tag, details = "") {
        if (auditEpoch) console.log("AUDIT " + JSON.stringify({tag: tag, ms: Date.now() - auditEpoch, details: details}));
    }
    onPhaseChanged: audit("phase:" + phase)
''')
    service = replace(service, '        state.generation++;\n        state.errorMessage = "";', '        auditEpoch = Date.now();\n        audit("begin");\n        state.generation++;\n        state.errorMessage = "";')
    service = service.replace('appid: "quickshell-de"', 'appid: "quickshell-screenshot-test"')
    (config / 'services/ScreenshotService.qml').write_text(service)
    overlay = (ROOT / 'modules/screenshot/ScreenshotOverlay.qml').read_text()
    overlay = replace(overlay, '    id: root\n', '''    id: root
    property bool auditPresented: false
    Connections {
        target: root.contentItem.Window.window
        function onFrameSwapped() {
            if (!root.auditPresented) {
                root.auditPresented = true;
                root.controller.audit("overlay-frame-submitted", root.screenName);
            }
        }
    }
''')
    (config / 'modules/screenshot/ScreenshotOverlay.qml').write_text(overlay)

    (config / 'shell.qml').write_text('''pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import qs.services
import qs.modules.screenshot
ShellRoot {
 Screenshot {}
 Timer {
  property double previous: Date.now()
  interval: 16
  repeat: true
  running: ScreenshotService.active
  onRunningChanged: previous = Date.now()
  onTriggered: {
   const now = Date.now();
   if (now - previous > 50) ScreenshotService.audit("gui-timer-gap", now - previous);
   previous = now;
  }
 }
 IpcHandler {
  target: "audit"
  function ready(): bool { return true; }
 }
}
''')
    return config


def ipc(path, command):
    with socket.socket(socket.AF_UNIX) as conn:
        conn.settimeout(3)
        conn.connect(str(path))
        conn.sendall(command.encode())
        parts = []
        while chunk := conn.recv(65536):
            parts.append(chunk)
        return json.loads(b''.join(parts))


def stop(proc):
    if proc and proc.poll() is None:
        proc.terminate()
        try:
            proc.wait(timeout=4)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=2)


def run():
    parser = argparse.ArgumentParser()
    parser.add_argument('--variant', choices=['fast'], default='fast')
    parser.add_argument('--cycles', type=int, default=31)
    args = parser.parse_args()
    work = Path(tempfile.mkdtemp(prefix='ssperf-', dir='/tmp'))
    runtime = work / 'r'
    runtime.mkdir(mode=0o700)
    source_hashes = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                     for folder in ('modules/screenshot', 'services') for p in (ROOT / folder).glob('*') if p.is_file()}
    config = prepare(work, args.variant)
    original_runtime = Path(os.environ['XDG_RUNTIME_DIR'])
    (runtime / 'hypr').symlink_to(original_runtime / 'hypr', target_is_directory=True)
    display = Path(os.environ['WAYLAND_DISPLAY'])
    if not display.is_absolute():
        display = original_runtime / display
    hypr_socket = original_runtime / 'hypr' / os.environ['HYPRLAND_INSTANCE_SIGNATURE'] / '.socket.sock'
    monitors = [{k: m[k] for k in ('name', 'width', 'height', 'scale', 'refreshRate')} for m in ipc(hypr_socket, 'j/monitors')]
    env = dict(os.environ, QML_IMPORT_PATH=str(config / 'integrations'), XDG_RUNTIME_DIR=str(runtime), XDG_CONFIG_HOME=str(work / 'config'),
               XDG_CACHE_HOME=str(work / 'cache'), XDG_STATE_HOME=str(work / 'state'),
               WAYLAND_DISPLAY=str(display), QT_QPA_PLATFORM='wayland', QSG_INFO='1')
    bus_config = work / 'bus.conf'
    bus_config.write_text('<busconfig><type>session</type><listen>unix:tmpdir=/tmp</listen><policy context="default">'
                          '<allow send_destination="*"/><allow receive_sender="*"/><allow own="*"/></policy></busconfig>')
    bus = shell = None
    results = {'variant': args.variant, 'work': str(work), 'monitors': monitors, 'samples': [], 'source_sha256': source_hashes}
    try:
        bus = subprocess.Popen(['dbus-daemon', '--config-file=' + str(bus_config), '--nofork', '--print-address=1'], env=env,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        env['DBUS_SESSION_BUS_ADDRESS'] = bus.stdout.readline().strip()
        assert env['DBUS_SESSION_BUS_ADDRESS'].startswith('unix:')
        with (work / 'shell.log').open('w') as log:
            shell = subprocess.Popen(['qs', '-p', str(config), '--no-color'], env=env, stdout=log, stderr=log)
        def call(target, method, timeout=8):
            assert shell.poll() is None, (work / 'shell.log').read_text()
            p = subprocess.run(['qs', 'ipc', '--pid', str(shell.pid), 'call', target, method], env=env,
                               capture_output=True, text=True, timeout=timeout)
            if p.returncode:
                raise RuntimeError(p.stderr)
            return p.stdout.strip()
        end = time.monotonic() + 8
        while True:
            try:
                if call('audit', 'ready', timeout=1) == 'true':
                    break
            except (RuntimeError, subprocess.TimeoutExpired):
                if time.monotonic() > end:
                    raise
                time.sleep(.05)
        time.sleep(.4)
        for cycle in range(args.cycles):
            offset = (work / 'shell.log').stat().st_size
            start = time.monotonic()
            assert call('screenshot', 'open') == 'true'
            command_ms = (time.monotonic() - start) * 1000
            end = start + 9
            events = []
            while time.monotonic() < end:
                text = (work / 'shell.log').read_text()[offset:]
                events = [json.loads(m) for m in re.findall(r'AUDIT (\{[^\n]+\})', text)]
                if any(e['tag'] == 'overlay-frame-submitted' for e in events):
                    break
                if shell.poll() is not None:
                    raise RuntimeError(text)
                time.sleep(.02)
            else:
                raise RuntimeError('No submitted overlay frame: ' + (work / 'shell.log').read_text())
            time.sleep(.05)
            status = json.loads(call('screenshot', 'status'))
            assert status['phase'] == 'selecting' and not status['errorMessage'], status
            call('screenshot', 'cancel')
            sample = dict(cycle=cycle, command_ms=round(command_ms, 2), events=events, screens=status['screens'])
            results['samples'].append(sample)
            print(json.dumps(sample), flush=True)
            time.sleep(.35)
        frames = [next(e['ms'] for e in sample['events'] if e['tag'] == 'overlay-frame-submitted')
                  for sample in results['samples']]
        warm = sorted(frames[1:])
        results['timing_ms'] = dict(first=frames[0], warm_median=statistics.median(warm) if warm else None,
                                   warm_p95=warm[math.ceil(.95 * len(warm)) - 1] if warm else None,
                                   warm_max=max(warm) if warm else None)
        results['max_gui_gap_ms'] = max((e['details'] for sample in results['samples'] for e in sample['events']
                                        if e['tag'] == 'gui-timer-gap'), default=0)
        if len(warm) >= 30:
            assert results['timing_ms']['warm_median'] <= 200, results['timing_ms']
            assert results['timing_ms']['warm_p95'] <= 300, results['timing_ms']
        results['passed'] = True
    finally:
        stop(shell)
        stop(bus)
        results['source_unchanged'] = all(hashlib.sha256((ROOT / p).read_bytes()).hexdigest() == h for p, h in source_hashes.items())
        # Remove only this probe's own screenshots, including after an exception.
        captures = runtime / 'quickshell-de-screenshots'
        if captures.exists():
            shutil.rmtree(captures)
        (work / 'result.json').write_text(json.dumps(results, indent=2))
        print('EVIDENCE', work, flush=True)


if __name__ == '__main__':
    run()
