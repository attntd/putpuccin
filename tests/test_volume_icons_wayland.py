#!/usr/bin/env python3
"""Run quick-menu and real OSD icon regressions on a private headless output."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

from caffeinate_bus import PrivateLogind
from test_lockscreen_wayland import ipc, production_state, wait, stop

work = Path(tempfile.mkdtemp(prefix='qvol-'))
runtime = work / 'r'
runtime.mkdir(mode=0o700)
parent_runtime = Path(os.environ['XDG_RUNTIME_DIR'])
parent = parent_runtime / 'hypr' / os.environ['HYPRLAND_INSTANCE_SIGNATURE'] / '.socket.sock'
before = production_state(parent)
display = Path(os.environ['WAYLAND_DISPLAY'])
if not display.is_absolute():
    display = parent_runtime / display
scale = float(os.environ.get('QS_VOLUME_TEST_SCALE', '1'))
assert scale in (1, 1.2, 1.5, 2)
config = work / 'hyprland.lua'
config.write_text('''hl.monitor({output="WAYLAND-1", disabled=true})
hl.monitor({output="VOLUME", mode="1920x1080@60", position="0x0", scale=''' + str(scale) + '''})
hl.config({misc={disable_hyprland_logo=true,disable_splash_rendering=true,force_default_wallpaper=0},animations={enabled=false},xwayland={enabled=false}})
''')
bus = PrivateLogind(work)
env = dict(os.environ, XDG_RUNTIME_DIR=str(runtime), XDG_CONFIG_HOME=str(work / 'config'),
    XDG_CACHE_HOME=str(work / 'cache'), XDG_STATE_HOME=str(work / 'state'),
    XDG_DATA_HOME=str(work / 'data'), WAYLAND_DISPLAY=str(display), DISPLAY='',
    HYPRLAND_INSTANCE_SIGNATURE='', LIBSEAT_BACKEND='seatd', SEATD_SOCK=str(work / 'missing'),
    AQ_DRM_DEVICES=str(work / 'missing'), HYPRLAND_NO_SD_VARS='1', HYPRLAND_NO_SD_NOTIFY='1',
    HYPRLAND_NO_CRASHREPORTER='1', HYPRLAND_NO_RT='1', QT_QPA_PLATFORM='wayland',
    QT_QPA_PLATFORMTHEME='', NO_AT_BRIDGE='1', GSETTINGS_BACKEND='memory',
    DBUS_SESSION_BUS_ADDRESS=bus.address, DBUS_SYSTEM_BUS_ADDRESS=bus.address)
for key in ('NOTIFY_SOCKET', 'LISTEN_FDS', 'LISTEN_PID', 'WAYLAND_SOCKET', 'QT_SCALE_FACTOR'):
    env.pop(key, None)
comp = None
try:
    with (work / 'compositor.log').open('w') as log:
        comp = subprocess.Popen(['Hyprland', '-c', str(config)], env=env, stdout=log, stderr=log)
        child = wait(lambda: next((runtime / 'hypr').glob('*/.socket.sock'), None))
        assert child.is_relative_to(runtime) and child != parent
        assert ipc(child, 'output create headless VOLUME').strip() == 'ok'
        monitors = wait(lambda: json.loads(ipc(child, 'j/monitors')))
        assert len(monitors) == 1 and monitors[0]['scale'] == scale
        assert not ipc(child, 'configerrors').strip()
        env.update(QS_QUICK_TILES_ONLY='1', QS_CAFFEINATE_WAYLAND=str(runtime / 'wayland-1'))
        result = subprocess.run([sys.executable, str(Path(__file__).with_name('test_caffeinate.py'))],
            env=env, timeout=150 if env.get('QS_QUICK_AUDIO_ONLY') == '1' else 90)
        assert result.returncode == 0, str(work)
finally:
    stop(comp)
    bus.close()
    unchanged = before == production_state(parent)
    (work / 'result.json').write_text(json.dumps({'scale': scale, 'production_unchanged': unchanged}))
    print('Private compositor:', work, 'production unchanged:', unchanged, flush=True)
    assert unchanged
