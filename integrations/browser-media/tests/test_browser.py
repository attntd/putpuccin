#!/usr/bin/env python3
"""Real MAIN+isolated WebExtension, native messaging and MPRIS in a fresh Zen.

Private D-Bus, synthetic HTTPS pages and a dedicated temporary profile. No
existing browser sessions, site data or media are accessed. No signing bypass.
The synthetic browser profile mutes output with media.volume_scale=0.
"""
from pathlib import Path
import functools
import http.server
import json
import os
import signal
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time

if os.environ.get('QS_BROWSER_PRIVATE') != '1':
    with tempfile.TemporaryDirectory(prefix='qs-browser-bus-') as directory:
        bus = Path(directory)/'bus.conf'
        bus.write_text('<busconfig><type>session</type><listen>unix:tmpdir=/tmp</listen><policy context="default"><allow send_destination="*"/><allow receive_sender="*"/><allow own="*"/></policy></busconfig>')
        raise SystemExit(subprocess.call(['dbus-run-session','--config-file',str(bus),'--',sys.executable,__file__],env=dict(os.environ,QS_BROWSER_PRIVATE='1')))

import dbus
root=Path(__file__).resolve().parents[1]
work=Path(tempfile.mkdtemp(prefix='quickshell-browser-media-'))
profile=work/'profile';profile.mkdir()
with socket.socket() as reservation:
    reservation.bind(('127.0.0.1',0));marionette_port=reservation.getsockname()[1]
prefs={'marionette.port':marionette_port,'browser.shell.checkDefaultBrowser':False,
    'browser.startup.homepage_override.mstone':'ignore','browser.startup.homepage':'about:blank',
    'browser.startup.page':0,'browser.newtabpage.enabled':False,'zen.welcome-screen.seen':True,
    'toolkit.telemetry.enabled':False,'datareporting.healthreport.uploadEnabled':False,
    'datareporting.policy.dataSubmissionEnabled':False,'media.autoplay.default':0,
    'media.volume_scale':'0.0','network.dns.localDomains':'soundcloud.com,music.apple.com',
    'network.trr.mode':5,'network.proxy.type':0}
