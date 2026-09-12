#!/usr/bin/env python3
"""Lock regression in private headless Hyprland; PAM fixtures never touch production."""
import argparse
import json
import os
import re
import shutil
import socket
import subprocess
import tempfile
import time
from pathlib import Path

def ipc(path, command):
    with socket.socket(socket.AF_UNIX) as s:
        s.settimeout(3)
        s.connect(str(path))
        s.sendall(command.encode())
        data = []
        while (block := s.recv(65536)):
            data.append(block)
        return b''.join(data).decode()

def production_state(path):
    # Workspace, focus, DPMS and scanout flags can change while the user works;
    # compare output geometry and mapped nested windows instead.
    monitors = json.loads(ipc(path, 'j/monitors'))
    clients = json.loads(ipc(path, 'j/clients'))
    return {
        'monitors': sorted(tuple(m[k] for k in ('name', 'width', 'height', 'x', 'y', 'scale', 'transform'))
                           for m in monitors),
        'nested_windows': sorted(c['address'] for c in clients if c['class'] == 'aquamarine'),
    }

def wait(fn, timeout=10):
    end = time.monotonic() + timeout
    last = None
    while time.monotonic() < end:
        try:
            last = fn()
            if last:
                return last
        except (AssertionError, ValueError, OSError, RuntimeError):
            pass
        time.sleep(0.025)
    raise AssertionError('Timeout: ' + repr(last))

def stop(p):
    if p and p.poll() is None:
        p.terminate()
        try:
            p.wait(timeout=3)
        except subprocess.TimeoutExpired:
            p.kill()
            p.wait(timeout=3)

