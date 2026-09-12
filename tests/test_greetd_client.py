#!/usr/bin/env python3
"""Exercise only the IPC transport against an in-process fake daemon; no PAM."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='qs-greetd-protocol-') as directory:
    for variant in ('production', 'test'):
        build = Path(directory) / variant
        build.mkdir()
        project = build / 'test.pro'
        project.write_text('TEMPLATE = app\nCONFIG += console c++17 testcase\nQT = core network testlib\n'
            + ('DEFINES += GREETER_TESTING\n' if variant == 'test' else '')
            + f'INCLUDEPATH += {ROOT}/integrations/GreeterNative\n'
            + f'HEADERS += {ROOT}/integrations/GreeterNative/greetdclient.h\n'
            + f'SOURCES += {ROOT}/integrations/GreeterNative/greetdclient.cpp {ROOT}/tests/fixtures/greetd-client.cpp\n')
        subprocess.run(['qmake6', str(project)], cwd=build, check=True, stdout=subprocess.DEVNULL)
        subprocess.run(['make', '-j2'], cwd=build, check=True, stdout=subprocess.DEVNULL)
        subprocess.run([str(build / 'test')], cwd=build, check=True)
