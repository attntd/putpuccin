#!/usr/bin/env python3
"""SurfaceManager teardown with synthetic monitor/shortcut protocol, private D-Bus."""
from pathlib import Path
import json,os,shutil,subprocess,tempfile,sys,time,re
if os.environ.get('CORE_SURFACE_PRIVATE')!='1':
 with tempfile.TemporaryDirectory(prefix='core-surface-bus-') as folder:
  p=Path(folder)/'bus.conf';p.write_text('<busconfig><type>session</type><listen>unix:tmpdir=/tmp</listen><policy context="default"><allow send_destination="*"/><allow receive_sender="*"/><allow own="*"/></policy></busconfig>')
  raise SystemExit(subprocess.call(['dbus-run-session','--config-file',str(p),'--',sys.executable,__file__],env=dict(os.environ,CORE_SURFACE_PRIVATE='1')))
root=Path(__file__).resolve().parents[1];work=Path(tempfile.mkdtemp(prefix='qs-core-surfaces-'));shell=work/'shell';(shell/'core').mkdir(parents=True);(shell/'audit').mkdir();(shell/'services').mkdir()
s=(root/'core/SurfaceManager.qml').read_text().replace('import Quickshell.Hyprland','import qs.audit')
# Mock only the external shortcut protocol; keep all SurfaceManager state/functions.
while '    GlobalShortcut {' in s:
 start=s.index('    GlobalShortcut {');cursor=start+s[start:].index('{');depth=1;end=cursor+1
 while depth:
  if s[end]=='{':depth+=1
  elif s[end]=='}':depth-=1
  end+=1
 block=s[start:end];m=re.search(r'id: (switcherLeft|switcherRight)',block)
 replacement='    QtObject { id: '+m.group(1)+'; property bool pressed: false }' if m else ''
 s=s[:start]+replacement+s[end:]
