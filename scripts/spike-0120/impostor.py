#!/usr/bin/env python3
"""Spike #120: a process of the same user that tries to be the prompt: it keeps connecting to the Agent's
prompt socket and answers "allow" with the right PIN. Prints what it received. Run for N seconds."""
import json, socket, sys, time
end = time.time() + float(sys.argv[1] if len(sys.argv) > 1 else 8)
got = 0
while time.time() < end:
    try:
        s = socket.socket(socket.AF_UNIX); s.settimeout(1.5); s.connect("/run/lhctap2/prompt.sock")
        s.sendall(b'{"allow": true, "pin": "123456"}\n')
        data = s.recv(200)
        if data: got += 1; print("received", data[:80])
        s.close()
    except OSError:
        pass
    time.sleep(0.3)
print("impostor done; messages from the Agent:", got)
