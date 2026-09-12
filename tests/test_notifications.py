#!/usr/bin/env python3
"""Real Quickshell/D-Bus integration on a private bus; no session notifications."""
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time

if os.environ.get('QS_NOTIFICATION_TEST_BUS') != '1':
    env = dict(os.environ, QS_NOTIFICATION_TEST_BUS='1')
    raise SystemExit(subprocess.call(['dbus-run-session', '--', sys.executable, __file__], env=env))

root = Path(__file__).resolve().parents[1]
work = Path(tempfile.mkdtemp(prefix='quickshell-notifications-test-'))
config = work / 'shell'
shutil.copytree(root, config, ignore=shutil.ignore_patterns('inspirations', 'test-shell.qml'))
shutil.copy2(config / 'tests/fixtures/notification-service.qml', config / 'shell.qml')
runtime = work / 'runtime'
runtime.mkdir(mode=0o700)
data_home = work / 'data'
(data_home / 'applications').mkdir(parents=True)
launch_marker = work / 'launched-marker'
(data_home / 'applications/qs-notification-fixture.desktop').write_text(f'[Desktop Entry]\nType=Application\nName=QS Notification Fixture\nExec=/usr/bin/touch {launch_marker}\nStartupWMClass=qs-notification-fixture\n')
env = dict(os.environ, XDG_DATA_HOME=str(data_home), QS_NO_RELOAD_POPUP='1', QT_QPA_PLATFORM='offscreen', XDG_RUNTIME_DIR=str(runtime), XDG_CONFIG_HOME=str(work / 'config'), XDG_STATE_HOME=str(work / 'state'), XDG_CACHE_HOME=str(work / 'cache'), HYPRLAND_INSTANCE_SIGNATURE='', WAYLAND_DISPLAY='')
state_path = work / 'state/quickshell-de/notifications.json'
proc = None
log = (work / 'shell.log').open('w+')
monitor_log = (work / 'signals.log').open('w+')
monitor = subprocess.Popen(['dbus-monitor', '--session', "type='signal',interface='org.freedesktop.Notifications'"], stdout=monitor_log, stderr=subprocess.DEVNULL, env=env)

def ipc(method, *args):
    return subprocess.check_output(['qs', 'ipc', '--pid', str(proc.pid), 'call', 'test', method, *[str(x).lower() if isinstance(x, bool) else str(x) for x in args]], env=env, stderr=subprocess.DEVNULL, text=True).strip()

def state(): return json.loads(ipc('state'))

def until(predicate, timeout=5):
    end = time.monotonic() + timeout
    last = None
    while time.monotonic() < end:
        try:
            last = predicate()
            if last: return last
        except (subprocess.CalledProcessError, json.JSONDecodeError): pass
        time.sleep(.05)
    raise AssertionError(f'Timeout; last result: {last}; logs: {work}')

def start():
    global proc
    proc = subprocess.Popen(['qs', '-p', str(config), '--no-color'], env=env, stdout=log, stderr=subprocess.STDOUT)
    until(lambda: state()['state'] in ('ready', 'error'))

def stop():
    global proc
    if proc and proc.poll() is None:
        proc.send_signal(signal.SIGTERM)
        proc.wait(timeout=5)

def call(method, *args):
    return subprocess.check_output(['gdbus', 'call', '--session', '--dest', 'org.freedesktop.Notifications', '--object-path', '/org/freedesktop/Notifications', '--method', 'org.freedesktop.Notifications.' + method, '--', *args], env=env, text=True).strip()

def notify(summary='Test', body='Treść', app='TestApp', replaces=0, actions=(), hints='{}'):
    result = call('Notify', app, str(replaces), '', summary, body, json.dumps(list(actions), ensure_ascii=False), hints, '-1')
    nid = int(re.search(r'uint32 (\d+)', result)[1])
    until(lambda: any(r['serverId'] == nid and r['summary'] == summary for r in state()['records']))
    return next(r for r in state()['records'] if r['serverId'] == nid)

def check(name): print('PASS', name, flush=True)

