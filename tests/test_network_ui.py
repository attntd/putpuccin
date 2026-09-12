#!/usr/bin/env python3
"""Native editor over private D-Bus and actual QML service/forms; no host radio writes."""
from pathlib import Path
import json, os, re, shutil, subprocess, sys, tempfile, time

SERVICE = 'org.freedesktop.NetworkManager'
UUID = '11111111-1111-1111-1111-000000000001'

def fixture():
    import dbus, dbus.service
    from dbus.mainloop.glib import DBusGMainLoop
    import ctypes
    glib = ctypes.CDLL('libglib-2.0.so.0')
    Callback = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_void_p)
    callbacks = []
    glib.g_main_loop_new.argtypes = [ctypes.c_void_p, ctypes.c_int]
    glib.g_main_loop_new.restype = ctypes.c_void_p
    glib.g_main_loop_run.argtypes = [ctypes.c_void_p]
    glib.g_main_loop_quit.argtypes = [ctypes.c_void_p]
    glib.g_timeout_add.argtypes = [ctypes.c_uint, Callback, ctypes.c_void_p]
    class Loop:
        def __init__(self): self.handle = glib.g_main_loop_new(None, False)
        def run(self): glib.g_main_loop_run(self.handle)
        def quit(self): glib.g_main_loop_quit(self.handle)
    class GLib:
        MainLoop = Loop
        @staticmethod
        def timeout_add(delay, function):
            callback = Callback(lambda _: int(bool(function())))
            callbacks.append(callback)
            return glib.g_timeout_add(delay, callback, None)
    DBusGMainLoop(set_as_default=True)
    bus = dbus.SessionBus()
    owner = dbus.service.BusName(SERVICE, bus)
    loop = GLib.MainLoop()

    class Server(dbus.service.Object):
        def __init__(self):
            super().__init__(bus, '/org/freedesktop/NetworkManager/Settings')
            self.vpns = {}; self.adds = 0; self.activations = 0; self.deactivations = 0; self.next_id = 2
            self.mode = 'normal'; self.writes = 0; self.deletes = 0; self.secrets = 0; self.version = 1
            self.settings = {
                'connection': {'id': 'Sieć testowa', 'uuid': UUID, 'type': '802-11-wireless',
                    'autoconnect': True, 'metered': dbus.UInt32(0), 'permissions': dbus.Array(['user:test:'], signature='s')},
                '802-11-wireless': {'ssid': dbus.ByteArray(b'Siec testowa'), 'mode': 'infrastructure', 'hidden': False},
                '802-11-wireless-security': {'key-mgmt': 'wpa-psk', 'psk-flags': dbus.UInt32(0)},
                'ipv4': {'method': 'auto', 'address-data': dbus.Array([], signature='a{sv}'),
                    'dns': dbus.Array([dbus.UInt32(0x01010101)], signature='u'),
                    'route-data': dbus.Array([{'dest': '10.10.0.0', 'prefix': dbus.UInt32(16), 'next-hop': '192.168.1.1'}], signature='a{sv}'),
                    'route-metric': dbus.Int64(777)},
                'ipv6': {'method': 'auto', 'address-data': dbus.Array([], signature='a{sv}'),
                    'dns': dbus.Array([dbus.ByteArray(bytes.fromhex('26064700470000000000000000001111'))], signature='ay')},
                'proxy': {'method': dbus.Int32(0)},
            }

        @dbus.service.method(SERVICE + '.Settings', in_signature='s', out_signature='o')
        def GetConnectionByUuid(self, uuid):
            for path, connection in self.vpns.items():
                if connection.settings['connection']['uuid'] == uuid: return dbus.ObjectPath(path)
            if str(uuid) != UUID:
                raise dbus.exceptions.DBusException('Missing', name=SERVICE + '.Settings.InvalidConnection')
            return dbus.ObjectPath('/org/freedesktop/NetworkManager/Settings/1')

        @dbus.service.method(SERVICE + '.Settings', in_signature='', out_signature='ao')
        def ListConnections(self):
            return ['/org/freedesktop/NetworkManager/Settings/1'] + list(self.vpns)

        @dbus.service.signal(SERVICE + '.Settings', signature='o')
        def NewConnection(self, path): pass

        @dbus.service.signal(SERVICE + '.Settings', signature='o')
        def ConnectionRemoved(self, path): pass

        @dbus.service.method(SERVICE + '.Settings', in_signature='a{sa{sv}}ua{sv}', out_signature='oa{sv}', async_callbacks=('ok','fail'))
        def AddConnection2(self, settings, flags, args, ok, fail):
            if self.mode == 'deny':
                fail(dbus.exceptions.DBusException('Denied', name=SERVICE + '.Settings.PermissionDenied')); return
            try:
                assert flags == 33 and not settings['connection']['autoconnect']
                assert settings['connection']['type'] == 'wireguard'
                assert len(settings['wireguard']['private-key']) == 44
                assert isinstance(settings['wireguard']['listen-port'], dbus.UInt32)
                assert settings['wireguard']['peers'].signature == 'a{sv}'
                for peer in settings['wireguard']['peers']:
                    assert peer['allowed-ips'].signature == 's'
                    assert isinstance(peer['persistent-keepalive'], dbus.UInt32)
                for family in ['ipv4','ipv6']:
                    for address in settings[family].get('address-data',[]): assert isinstance(address['prefix'],dbus.UInt32)
                validate_nm(settings)
            except (AssertionError, KeyError) as error:
                fail(dbus.exceptions.DBusException(str(error), name=SERVICE + '.Settings.InvalidConnection')); return
            def commit():
                path='/org/freedesktop/NetworkManager/Settings/'+str(self.next_id); self.next_id+=1
                self.vpns[path]=VpnConnection(bus,path,settings); self.adds+=1
                self.NewConnection(path); ok(dbus.ObjectPath(path),{}); return False
            if self.mode == 'save-delay': GLib.timeout_add(400,commit)
            else: commit()

        @dbus.service.method('org.test.Network', in_signature='s', out_signature='')
        def Mode(self, mode):
            self.mode = str(mode)
            if mode == 'conflict': self.settings['connection']['id'] = 'Zmienione w innym miejscu'

        @dbus.service.method('org.test.Network', in_signature='', out_signature='s')
        def Snapshot(self):
            return json.dumps(dict(writes=self.writes, deletes=self.deletes, secrets=self.secrets,
                adds=self.adds, vpnCount=len(self.vpns), activations=self.activations, deactivations=self.deactivations,
                name=str(self.settings['connection']['id']), autoconnect=bool(self.settings['connection']['autoconnect']),
                hidden=bool(self.settings['802-11-wireless'].get('hidden', False)),
                metered=int(self.settings['connection']['metered']),
                ip4=str(self.settings['ipv4']['method']), ip6=str(self.settings['ipv6']['method']),
                addresses4=len(self.settings['ipv4'].get('address-data',[])),
                addresses6=len(self.settings['ipv6'].get('address-data',[])),
                dns6=len(self.settings['ipv6'].get('dns-data',[]))))

        @dbus.service.method('org.test.Network', in_signature='', out_signature='')
        def Quit(self):
            GLib.timeout_add(50, lambda: loop.quit())

    server = Server()

    class Connection(dbus.service.Object):
        @dbus.service.method('org.freedesktop.DBus.Properties', in_signature='ss', out_signature='v')
        def Get(self, interface, key):
            assert interface == SERVICE + '.Settings.Connection' and key == 'VersionId'
            return dbus.UInt64(server.version)

        @dbus.service.method(SERVICE + '.Settings.Connection', in_signature='', out_signature='a{sa{sv}}', async_callbacks=('ok', 'fail'))
        def GetSettings(self, ok, fail):
            if server.mode == 'load-delay':
                GLib.timeout_add(400, lambda: (ok(server.settings), False)[1])
            else: ok(server.settings)

        @dbus.service.method(SERVICE + '.Settings.Connection', in_signature='a{sa{sv}}ua{sv}', out_signature='a{sv}', async_callbacks=('ok', 'fail'))
        def Update2(self, settings, flags, args, ok, fail):
            if server.mode == 'deny':
                fail(dbus.exceptions.DBusException('Denied', name=SERVICE + '.Settings.PermissionDenied')); return
            try:
                assert int(flags) == 65, 'Save must not reapply to the active device'
                assert isinstance(args['version-id'],dbus.UInt64) and args['version-id']==server.version
                assert settings['802-11-wireless-security'] == server.settings['802-11-wireless-security']
                assert settings['connection']['permissions'] == server.settings['connection']['permissions']
                assert settings['ipv4']['route-data'] == server.settings['ipv4']['route-data']
                assert settings['ipv4']['route-metric'] == server.settings['ipv4']['route-metric']
                assert isinstance(settings['connection']['metered'], dbus.UInt32)
                for family in ['ipv4', 'ipv6']:
                    for address in settings[family].get('address-data', []):
                        assert isinstance(address['prefix'], dbus.UInt32)
                    if 'dns-data' in settings[family]:
                        assert settings[family]['dns-data'].signature == 's'
                assert isinstance(settings['802-11-wireless']['ssid'], dbus.ByteArray) or settings['802-11-wireless']['ssid'].signature == 'y'
            except (AssertionError, KeyError) as error:
                fail(dbus.exceptions.DBusException(str(error), name=SERVICE + '.Settings.InvalidConnection')); return
            def apply():
                server.settings = settings; server.writes += 1; server.version += 1
                ok({}); return False
            if server.mode == 'save-delay': GLib.timeout_add(400, apply)
            else: apply()

        @dbus.service.method(SERVICE + '.Settings.Connection', in_signature='', out_signature='')
        def Delete(self):
            if server.mode == 'deny':
                raise dbus.exceptions.DBusException('Denied', name=SERVICE + '.Settings.PermissionDenied')
            server.deletes += 1

        @dbus.service.method(SERVICE + '.Settings.Connection', in_signature='s', out_signature='a{sa{sv}}')
        def GetSecrets(self, group):
            server.secrets += 1
            raise dbus.exceptions.DBusException('Secrets must not be read', name=SERVICE + '.Settings.PermissionDenied')

    # Ask real libnm to validate the imported, typed D-Bus map without a host NMClient.
    def validate_nm(settings):
        def variant(value):
            if isinstance(value,dbus.Boolean): return 'true' if value else 'false'
            if isinstance(value,dbus.UInt32): return 'uint32 '+str(value)
            if isinstance(value,dbus.Int32): return 'int32 '+str(value)
            if isinstance(value,dbus.UInt64): return 'uint64 '+str(value)
            if isinstance(value,(str,dbus.String)): return "'"+str(value).replace('\\','\\\\').replace("'","\\'")+"'"
            if isinstance(value,(dict,dbus.Dictionary)):
                return '{'+', '.join(variant(k)+': <'+variant(v)+'>' for k,v in value.items())+'}'
            if isinstance(value,(list,dbus.Array)):
                return '@a'+str(value.signature)+' ['+', '.join(variant(v) for v in value)+']'
            raise AssertionError('Unexpected import type')
        text='{'+', '.join(variant(k)+': '+variant(v) for k,v in settings.items())+'}'
        glib.g_variant_parse.argtypes=[ctypes.c_void_p,ctypes.c_char_p,ctypes.c_void_p,ctypes.c_void_p,ctypes.c_void_p]
        glib.g_variant_parse.restype=ctypes.c_void_p
        glib.g_variant_unref.argtypes=[ctypes.c_void_p]
        raw=glib.g_variant_parse(None,text.encode(),None,None,None); assert raw, 'Variant conversion failed'
        nm=ctypes.CDLL('libnm.so.0'); nm.nm_simple_connection_new_from_dbus.argtypes=[ctypes.c_void_p,ctypes.c_void_p]; nm.nm_simple_connection_new_from_dbus.restype=ctypes.c_void_p
        nm.nm_connection_verify.argtypes=[ctypes.c_void_p,ctypes.c_void_p]
        conn=nm.nm_simple_connection_new_from_dbus(raw,None); assert conn,'Invalid NetworkManager settings'
        assert nm.nm_connection_verify(conn,None),'libnm rejected configuration'
        obj=ctypes.CDLL('libgobject-2.0.so.0');obj.g_object_unref.argtypes=[ctypes.c_void_p];obj.g_object_unref(conn);glib.g_variant_unref(raw)

    class VpnConnection(dbus.service.Object):
        def __init__(self,bus,path,settings):
            super().__init__(bus,path);self.path=path;self.settings=settings;self.version=1
        @dbus.service.method(SERVICE+'.Settings.Connection',in_signature='',out_signature='a{sa{sv}}')
        def GetSettings(self):
            settings={section:dict(values) for section,values in self.settings.items()}
            if 'peers' in settings.get('wireguard',{}):
                settings['wireguard']['peers']=dbus.Array([dbus.Dictionary(dict(peer),signature='sv') for peer in settings['wireguard']['peers']],signature='a{sv}')
            settings.get('wireguard',{}).pop('private-key',None)
            for peer in settings.get('wireguard',{}).get('peers',[]):peer.pop('preshared-key',None)
            return settings
        @dbus.service.method('org.freedesktop.DBus.Properties',in_signature='ss',out_signature='v')
        def Get(self,interface,key):
            assert key=='VersionId';return dbus.UInt64(self.version)
        @dbus.service.signal(SERVICE+'.Settings.Connection',signature='')
        def Updated(self):pass
        @dbus.service.method(SERVICE+'.Settings.Connection',in_signature='a{sa{sv}}ua{sv}',out_signature='a{sv}')
        def Update2(self,settings,flags,args):
            assert flags==65 and args['version-id']==self.version
            assert '802-11-wireless' not in settings
            assert settings['wireguard']['peers']==self.GetSettings()['wireguard']['peers']
            # NetworkManager retains omitted system-owned secrets on Update2.
            settings['wireguard']['private-key']=self.settings['wireguard']['private-key']
            self.settings=settings;self.version+=1;self.Updated();return {}
        @dbus.service.method(SERVICE+'.Settings.Connection',in_signature='',out_signature='')
        def Delete(self):
            del server.vpns[self.path];server.ConnectionRemoved(self.path);self.remove_from_connection()
        @dbus.service.method(SERVICE+'.Settings.Connection',in_signature='s',out_signature='a{sa{sv}}')
        def GetSecrets(self,section):server.secrets+=1;raise AssertionError('No GetSecrets allowed')

    class Active(dbus.service.Object):
        def __init__(self):
            super().__init__(bus,'/org/freedesktop/NetworkManager/ActiveConnection/1');self.properties={}
        @dbus.service.method('org.freedesktop.DBus.Properties',in_signature='s',out_signature='a{sv}')
        def GetAll(self,interface):return self.properties
        @dbus.service.signal('org.freedesktop.DBus.Properties',signature='sa{sv}as')
        def PropertiesChanged(self,interface,properties,invalidated):pass
    active=Active()
    class Manager(dbus.service.Object):
        def __init__(self):super().__init__(bus,'/org/freedesktop/NetworkManager');self.active=False
        @dbus.service.method('org.freedesktop.DBus.Properties',in_signature='ss',out_signature='v')
        def Get(self,interface,key):
            assert key=='ActiveConnections';return dbus.Array(['/org/freedesktop/NetworkManager/ActiveConnection/1'] if self.active else [],signature='o')
        @dbus.service.signal('org.freedesktop.DBus.Properties',signature='sa{sv}as')
        def PropertiesChanged(self,interface,properties,invalidated):pass
        @dbus.service.method(SERVICE,in_signature='ooo',out_signature='o')
        def ActivateConnection(self,path,device,specific):
            assert device=='/' and specific=='/' and path in server.vpns
            server.activations+=1;self.active=True
            active.properties={'Type':'wireguard','Uuid':server.vpns[path].settings['connection']['uuid'],'State':dbus.UInt32(1)}
            self.PropertiesChanged(SERVICE,{'ActiveConnections':self.Get(SERVICE,'ActiveConnections')},[])
            def connected():
                active.properties['State']=dbus.UInt32(2);active.PropertiesChanged(SERVICE+'.Connection.Active',{'State':dbus.UInt32(2)},[]);return False
            GLib.timeout_add(200,connected)
            return '/org/freedesktop/NetworkManager/ActiveConnection/1'
        @dbus.service.method(SERVICE,in_signature='o',out_signature='')
        def DeactivateConnection(self,path):
            assert self.active;server.deactivations+=1
            active.properties['State']=dbus.UInt32(4);active.PropertiesChanged(SERVICE+'.Connection.Active',{'State':dbus.UInt32(4)},[])
            self.active=False;self.PropertiesChanged(SERVICE,{'ActiveConnections':self.Get(SERVICE,'ActiveConnections')},[])
    manager=Manager()

    connection = Connection(bus, '/org/freedesktop/NetworkManager/Settings/1')
    print('ready', flush=True)
    loop.run()

