#!/usr/bin/env python3
"""Unrelated settings reloads must preserve live toolbar delegate ownership."""
import json,os,shutil,subprocess,tempfile,time,sys
from pathlib import Path
if os.environ.get('QS_SETTINGS_PRIVATE_BUS') != '1':
 raise SystemExit(subprocess.call(['dbus-run-session','--',sys.executable,__file__],env=dict(os.environ,QS_SETTINGS_PRIVATE_BUS='1')))
root=Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='qs-settings-stability-') as tmp:
 w=Path(tmp);c=w/'shell';c.mkdir();shutil.copytree(root/'core',c/'core')
 (c/'core/qmldir').write_text('module qs.core\nsingleton Settings 1.0 Settings.qml\n')
 (c/'shell.qml').write_text('''import QtQuick
import Quickshell
import Quickshell.Io
import qs.core
ShellRoot {
 id: root
 property int created: 0
 property int destroyed: 0
 Window { visible: true; width: 100; height: 100; Repeater {
  model: Settings.rightModules
  Item { Component.onCompleted: root.created++; Component.onDestruction: root.destroyed++ }
 } }
 IpcHandler {
  target: "test"
  function status(): string { return JSON.stringify({created: root.created, destroyed: root.destroyed, revision: Settings.revision, modules: Settings.rightModules, duration: Settings.notificationToastDuration}); }
 }
}''')
 runtime=w/'runtime';runtime.mkdir(mode=0o700)
 conf=w/'config/quickshell-de';conf.mkdir(parents=True)
 p=conf/'settings.json';s=json.loads((root/'config/settings.example.json').read_text());p.write_text(json.dumps(s))
 env=dict(os.environ,QT_QPA_PLATFORM='offscreen',QT_QPA_PLATFORMTHEME='',WAYLAND_DISPLAY='',HYPRLAND_INSTANCE_SIGNATURE='',XDG_RUNTIME_DIR=str(runtime),XDG_CONFIG_HOME=str(w/'config'),XDG_STATE_HOME=str(w/'state'),XDG_CACHE_HOME=str(w/'cache'))
 with (w/'log').open('w+') as log:
  proc=subprocess.Popen(['qs','-p',str(c),'--no-color'],env=env,stdout=log,stderr=log)
  def state():
   r=subprocess.run(['qs','ipc','--pid',str(proc.pid),'call','test','status'],env=env,capture_output=True,text=True,timeout=2)
   return json.loads(r.stdout) if r.returncode==0 and r.stdout.strip() else None
  try:
   deadline=time.monotonic()+8
   while True:
    a=state()
    if a and a['revision']>0:break
    assert time.monotonic()<deadline,'startup timeout'
    time.sleep(.1)
   for i in range(20):
    s['notificationToastDuration']=6000+i+1;p.write_text(json.dumps(s));deadline=time.monotonic()+3
    while True:
     b=state()
     if b['duration']==s['notificationToastDuration']:break
     assert time.monotonic()<deadline,'settings timeout'
     time.sleep(.05)
    assert (b['created'],b['destroyed'])==(a['created'],a['destroyed']),(a,b)
   print('PASS: 20 file reloads preserve all toolbar delegates')
   s['rightModules']=list(reversed(s['rightModules']));p.write_text(json.dumps(s));deadline=time.monotonic()+3
   while True:
    b=state()
    if b['modules']==s['rightModules']:break
    assert time.monotonic()<deadline,'reorder timeout'
    time.sleep(.05)
   assert b['created']>a['created'] and b['destroyed']>a['destroyed']
   print('PASS: actual module reordering updates delegates')
  except Exception:
   log.seek(0);print(log.read());raise
  finally:
   proc.terminate();proc.wait(timeout=3)
