#!/usr/bin/python
"""Actual SystemActions with absolute fake executables; never power/lock/logout."""
import json,os,shutil,subprocess,time,tempfile
from pathlib import Path
root=Path(__file__).resolve().parents[1];work=Path(tempfile.mkdtemp(prefix='quickshell-power-process-'))
for d in ('services','stubs','scripts','runtime'): (work/d).mkdir(mode=0o700)
(work/'services/qmldir').write_text('singleton SystemActions 1.0 SystemActions.qml\n')
s=(root/'services/SystemActions.qml').read_text().replace('import Quickshell.Hyprland','import "../stubs"').replace('["systemctl", unitAction]', '['+json.dumps(str(work/'scripts/fake-systemctl'))+', unitAction]')
(work/'services/SystemActions.qml').write_text(s)
(work/'stubs/qmldir').write_text('singleton Hyprland 1.0 Hyprland.qml\n')
(work/'stubs/Hyprland.qml').write_text('pragma Singleton\nimport QtQuick\nQtObject { property bool usingLua: true; function dispatch(command) {} }\n')
(work/'scripts/power-capabilities').write_text('#!/bin/sh\nexit 0\n');(work/'scripts/power-capabilities').chmod(0o755)
assert '['+json.dumps(str(work/'scripts/fake-systemctl'))+', unitAction]' in s
(work/'scripts/fake-systemctl').write_text('#!/usr/bin/python\nimport pathlib,sys,time\nwith pathlib.Path('+repr(str(work/'action.json'))+').open("a") as log: log.write(sys.argv[1]+"\\n")\ntime.sleep(.1)\nsys.exit(int(pathlib.Path('+repr(str(work/'exit-code'))+').read_text()))\n');(work/'scripts/fake-systemctl').chmod(0o755)
(work/'scripts/lock-screen').write_text('#!/usr/bin/python\nimport pathlib,sys,time\nwith pathlib.Path('+repr(str(work/'action.json'))+').open("a") as log: log.write("lock\\n")\ntime.sleep(.2)\ncode=int(pathlib.Path('+repr(str(work/'exit-code'))+').read_text())\nif code: print("Lock helper failure",file=sys.stderr)\nsys.exit(code)\n');(work/'scripts/lock-screen').chmod(0o755)
(work/'exit-code').write_text('0')
(work/'shell.qml').write_text('''import QtQuick
import Quickshell
import Quickshell.Io
import "services" as Services
ShellRoot {
 property var completed: []
 property var failures: []
 Connections { target: Services.SystemActions
  function onSucceeded(actionId) { completed=completed.concat([actionId]); }
  function onFailed(actionId, message) { failures=failures.concat([actionId]); }
 }
 IpcHandler { target: "audit"
  function rapid(): string { Services.SystemActions.execute("suspend");Services.SystemActions.execute("reboot");return JSON.stringify({busy:Services.SystemActions.busy,pending:Services.SystemActions.pendingAction}); }
  function single(): void { Services.SystemActions.execute("suspend"); }
  function lock(): string { Services.SystemActions.execute("lock");return JSON.stringify({busy:Services.SystemActions.busy,pending:Services.SystemActions.pendingAction,completed:completed}); }
  function errorText(): string { return Services.SystemActions.errorMessage; }
  function snapshot(): string { return JSON.stringify({busy:Services.SystemActions.busy,pending:Services.SystemActions.pendingAction,error:!!Services.SystemActions.errorMessage,completed:completed,failures:failures}); }
 }
}
''')
env=dict(os.environ,QT_QPA_PLATFORM='offscreen',WAYLAND_DISPLAY='',HYPRLAND_INSTANCE_SIGNATURE='',XDG_RUNTIME_DIR=str(work/'runtime'),DBUS_SESSION_BUS_ADDRESS='unix:path=/no-audit-bus',DBUS_SYSTEM_BUS_ADDRESS='unix:path=/no-audit-bus')
with (work/'shell.log').open('w') as log:
 p=subprocess.Popen(['qs','-p',str(work),'--no-color'],env=env,stdout=log,stderr=log)
 def ipc(method):
  r=subprocess.run(['qs','ipc','--pid',str(p.pid),'call','audit',method],env=env,capture_output=True,text=True,timeout=3)
  assert r.returncode==0,r.stderr;return r.stdout.strip()
 try:
  for _ in range(60):
   try:ipc('snapshot');break
   except AssertionError:time.sleep(.05)
  def settled():
   deadline=time.monotonic()+3
   while time.monotonic()<deadline:
    snapshot=json.loads(ipc('snapshot'))
    if not snapshot['busy'] and not snapshot['pending']:return snapshot
    time.sleep(.025)
   raise AssertionError(snapshot)
  immediate=json.loads(ipc('rapid'));after=settled()
  assert immediate==dict(busy=True,pending='suspend'),immediate
  assert after==dict(busy=False,pending='',error=False,completed=['suspend'],failures=[]),after
  assert (work/'action.json').read_text().splitlines()==['suspend']
  (work/'scripts/fake-systemctl').rename(work/'scripts/fake-systemctl.saved');ipc('single');missing=settled()
  assert missing['error'] and missing['failures']==['suspend'] and missing['completed']==['suspend'],missing
  (work/'scripts/fake-systemctl.saved').rename(work/'scripts/fake-systemctl');(work/'exit-code').write_text('1')
  ipc('single');rejected=settled();assert rejected['error'] and rejected['failures']==['suspend','suspend'],rejected
  (work/'exit-code').write_text('0');ipc('single');recovered=settled()
  assert not recovered['error'] and recovered['completed']==['suspend','suspend'],recovered
  assert (work/'action.json').read_text().splitlines()==['suspend','suspend','suspend']
  lockImmediate=json.loads(ipc('lock'))
  assert lockImmediate==dict(busy=True,pending='lock',completed=['suspend','suspend']),lockImmediate
  lockConfirmed=settled()
  assert lockConfirmed['completed']==['suspend','suspend','lock'] and not lockConfirmed['error'],lockConfirmed
  (work/'scripts/lock-screen').rename(work/'scripts/lock-screen.saved');ipc('lock');lockMissing=settled()
  assert lockMissing['error'] and lockMissing['failures']==['suspend','suspend','lock'],lockMissing
  (work/'scripts/lock-screen.saved').rename(work/'scripts/lock-screen');(work/'exit-code').write_text('1')
  ipc('lock');lockRejected=settled()
  assert lockRejected['error'] and lockRejected['failures']==['suspend','suspend','lock','lock'],lockRejected
  assert ipc('errorText')=='Lock helper failure'
  (work/'exit-code').write_text('0');ipc('lock');lockRecovered=settled()
  assert lockRecovered['completed']==['suspend','suspend','lock','lock'] and not lockRecovered['error'],lockRecovered
  assert (work/'action.json').read_text().splitlines()==['suspend','suspend','suspend','lock','lock','lock']
  log.flush();logs=(work/'shell.log').read_text()
  assert not any(x in logs for x in ('Binding loop','ReferenceError','TypeError','Failed to load configuration')),logs
  result=dict(status='PASS',artifacts=str(work),immediate=immediate,actuallyExecuted=(work/'action.json').read_text().splitlines(),after=after,missingExecutable=missing,rejected=rejected,recovered=recovered,lockImmediate=lockImmediate,lockConfirmed=lockConfirmed,lockMissing=lockMissing,lockRejected=lockRejected,lockRecovered=lockRecovered)
  (work/'result.json').write_text(json.dumps(result,indent=2));print(json.dumps(result,indent=2))
 finally:p.terminate();p.wait(timeout=3)
