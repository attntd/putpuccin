#!/usr/bin/env python3
"""Exercise the real askpass transport and QML UI on private headless outputs."""
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

from test_lockscreen_wayland import ipc, production_state, wait, stop
from analyze_authentication_fade import analyze_recording


def build_recorder(work):
    fixtures = Path(__file__).parent / 'fixtures'
    protocol = fixtures / 'wlr-screencopy-unstable-v1.xml'
    for mode, name in [('client-header', 'screencopy-client.h'), ('private-code', 'screencopy-protocol.c')]:
        subprocess.run(['wayland-scanner', mode, str(protocol), str(work / name)], check=True)
    flags = shlex.split(subprocess.check_output(['pkg-config', '--cflags', '--libs', 'wayland-client', 'libpng'], text=True))
    binary = work / 'record'
    subprocess.run(['cc', '-O2', '-I', str(work), '-o', str(binary),
        str(fixtures / 'authentication-screencopy.c'), str(work / 'screencopy-protocol.c'), *flags], check=True)
    return binary


MOCK = '''import QtQuick
QtObject {
    id: agent
    property bool isRegistered: true
    property var flow: null
    function begin() { flow = factory.createObject(agent); }
    property Component factory: Component {
        QtObject {
            property string message: "Uwierzytelnienie jest wymagane, aby uruchomić program jako administrator."
            property string actionId: "test.authentication"
            property string inputPrompt: "Password: "
            property bool isResponseRequired: true
            property bool responseVisible: false
            property string supplementaryMessage: ""
            property bool supplementaryIsError: false
            property var identities: [{displayName: "Test A"}, {displayName: "Test B"}]
            property var selectedIdentity: identities[0]
            function submit(value) {
                if (value === "123456") { agent.flow = null; destroy(); }
                else { supplementaryMessage = "Nieprawidłowy PIN"; supplementaryIsError = true; }
            }
            function cancelAuthenticationRequest() { agent.flow = null; destroy(); }
        }
    }
}
'''


