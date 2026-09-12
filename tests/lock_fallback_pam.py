"""PAM and host-account guards for the disposable Hyprlock integration test."""
import fcntl
import errno
import hashlib
import os
from pathlib import Path
import pwd
import re
import stat
import subprocess

FIXTURES = Path(__file__).parent / "fixtures"
PROFILE = ("auth optional pam_faildelay.so delay=1000000\n"
           "auth required pam_deny.so\n"
           "account required pam_deny.so\n"
           "password required pam_deny.so\n"
           "session required pam_deny.so\n")


def validate_binary(path):
    path = path.resolve(strict=True)
    info = path.stat()
    if not stat.S_ISREG(info.st_mode) or info.st_mode & (stat.S_ISUID | stat.S_ISGID):
        raise RuntimeError("Test Hyprlock must be a regular non-setuid/non-setgid executable")
    try:
        capabilities = os.getxattr(path, "security.capability")
    except OSError as error:
        if error.errno not in (errno.ENODATA, errno.ENOTSUP):
            raise
        capabilities = b""
    if capabilities:
        raise RuntimeError("Test Hyprlock must have no file capabilities; preload could be ignored")
    symbols = subprocess.check_output(["nm", "-D", str(path)], text=True)
    if not re.search(r"\bU pam_start(?:@|$)", symbols, re.M):
        raise RuntimeError("Test Hyprlock must dynamically import the intercepted pam_start")
    return hashlib.sha256(path.read_bytes()).hexdigest()


def host_tally_path():
    directory = Path("/run/faillock")
    for line in Path("/etc/security/faillock.conf").read_text().splitlines():
        match = re.fullmatch(r"\s*dir\s*=\s*(\S+)\s*(?:#.*)?", line)
        if match:
            directory = Path(match[1])
    # An inline override has precedence. Refuse ambiguity instead of watching
    # an unrelated file and silently claiming host PAM was untouched.
    overrides = set()
    for line in Path("/etc/pam.d/system-auth").read_text().splitlines():
        line = line.split("#", 1)[0]
        if "pam_faillock.so" in line:
            overrides.update(re.findall(r"\bdir=(\S+)", line))
    if len(overrides) > 1:
        raise RuntimeError("Cannot identify the single host faillock directory")
    if overrides:
        directory = Path(overrides.pop())
    if not directory.is_absolute():
        raise RuntimeError("Host faillock directory must be absolute")
    return directory.resolve(strict=True) / pwd.getpwuid(os.getuid()).pw_name


def snapshot_tally(path):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
    except FileNotFoundError:
        # The parent must be readable; permission failure is never "absent".
        list(path.parent.iterdir())
        return None
    try:
        fcntl.flock(fd, fcntl.LOCK_SH)
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
            raise RuntimeError("Refusing an unexpected host tally file")
        data = os.read(fd, 1024 * 1024)
        if os.read(fd, 1):
            raise RuntimeError("Host tally is unexpectedly large")
        return (data, info.st_ino, info.st_mtime_ns, info.st_ctime_ns, info.st_mode, info.st_uid)
    finally:
        os.close(fd)


def tally_report(snapshot):
    return {"exists": snapshot is not None,
            "bytes": len(snapshot[0]) if snapshot else 0,
            "sha256": hashlib.sha256(snapshot[0]).hexdigest() if snapshot else None}


def build_isolation(work):
    directory = work / "pam"
    directory.mkdir(mode=0o700)
    service = directory / "system-auth"
    service.write_text(PROFILE)
    service.chmod(0o600)
    library = directory / "isolated-pam.so"
    probe = directory / "isolated-pam-probe"
    subprocess.run(["cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-fPIC", "-shared",
                    str(FIXTURES / "isolated-pam.c"), "-o", str(library), "-ldl", "-lpam"], check=True)
    subprocess.run(["cc", "-std=c11", "-Wall", "-Wextra", "-Werror",
                    str(FIXTURES / "isolated-pam-probe.c"), "-o", str(probe), "-ldl", "-lpam"], check=True)
    library.chmod(0o500)
    probe.chmod(0o500)
    return directory, library, probe


def check_isolation(directory, library, probe, env):
    env = dict(env, QS_TEST_PAM_DIRECTORY=str(directory))
    if "LD_PRELOAD" in env:
        raise RuntimeError("PAM probe must not inherit a global LD_PRELOAD")
    command = [str(probe), str(library)]
    success = subprocess.run(command, env=env, capture_output=True, text=True, timeout=5)
    if success.returncode or success.stdout.strip() != "ISOLATED_PAM_DENIED":
        raise RuntimeError(f"Private PAM probe failed ({success.returncode}): " + success.stdout + success.stderr)
    before = (directory / "hook-used").read_bytes()
    missing = dict(env)
    missing.pop("QS_TEST_PAM_DIRECTORY")
    invalid = dict(env, WAYLAND_DISPLAY="/run/user/99999/host-display")
    host_runtime = dict(env, XDG_RUNTIME_DIR=f"/run/user/{os.getuid()}",
                        WAYLAND_DISPLAY=f"/run/user/{os.getuid()}/wayland-1")
    original = (directory / "system-auth").read_text()
    for scenario in (missing, invalid, host_runtime):
        failed = subprocess.run(command, env=scenario, capture_output=True, text=True, timeout=3)
        if failed.returncode != 125:
            raise RuntimeError("PAM isolation did not refuse invalid context")
    try:
        (directory / "system-auth").write_text("auth include system-auth\n")
        failed = subprocess.run(command, env=env, capture_output=True, text=True, timeout=3)
        if failed.returncode != 125:
            raise RuntimeError("PAM isolation accepted an unsafe profile")
    finally:
        (directory / "system-auth").write_text(original)
    if (directory / "hook-used").read_bytes() != before:
        raise RuntimeError("Rejected PAM probe reached the real PAM backend")
    return hashlib.sha256(library.read_bytes()).hexdigest()
