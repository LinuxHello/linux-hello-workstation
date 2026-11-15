#!/usr/bin/env python3
"""Simulates what a person (or an attacker with synthetic input) does when the prompt window appears.
   lhuser.py click|deny|chooseN|touch|pin|nothing [PIN]   loops: waits for the prompt window, then acts through XTEST (xdotool).
   Prints one line per window. A real user's sensor touch is not simulated here: see lhsensor."""
import subprocess, sys, time
mode, pin = sys.argv[1], (sys.argv[2] if len(sys.argv) > 2 else "")
def x(*a): return subprocess.run(["xdotool", *a], capture_output=True, text=True)
while True:
    r = x("search", "--sync", "--name", "Linux Hello prompt")
    time.sleep(0.6)                                   # let the window map and settle
    if mode == "click":
        x("mousemove", "200", "215", "click", "1")    # the Allow button of lh-prompt-stub (window at +100+100)
    elif mode.startswith("choose"):                  # chooseN: click the Nth choice (click mode: that is also the presence)
        x("mousemove", "290", str(175 + 34 * int(mode[6:])), "click", "1")
    elif mode == "deny":
        x("mousemove", "350", "215", "click", "1")
    elif mode == "touch":                             # a finger on the sensor: not an X event, root writes the sensor socket
        subprocess.run(["sudo", "-n", "python3", "/home/lh/spike120/lhsensor", "match"])
    elif mode == "pin":
        wid = r.stdout.split()[-1] if r.stdout.split() else ""
        x("mousemove", "270", "190", "click", "1")
        if wid: x("windowfocus", wid)                 # a browser window may hold the keyboard focus (no window manager)
        x("type", "--delay", "40", pin); x("key", "Return")
    print(time.strftime("%H:%M:%S"), "prompt window seen, mode", mode, flush=True)
    time.sleep(1.5)