if '--fixture' in sys.argv:
    fixture(); raise SystemExit()

if os.environ.get('QS_NETWORK_PRIVATE') != '1':
    with tempfile.TemporaryDirectory(prefix='qs-network-bus-') as directory:
        conf = Path(directory) / 'bus.conf'
        conf.write_text('<busconfig><type>session</type><listen>unix:tmpdir=/tmp</listen><policy context="default"><allow send_destination="*"/><allow receive_sender="*"/><allow own="*"/></policy></busconfig>')
        raise SystemExit(subprocess.call(['dbus-run-session', '--config-file', str(conf), '--', sys.executable, __file__],
            env=dict(os.environ, QS_NETWORK_PRIVATE='1',
                QS_NETWORK_PROMPT_WAYLAND='1' if '--prompt-wayland' in sys.argv else '0')))

import dbus
ROOT = Path(__file__).resolve().parents[1]
WORK = Path(tempfile.mkdtemp(prefix='qnp-' if os.environ.get('QS_NETWORK_PROMPT_WAYLAND') == '1' else 'qs-network-ui-'))
CONFIG = WORK / 'shell'
print('WORK', WORK, flush=True)
for directory, names in {
    'core': ['Theme', 'Metrics', 'Motion', 'Strings', 'Icons'],
    'components': ['ActionButton', 'PopupFrame', 'ToggleRow', 'PillSwitch', 'SectionTitle', 'EmptyState', 'SearchField'],
    'services': ['NetworkService'], 'popups': ['NetworkPopup'],
    'modules/network': ['NetworkSettings', 'NetworkProfileEditor', 'NetworkField', 'NetworkChoice', 'NetworkWindow', 'NetworkNearby', 'NetworkProfiles', 'NetworkVpnImport'],
}.items():
    target = CONFIG / directory; target.mkdir(parents=True)
    entries = ['module qs.' + directory.replace('/', '.')]
    for name in names:
        text = (ROOT / directory / (name + '.qml')).read_text()
        if name == 'Metrics': text = text.replace('readonly property int networkWindow', 'property int networkWindow')
        if name in ['NetworkService', 'NetworkPopup', 'NetworkNearby']: text = text.replace('import Quickshell.Networking', 'import qs.audit')
        (target / (name + '.qml')).write_text(text)
        entries.append(('singleton ' if directory in ('core', 'services') else '') + name + ' 1.0 ' + name + '.qml')
    (target / 'qmldir').write_text('\n'.join(entries) + '\n')

