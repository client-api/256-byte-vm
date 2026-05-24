#!/usr/bin/env python3
"""End-to-end smoke test.

Boots build/boot.img in qemu with a bidirectional COM1 unix socket, then:
  1. Checks the banner ('ClientAPI') reaches serial.
  2. Sends 'hello\\r' and confirms the guest replies with 'olleh'.
  3. Sends ACPI power-button via the QEMU monitor (analogue of
     `qm shutdown`) and confirms the guest exits cleanly within 5 s.

Exit code 0 on success, 1 on any failure.
"""
from __future__ import annotations

import os
import socket
import subprocess
import sys
import time
from pathlib import Path


IMG    = Path("build/boot.img")
COMSOCK = "/tmp/256bv-com1.sock"
MONSOCK = "/tmp/256bv-mon.sock"


def cleanup() -> None:
    for p in (COMSOCK, MONSOCK):
        try:
            os.unlink(p)
        except FileNotFoundError:
            pass


def wait_socket(path: str, timeout: float = 3.0) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if os.path.exists(path):
            return
        time.sleep(0.05)
    raise TimeoutError(path)


def drain(s: socket.socket, timeout: float) -> bytes:
    s.settimeout(timeout)
    buf = b""
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            chunk = s.recv(4096)
            if not chunk:
                break
            buf += chunk
        except socket.timeout:
            break
    return buf


def main() -> int:
    if not IMG.exists():
        print(f"{IMG} missing — run `make all` first")
        return 1

    cleanup()
    qemu = subprocess.Popen([
        "qemu-system-x86_64",
        "-machine", "pc-i440fx-7.2",
        "-display", "none",
        "-no-reboot",
        "-chardev", f"socket,id=s0,path={COMSOCK},server=on,wait=off",
        "-serial", "chardev:s0",
        "-monitor", f"unix:{MONSOCK},server,nowait",
        "-drive", f"format=raw,file={IMG}",
    ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    try:
        wait_socket(COMSOCK)
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.connect(COMSOCK)

        banner = drain(s, 2.0)
        print("--- banner ---")
        print(banner.decode(errors="replace"))
        if b"ClientAPI" not in banner:
            print("FAIL: banner missing 'ClientAPI'")
            return 1
        if b"$ " not in banner:
            print("FAIL: prompt '$ ' not visible after banner")
            return 1

        for ch in b"hello\r":
            s.sendall(bytes([ch]))
            time.sleep(0.05)
        reply = drain(s, 2.0)
        print("--- after 'hello\\r' ---")
        print(reply.decode(errors="replace"))
        if b"olleh" not in reply:
            print("FAIL: reverse-echo 'olleh' missing")
            return 1
        s.close()

        wait_socket(MONSOCK)
        m = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        m.connect(MONSOCK)
        m.settimeout(1.0)
        try:
            m.recv(4096)        # HMP banner
        except socket.timeout:
            pass
        start = time.time()
        m.sendall(b"system_powerdown\n")
        # Keep the monitor connection open so the command isn't truncated;
        # qemu closes it on its way out, which we'll observe via .poll().
        deadline = start + 5.0
        try:
            while time.time() < deadline:
                if qemu.poll() is not None:
                    ms = (time.time() - start) * 1000
                    print(f"PASS: guest reacted to ACPI shutdown in {ms:.0f} ms")
                    return 0
                time.sleep(0.1)
            print("FAIL: guest did not exit on ACPI shutdown within 5 s")
            return 1
        finally:
            m.close()
    finally:
        if qemu.poll() is None:
            qemu.kill()
            qemu.wait(timeout=3)
        cleanup()


if __name__ == "__main__":
    sys.exit(main())
