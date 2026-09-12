#!/usr/bin/env python3
"""Exercise PAM control flow with synthetic modules, never host auth/fprintd.

The framework uses pam_start_confdir with an existing private profile. Every
account/password/fingerprint module is replaced by one /tmp test library;
all includes are removed. The only real module is pam_echo (constant text).
"""
import hashlib
import os
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
tally = Path('/var/run/faillock') / str(os.getlogin() if os.isatty(0) else __import__('pwd').getpwuid(os.getuid()).pw_name)
def tally_state():
    return (hashlib.sha256(tally.read_bytes()).hexdigest(), tally.stat().st_mtime_ns) if tally.exists() else None

before = tally_state()
try:
    with tempfile.TemporaryDirectory(prefix='qs-greeter-pam-test-') as directory:
        work = Path(directory)
        module = work / 'synthetic.so'
        gate = work / 'pam_greeter_gate.so'
        probe = work / 'probe'
        subprocess.run(['cc', '-Wall', '-Wextra', '-shared', '-fPIC', '-o', str(module),
            str(ROOT / 'tests/fixtures/greeter-pam-module.c'), '-lpam'], check=True)
        subprocess.run(['cc', '-Wall', '-Wextra', '-o', str(probe),
            str(ROOT / 'tests/fixtures/greeter-pam-probe.c'), '-lpam'], check=True)
        subprocess.run(['cc', '-Wall', '-Wextra', '-Werror', '-shared', '-fPIC', '-o', str(gate),
            str(ROOT / 'integrations/GreeterNative/pam-greeter-gate.c'), '-lpam'], check=True)
        profile = []
        guards = 0
        for line in (ROOT / 'greeter/pam.conf').read_text().splitlines():
            if not line.startswith(('auth ', 'account ')): continue
            match = re.fullmatch(r'(auth|account)\s+(\[[^\]]+\]|\w+)\s+(\S+)(?:\s+(.*))?', line)
            assert match, line
            kind, control, name, args = match.groups()
            if name == 'pam_fprintd.so':
                name, args = str(module), 'fingerprint'
            elif name == 'pam_echo.so':
                name = '/usr/lib/security/pam_echo.so'
                assert args == 'GREETER_FINGERPRINT_ERROR'
            elif name.endswith('/pam_greeter_gate.so'):
                assert control == '[success=ignore default=die]' and args is None
                name = str(gate)
            elif control == 'include':
                assert name == ('system-auth' if kind == 'auth' else 'system-login')
                control, name, args = 'required', str(module), 'password' if kind == 'auth' else 'account'
            else:
                assert kind == 'auth' and name in ('pam_nologin.so', 'pam_shells.so', 'pam_faillock.so')
                name, args = str(module), 'guard' + str(guards); guards += 1
            profile.append(f'{kind} {control} {name} {args or ""}\n')
        contents = ''.join(profile)
        assert 'include' not in contents and 'substack' not in contents
        assert 'pam_fprintd.so' not in contents and 'pam_unix.so' not in contents and 'pam_faillock.so' not in contents
        assert 'system-auth' not in contents and 'system-login' not in contents
        (work / 'isolated-greeter').write_text(contents)
        (work / 'other').write_text(f'auth requisite {module} deny\naccount requisite {module} deny\n')
        # scenario: expected result, fingerprint invocations, password invocations, error markers
        cases = {
            'fp_ok': ('success', 1, 0, 0),
            'unavailable_then_ok': ('success', 2, 0, 1),
            'unavailable_password_ok': ('success', 2, 1, 2),
            'unavailable_password_bad': ('denied', 2, 1, 2),
            'mismatch_password_ok': ('success', 1, 1, 0),
            'mismatch_password_bad': ('denied', 1, 1, 0),
            'cancel_idle': ('denied', 2, 0, 2),
            'cancel_mismatch': ('denied', 1, 0, 0),
            'account_denied': ('denied', 1, 0, 0),
            **{f'guard{i}': ('denied', 0, 0, 0) for i in range(3)},
        }
        for scenario, (result, fingerprints, passwords, markers) in cases.items():
            output = subprocess.check_output([str(probe), str(work)], text=True,
                env=dict(os.environ, GREETER_PAM_TEST_CASE=scenario), timeout=5)
            assert 'RESULT ' + result in output, (scenario, output)
            assert output.count('STEP fingerprint') == fingerprints, (scenario, output)
            assert output.count('STEP password') == passwords, (scenario, output)
            assert output.count('MESSAGE GREETER_FINGERPRINT_ERROR') == markers, (scenario, output)
            if scenario.startswith('cancel_'):
                assert 'AUTH_CODE 19' in output, (scenario, output)  # PAM_CONV_ERR
                assert 'STEP account' not in output, (scenario, output)
            print('PASS', scenario)
finally:
    assert tally_state() == before, 'Host PAM failure tally changed'
print('Private PAM policy passed; host failure tally unchanged.')