(profile/'user.js').write_text(''.join('user_pref('+json.dumps(k)+','+json.dumps(v)+');\n' for k,v in prefs.items()))
page='''<!doctype html><title>SoundCloud fixture page</title><h1>Synthetic browser media</h1>
<div class="playbackTimeline__progressWrapper" role="progressbar" aria-valuemax="90" aria-valuenow="12"></div>
<script>
window.fixture = {commands: [], audio:null, context:null};
const ms=navigator.mediaSession;
for(const action of ['play','pause','nexttrack','previoustrack','seekto']) {
 ms.setActionHandler(action, details=>{
  fixture.commands.push(details);
  if(action==='play') ms.playbackState='playing';
  if(action==='pause') ms.playbackState='paused';
  if(action==='seekto') {
   const timeline=document.querySelector('[role=progressbar]');
   if(timeline) timeline.setAttribute('aria-valuenow',details.seekTime);
   if(fixture.audio)fixture.audio.currentTime=details.seekTime;
  }
 });
}
fixture.webAudio=async()=>{
 if(fixture.audio){fixture.audio.pause();fixture.audio.remove();fixture.audio=null;}
 fixture.context=new AudioContext();const oscillator=fixture.context.createOscillator();
 const gain=fixture.context.createGain();gain.gain.value=0.000001;
 oscillator.connect(gain);gain.connect(fixture.context.destination);oscillator.start();
 await fixture.context.resume();
 ms.metadata=new MediaMetadata({title:'WebAudio fixture track',artist:'Fixture artist'});
 ms.playbackState='playing';
};
fixture.htmlAudio=async()=>{
 const length=40*8000,b=new ArrayBuffer(44+length*2),v=new DataView(b);
 function t(o,s){for(let i=0;i<s.length;i++)v.setUint8(o+i,s.charCodeAt(i));}
 t(0,'RIFF');v.setUint32(4,36+length*2,true);t(8,'WAVE');t(12,'fmt ');v.setUint32(16,16,true);
 v.setUint16(20,1,true);v.setUint16(22,1,true);v.setUint32(24,8000,true);v.setUint32(28,16000,true);
 v.setUint16(32,2,true);v.setUint16(34,16,true);t(36,'data');v.setUint32(40,length*2,true);
 for(let i=0;i<length;i++)v.setInt16(44+i*2,Math.sin(i/8000*440*2*Math.PI)*1000,true);
 fixture.audio=new Audio(URL.createObjectURL(new Blob([b],{type:'audio/wav'})));
 fixture.audio.volume=0.000001;
 ms.metadata=new MediaMetadata({title:'HTML audio fixture track',artist:'Fixture artist'});
 ms.playbackState='none';
 await fixture.audio.play();
};
</script>'''
(work/'fixture.html').write_text(page)
class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self,*args):pass
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),functools.partial(QuietHandler,directory=str(work)))
subprocess.run(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-days','1','-keyout',str(work/'key.pem'),'-out',str(work/'cert.pem'),'-subj','/CN=soundcloud.com'],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);context.load_cert_chain(work/'cert.pem',work/'key.pem');server.socket=context.wrap_socket(server.socket,server_side=True)
threading.Thread(target=server.serve_forever,daemon=True).start()
bus=dbus.SessionBus();prefix='org.mpris.MediaPlayer2.quickshell_browser.'

def players():return sorted(str(n) for n in bus.list_names() if n.startswith(prefix))
def props(name):return dbus.Interface(bus.get_object(name,'/org/mpris/MediaPlayer2'),'org.freedesktop.DBus.Properties')
def metadata(name):return props(name).Get('org.mpris.MediaPlayer2.Player','Metadata')
def until(predicate,message,timeout=8):
    deadline=time.monotonic()+timeout
    while time.monotonic()<deadline:
        try:
            value=predicate()
            if value:return value
        except (dbus.DBusException,KeyError):pass
        time.sleep(.05)
    raise AssertionError(message+'; logs: '+str(work))

with (work/'browser.log').open('w') as log:
    browser=subprocess.Popen(['/usr/bin/zen-browser','--headless','--no-remote','--profile',str(profile),'--marionette','about:blank'],env=dict(os.environ,DBUS_SYSTEM_BUS_ADDRESS=os.environ['DBUS_SESSION_BUS_ADDRESS']),stdout=log,stderr=log,start_new_session=True)
    try:
        deadline=time.monotonic()+15
        while True:
            try:sock=socket.create_connection(('127.0.0.1',marionette_port),timeout=.3);break
            except OSError:
                assert browser.poll() is None and time.monotonic()<deadline,work
                time.sleep(.1)
        sock.settimeout(15);stream=sock.makefile('rwb',buffering=0)
        def receive():
            size=b''
            while True:
                char=stream.read(1)
                if char==b':':break
                if not char:raise EOFError()
                size+=char
            data=b''
            while len(data)<int(size):data+=stream.read(int(size)-len(data))
            return json.loads(data)
        receive();sequence=0
        def request(command,args=None):
            global sequence
            sequence+=1;data=json.dumps([0,sequence,command,args or {}]).encode()
            stream.write(str(len(data)).encode()+b':'+data)
            response=receive()
            if response[2]:raise AssertionError((command,response[2],work))
            result=response[3]
            return result.get('value') if isinstance(result,dict) and 'value'in result else result
        def script(code):return request('WebDriver:ExecuteScript',{'script':code,'args':[]})
        def async_script(code):return request('WebDriver:ExecuteAsyncScript',{'script':code,'args':[]})
        session=request('WebDriver:NewSession',{'acceptInsecureCerts':True})
        assert session['capabilities']['acceptInsecureCerts'] is True, session
        # Temporary install is an official API and retains normal signing policy.
        addon=request('Addon:Install',{'path':str(root/'extension'),'temporary':True})
        assert addon=='quickshell-browser-media@local',(addon,work)
        lifecycle=script((root/'tests/background_cases.js').read_text().replace('// BACKGROUND',
            (root/'extension/background.js').read_text()))
        zero=script('try{navigator.mediaSession.setPositionState({duration:20,position:2,playbackRate:0});return false;}catch(e){return e.name==="TypeError";}')
        assert zero
        request('WebDriver:Navigate',{'url':f'https://soundcloud.com:{server.server_port}/fixture.html'})
        assert async_script('fixture.webAudio().then(()=>arguments[0](true),()=>arguments[0](false));')
        first=until(lambda:players()[0] if players() else None,'WebAudio did not reach native MPRIS')
        data=metadata(first)
        assert data['browser:pageTitle']=='SoundCloud fixture page'
        assert data['browser:sourceHost']=='soundcloud.com'
        assert data['xesam:title']=='WebAudio fixture track'
        assert int(data['mpris:length'])==90000000
        assert script('return document.querySelectorAll("audio,video").length;')==0,'Bridge created synthetic audio'
        player=dbus.Interface(bus.get_object(first,'/org/mpris/MediaPlayer2'),'org.mpris.MediaPlayer2.Player')
        player.SetPosition(data['mpris:trackid'],dbus.Int64(33000000))
        until(lambda:abs(int(props(first).Get('org.mpris.MediaPlayer2.Player','Position'))/1e6-33)<1,'Seek callback was not routed')
        player.Pause();until(lambda:props(first).Get('org.mpris.MediaPlayer2.Player','PlaybackStatus')=='Paused','Pause failed')
        player.Play();until(lambda:props(first).Get('org.mpris.MediaPlayer2.Player','PlaybackStatus')=='Playing','Play failed')
        script('document.title="Updated fixture title";')
        until(lambda:metadata(first)['browser:pageTitle']=='Updated fixture title','Page title observer failed')
        script('document.querySelector("[role=progressbar]").removeAttribute("aria-valuenow");')
        until(lambda:'mpris:length' not in metadata(first),'Missing aria-valuenow fabricated zero')
        # WebAudio timing without DOM progress: pause/resume must retain elapsed time.
        script('document.querySelector("[role=progressbar]").remove();navigator.mediaSession.setPositionState({duration:70,position:10,playbackRate:1});')
        time.sleep(.5);script('navigator.mediaSession.playbackState="paused";')
        frozen=until(lambda:float(props(first).Get('org.mpris.MediaPlayer2.Player','Position'))/1e6,'No explicit position')
        assert 10.35<frozen<11.5,('Pause lost elapsed time',frozen)
        time.sleep(.4)
        assert abs(float(props(first).Get('org.mpris.MediaPlayer2.Player','Position'))/1e6-frozen)<.1
        script('navigator.mediaSession.playbackState="playing";')
        time.sleep(.35)
        assert float(props(first).Get('org.mpris.MediaPlayer2.Player','Position'))/1e6>frozen+.2
        # Separate HTML media page; background source must retain its own title.
        old_handle=request('WebDriver:GetWindowHandle')
        new_window=request('WebDriver:NewWindow',{'type':'tab'})
        request('WebDriver:SwitchToWindow',{'handle':new_window['handle']})
        request('WebDriver:Navigate',{'url':f'https://music.apple.com:{server.server_port}/fixture.html'})
        assert async_script('fixture.htmlAudio().then(()=>arguments[0](true),()=>arguments[0](false));')
        second=until(lambda:next((n for n in players() if n!=first),None),'HTML source did not reach native MPRIS')
        until(lambda:metadata(second).get('mpris:length')==40000000,'Real HTML duration missing')
        assert metadata(first)['browser:pageTitle']=='Updated fixture title'
        assert metadata(second)['browser:sourceHost']=='music.apple.com'
        # A paused old HTML element must not supply the new WebAudio track duration.
        script('fixture.audio.pause();navigator.mediaSession.metadata=new MediaMetadata({title:"New WebAudio track"});navigator.mediaSession.playbackState="playing";')
        until(lambda:metadata(second)['xesam:title']=='New WebAudio track','Track did not update')
        assert 'mpris:length' not in metadata(second),'Stale HTML duration leaked into WebAudio'
        request('WebDriver:Navigate',{'url':'about:blank'})
        until(lambda:second not in players(),'Navigation left a ghost player')
        request('WebDriver:SwitchToWindow',{'handle':old_handle})
        request('WebDriver:CloseWindow')
        until(lambda:not players(),'Tab close left a ghost player')
        request('Addon:Uninstall',{'id':addon})
        result={'passed':True,'browser':'Zen 1.21.16b / Gecko 154.0.1','scopes':'exact production manifest',
            'mainWorldRelayNativeMpris':True,'pureWebAudio':True,'htmlMediaDuration':40,
            'pageTitleFromBackgroundTab':True,'commands':['Play','Pause','SetPosition'],
            'pausedExplicitPosition':frozen,'navigationCleanup':True,'tabCloseCleanup':True,
            'zeroRateRejected':zero,'productionProfileTouched':False}
        result.update(lifecycle)
        result['missingAriaPositionStaysUnknown']=True
        (work/'result.json').write_text(json.dumps(result,indent=2));print(json.dumps(result,indent=2));print('Logs:',work)
    finally:
        os.killpg(browser.pid,signal.SIGTERM)
        try:browser.wait(timeout=5)
        except subprocess.TimeoutExpired:os.killpg(browser.pid,signal.SIGKILL);browser.wait(timeout=3)
        server.shutdown()