try:
    start()
    assert not state()['error'], state()
    assert 'persistence' in call('GetCapabilities') and 'actions' in call('GetCapabilities')
    r = notify(actions=['default', 'Otwórz', 'archive', 'Archiwizuj'])
    assert state()['hasNew'] and len(state()['toasts']) == 1
    assert state()['toasts'][0]['remaining'] == 6000
    uid, nid = r['uid'], r['serverId']
    ipc('hide', uid)
    assert len(state()['records']) == 1 and not state()['toasts']
    ipc('activate', uid, 'archive')
    until(lambda: not state()['records'][0]['actions'])
    time.sleep(.15)
    monitor_log.flush()
    signals = (work / 'signals.log').read_text()
    assert 'ActionInvoked' in signals and '"archive"' in signals and 'NotificationClosed' in signals
    check('protocol capabilities, hide retains live actions, action signal, archive after sender closure')

    ipc('clear')
    r = notify('Before')
    updated = notify('After', replaces=r['serverId'])
    assert updated['uid'] == r['uid'] and len(state()['records']) == 1
    call('CloseNotification', str(r['serverId']))
    until(lambda: not state()['toasts'])
    assert state()['records'][0]['summary'] == 'After'
    check('Notify replacement updates one record; CloseNotification archives it')

    ipc('clear'); ipc('duration', 1000)
    r = notify('Timer')
    time.sleep(.4); ipc('pause', r['uid'], True)
    time.sleep(1.1); assert len(state()['toasts']) == 1
    ipc('pause', r['uid'], False)
    until(lambda: not state()['toasts'], 2)
    assert len(state()['records']) == 1
    r = notify('Critical', hints="{'urgency': <byte 2>}")
    time.sleep(1.2); assert len(state()['toasts']) == 1
    ipc('dnd', True); assert not state()['toasts']
    notify('DND critical', hints="{'urgency': <byte 2>}")
    assert not state()['toasts'] and len(state()['records']) == 3
    ipc('dnd', False); assert not state()['toasts']
    check('timeout, hover pause, manual critical dismissal, DND including critical, no replay')

    ipc('clear'); ipc('duration', 6000)
    for i in range(5): notify(f'Burst {i}')
    assert len(state()['records']) == 5 and len(state()['toasts']) == 3
    assert state()['hasNew']
    screen = state()['toasts'][0]['screen']
    ipc('center', screen, True)
    assert not state()['toasts'] and not state()['hasNew']
    notify('Center open')
    assert not state()['toasts'] and not state()['hasNew']
    ipc('center', screen, False)
    uid = state()['records'][0]['uid']
    ipc('discard', uid); assert state()['undo'] and len(state()['records']) == 5
    ipc('undo'); assert not state()['undo'] and len(state()['records']) == 6
    ipc('discard', uid)
    until(lambda: not state()['undo'], 6)
    assert len(state()['records']) == 5
    check('three-toast burst limit, center suppression/read dot, discard and undo deadline')

    notify('Other', app='SecondApp', body='needle')
    groups = json.loads(ipc('groups', ''))
    assert len(groups) == 2 and groups[0]['name'] == 'SecondApp'
    assert len(json.loads(ipc('groups', 'needle'))) == 1
    ipc('limit', 3); assert len(state()['records']) == 3
    check('group ordering, app/body search, immediate retention count limit')

    ipc('clear'); ipc('limit', 500)
    r = notify('Reload live', actions=['default','Open','secondary','Run'])
    transient = notify('Secret transient', hints="{'transient': <true>}")
    ipc('dnd', True)
    time.sleep(.5)
    saved = json.loads(state_path.read_text())
    assert len(saved['records']) == 1 and saved['records'][0]['summary'] == 'Reload live'
    assert 'actions' not in saved['records'][0]
    assert state_path.stat().st_mode & 0o777 == 0o600
    assert state_path.parent.stat().st_mode & 0o777 == 0o700
    # A new QML generation keeps native live IDs but must not replay any toast.
    shell_file = config / 'shell.qml'
    shell_file.write_text(shell_file.read_text() + '\n// reload test\n')
    time.sleep(.5)
    until(lambda: state()['state'] in ('ready', 'error'))
    assert state()['dnd'] and not state()['toasts']
    assert len([v for v in state()['records'] if v['summary'] == 'Reload live']) == 1
    live = next(v for v in state()['records'] if v['summary'] == 'Reload live')
    assert live['uid'] == r['uid'] and live['actions']
    ipc('activate', live['uid'], 'secondary')
    time.sleep(.4)
    stop(); start()
    assert state()['dnd'] and not state()['toasts']
    assert len(state()['records']) == 1 and not state()['records'][0]['actions']
    check('private atomic persistence, transient exclusion, reload live actions, restart archive/DND')

    ipc('clear')
    thrown = notify('Discard just before reload')
    ipc('discard', thrown['uid'])
    shell_file.write_text(shell_file.read_text() + '\n// immediate discard reload\n')
    time.sleep(.5)
    until(lambda: state()['state'] in ('ready', 'error'))
    assert not state()['records'], state()
    check('discard during undo window is not resurrected on QML reload')

    stop()
    stale = dict(saved['records'][0], uid='old', time=int((time.time() - 8 * 86400) * 1000))
    saved['records'] = [stale, *saved['records']]
    state_path.write_text(json.dumps(saved))
    start()
    assert all(r['uid'] != 'old' for r in state()['records'])
    stop()
    state_path.write_text('{ corrupt')
    start()
    assert not state()['records'] and '.corrupt' in state()['error']
    assert list(state_path.parent.glob('notifications.json.corrupt-*'))
    notify('Survives corruption')
    check('seven-day pruning and corrupt-file quarantine with functioning server')

    ipc('clear')
    r = notify('Launch known entry', app='QS Notification Fixture', hints="{'desktop-entry': <'qs-notification-fixture'>}")
    ipc('activate', r['uid'], '')
    until(lambda: launch_marker.exists())
    r = notify('Unknown application', app='Definitely-not-a-real-application-752481')
    ipc('activate', r['uid'], '')
    assert state()['error']
    check('native DesktopEntry launch and visible failure for unknown applications')

    ipc('clear'); ipc('dnd', True)
    for i in range(505):
        call('Notify', 'Flood', '0', '', str(i), 'Bounded history', '[]', '{}', '1000')
    until(lambda: json.loads(ipc('stats'))['count'] == 500)
    assert json.loads(ipc('stats')) == dict(count=500, first='504', toasts=0)
    check('505-notification flood retains exactly the newest 500 records')

    time.sleep(.4)
    log.flush()
    text = (work / 'shell.log').read_text()
    unexpected = [line for line in text.splitlines() if ('ERROR' in line or 'TypeError' in line or 'ReferenceError' in line or 'Binding loop' in line)]
    assert not unexpected, '\n'.join(unexpected)
    print('All notification integration checks passed. Artifacts:', work, flush=True)
finally:
    stop()
    monitor.terminate(); monitor.wait(timeout=3)
    log.close(); monitor_log.close()