def run():
    parser = argparse.ArgumentParser()
    parser.add_argument('--source', default=str(Path(__file__).resolve().parents[1]))
    parser.add_argument('--cycles', type=int, default=20)
    parser.add_argument('--visual', action='store_true')
    args = parser.parse_args()
    source = Path(args.source)
    work = Path(tempfile.mkdtemp(prefix='qls-'))
    runtime = work / 'r'
    runtime.mkdir(mode=0o700)
    shell = work / 'shell'
    shutil.copytree(source, shell, ignore=shutil.ignore_patterns('inspirations', '__pycache__', 'docs', 'tests'))
    service = shell / 'services/LockService.qml'
    content = service.read_text().replace('config: "system-auth"', 'config: "test-password"\n        configDirectory: Quickshell.shellPath("assets/pam")')
    content = content.replace('    function lock() {', '''    property var reviewViews: []
    function reviewFingerprint() { state.fingerprintAvailable = true; fingerprintPam.start(); }
    function reviewHold(value) { successDelay.interval = value ? 100000 : Motion.elaborate; }
    function reviewContinue() { successDelay.interval = Motion.elaborate; successDelay.restart(); }
    function lock() {''')
    service.write_text(content)
    (shell / 'scripts/fingerprint-enrolled').write_text('#!/bin/sh\nprintf "false\\n"\n')
    (shell / 'assets/pam/test-password').write_text('auth required pam_deny.so\n')
    (shell / 'assets/pam/fingerprint').write_text('auth required pam_deny.so\n')
    lock = shell / 'modules/lockscreen/LockScreen.qml'
    content = lock.read_text()
    if 'id: surface' not in content:
        content = content.replace('WlSessionLockSurface {', 'WlSessionLockSurface {\n            id: surface')
    if 'id: view' not in content:
        content = content.replace('LockView {', 'LockView {\n                id: view')
    content = content.replace('import QtQuick\n', 'import QtQuick\nimport QtQuick.Window\n')
    content = content.replace('                auth: LockService', '''                onWallpaperSourceChanged: console.log("WALLPAPER " + wallpaperSource)
                property bool firstFrame: false
                Connections {
                    target: view.Window.window
                    function onFrameSwapped() {
                        if (!view.firstFrame) {
                            view.firstFrame = true;
                            console.log("LOCK_FIRST_FRAME " + surface.screen.name);
                            view.grabToImage(result => {
                                if (result.saveToFile("''' + str(work) + '''/first-" + surface.screen.name + ".png"))
                                    console.log("FIRST_SAVED " + surface.screen.name);
                            });
                        }
                    }
                }
                Connections {
                    target: LockService
                    function onBusyChanged() {
                        if (LockService.busy && LockService.secure) { console.log("VISUAL " + view.wallpaperSource + " " + JSON.stringify(view.children.map(c => ({type: String(c), source: String(c.source || ""), opacity: c.opacity, status: c.status})))); snapshotTimer.start(); }
                    }
                }
                Timer {
                    id: snapshotTimer
                    interval: 170
                    onTriggered: view.grabToImage(result => result.saveToFile("''' + str(work) + '/success-" + surface.screen.name + ".png"))\n                }\n                auth: LockService')
    if not args.visual:
        start = content.index('                onWallpaperSourceChanged:')
        end = content.index('                auth: LockService', start)
        content = content[:start] + content[end:]
    lock.write_text(content)
    lock.write_text(lock.read_text().replace('                auth: LockService',
        '                Component.onCompleted: LockService.reviewViews = LockService.reviewViews.concat([view])\n                auth: LockService'))
    if args.visual and 'function exitCaptured' in service.read_text():
        content = service.read_text().replace('        const frames = Object.assign({}, state.exitFrames);', '        result.saveToFile("' + str(work) + '/exit-" + screenName + ".png");\n        const frames = Object.assign({}, state.exitFrames);')
        service.write_text(content)
    (shell / 'shell.qml').write_text((Path(__file__).parent / 'fixtures/lockscreen-wayland.qml').read_text())
    cfg = work / 'config/quickshell-de'
    cfg.mkdir(parents=True)
    (work / 'config/hypr').symlink_to(Path(os.environ.get('XDG_CONFIG_HOME', Path.home() / '.config')) / 'hypr', target_is_directory=True)
    (cfg / 'settings.json').write_text(json.dumps({'schemaVersion': 1, 'wallpaperDirectory': str(Path(os.environ.get('XDG_CONFIG_HOME', Path.home() / '.config')) / 'hypr/backgrounds'), 'lockAvatarPath': str(Path(os.environ.get('XDG_CONFIG_HOME', Path.home() / '.config')) / 'hypr/putek_mocha_avatar_155.png')}))
    parent_runtime = Path(os.environ['XDG_RUNTIME_DIR'])
    parent = parent_runtime / 'hypr' / os.environ['HYPRLAND_INSTANCE_SIGNATURE'] / '.socket.sock'
    display = Path(os.environ['WAYLAND_DISPLAY'])
    if not display.is_absolute():
        display = parent_runtime / display
    before = production_state(parent)
    config = work / 'hyprland.lua'
    config.write_text('''hl.monitor({ output = "WAYLAND-1", disabled = true })
hl.monitor({ output = "LOCK-A", mode = "1280x720@60", position = "0x0", scale = 1 })
hl.monitor({ output = "LOCK-B", mode = "1440x900@60", position = "1280x0", scale = 1.2 })
hl.config({ misc = { disable_hyprland_logo = true, disable_splash_rendering = true, force_default_wallpaper = 0 }, animations = { enabled = false }, xwayland = { enabled = false } })
hl.layer_rule({ name = "lock-exit-test", match = { namespace = "^quickshell-de:lock-exit$" }, no_anim = true })
''')
    env = dict(os.environ, QML_IMPORT_PATH=str(shell / 'integrations'), XDG_RUNTIME_DIR=str(runtime), XDG_CONFIG_HOME=str(work / 'config'), XDG_CACHE_HOME=str(work / 'cache'), XDG_STATE_HOME=str(work / 'state'), WAYLAND_DISPLAY=str(display), DISPLAY='', HYPRLAND_INSTANCE_SIGNATURE='', LIBSEAT_BACKEND='seatd', SEATD_SOCK=str(work / 'missing'), AQ_DRM_DEVICES=str(work / 'missing'), HYPRLAND_NO_SD_VARS='1', HYPRLAND_NO_SD_NOTIFY='1', HYPRLAND_NO_CRASHREPORTER='1', HYPRLAND_NO_RT='1', GSETTINGS_BACKEND='memory', QT_QPA_PLATFORM='wayland', QT_QPA_PLATFORMTHEME='', NO_AT_BRIDGE='1')
    for key in ('NOTIFY_SOCKET', 'LISTEN_FDS', 'LISTEN_PID', 'WAYLAND_SOCKET'):
        env.pop(key, None)
    buscfg = work / 'bus.conf'
    buscfg.write_text('<busconfig><type>session</type><listen>unix:tmpdir=/tmp</listen><policy context="default"><allow send_destination="*"/><allow receive_sender="*"/><allow own="*"/></policy></busconfig>')
    bus = comp = proc = None
    streams = []
    result = {'work': str(work), 'source': str(source), 'checks': [], 'passed': False}
    print('WORK', work, flush=True)
    try:
        bus = subprocess.Popen(['dbus-daemon', '--config-file=' + str(buscfg), '--nofork', '--print-address=1'], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        env['DBUS_SESSION_BUS_ADDRESS'] = bus.stdout.readline().strip()
        log = (work / 'compositor.log').open('w')
        streams.append(log)
        comp = subprocess.Popen(['Hyprland', '-c', str(config)], env=env, stdout=log, stderr=log)
        child = wait(lambda: next((runtime / 'hypr').glob('*/.socket.sock'), None))
        assert child.is_relative_to(runtime) and child != parent
        for name in ('LOCK-A', 'LOCK-B'):
            assert ipc(child, 'output create headless ' + name).strip() == 'ok'
        wait(lambda: len(json.loads(ipc(child, 'j/monitors'))) == 2)
        assert not ipc(child, 'configerrors').strip()
        env.update(WAYLAND_DISPLAY=str(runtime / 'wayland-1'), HYPRLAND_INSTANCE_SIGNATURE=child.parent.name)
        log = (work / 'shell.log').open('w')
        streams.append(log)
        proc = subprocess.Popen(['qs', '-p', str(shell), '--no-color'], env=env, stdout=log, stderr=log)

        def call(target, method, *args):
            assert proc.poll() is None, (work / 'shell.log').read_text()
            r = subprocess.run(['qs', 'ipc', '--pid', str(proc.pid), 'call', target, method, *map(str, args)], env=env, capture_output=True, text=True, timeout=5)
            if r.returncode:
                raise RuntimeError(r.stderr)
            return r.stdout.strip()

        def state():
            return json.loads(call('review', 'state'))

        def stats():
            values = Path(f'/proc/{proc.pid}/stat').read_text().rsplit(')', 1)[1].split()
            return (int(values[11]) + int(values[12]), int(values[21]) * os.sysconf('SC_PAGE_SIZE') // 1024)

        def measure():
            a = stats()
            start = time.monotonic()
            time.sleep(2)
            b = stats()
            return {'cpu_percent': round((b[0] - a[0]) / os.sysconf('SC_CLK_TCK') / (time.monotonic() - start) * 100, 2), 'rss_kib': b[1]}

        def closed():
            # One snapshot: separate IPC reads can straddle the start of release.
            wait(lambda: (s := state()) and not s['releasing'] and not s['locked']
                and not s['busy'] and s['watchFiles'])
            # The compositor applies the surface removal asynchronously after
            # QML clears releasing. Bound that final Wayland round trip too.
            wait(lambda: 'quickshell-de:lock-exit' not in ipc(child, 'j/layers'), timeout=1)
        wait(lambda: not state()['locked'] and state()['currentWallpaper'])
        result['before'] = measure()
        call('lockscreen', 'lock')
        wait(lambda: state()['secure'])
        time.sleep(0.5)
        layout = json.loads(call('review', 'layout'))
        assert len(layout) == 2, layout
        for view in layout:
            assert abs(view['groupCenter'] - view['screenHeight'] / 2) < .01, view
            assert view['frameWidth'] == 320 and view['frameHeight'] == 48, view
            assert view['placeholderEmpty'] and not view['errorVisible'], view
            assert view['clipped'] and view['masked'] and view['cursorInside'], view
            assert view['cursorHidden'], view
        result['layoutReady'] = layout
        if args.visual:
            # Reload later recreates the test probe; preserve the first frame
            # of the actual lock request before that separate security check.
            for name in ('LOCK-A', 'LOCK-B'):
                path = work / ('first-' + name + '.png')
                wait(lambda: ('FIRST_SAVED ' + name) in (work / 'shell.log').read_text())
                shutil.copy2(path, work / ('initial-' + name + '.png'))
        call('review', 'submit')
        wait(lambda: state()['message'])
        assert state()['locked'] and (not state()['releasing'])
        call('review', 'fingerprint')
        wait(lambda: state()['fp'] == 'failure')
        assert state()['locked']
        layout = json.loads(call('review', 'layout'))
        for view in layout:
            assert view['fingerprintVisible'] and view['fingerprintInside'], view
            assert view['inputGap'] >= 12 and view['cursorInside'], view
            assert view['errorVisible'] and view['errorFits'], view
        result['layoutError'] = layout
        result['checks'].append('Centered avatar/field block, internal fingerprint gap, clipped long password, only inline errors')
        result['checks'].append('Native lock; denied password and fingerprint keep both outputs locked')
        call('review', 'reload')
        wait(lambda: state()['secure'])
        assert state()['locked']
        result['checks'].append('Soft reload preserves native session lock')
        (shell / 'assets/pam/fingerprint').write_text('auth required pam_permit.so\n')
        call('review', 'hold', 'true')
        call('review', 'fingerprint')
        wait(lambda: state()['fp'] == 'success')
        time.sleep(0.4)
        assert state()['locked'] and state()['secure']
        call('review', 'proceed')
        wait(lambda: not state()['locked'])
        assert state()['releasing']
        closed()
        result['checks'].append('Successful fingerprint retains native lock through feedback and releases all exit layers')
        if args.visual and 'function exitCaptured' in service.read_text():
            for name in ('LOCK-A', 'LOCK-B'):
                comparison = subprocess.run(['magick', 'compare', '-metric', 'AE', str(work / ('success-' + name + '.png')), str(work / ('exit-' + name + '.png')), 'null:'], capture_output=True, text=True, timeout=10)
                assert comparison.returncode == 0, (name, comparison.stderr)
                pixels = subprocess.check_output(['magick', str(work / ('initial-' + name + '.png')), '-format', '%[pixel:p{50,50}]|%[pixel:p{200,100}]', 'info:'], text=True, timeout=10).split('|')
                assert pixels[0] != pixels[1], 'Solid initial frame on ' + name
            result['checks'].append('Wallpaper in first frame; identical success and exit pixels on both outputs')
        for p in list(work.glob('*.png')):
            shutil.copy2(p, work / ('visual-' + p.name))
        (shell / 'assets/pam/test-password').write_text('auth required pam_permit.so\n')
        samples = []
        for cycle in range(args.cycles):
            call('lockscreen', 'lock')
            wait(lambda: state()['secure'])
            time.sleep(0.5)
            start = time.monotonic()
            call('review', 'submit')
            wait(lambda: not state()['locked'])
            release_ms = round((time.monotonic() - start) * 1000, 1)
            closed()
            samples.append({'release_ms': release_ms, 'total_ms': round((time.monotonic() - start) * 1000, 1), 'rss_kib': stats()[1]})
        result['cycles'] = samples
        result['after'] = measure()
        result['checks'].append(str(args.cycles) + ' native lock/PAM/unlock cycles on scales 1 and 1.2, no surviving layers')
        call('lockscreen', 'lock')
        wait(lambda: state()['secure'])
        time.sleep(0.5)
        call('review', 'submit')
        wait(lambda: state()['fadingOut'])
        call('lockscreen', 'lock')
        wait(lambda: state()['secure'])
        time.sleep(0.8)
        assert state()['locked'] and state()['secure'] and (not state()['busy'])
        assert 'quickshell-de:lock-exit' not in ipc(child, 'j/layers')
        call('review', 'submit')
        closed()
        result['checks'].append('Relocking during fade removes old images and stays secure')
        call('review', 'reducedMotion', 'true')
        call('lockscreen', 'lock')
        wait(lambda: state()['secure'])
        time.sleep(0.3)
        call('review', 'submit')
        closed()
        result['checks'].append('Reduced motion unlock completes and cleans up')
        assert child.is_relative_to(runtime) and child != parent
        call('lockscreen', 'lock')
        wait(lambda: state()['secure'])
        assert ipc(child, 'output remove LOCK-B').strip() == 'ok'
        time.sleep(0.3)
        assert state()['locked'] and state()['secure']
        assert ipc(child, 'output create headless LOCK-B').strip() == 'ok'
        time.sleep(0.5)
        assert state()['locked'] and state()['secure']
        call('review', 'submit')
        closed()
        result['checks'].append('Output removal/addition while locked remains secure and unlocks cleanly')
        errors = [line for line in (work / 'shell.log').read_text().splitlines() if re.search('WARN |TypeError:|ReferenceError:|Binding loop|Cannot assign|Unable to assign', line)]
        errors = [line for line in errors if 'qt.qpa.services: Failed to register with host portal' not in line]
        result['warnings'] = errors
        assert not errors, errors
        result['passed'] = True
    finally:
        stop(proc)
        stop(comp)
        stop(bus)
        for stream in streams:
            stream.close()
        result['production_before'] = before
        result['production_after'] = production_state(parent)
        result['production_monitors_unchanged'] = result['production_after'] == before
        (work / 'result.json').write_text(json.dumps(result, indent=2))
        print(json.dumps(result, indent=2), flush=True)
        assert result['production_monitors_unchanged'], 'Production output geometry or mapped nested windows changed'
if __name__ == '__main__':
    run()