def stub(directory, name, body):
    target = CONFIG / directory; target.mkdir(exist_ok=True)
    (target / (name + '.qml')).write_text('pragma Singleton\nimport QtQuick\nimport Quickshell\nSingleton {\n' + body + '\n}\n')
    with (target / 'qmldir').open('a') as f: f.write('singleton ' + name + ' 1.0 ' + name + '.qml\n')

stub('core', 'Settings', 'property bool reducedMotion: false\nproperty real surfaceOpacity: 0.9\nproperty real interactiveOpacity: 0')
stub('core', 'SurfaceManager', '''property string surface: "network"
 signal changed()
 function isOpen(id, screen) { return surface === id; }
 function focusedScreenName() { return "test-a"; }
 function openOn(id, screen) { surface = id; changed(); return true; }
 function closeOn(screen) { surface = ""; changed(); }
 function prepareSettingsWindow(screen) { closeOn(screen); return true; }
''')
stub('audit', 'DeviceType', 'enum Value { None, Wifi, Wired }')
stub('audit', 'NetworkBackendType', 'enum Value { None, NetworkManager }')
stub('audit', 'WifiSecurityType', 'enum Value { Open, Owe, WpaPsk, Wpa2Psk, Sae }')
stub('audit', 'Networking', '''id: root
 property int pskConnections: 0
 property int backend: NetworkBackendType.NetworkManager
 property bool wifiEnabled: true
 property QtObject wifi: QtObject {
   property int type: DeviceType.Wifi
   property bool connected: true
   property bool scannerEnabled: false
   property var networks: ({values: [root.network]})
 }
 property QtObject network: QtObject {
   property string name: "Sieć testowa"
   property bool connected: true
   property bool known: true
   property bool stateChanging: false
   property real signalStrength: .8
   property int security: WifiSecurityType.Wpa2Psk
   property var nmSettings: []
   signal connectionFailed(int reason)
   function connect() {} function disconnect() {}
   function connectWithPsk(value) { if (value === "test-only-password") root.pskConnections++; }
 }
 property var devices: ({values:[wifi]})
 Component.onCompleted: {
   const profiles=[];
   for(let i=1;i<=24;i++) profiles.push({uuid:"11111111-1111-1111-1111-"+String(i).padStart(12,"0"),id:i===1?"Sieć testowa":"Zapisana sieć "+i});
   network.nmSettings=profiles;
 }
''')
(CONFIG / 'shell.qml').write_text('//@ pragma Env QML_IMPORT_PATH = ' + str(ROOT / 'integrations') + '\n' + (ROOT / 'tests/fixtures/network.qml').read_text())
if os.environ.get('QS_NETWORK_PROMPT_WAYLAND') == '1':
    from network_prompt_wayland import run
    run(ROOT, WORK, CONFIG)
    raise SystemExit()
