#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""GPD Win 5 背键守护进程: L4/R4 -> uinput F14/F15.

Managed by the steamos-nix flake — source of truth in /nix/store.
Original logic extracted verbatim from steamos-setup.sh step [4]; only this
docstring was updated. Run via the generated gpd-win5-backkeys.service
(ExecStart uses the nix python3 interpreter, not /usr/bin/python3).
"""
import glob, os, struct, sys, time
TARGET_VID, TARGET_PID = 0x2F24, 0x0137
REPORT_ID = 0x01
L4_BYTE, R4_BYTE = 9, 10
L4_CODE, R4_CODE = 0x69, 0x6A
KEY_F14, KEY_F15 = 184, 185
EV_SYN, EV_KEY = 0x00, 0x01
BUS_BLUETOOTH = 0x05
UI_SET_EVBIT, UI_SET_KEYBIT = 0x40045564, 0x40045565
UI_DEV_SETUP, UI_DEV_CREATE = 0x405C5503, 0x5501
INPUT_EVENT = struct.Struct("llHHi")
UINPUT_NAME = "GPD Win 5 Back Buttons"
DEBUG = os.environ.get("GPD_BACKKEYS_DEBUG") == "1"

def log(m): sys.stdout.write(m + "\n"); sys.stdout.flush()

def find_hidraw():
    for path in sorted(glob.glob("/sys/class/hidraw/hidraw*")):
        try:
            with open(path + "/device/uevent") as f:
                for line in f:
                    if not line.startswith("HID_ID="): continue
                    p = line.strip().split(":")
                    if len(p) < 3: continue
                    if int(p[1][-4:] or "0", 16) == TARGET_VID and int(p[2], 16) == TARGET_PID:
                        return "/dev/" + os.path.basename(path)
        except OSError: continue
    return None

def create_uinput():
    import fcntl
    fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
    fcntl.ioctl(fd, UI_SET_EVBIT, EV_KEY); fcntl.ioctl(fd, UI_SET_EVBIT, EV_SYN)
    fcntl.ioctl(fd, UI_SET_KEYBIT, KEY_F14); fcntl.ioctl(fd, UI_SET_KEYBIT, KEY_F15)
    s = struct.pack("HHHH", BUS_BLUETOOTH, TARGET_VID, 0x9001, 1)
    s += UINPUT_NAME.encode().ljust(80, b"\x00") + struct.pack("I", 0)
    fcntl.ioctl(fd, UI_DEV_SETUP, s); fcntl.ioctl(fd, UI_DEV_CREATE)
    return fd

def emit(fd, t, c, v): os.write(fd, INPUT_EVENT.pack(0, 0, t, c, v))
def press(fd, c): emit(fd, EV_KEY, c, 1); emit(fd, EV_SYN, 0, 0)
def release(fd, c): emit(fd, EV_KEY, c, 0); emit(fd, EV_SYN, 0, 0)

def main():
    if "--monitor" in sys.argv:
        prev = None
        while True:
            path = find_hidraw()
            if not path: log("未找到设备,2s重试"); time.sleep(2); continue
            log("监听 %s" % path)
            try: fd = os.open(path, os.O_RDONLY)
            except OSError: time.sleep(2); continue
            try:
                while True:
                    data = os.read(fd, 128)
                    if not data: break
                    if data.hex() != prev:
                        prev = data.hex(); m = []
                        if len(data) > L4_BYTE and data[L4_BYTE] == L4_CODE: m.append("L4↓")
                        if len(data) > R4_BYTE and data[R4_BYTE] == R4_CODE: m.append("R4↓")
                        log("  " + " ".join("%02x" % b for b in data[:16]) + ("  <- " + " ".join(m) if m else ""))
            except OSError: pass
            finally: os.close(fd)
            time.sleep(1)
    if os.geteuid() != 0: print("需root", file=sys.stderr); return 1
    log("GPD Win5 背键守护进程启动")
    ufd = create_uinput()
    log("uinput 键盘 %s (F14=L4 F15=R4)" % UINPUT_NAME)
    l4d = r4d = False; prevr = None
    while True:
        path = find_hidraw()
        if not path: log("未找到设备,2s重试"); time.sleep(2); continue
        log("监听 %s" % path)
        try: fd = os.open(path, os.O_RDONLY)
        except OSError as e: log("打开失败 %s" % e); time.sleep(2); continue
        try:
            while True:
                data = os.read(fd, 128)
                if not data: log("设备EOF,重发现"); break
                if DEBUG and data.hex() != prevr:
                    prevr = data.hex(); log("  report: " + " ".join("%02x" % b for b in data[:24]))
                if len(data) <= max(L4_BYTE, R4_BYTE) or data[0] != REPORT_ID: continue
                l4n, r4n = data[L4_BYTE] == L4_CODE, data[R4_BYTE] == R4_CODE
                if l4n and not l4d: log("L4↓ F14"); press(ufd, KEY_F14)
                elif not l4n and l4d: log("L4↑"); release(ufd, KEY_F14)
                l4d = l4n
                if r4n and not r4d: log("R4↓ F15"); press(ufd, KEY_F15)
                elif not r4n and r4d: log("R4↑"); release(ufd, KEY_F15)
                r4d = r4n
        except OSError as e: log("读取中断 %s" % e)
        finally: os.close(fd)
        time.sleep(1)

if __name__ == "__main__": sys.exit(main())
