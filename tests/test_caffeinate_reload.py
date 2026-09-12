#!/usr/bin/env python3
"""Reload the actual QS service while measuring continuous logind FD ownership."""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time

from caffeinate_bus import PrivateLogind

ROOT = Path(__file__).resolve().parents[1]
WORK = Path(tempfile.mkdtemp(prefix='qs-caffeinate-reload-test-'))
CONFIG = WORK / 'shell'
for directory, name in [('services', 'CaffeinateService'), ('core', 'Strings')]:
    folder = CONFIG / directory
    folder.mkdir(parents=True)
    shutil.copy2(ROOT / directory / (name + '.qml'), folder)
    (folder / 'qmldir').write_text(f'module qs.{directory}\nsingleton {name} 1.0 {name}.qml\n')
shutil.copytree(ROOT / 'integrations/SessionNative', CONFIG / 'integrations/SessionNative')
original = (ROOT / 'tests/fixtures/caffeinate_reload.qml').read_text()
shell = CONFIG / 'shell.qml'
shell.write_text(original)
(WORK / 'runtime').mkdir(mode=0o700)
bus = PrivateLogind(WORK)
env = dict(os.environ, **bus.env, QT_QPA_PLATFORM='offscreen', QT_QPA_PLATFORMTHEME='',
           WAYLAND_DISPLAY='', HYPRLAND_INSTANCE_SIGNATURE='', NO_AT_BRIDGE='1',
           XDG_RUNTIME_DIR=str(WORK / 'runtime'), QML_IMPORT_PATH=str(CONFIG / 'integrations'),
           XDG_CONFIG_HOME=str(WORK / 'config'), XDG_STATE_HOME=str(WORK / 'state'),
           XDG_CACHE_HOME=str(WORK / 'cache'))
proc = None
logs = []


def start():
    global proc
    path = WORK / f'shell-{len(logs)}.log'
    logs.append(path)
    with path.open('w') as log:
        proc = subprocess.Popen(['qs', '-p', str(CONFIG), '--no-color'], env=env, stdout=log, stderr=log)
    wait_for(lambda: info()['initialMode'] == 'off')


def ipc(target, method, *args):
    result = subprocess.run(['qs', 'ipc', '--pid', str(proc.pid), 'call', target, method,
                             *[str(arg).lower() if isinstance(arg, bool) else str(arg) for arg in args]],
                            env=env, capture_output=True, text=True, timeout=5)
    assert result.returncode == 0, (result.stdout, result.stderr, str(WORK))
    return result.stdout.strip()


def status(): return json.loads(ipc('caffeinate', 'status'))
def info(): return json.loads(ipc('reloadtest', 'status'))


def wait_for(check, timeout=6):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        assert proc is None or proc.poll() is None, str(WORK)
        try:
            if value := check(): return value
        except (AssertionError, json.JSONDecodeError): pass
        time.sleep(.02)
    raise AssertionError(('timeout', str(WORK), [p.read_text()[-1500:] for p in logs]))


def set_mode(mode):
    ipc('caffeinate', 'setMode', mode)
    wait_for(lambda: status()['mode'] == mode and not status()['busy'])
    wait_for(lambda: len(bus.leases()['active']) == (mode != 'off'))


def reload(hard, expected):
    previous = info()['generation']
    ipc('reloadtest', 'reload', hard)
    wait_for(lambda: info()['generation'] != previous)
    assert info()['initialMode'] == expected, (info(), expected)
    assert status()['mode'] == expected, status()


def sample():
    values = (Path('/proc') / str(proc.pid) / 'stat').read_text().split()
    return dict(ticks=int(values[13]) + int(values[14]),
                rss_kib=int(values[23]) * os.sysconf('SC_PAGE_SIZE') // 1024,
                fds=len(list((Path('/proc') / str(proc.pid) / 'fd').iterdir())))


def measure():
    before = sample()
    start_time = time.monotonic()
    time.sleep(1)
    after = sample()
    after['cpu_percent'] = round((after['ticks'] - before['ticks']) / os.sysconf('SC_CLK_TCK')
                                  / (time.monotonic() - start_time) * 100, 2)
    return after


def stop(kill=False):
    global proc
    if proc and proc.poll() is None:
        proc.kill() if kill else proc.terminate()
        proc.wait(timeout=5)
    proc = None
    wait_for(lambda: not bus.leases()['active'])