runtime = WORK / 'runtime'; runtime.mkdir(mode=0o700)
env = dict(os.environ, QT_QPA_PLATFORM='offscreen', QT_QPA_PLATFORMTHEME='', NO_AT_BRIDGE='1',
    WAYLAND_DISPLAY='', HYPRLAND_INSTANCE_SIGNATURE='', DBUS_SYSTEM_BUS_ADDRESS=os.environ['DBUS_SESSION_BUS_ADDRESS'],
    XDG_RUNTIME_DIR=str(runtime), XDG_CONFIG_HOME=str(WORK/'config'), XDG_STATE_HOME=str(WORK/'state'), XDG_CACHE_HOME=str(WORK/'cache'))
server_log = (WORK / 'server.log').open('w')
server = subprocess.Popen([sys.executable, __file__, '--fixture'], stdout=server_log, stderr=server_log)
shell_log = (WORK / 'shell.log').open('w')
proc = subprocess.Popen(['qs', '-p', str(CONFIG), '--no-color'], env=env, stdout=shell_log, stderr=shell_log)
bus = dbus.SessionBus()

def ipc(method, *args):
    result = subprocess.run(['qs', 'ipc', '--pid', str(proc.pid), 'call', 'networkTest', method, *map(str,args)], env=env, capture_output=True, text=True, timeout=12)
    assert result.returncode == 0, (result.stderr, str(WORK))
    return result.stdout.strip()