(shell/'core/SurfaceManager.qml').write_text(s);shutil.copy(root/'core/Strings.qml',shell/'core/Strings.qml');(shell/'core/qmldir').write_text('module qs.core\nsingleton SurfaceManager 1.0 SurfaceManager.qml\nsingleton Strings 1.0 Strings.qml\n')
(shell/'audit/qmldir').write_text('module qs.audit\nsingleton Hyprland 1.0 Hyprland.qml\n');(shell/'audit/Hyprland.qml').write_text('pragma Singleton\nimport QtQuick\nQtObject {property var focusedMonitor: ({name:"B"});property var workspaces:({values:[]});property var focusedWorkspace:null}\n')
(shell/'services/qmldir').write_text('module qs.services\nsingleton NotificationService 1.0 NotificationService.qml\nsingleton ScreenshotService 1.0 ScreenshotService.qml\n');(shell/'services/NotificationService.qml').write_text('pragma Singleton\nimport QtQuick\nQtObject {function toggleDnd(){}}')
(shell/'services/ScreenshotService.qml').write_text('pragma Singleton\nimport QtQuick\nQtObject {property bool active:false;property int generation:1;function holdCapture(id,token){} function releaseCapture(id,token){} function cancel(){active=false}}')
(shell/'shell.qml').write_text('''import QtQuick
import Quickshell
import Quickshell.Io
import qs.core
import qs.services
ShellRoot {
 IpcHandler {target:"audit"
 function run(): string {
  const s=SurfaceManager;const hasForget=typeof s.forgetScreen === "function";
  function removeA(){if(hasForget)s.forgetScreen("A");else s.closeOn("A");}
  s.detachedLauncherVisible=true;s.detachedLauncherScreenName="A";
  s.activeByScreen=({A:"notifications",B:"media"});s.pinnedNotifications=({A:true,B:true});
  removeA();
  const removed={launcherVisible:s.detachedLauncherVisible,launcherScreen:s.detachedLauncherScreenName,
    activeB:s.activeSurface("B"),pinnedB:s.pinnedNotifications.B};
  s.toggleDetachedLauncher();
  const toggled={visible:s.detachedLauncherVisible,screen:s.detachedLauncherScreenName};
  s.closeAllInternal();s.workspaceSwitcherVisible=true;s.workspaceSwitcherScreenName="A";
  s.activeByScreen=({B:"media"});removeA();
  const switcher={visible:s.workspaceSwitcherVisible,screen:s.workspaceSwitcherScreenName,activeB:s.activeSurface("B")};
  s.workspaceSwitcherVisible=false;s.detachedLauncherVisible=true;s.detachedLauncherScreenName="B";removeA();
  const unaffected={launcherVisible:s.detachedLauncherVisible,launcherScreen:s.detachedLauncherScreenName};
  s.workspaceSwitcherVisible=true;s.detachedLauncherVisible=true;s.detachedLauncherScreenName="B";
  s.activeByScreen=({A:"notifications",B:"quickSettings"});s.pinnedNotifications=({A:true});
  ScreenshotService.active=true;
  const capture={active:ScreenshotService.active,launcher:s.detachedLauncherVisible,
    switcher:s.workspaceSwitcherVisible,popups:Object.keys(s.activeByScreen).length,
    pins:Object.keys(s.pinnedNotifications).length};
  const hoverOpened=s.openOn("media","B",true);
  const hover={opened:hoverOpened,capture:ScreenshotService.active,popup:s.activeSurface("B")};
  s.openOn("media","B");
  const explicit={capture:ScreenshotService.active,popup:s.activeSurface("B")};
  ScreenshotService.active=true;s.openDetachedLauncher();
  const launcher={capture:ScreenshotService.active,visible:s.detachedLauncherVisible};
  ScreenshotService.active=true;s.workspaceSwitcherVisible=true;
  const replacementSwitcher={capture:ScreenshotService.active,visible:s.workspaceSwitcherVisible};
  s.workspaceSwitcherVisible=false;s.closeAllInternal();
  return JSON.stringify({hasForget,removed,toggled,switcher,unaffected,capture,hover,explicit,launcher,replacementSwitcher});
 }
 }
}''')
runtime=work/'runtime';runtime.mkdir(mode=0o700);env=dict(os.environ,QT_QPA_PLATFORM='offscreen',QT_QPA_PLATFORMTHEME='',WAYLAND_DISPLAY='',HYPRLAND_INSTANCE_SIGNATURE='',XDG_RUNTIME_DIR=str(runtime),XDG_CONFIG_HOME=str(work/'config'),XDG_STATE_HOME=str(work/'state'),XDG_CACHE_HOME=str(work/'cache'))
log=(work/'log').open('w');p=subprocess.Popen(['qs','-p',str(shell),'--no-color'],env=env,stdout=log,stderr=log)
try:
 for _ in range(40):
  r=subprocess.run(['qs','ipc','--pid',str(p.pid),'call','audit','run'],env=env,capture_output=True,text=True,timeout=2)
  if r.returncode==0 and r.stdout.strip():break
  time.sleep(.1)
 result=json.loads(r.stdout);result['scope']='Actual state/functions, synthetic Hyprland monitor and shortcut protocol';result['work']=str(work)
 assert result['hasForget']
 assert result['removed']=={'launcherVisible':False,'launcherScreen':'','activeB':'media','pinnedB':True}
 assert result['toggled']=={'visible':True,'screen':'B'}
 assert result['switcher']=={'visible':False,'screen':'','activeB':'media'}
 assert result['unaffected']=={'launcherVisible':True,'launcherScreen':'B'}
 assert result['capture']=={'active':True,'launcher':False,'switcher':False,'popups':0,'pins':0}
 assert result['hover']=={'opened':False,'capture':True,'popup':''}
 assert result['explicit']=={'capture':False,'popup':'media'}
 assert result['launcher']=={'capture':False,'visible':True}
 assert result['replacementSwitcher']=={'capture':False,'visible':True}
 for _ in range(19):
  repeat=subprocess.run(['qs','ipc','--pid',str(p.pid),'call','audit','run'],env=env,capture_output=True,text=True,timeout=2)
  value=json.loads(repeat.stdout)
  assert all(value[key]==result[key] for key in ['removed','toggled','switcher','unaffected',
    'capture','hover','explicit','launcher','replacementSwitcher'])
 result['passed']=True;result['cycles']=20
 (work/'result.json').write_text(json.dumps(result,indent=2));print(json.dumps(result,indent=2))
finally:p.terminate();p.wait(timeout=3);log.close()
assert not re.search(r'WARN|ERROR|TypeError|ReferenceError', (work/'log').read_text()),str(work)
