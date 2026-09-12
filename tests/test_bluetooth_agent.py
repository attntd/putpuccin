#!/usr/bin/env python3
"""Real Qt D-Bus agent against BlueZ doubles on a PRIVATE bus, never hardware."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='qs-bluetooth-agent-test-') as build:
    log = Path(build) / 'build.log'
    with log.open('w') as output:
        for command in (['qmake6', str(root / 'tests/bluetooth-agent.pro')], ['make', '-j2']):
            result = subprocess.run(command, cwd=build, stdout=output, stderr=output)
            if result.returncode:
                raise RuntimeError(log.read_text())
    subprocess.run(['dbus-run-session', '--', 'sh', '-c',
                    'export DBUS_SYSTEM_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS"; exec "$1"',
                    'test', str(Path(build) / 'bluetooth-agent-test')], check=True, timeout=60)