def run():
    parser = argparse.ArgumentParser()
    parser.add_argument('--source', default=str(Path(__file__).resolve().parents[1]))
    parser.add_argument('--cycles', type=int, default=20)
    parser.add_argument('--compact', action='store_true')
    parser.add_argument('--qml-fade', action='store_true')
    parser.add_argument('--slow-motion', action='store_true')
    args = parser.parse_args()
    source = Path(args.source)
    work = Path(tempfile.mkdtemp(prefix='qauth-'))
    recorder_binary = build_recorder(work)
    runtime = work / 'r'
    runtime.mkdir(mode=0o700)
    shell = work / 'shell'
    shutil.copytree(source, shell, ignore=shutil.ignore_patterns('inspirations', '__pycache__', 'docs', 'tests'))
    if args.slow_motion:
        motion = shell / 'core/Motion.qml'
        motion.write_text(motion.read_text().replace('standard: 180', 'standard: 1000'))
    service = shell / 'services/AuthenticationService.qml'
    content, replaced = re.subn(r'\bPolkitAgent\s*\{\s*\}', 'MockPolkitAgent {}', service.read_text(), count=1)
    assert replaced == 1, 'The isolated Polkit mock must replace exactly one native agent'
    service.write_text(content
        .replace('    function present()', '    property bool reviewCapture: true\n    function reviewPolkit() { root.agent.begin(); }\n    function present()'))
    (shell / 'services/MockPolkitAgent.qml').write_text(MOCK)
    with (shell / 'services/qmldir').open('a') as stream:
        stream.write('\nMockPolkitAgent 1.0 MockPolkitAgent.qml\n')
    (shell / 'shell.qml').write_text((Path(__file__).parent / 'fixtures/authentication-wayland.qml').read_text())
    # Image captures stay in this test copy, never in production auth code.
    view = shell / 'modules/authentication/AuthenticationView.qml'
    view.write_text(view.read_text().replace('import QtQuick\n', 'import QtQuick\nimport QtQuick.Window\nimport qs.services\n').replace('    id: root', '''    id: root
    property double reviewCreatedAt: Date.now()
    Connections {
        target: root.Window.window
        function onFrameSwapped() {
            console.log("AUTH_FRAME " + JSON.stringify({id: root.reviewCreatedAt, ms: Date.now() - root.reviewCreatedAt,
                active: root.auth.active, opacity: root.opacity, width: root.width, height: root.height,
                ideal: root.implicitHeight, scrollY: scroll.contentY, input: root.presentation.needsInput,
                polkit: root.presentation.polkit, x: root.x, y: root.y, windowWidth: root.Window.window.width, windowHeight: root.Window.window.height}));
        }
    }
    Timer {
        interval: 350; running: AuthenticationService.reviewCapture
        onTriggered: {
            if (root.Window.window && root.Window.window.visible && root.auth.active)
                root.grabToImage(result => {
                    if (result.saveToFile("''' + str(work) + '''/view.png")) console.log("AUTH_IMAGE_SAVED");
                });
        }
    }''', 1))
    config = work / 'config/quickshell-de'
    config.mkdir(parents=True)
    (config / 'settings.json').write_text(json.dumps({'schemaVersion': 1}))
    parent_runtime = Path(os.environ['XDG_RUNTIME_DIR'])
    parent = parent_runtime / 'hypr' / os.environ['HYPRLAND_INSTANCE_SIGNATURE'] / '.socket.sock'
    display = Path(os.environ['WAYLAND_DISPLAY'])
    if not display.is_absolute():
        display = parent_runtime / display
    before = production_state(parent)
    compositor_config = work / 'hyprland.lua'
    compositor_config.write_text('''hl.monitor({output="WAYLAND-1", disabled=true})
hl.monitor({output="AUTH-A", mode="1280x720@60", position="0x0", scale=1})
hl.monitor({output="AUTH-B", mode="1440x900@60", position="1280x0", scale=1.2})
hl.config({misc={disable_hyprland_logo=true,disable_splash_rendering=true,force_default_wallpaper=0},animations={enabled=true},xwayland={enabled=false}})
hl.layer_rule({name="auth",match={namespace="^quickshell-de:authentication$"},animation="fade",blur=true,ignore_alpha=0.01})
''')
    with compositor_config.open('a') as stream:
        stream.write("""hl.curve("auth-linear", {type="bezier",points={{0,0},{1,1}}})
hl.curve("auth-almost-linear", {type="bezier",points={{0.5,0.5},{0.75,1.0}}})
hl.animation({leaf="layers",enabled=true,speed=1.8,bezier="auth-linear",style="fade"})
hl.animation({leaf="fadeLayersIn",enabled=true,speed=1.79,bezier="auth-almost-linear"})
hl.animation({leaf="fadeLayersOut",enabled=true,speed=1.39,bezier="auth-almost-linear"})
hl.config({decoration={blur={enabled=true,size=6,passes=2,new_optimizations=true,ignore_opacity=true,noise=0.02,vibrancy=0.1696}}})
hl.layer_rule({name="review-background",match={namespace="^auth-review-.*$"},no_anim=true})
""")
    if args.slow_motion:
        compositor_config.write_text(compositor_config.read_text().replace('speed=1.79', 'speed=10').replace('speed=1.39', 'speed=10'))
    if args.qml_fade:
        compositor_config.write_text(compositor_config.read_text().replace('animation="fade",blur=true', 'no_anim=true,blur=true'))
    env = dict(os.environ, QML_IMPORT_PATH=str(shell / 'integrations'), XDG_RUNTIME_DIR=str(runtime),
        XDG_CONFIG_HOME=str(work / 'config'), XDG_CACHE_HOME=str(work / 'cache'), XDG_STATE_HOME=str(work / 'state'),
        WAYLAND_DISPLAY=str(display), DISPLAY='', HYPRLAND_INSTANCE_SIGNATURE='', LIBSEAT_BACKEND='seatd',
        SEATD_SOCK=str(work / 'missing'), AQ_DRM_DEVICES=str(work / 'missing'), HYPRLAND_NO_SD_VARS='1',
        HYPRLAND_NO_SD_NOTIFY='1', HYPRLAND_NO_CRASHREPORTER='1', HYPRLAND_NO_RT='1', GSETTINGS_BACKEND='memory',
        QT_QPA_PLATFORM='wayland', QT_QPA_PLATFORMTHEME='', NO_AT_BRIDGE='1')
    for key in ('NOTIFY_SOCKET', 'LISTEN_FDS', 'LISTEN_PID', 'WAYLAND_SOCKET'):
        env.pop(key, None)
    buscfg = work / 'bus.conf'
    buscfg.write_text('<busconfig><type>session</type><listen>unix:tmpdir=/tmp</listen><policy context="default"><allow send_destination="*"/><allow receive_sender="*"/><allow own="*"/></policy></busconfig>')
    bus = comp = proc = None
    helpers = []
    streams = []
    result = {'work': str(work), 'checks': [], 'passed': False}
    print('WORK', work, flush=True)
    try:
        bus = subprocess.Popen(['dbus-daemon', '--config-file=' + str(buscfg), '--nofork', '--print-address=1'], env=env, stdout=subprocess.PIPE, text=True)
        env['DBUS_SESSION_BUS_ADDRESS'] = bus.stdout.readline().strip()
        env['DBUS_SYSTEM_BUS_ADDRESS'] = env['DBUS_SESSION_BUS_ADDRESS']
        log = (work / 'compositor.log').open('w'); streams.append(log)
        comp = subprocess.Popen(['Hyprland', '-c', str(compositor_config)], env=env, stdout=log, stderr=log)
        child = wait(lambda: next((runtime / 'hypr').glob('*/.socket.sock'), None))
        assert child.is_relative_to(runtime) and child != parent
        for name in ('AUTH-A', 'AUTH-B'):
            assert ipc(child, 'output create headless ' + name).strip() == 'ok'
        wait(lambda: len(json.loads(ipc(child, 'j/monitors'))) == 2)
        assert not ipc(child, 'configerrors').strip()
        env.update(WAYLAND_DISPLAY=str(runtime / 'wayland-1'), HYPRLAND_INSTANCE_SIGNATURE=child.parent.name)
        log = (work / 'shell.log').open('w'); streams.append(log)
        proc = subprocess.Popen(['qs', '-p', str(shell), '--no-color'], env=env, stdout=log, stderr=log)

        def call(target, method, *values):
            assert proc.poll() is None, (work / 'shell.log').read_text()
            r = subprocess.run(['qs', 'ipc', '--pid', str(proc.pid), 'call', target, method, *map(str, values)], env=env, capture_output=True, text=True, timeout=5)
            if r.returncode:
                raise RuntimeError(r.stderr)
            return r.stdout.strip()

        def state():
            return json.loads(call('review', 'state'))

        def key(*values):
            subprocess.run(['wtype', *values], env=env, check=True, timeout=5)

        def ask(mode, prompt='OpenSSH test <b>plain text</b>'):
            p = subprocess.Popen([str(shell / 'scripts/ssh-askpass'), prompt], env=dict(env, SSH_ASKPASS_PROMPT=mode), stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            helpers.append(p)
            return p

        def snapshot(name):
            r = subprocess.run(['qs', '-p', str(Path(__file__).parent / 'fixtures/authentication-capture.qml'), '--no-color'],
                env=dict(env, QS_REVIEW_IMAGE=str(work / name)), capture_output=True, text=True, timeout=10)
            assert r.returncode == 0 and 'AUTH_SCREEN_SAVED true' in r.stdout + r.stderr, r.stdout + r.stderr

        def closed():
            wait(lambda: not state()['active'] and not state()['retained'] and not state()['count'])
            wait(lambda: 'quickshell-de:authentication' not in ipc(child, 'j/layers'))
            wait(lambda: not list(runtime.glob('qs-askpass-*')))
            if not args.qml_fade:
                time.sleep(1.1 if args.slow_motion else 0.2)

        def stats():
            values = Path(f'/proc/{proc.pid}/stat').read_text().rsplit(')', 1)[1].split()
            return (int(values[11]) + int(values[12]), int(values[21]) * os.sysconf('SC_PAGE_SIZE') // 1024)

        def measure():
            a = stats(); start = time.monotonic(); time.sleep(2); b = stats()
            return {'cpu_percent': round((b[0] - a[0]) / os.sysconf('SC_CLK_TCK') / (time.monotonic() - start) * 100, 2), 'rss_kib': b[1]}

        wait(lambda: state()['registered'])
        result['before'] = measure()
        snapshot('background.png')
        p = ask('none', 'Confirm user presence for key ED25519-SK')
        wait(lambda: state()['active'])
        assert not state()['interactive'] and not state()['input']
        wait(lambda: 'AUTH_IMAGE_SAVED' in (work / 'shell.log').read_text())
        shutil.copy2(work / 'view.png', work / 'touch.png')
        snapshot('backdrop.png')
        p.terminate(); p.communicate(timeout=3); closed()
        result['checks'].append('Touch notification: no keyboard grab/input; SIGTERM removes UI and private socket')

        p = ask('input'); wait(lambda: state()['input']); time.sleep(0.3)
        key('test-only-secret'); key('-k', 'Return')
        stdout, stderr = p.communicate(timeout=5)
        assert p.returncode == 0 and stdout == b'test-only-secret\n' and not stderr
        closed()
        assert 'test-only-secret' not in (work / 'shell.log').read_text()
        result['checks'].append('Masked input + Enter: response only on helper stdout, never shell logs')

        p = ask('input', 'Long untrusted prompt <b>plain text</b> ' * 180 + 'x' * 512)
        wait(lambda: state()['input']); time.sleep(0.3)
        layer = json.loads(ipc(child, 'j/layers'))
        windows = [item for monitor in layer.values() for level in monitor['levels'].values() for item in level
                   if item['namespace'] == 'quickshell-de:authentication']
        assert len(windows) == 1
        if args.compact:
            assert windows[0]['h'] <= 688
        else:
            assert windows[0]['w'] == 1280 and windows[0]['h'] == 720
        frame_lines = [line.split('AUTH_FRAME ', 1)[1] for line in (work / 'shell.log').read_text().splitlines() if 'AUTH_FRAME ' in line]
        frame = json.loads(frame_lines[-1])
        assert 0 < frame['height'] <= 688
        if not args.compact:
            assert frame['y'] >= 16
        key('-k', 'Escape'); p.communicate(timeout=5); closed()
        result['checks'].append('Long plain-text prompts stay inside output bounds and remain keyboard accessible')

        p = ask('confirm'); wait(lambda: state()['interactive']); time.sleep(0.25)
        key('-k', 'Escape'); stdout, stderr = p.communicate(timeout=5)
        assert p.returncode != 0 and not stdout; closed()
        p = ask('confirm'); wait(lambda: state()['interactive']); time.sleep(0.25)
        key('-k', 'Tab'); key('-k', 'Return'); stdout, stderr = p.communicate(timeout=5)
        assert p.returncode == 0 and stdout == b'yes\n'; closed()
        result['checks'].append('Confirmation: Escape denies; explicit keyboard confirmation accepts')

        a = ask('none'); wait(lambda: state()['active'])
        b = ask('input'); wait(lambda: state()['count'] == 2 and state()['input'])
        key('-k', 'Escape'); b.communicate(timeout=5)
        wait(lambda: state()['active'] and not state()['interactive'])
        a.terminate(); a.communicate(timeout=5); closed()
        result['checks'].append('Concurrent requests: input takes priority and returns to touch notification')

        call('review', 'polkit'); wait(lambda: state()['polkit'] and state()['input']); time.sleep(0.3)
        assert state()['prompt'] == 'Hasło'
        prefix = 'Konto zostało zablokowane z powodu nieudanych logowań.\n'
        for original, translated in [
            ('(1 minute left to unlock)', '(Odblokowanie za 1 min)'),
            ('(5 minutes left to unlock)', '(Odblokowanie za 5 min)'),
            ('(2 minutes to unlock)', '(Odblokowanie za 2 min)'),
            ('(120 minutes left to unlock)', '(Odblokowanie za 120 min)'),
            ('PIN klucza: Password Manager', 'PIN klucza: Password Manager'),
        ]:
            call('review', 'supplementary', prefix + original)
            wait(lambda: state()['supplementary'] == prefix + translated)
        call('review', 'supplementary', prefix + '(5 minutes left to unlock)')
        wait(lambda: state()['supplementary'] == prefix + '(Odblokowanie za 5 min)')
        time.sleep(0.4); snapshot('polish-polkit.png')
        call('review', 'supplementary', '')
        result['checks'].append('Polish password label and PAM lockout duration; numbers and custom messages preserved')
        key('wrong'); key('-k', 'Return'); wait(lambda: state()['error'])
        assert state()['active']; key('123456'); key('-k', 'Return'); closed()
        frames_dir = work / 'frames'
        frames_dir.mkdir()
        recorder = subprocess.Popen([str(recorder_binary), str(frames_dir), '6000' if args.slow_motion else '3000'],
            env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        helpers.append(recorder)
        preamble = []
        while True:
            line = recorder.stdout.readline()
            assert line, 'Recorder did not become ready: ' + ''.join(preamble)
            preamble.append(line)
            if 'AUTH_RECORD_READY' in line:
                break
        time.sleep(0.15)
        result['recording_events'] = {'request_ms': time.time_ns() // 1000000}
        call('review', 'polkit'); wait(lambda: state()['polkit']); time.sleep(1.5 if args.slow_motion else 0.45)
        result['recording_events']['escape_ms'] = time.time_ns() // 1000000
        key('-k', 'Escape'); closed()
        output, _ = recorder.communicate(timeout=8)
        (work / 'recording.log').write_text(''.join(preamble) + output)
        assert recorder.returncode == 0 and len(list(frames_dir.glob('frame-*.png'))) >= 15
        result['composed_fade'] = analyze_recording(work, result['recording_events'])
        if not args.qml_fade:
            fade = result['composed_fade']
            assert fade['max_transition_gap_ms'] <= 65, ('Capture cadence inadequate to assess fade', fade)
            assert fade['intermediate_entrance_frames'] >= 3 and fade['intermediate_exit_frames'] >= 3, fade
            assert fade['largest_exit_step'] < 0.55 and fade['largest_exit_reversal'] < 0.1, fade
        result['checks'].append('Actual compositor frames captured through Polkit entrance and Escape dismissal')
        result['checks'].append('Polkit model: identity selector, rejected PIN retry, success and cancellation')

        p = ask('input'); wait(lambda: state()['input']); call('review', 'reload')
        stdout, stderr = p.communicate(timeout=5)
        assert p.returncode != 0 and not stdout; closed()
        result['checks'].append('Reload during askpass fails closed without fallback or leaked response')

        call('review', 'capture', 'false')
        result['before_cycles'] = measure()
        samples = []
        for cycle in range(args.cycles):
            p = ask('none'); wait(lambda: state()['active']); time.sleep(0.22)
            p.terminate(); p.communicate(timeout=5); closed(); samples.append(stats()[1])
        result['cycle_rss_kib'] = samples
        result['after'] = measure()
        result['checks'].append(str(args.cycles) + ' cycles: no surviving surfaces, helpers or sockets')

        call('review', 'capture', 'true')
        call('review', 'reduced', 'true')
        saved_images = (work / 'shell.log').read_text().count('AUTH_IMAGE_SAVED')
        p = ask('none'); wait(lambda: state()['active'])
        name = state()['screen']
        assert ipc(child, 'output remove ' + name).strip() == 'ok'
        wait(lambda: state()['active'] and state()['screen'] != name)
        wait(lambda: (work / 'shell.log').read_text().count('AUTH_IMAGE_SAVED') > saved_images)
        shutil.copy2(work / 'view.png', work / 'touch-hotplug.png')
        p.terminate(); p.communicate(timeout=5); closed()
        result['checks'].append('Reduced motion and active output removal move prompt to remaining output')
        p = ask('input'); wait(lambda: state()['input'])
        call('lockscreen', 'lock')
        stdout, stderr = p.communicate(timeout=5)
        assert p.returncode != 0 and not stdout; closed()
        p = ask('input'); stdout, stderr = p.communicate(timeout=5)
        assert p.returncode != 0 and not stdout; closed()
        result['checks'].append('Lock transition cancels current request and denies new prompts without fallback')
        if args.qml_fade and not args.compact:
            frame_groups = {}
            for line in (work / 'shell.log').read_text().splitlines():
                if 'AUTH_FRAME ' in line:
                    frame = json.loads(line.split('AUTH_FRAME ', 1)[1])
                    frame_groups.setdefault(frame['id'], []).append(frame)
            checked = 0
            for frames in frame_groups.values():
                entrance = []
                for frame in frames:
                    if not frame['active'] or frame['opacity'] >= 1:
                        break
                    if frame['opacity'] > 0:
                        entrance.append(frame)
                if entrance and len({(f["input"], f["polkit"]) for f in entrance}) == 1:
                    geometry = {(f['width'], f['height'], f['x'], f['y'], f['scrollY']) for f in entrance}
                    assert len(geometry) == 1, ('Moving during fade-in', entrance)
                    assert all(a['opacity'] <= b['opacity'] for a, b in zip(entrance, entrance[1:]))
                    for frame in entrance:
                        assert abs(frame['x'] - (frame['windowWidth'] - frame['width']) / 2) <= 1
                        assert abs(frame['y'] - (frame['windowHeight'] - frame['height']) / 2) <= 1
                    checked += 1
                leaving = [frame for frame in frames if not frame['active']]
                assert all(a['opacity'] >= b['opacity'] for a, b in zip(leaving, leaving[1:])), leaving
            assert checked >= args.cycles
            result['fade_surfaces_checked'] = checked
            result['checks'].append('Fade only: centered, stable card geometry and scroll position; monotonic entrance/exit opacity')
        if not args.qml_fade:
            geometry_frames = [json.loads(line.split('AUTH_FRAME ', 1)[1]) for line in (work / 'shell.log').read_text().splitlines() if 'AUTH_FRAME ' in line]
            assert geometry_frames
            for frame in geometry_frames:
                assert frame['opacity'] == 1
                assert abs(frame['x'] - (frame['windowWidth'] - frame['width']) / 2) <= 1, frame
                assert abs(frame['y'] - (frame['windowHeight'] - frame['height']) / 2) <= 1, frame
            result['checks'].append('Stable, opaque QML buffers centered before native compositor fade')
        warnings = [line for line in (work / 'shell.log').read_text().splitlines() if re.search('WARN |TypeError:|ReferenceError:|Binding loop|Cannot assign|Unable to assign', line)]
        warnings = [line for line in warnings if 'Failed to register with host portal' not in line]
        result['warnings'] = warnings
        assert not warnings, warnings
        result['passed'] = True
    finally:
        for p in helpers: stop(p)
        stop(proc); stop(comp); stop(bus)
        for stream in streams: stream.close()
        result['production_before'] = before
        result['production_after'] = production_state(parent)
        result['production_unchanged'] = before == result['production_after']
        (work / 'result.json').write_text(json.dumps(result, indent=2))
        print(json.dumps(result, indent=2), flush=True)
        assert result['production_unchanged']


if __name__ == '__main__':
    run()
