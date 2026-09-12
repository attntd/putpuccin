"""Real native plugin against a disposable bus; never contacts host logind."""
import atexit
import json
import os
from pathlib import Path
import subprocess
import time


class PrivateLogind:
    def __init__(self, work):
        self.work = Path(work)
        self.processes = []
        atexit.register(self.close)
        build = self.work / 'logind-build'
        build.mkdir()
        with (self.work / 'logind-build.log').open('w') as log:
            for command in (['qmake6', str(Path(__file__).with_name('caffeinate-logind.pro'))],
                            ['make', '-j2']):
                result = subprocess.run(command, cwd=build, stdout=log, stderr=log)
                if result.returncode:
                    raise RuntimeError((self.work / 'logind-build.log').read_text())
        self.daemon = subprocess.Popen(['dbus-daemon', '--session', '--nofork', '--print-address=1'],
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.processes.append(self.daemon)
        self.address = self.daemon.stdout.readline().strip()
        assert self.address.startswith('unix:'), self.address
        self.env = dict(DBUS_SYSTEM_BUS_ADDRESS=self.address, DBUS_SESSION_BUS_ADDRESS=self.address)
        self.behavior('ready')
        with (self.work / 'logind.log').open('w') as log:
            self.mock = subprocess.Popen([str(build / 'caffeinate-logind'), str(self.work)],
                                          env=dict(os.environ, **self.env), stdout=log, stderr=log)
        self.processes.append(self.mock)
        deadline = time.monotonic() + 5
        while not (self.work / 'bus-ready').exists():
            assert self.mock.poll() is None and time.monotonic() < deadline, str(self.work)
            time.sleep(.02)

    def behavior(self, value):
        (self.work / 'behavior').write_text(value)

    def leases(self):
        return json.loads((self.work / 'leases.json').read_text())

    def control(self, method):
        subprocess.run(['busctl', '--address=' + self.address, 'call', 'org.quickshell.test.Logind',
                        '/org/freedesktop/login1', 'org.quickshell.test.Logind', method],
                       check=True, capture_output=True, timeout=5)

    def close(self):
        for process in reversed(self.processes):
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
        self.processes.clear()