def wait(check, timeout=5):
    end = time.monotonic()+timeout
    while time.monotonic()<end:
        try:
            result=check()
            if result: return result
        except (AssertionError, json.JSONDecodeError, dbus.exceptions.DBusException): pass
        assert proc.poll() is None, (WORK/'shell.log').read_text()
        time.sleep(.05)
    raise AssertionError('Timeout: '+str(WORK))
def measure():
    def ticks(): return sum(map(int,Path(f'/proc/{proc.pid}/stat').read_text().rsplit(')',1)[1].split()[11:13]))
    a=ticks();start=time.monotonic();time.sleep(1)
    rss=int(next(line.split()[1] for line in Path(f'/proc/{proc.pid}/status').read_text().splitlines() if line.startswith('VmRSS:')))
    return dict(cpu_percent=round(100*(ticks()-a)/os.sysconf('SC_CLK_TCK')/(time.monotonic()-start),2),rss_kib=rss)

result={}
try:
    wait(lambda:bus.name_has_owner(SERVICE))
    control = dbus.Interface(bus.get_object(SERVICE, '/org/freedesktop/NetworkManager/Settings'),'org.test.Network')
    state=lambda:json.loads(ipc('state'))
    snapshot=lambda:json.loads(control.Snapshot())
    wait(lambda:ipc('ready')=='true')
    result['before']=measure()
    result['list']=json.loads(ipc('list'))
    ipc('edit'); wait(lambda:state()['loaded'])
    ipc('capture',str(WORK/'general.png'))
    result['smallOutput']=json.loads(ipc('small'))
    result['ipv4']=json.loads(ipc('ipv4',str(WORK/'ipv4.png')))
    wait(lambda:not state()['editing'])
    assert snapshot()['writes']==1 and snapshot()['ip4']=='manual'
    ipc('edit');wait(lambda:state()['loaded'])
    draft=json.loads(ipc('settings'))
    assert draft['ipv6']['dns']=='2606:4700:4700::1111'
    draft.update(autoconnect=False,hidden=True,metered=1)
    draft['ipv6'].update(method='manual',addresses='2001:db8::20/64, 2001:db8::21/64',gateway='2001:db8::1',dns='2001:4860:4860::8888',autoDns=False)
    ipc('write',json.dumps(draft));wait(lambda:not state()['editing'])
    assert snapshot()['writes']==2 and snapshot()['addresses6']==2 and snapshot()['dns6']==1
    assert not snapshot()['autoconnect'] and snapshot()['hidden'] and snapshot()['metered']==1
    ipc('edit');wait(lambda:state()['loaded'])
    draft=json.loads(ipc('settings'));draft['ipv4']['method']='auto';draft['ipv6']['method']='disabled'
    ipc('write',json.dumps(draft));wait(lambda:not state()['editing'])
    assert snapshot()['writes']==3 and snapshot()['addresses4']==0 and snapshot()['addresses6']==0 and snapshot()['dns6']==0
    result['typedIPv6AndGeneralSettings']=True
    result['automaticAndDisabledClearStaticConfiguration']=True
    ipc('edit');wait(lambda:state()['loaded'])
    control.Mode('deny');ipc('rename','Nowa nazwa')
    wait(lambda:not state()['busy'] and state()['error'])
    assert state()['editing'] and snapshot()['writes']==3
    result['denied']=state()['error']
    control.Mode('normal');ipc('save');wait(lambda:not state()['editing'])
    assert snapshot()['writes']==4 and snapshot()['name']=='Nowa nazwa'
    ipc('edit');wait(lambda:state()['loaded']);ipc('invalidDns')
    wait(lambda:not state()['busy'] and state()['error'])
    assert snapshot()['writes']==4
    result['invalidDns']=state()['error']
    ipc('discardBack');ipc('edit');wait(lambda:state()['loaded'])
    control.Mode('conflict');ipc('rename','Nadpisanie')
    wait(lambda:not state()['busy'] and state()['error'])
    assert snapshot()['writes']==4 and snapshot()['name']=='Zmienione w innym miejscu'
    result['conflict']=state()['error']
    control.Mode('normal');ipc('discardBack');ipc('edit');wait(lambda:state()['loaded'])
    result['forget']=json.loads(ipc('forget'))
    wait(lambda:not state()['editing']);assert snapshot()['deletes']==1
    config=WORK/'test-vpn.conf'
    # Synthetic keys only; the real host connection manager never sees them.
    config.write_text('[Interface]\nPrivateKey = AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=\nAddress = 10.42.0.2/24, fd42::2/64\nDNS = 1.1.1.1, 2606:4700:4700::1111\nListenPort = 51820\n[Peer]\nPublicKey = AgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgI=\nAllowedIPs = 0.0.0.0/0, ::/0\nEndpoint = vpn.example.com:51820\nPersistentKeepalive = 25\n')
    config.chmod(0o600)
    ipc('vpn');wait(lambda:not state()['busy'])
    assert ipc('importVpn',config.as_uri())=='true'
    assert set(state()['preview'])=={'name','type','fileName'}
    assert snapshot()['adds']==0
    ipc('cancelImport');assert not state()['preview'] and snapshot()['adds']==0
    assert ipc('importVpn',config.as_uri())=='true'
    ipc('capture',str(WORK/'vpn-import.png'))
    control.Mode('deny');ipc('addVpn');wait(lambda:not state()['busy'] and state()['vpnError'])
    assert snapshot()['adds']==0 and state()['preview']
    control.Mode('normal');ipc('addVpn');wait(lambda:state()['vpnCount']==1 and not state()['preview'])
    assert snapshot()['adds']==1 and snapshot()['activations']==0
    ipc('capture',str(WORK/'vpn-list.png'))
    ipc('toggleVpn');wait(lambda:state()['vpnState']==2)
    assert snapshot()['activations']==1
    ipc('toggleVpn');wait(lambda:state()['vpnState']==0)
    assert snapshot()['deactivations']==1 and not state()['vpnError']
    ipc('editVpn');wait(lambda:state()['loaded']);assert ipc('verifyVpnEditor')=='true'
    ipc('rename','VPN biuro');wait(lambda:not state()['editing'])
    ipc('editVpn');wait(lambda:state()['loaded']);assert json.loads(ipc('settings'))['name']=='VPN biuro'
    ipc('forget');wait(lambda:state()['vpnCount']==0)
    assert snapshot()['secrets']==0
    invalid=WORK/'unsupported.conf';invalid.write_text(config.read_text()+'PostUp = echo unsafe\n')
    assert ipc('importVpn',invalid.as_uri())=='false';assert snapshot()['adds']==1 and not state()['preview']
    ipc('close');ipc('vpn');assert ipc('importVpn',config.as_uri())=='true'
    control.Mode('save-delay');ipc('addVpn');ipc('close');wait(lambda:not state()['busy'])
    assert snapshot()['adds']==2
    control.Mode('normal');ipc('vpn');wait(lambda:state()['vpnCount']==1)
    ipc('osClose');assert ipc('windowOpen')=='false'
    result['vpnImportActivationEditingAndRemoval']=True
    result['vpnCancelDenialTypedSettingsAndSecrets']=True
    result['vpnCloseDuringConfirmedImport']=True
    for _ in range(20):assert json.loads(ipc('cycle'))['passed']
    result['warmup_cycles']=20
    result['before_cycles']=measure();result['rss_cycles']=[]
    for _ in range(20):
        assert json.loads(ipc('cycle'))['passed']
        result['rss_cycles'].append(measure()['rss_kib'])
    result['after']=measure()
    ipc('collect');result['afterGc']=measure()
    result['steadyCycles']=[]
    for _ in range(20):
        assert json.loads(ipc('cycle'))['passed']
        result['steadyCycles'].append(measure()['rss_kib'])
    ipc('collect');result['steadyAfter']=measure()
    control.Mode('load-delay');ipc('edit');ipc('close')
    time.sleep(.6);assert not state()['busy'] and not state()['editing']
    result['closeDuringLoad']=True
    control.Mode('normal');ipc('edit');wait(lambda:state()['loaded'])
    control.Mode('save-delay');ipc('rename','Zapis w toku');ipc('close')
    wait(lambda:not state()['busy']);assert snapshot()['writes']==5 and snapshot()['name']=='Zapis w toku'
    result['closeDuringConfirmedSave']=True
    result['backend']=snapshot();assert result['backend']['secrets']==0
    control.Mode('load-delay');ipc('edit');control.Quit()
    wait(lambda:not state()['busy'] and state()['error'])
    ipc('close');result['ownerLoss']=True
    server.wait(timeout=3)
    server=subprocess.Popen([sys.executable,__file__,'--fixture'],stdout=server_log,stderr=server_log)
    wait(lambda:bus.name_has_owner(SERVICE))
    control=dbus.Interface(bus.get_object(SERVICE,'/org/freedesktop/NetworkManager/Settings'),'org.test.Network')
    ipc('edit');wait(lambda:state()['loaded']);ipc('close')
    result['ownerRecovery']=True
    warnings=[line for line in (WORK/'shell.log').read_text().splitlines() if re.search(r'WARN|ERROR|ReferenceError|TypeError|Binding loop',line) and 'This plugin does not support setting window masks' not in line]
    assert not warnings,warnings
    result.update(passed=True,cycles=20,warnings=warnings,artifacts=str(WORK))
finally:
    if proc.poll() is None:
        result["last_state"]=state()
    if server.poll() is None:
        result["backend_final"]=snapshot()
    proc.terminate();proc.wait(timeout=3)
    if server.poll() is None:server.terminate()
    server.wait(timeout=3);server_log.close();shell_log.close()
    (WORK/'result.json').write_text(json.dumps(result,indent=2,ensure_ascii=False))
print(json.dumps(result,indent=2,ensure_ascii=False))