try:
    start()
    assert bus.leases()['calls'] == 0
    set_mode('presentation')
    lease = bus.leases()
    before = measure()
    cycles = []
    modes = ['background', 'presentation', 'secure-background']
    for cycle in range(20):
        mode = modes[cycle % len(modes)]
        set_mode(mode)
        reload(cycle % 2 == 1, mode)
        # An unchanged FD identity and no EOF prove there was no lease gap.
        assert bus.leases() == lease, (cycle, bus.leases(), lease)
        cycles.append(dict(cycle=cycle, mode=mode, hard=cycle % 2 == 1, **sample()))
    after = measure()
    assert max(s['fds'] for s in cycles[5:]) <= cycles[5]['fds'] + 1, cycles

    # Invalid QML keeps the last working generation and its exact lease.
    previous = info()
    shell.write_text(original + '\nthis is intentionally invalid QML\n')
    ipc('reloadtest', 'reload', False)
    wait_for(lambda: info()['failures'] > previous['failures'])
    assert info()['generation'] == previous['generation'] and bus.leases() == lease
    shell.write_text(original)
    reload(False, mode)

    set_mode('off')
    calls = bus.leases()['calls']
    for hard in [False, True, False, True]: reload(hard, 'off')
    assert bus.leases()['calls'] == calls and not bus.leases()['active']

    # Reload while Inhibit is pending, then change the latest request.
    bus.behavior('held')
    ipc('caffeinate', 'setMode', 'background')
    assert status()['busy'] and not status()['active']
    reload(True, 'off')
    ipc('caffeinate', 'setMode', 'off')
    ipc('caffeinate', 'setMode', 'secure-background')
    bus.control('FinishPending')
    wait_for(lambda: status()['mode'] == 'secure-background' and not status()['busy'])
    assert bus.leases()['calls'] == calls + 1
    set_mode('off')
    calls = bus.leases()['calls']
    ipc('caffeinate', 'setMode', 'background')
    ipc('caffeinate', 'setMode', 'off')
    reload(False, 'off')
    bus.control('FinishPending')
    wait_for(lambda: not status()['busy'])
    wait_for(lambda: not bus.leases()['active'])
    assert bus.leases()['calls'] == calls + 1

    failures = {}
    for behavior in ['fail', 'malformed', 'timeout']:
        bus.behavior(behavior)
        ipc('caffeinate', 'setMode', 'presentation')
        failures[behavior] = wait_for(lambda: (s if s['error'] and not s['busy'] else None)
                                      if (s := status()) else None)
        assert not status()['active']
        if behavior == 'timeout':
            issued = bus.leases()['issued']
            wait_for(lambda: bus.leases()['issued'] > issued)
            wait_for(lambda: not bus.leases()['active'])
        bus.behavior('ready')
        set_mode('background')
        set_mode('off')

    # Loss of logind clears claims immediately; explicit retry after return.
    set_mode('presentation')
    bus.control('ReleaseName')
    wait_for(lambda: status()['error'] and not status()['active'])
    wait_for(lambda: not bus.leases()['active'])
    ipc('caffeinate', 'setMode', 'presentation')
    wait_for(lambda: status()['error'] and not status()['busy'])
    bus.control('AcquireName')
    set_mode('background')

    # Removing the service on a successful reload must release the inhibitor.
    removed = original.replace('    readonly property var caffeinate: CaffeinateService\n', '')
    removed = removed.replace('initialMode = CaffeinateService.mode;', 'initialMode = "removed";')
    shell.write_text(removed)
    previous = info()['generation']
    ipc('reloadtest', 'reload', True)
    wait_for(lambda: info()['generation'] != previous)
    wait_for(lambda: not bus.leases()['active'])
    shell.write_text(original)
    reload(False, 'off')

    # No stale pending response may resurrect a lease after service removal.
    bus.behavior('held')
    ipc('caffeinate', 'setMode', 'presentation')
    shell.write_text(removed)
    previous = info()['generation']
    ipc('reloadtest', 'reload', True)
    wait_for(lambda: info()['generation'] != previous)
    issued = bus.leases()['issued']
    bus.control('FinishPending')
    wait_for(lambda: bus.leases()['issued'] > issued)
    wait_for(lambda: not bus.leases()['active'])
    shell.write_text(original)
    reload(False, 'off')
    bus.behavior('ready')

    set_mode('presentation')
    stop()
    start()
    assert status()['mode'] == 'off' and not bus.leases()['active']
    set_mode('secure-background')
    stop(kill=True)
    start()
    assert status()['mode'] == 'off'

    # Whole D-Bus disconnect also clears the visible active state.
    set_mode('background')
    bus.daemon.terminate()
    bus.daemon.wait(timeout=3)
    wait_for(lambda: not status()['active'] and status()['error'])
    wait_for(lambda: not bus.leases()['active'])
    stop()
    warnings = re.findall(r'^.*(?:WARN scene|ReferenceError:|TypeError:|Binding loop).*$','\n'.join(p.read_text() for p in logs), re.M)
    assert not warnings, warnings
    assert lease['requests'][0][0] == 'sleep' and lease['requests'][0][3] == 'block'
    result = dict(passed=True, before=before, after=after, reload_cycles=cycles,
                  failures=failures, final_leases=bus.leases())
    (WORK / 'result.json').write_text(json.dumps(result, indent=2))
    print(json.dumps(dict(artifacts=str(WORK), **result), indent=2))
finally:
    if proc and proc.poll() is None:
        proc.terminate()
        try: proc.wait(timeout=3)
        except subprocess.TimeoutExpired: proc.kill(); proc.wait()
    bus.close()
