#!/usr/bin/python
"""Isolated actual-service tests. Never connects to Hyprland or real cliphist."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
WORK = Path(tempfile.mkdtemp(prefix='quickshell-service-lifecycle-'))
for name in ('services', 'stubs', 'scripts', 'bin', 'runtime', 'state'):
    (WORK / name).mkdir(mode=0o700)

def write(path, text, executable=False):
    target = WORK / path
    target.write_text(text)
    if executable:
        target.chmod(0o755)

hyprland = (ROOT/'services/HyprlandService.qml').read_text().replace('import Quickshell.Hyprland', 'import "../stubs" as Fixture').replace('Hyprland.', 'Fixture.Hyprland.').replace('target: Hyprland\n', 'target: Fixture.Hyprland\n')
write('services/HyprlandService.qml', hyprland)
clipboard = (ROOT/'services/ClipboardService.qml').read_text().replace('import Quickshell.Hyprland\n', '').replace('import qs.core', 'import "../stubs"').replace('import qs.services', 'import "../stubs"')
write('services/ClipboardService.qml', clipboard)
write('services/qmldir', 'singleton HyprlandService 1.0 HyprlandService.qml\nsingleton ClipboardService 1.0 ClipboardService.qml\n')
write('stubs/qmldir', ''.join(f'singleton {name} 1.0 {name}.qml\n' for name in ('Hyprland', 'Settings', 'Motion', 'SurfaceManager', 'HyprlandService')))
write('stubs/Settings.qml', 'pragma Singleton\nimport QtQuick\nQtObject { property int clipboardMaxItems: 3; property int clipboardMaxBytes: 2097152; property bool clipboardAutoPaste: false; property bool reducedMotion: true }\n')
write('stubs/Motion.qml', 'pragma Singleton\nimport QtQuick\nQtObject { property int fast: 100 }\n')
write('stubs/SurfaceManager.qml', 'pragma Singleton\nimport QtQuick\nQtObject { signal changed(string screenName, string surfaceId) }\n')
write('stubs/HyprlandService.qml', 'pragma Singleton\nimport QtQuick\nQtObject { function requestPaste(address) {} }\n')
write('stubs/Hyprland.qml', '''pragma Singleton
import QtQuick
import Quickshell
Singleton {
 id: root
 property bool usingLua: true
 property var commands: []
 property QtObject monitorA: QtObject { property string name: "test-a"; property var activeWorkspace: root.workspaceA }
 property QtObject monitorB: QtObject { property string name: "test-b"; property var activeWorkspace: root.workspaceB }
 property QtObject workspaceA: QtObject { property var toplevels: root.windowsA }
 property QtObject workspaceB: QtObject { property var toplevels: root.windowsB }
 property QtObject windowsA: QtObject { property var values: [root.windowA] }
 property QtObject windowsB: QtObject { property var values: [root.windowB] }
 property QtObject windowA: QtObject { property string address: "a11"; property var monitor: root.monitorA; property var workspace: root.workspaceA; property var lastIpcObject: ({class:"editor",pid:100}); property string title: "Synthetic A" }
 property QtObject windowB: QtObject { property string address: "b22"; property var monitor: root.monitorB; property var workspace: root.workspaceB; property var lastIpcObject: ({class:"editor",pid:200}); property string title: "Synthetic B" }
 property var activeToplevel: windowB
 property var focusedMonitor: monitorB
 property QtObject toplevels: QtObject { property var values: [root.windowA, root.windowB] }
 property QtObject workspaces: QtObject { property var values: []; signal objectInsertedPost(); signal objectRemovedPost() }
 signal focusedWorkspaceChanged()
 function monitorFor(screen) { return screen.name === "test-a" ? monitorA : monitorB; }
 function dispatch(command) { commands = commands.concat([command]); }
 function refreshToplevels() {}
}
''')
write('scripts/terminal-context', '''#!/usr/bin/python
import json,os,pathlib,time
state=pathlib.Path(os.environ['AUDIT_CLIP_ROOT'])
config=json.loads((state/'config.json').read_text())
with (state/'terminal-calls').open('a') as log: log.write('request\\n')
time.sleep(config.get('terminalDelay',0))
print(json.dumps(dict(host='synthetic-remote',remote=True,cwd='/remote/project',command='fish')))
''', True)
shutil.copy2(ROOT/'scripts/clipboard-action', WORK/'scripts/clipboard-action')
write('bin/cliphist', '''#!/usr/bin/python
import json,os,pathlib,sys,time
state=pathlib.Path(os.environ['AUDIT_CLIP_ROOT'])
config=json.loads((state/'config.json').read_text())
operation=sys.argv[1]
if operation=='list':
 ids=json.loads((state/'ids.json').read_text())
 time.sleep(config.get('listDelay',0))
 for id in ids: print(str(id)+'\\t[[ binary data synthetic ]]')
elif operation=='decode':
 id=int(sys.stdin.read().strip())
 (state/'decode-started').write_text(str(id))
 time.sleep(config.get('decodeDelay',0))
 sys.stdout.buffer.write(b'SYNTHETIC_IMAGE'*100)
 if config.get('decodeFailure'): sys.exit(1)
elif operation=='delete':
 id=int(sys.stdin.read().strip());ids=json.loads((state/'ids.json').read_text());(state/'ids.json').write_text(json.dumps([x for x in ids if x!=id]))
elif operation=='wipe': (state/'ids.json').write_text('[]')
else: sys.exit(2)
''', True)
write('bin/wl-paste', '#!/usr/bin/python\nimport signal,time\nsignal.signal(signal.SIGTERM, lambda *_: exit(0))\nwhile True: time.sleep(3600)\n', True)
write('bin/wl-copy', '#!/usr/bin/python\nimport sys\nsys.stdin.buffer.read()\n', True)
write('shell.qml', '''import QtQuick
import QtTest
import Quickshell
import Quickshell.Io
import "services" as Services
import "stubs" as Fixture
ShellRoot {
 property var clipboard: Services.ClipboardService
 property var adapter: Services.HyprlandService
 IpcHandler {
  target: "audit"
  function snapshot(): string {
   const c=Services.ClipboardService,h=Services.HyprlandService;
   return JSON.stringify({state:c.state,ids:c.entries.map(x=>x.id), thumbnails:c.entries.filter(x=>x.thumbnail).map(x=>x.id),
    activeThumbnail:c.activeThumbnailId, pending:c.pendingOperation,listPending:c.listPending,
    thumbnailRoot:c.thumbnailRoot,cache:h.terminalContextByAddress,resolving:!!h.resolvingRequest,queued:!!h.queuedPathRequest,
    error:!!c.errorMessage});
  }
  function refresh(): void { Services.ClipboardService.refresh(); }
  function thumbnail(id: int): void { Services.ClipboardService.requestThumbnail(id); }
  function remove(id: int): void { Services.ClipboardService.remove(id); }
  function wipe(): void { Services.ClipboardService.wipe(); }
  function copy(id: int): void { Services.ClipboardService.copy(id); }
  function commands(): string {
   const h=Services.HyprlandService,s={name:"test-a"};
   const result=[];
   for(const lua of [true,false]) {
    Fixture.Hyprland.usingLua=lua;Fixture.Hyprland.commands=[];
    h.closeActiveWindow(s);h.moveActiveWindowToWorkspace(3,s);
    result.push(Fixture.Hyprland.commands);
   }
   const native=h.requestPaste("a11"),prefixed=h.requestPaste("0x000A11");
   const rejected=["","0x0","a11;exit","address:0xa11","fff", "1234567890abcdef0"].every(x=>!h.requestPaste(x));
   return JSON.stringify({commands:result,native:native,prefixed:prefixed,rejected:rejected});
  }
  function terminal(pid: int): void {
   Fixture.Hyprland.windowA.lastIpcObject={class:"kitty",pid:pid};
   Services.HyprlandService.requestTerminalPath(Fixture.Hyprland.windowA);
  }
  function closeWindows(): void {
   Fixture.Hyprland.toplevels.values=[];Fixture.Hyprland.windowsA.values=[];Fixture.Hyprland.windowsB.values=[];
   Fixture.Hyprland.activeToplevel=null;
  }
  function restore(): void {
   Fixture.Hyprland.toplevels.values=[Fixture.Hyprland.windowA,Fixture.Hyprland.windowB];
   Fixture.Hyprland.windowsA.values=[Fixture.Hyprland.windowA];
  }
  function staleCommands(): string {
   Fixture.Hyprland.commands=[];
   return JSON.stringify({close:Services.HyprlandService.closeActiveWindow({name:"test-a"}),
    move:Services.HyprlandService.moveActiveWindowToWorkspace(2,{name:"test-a"}),
    paste:Services.HyprlandService.requestPaste("a11"), commands:Fixture.Hyprland.commands});
  }
 }
}
''')
env=dict(os.environ,QT_QPA_PLATFORM='offscreen',WAYLAND_DISPLAY='',HYPRLAND_INSTANCE_SIGNATURE='',XDG_RUNTIME_DIR=str(WORK/'runtime'),DBUS_SESSION_BUS_ADDRESS='unix:path=/nonexistent-audit-bus',DBUS_SYSTEM_BUS_ADDRESS='unix:path=/nonexistent-audit-bus',AUDIT_CLIP_ROOT=str(WORK/'state'),PATH=str(WORK/'bin')+':'+os.environ['PATH'])

def config(**values): write('state/config.json',json.dumps(values))
def ids(values): write('state/ids.json',json.dumps(values))
config();ids([1,2,3])
log=(WORK/'shell.log').open('w')
p=subprocess.Popen(['qs','-p',str(WORK),'--no-color'],env=env,stdout=log,stderr=log)

def ipc(method,*args):
 q=subprocess.run(['qs','ipc','--pid',str(p.pid),'call','audit',method,*map(str,args)],env=env,text=True,capture_output=True,timeout=3)
 assert q.returncode==0,(q.stderr,str(WORK))
 return q.stdout.strip()
def snap(): return json.loads(ipc('snapshot'))
def wait(check,timeout=3):
 end=time.monotonic()+timeout
 while time.monotonic()<end:
  try:
   value=check()
   if value:return value
  except (AssertionError,json.JSONDecodeError): pass
  assert p.poll() is None,str(WORK)
  time.sleep(.025)
 raise AssertionError(('timeout',str(WORK),snap()))
def files():return sorted(x.name for x in Path(snap()['thumbnailRoot']).glob('*') if x.name.isdigit())
result={}
try:
 wait(lambda:snap()['ids']==[1,2,3])
 commands=json.loads(ipc('commands'));assert commands['native'] and commands['prefixed'] and commands['rejected'],commands
 assert commands['commands']==[['hl.dsp.window.close({ window = "address:0xa11" })','hl.dsp.window.move({ workspace = 3, follow = false, window = "address:0xa11" })'],['closewindow address:0xa11','movetoworkspacesilent 3,address:0xa11']],commands
 result['windowTargeting']=commands
 ipc('terminal',100);wait(lambda:snap()['cache'].get('a11',{}).get('remote') is True)
 assert snap()['cache']['a11']['cwd']=='/remote/project'
 ipc('closeWindows');wait(lambda:not snap()['cache'])
 stale=json.loads(ipc('staleCommands'));assert stale==dict(close=False,move=False,paste=False,commands=[]),stale
 ipc('restore');config(terminalDelay=.5)
 ipc('terminal',100);wait(lambda:snap()['resolving']);ipc('terminal',100);assert snap()['queued']
 ipc('closeWindows');wait(lambda:not snap()['resolving'] and not snap()['queued']);time.sleep(.6);assert not snap()['cache']
 ipc('restore');ipc('terminal',100);wait(lambda:snap()['resolving']);ipc('terminal',101)
 wait(lambda:snap()['cache'].get('a11',{}).get('ownerPid')==101,3)
 assert len(snap()['cache'])==1
 config(terminalDelay=4);start=time.monotonic();ipc('terminal',101);wait(lambda:snap()['resolving']);wait(lambda:not snap()['resolving'],2)
 assert time.monotonic()-start<1.5 and not snap()['cache']
 (WORK/'scripts/terminal-context').rename(WORK/'scripts/terminal-context.saved');ipc('terminal',101);wait(lambda:not snap()['resolving']);assert not snap()['cache']
 result['terminalLifecycle']=dict(closedCacheRemoved=True,lateAndQueuedClosedResultsRejected=True,pidReuseRejected=True,remoteContextPreserved=True,timeoutMs=round((time.monotonic()-start)*1000),failedStartCleared=True)
 config()
 for id in [1,2,3]:ipc('thumbnail',id)
 wait(lambda:snap()['thumbnails']==[1,2,3]);assert files()==['1','2','3']
 ipc('remove',2);wait(lambda:snap()['ids']==[1,3] and files()==['1','3'])
 ids([3,4,5,6]);ipc('refresh');wait(lambda:snap()['ids']==[3,4,5] and files()==['3'])
 config(decodeDelay=.4);ipc('thumbnail',4);wait(lambda:(WORK/'state/decode-started').read_text()=='4')
 ipc('wipe');wait(lambda:not snap()['ids']);wait(lambda:snap()['activeThumbnail']==-1 and not files())
 result['clipboardCleanup']=dict(deleteRemovedFile=True,historyPrunedToMaxItems=True,evictionRemovedFile=True,lateDecodeAfterWipeRemoved=True)
 config(decodeFailure=True);ids([7]);ipc('refresh');wait(lambda:snap()['ids']==[7]);ipc('thumbnail',7);wait(lambda:snap()['activeThumbnail']==-1)
 assert not list((WORK/'runtime').glob('quickshell-de-decoded.*'))
 assert not files()
 result['clipboardCleanup']['failedDecodeTemporaryRemoved']=True
 config(listDelay=.3);ids([8]);ipc('refresh');wait(lambda:snap()['listPending']);ipc('wipe');wait(lambda:not snap()['listPending'] and not snap()['ids']);assert not files()
 result['clipboardCleanup']['staleListAfterWipeRejected']=True
 config(listDelay=10);ipc('refresh');start=time.monotonic();wait(lambda:snap()['listPending']);wait(lambda:not snap()['listPending'],7)
 assert snap()['state']=='unavailable' and snap()['error']
 result['listTimeoutMs']=round((time.monotonic()-start)*1000)
 config();write('bin/cliphist','#!/bin/sh\nexit 127\n',True)
 ipc('refresh');wait(lambda:not snap()['listPending']);assert snap()['state']=='unavailable'
 result['commandFailureUnavailable']=True
 write('bin/timeout','#!/nonexistent-audit-interpreter\n',True)
 ipc('refresh');wait(lambda:not snap()['listPending']);assert snap()['state']=='unavailable'
 result['failedToStartUnavailable']=True
 log.flush();text=(WORK/'shell.log').read_text()
 assert not any(s in text for s in ('Binding loop','ReferenceError','TypeError','Failed to load configuration')),(str(WORK),text)
 result['status']='PASS';(WORK/'result.json').write_text(json.dumps(result,indent=2));print(json.dumps(dict(artifacts=str(WORK),**result),indent=2))
finally:
 p.terminate()
 try:p.wait(timeout=3)
 except subprocess.TimeoutExpired:p.kill();p.wait()
 log.close()
