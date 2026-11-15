#!/usr/bin/env python3
"""A raw CTAP2 client (python-fido2) with exact control over the request: options, repeats on one channel.
   ctapraw.py info
   ctapraw.py make [--rk] [--uv] [--user N] [--rp ID]
   ctapraw.py get [--allow HEX] [--uv] [--up0] [--times N] [--rp ID]      (same request N times on one channel)
Prints one JSON object per response, with the flags decoded from authenticatorData."""
import argparse, hashlib, json, os, sys, time
from fido2.hid import CtapHidDevice
from fido2.ctap import CtapError
from fido2.ctap2 import Ctap2

ap = argparse.ArgumentParser()
ap.add_argument("cmd")
ap.add_argument("--rk", action="store_true"); ap.add_argument("--uv", action="store_true"); ap.add_argument("--up0", action="store_true")
ap.add_argument("--user", type=int, default=4); ap.add_argument("--rp", default="localhost")
ap.add_argument("--allow", default=""); ap.add_argument("--times", type=int, default=1)
a = ap.parse_args()
dev = next(CtapHidDevice.list_devices())
ctap = Ctap2(dev)

def flags(ad):
    f = bytes(ad)[32]
    return {"UP": f & 1, "UV": (f >> 2) & 1, "AT": (f >> 6) & 1}

def say(**kw):
    print(json.dumps(kw, default=lambda o: o.hex() if isinstance(o, (bytes, bytearray)) else str(o)), flush=True)

t0 = time.time()
try:
    if a.cmd == "info":
        i = ctap.info
        say(versions=i.versions, options=i.options, aaguid=i.aaguid.hex())
    elif a.cmd == "make":
        opts = {}
        if a.rk: opts["rk"] = True
        if a.uv: opts["uv"] = True
        r = ctap.make_credential(os.urandom(32), {"id": a.rp, "name": "Spike"},
                                 {"id": bytes([1, 2, 3, a.user]), "name": f"alice{a.user}", "displayName": "Alice"},
                                 [{"type": "public-key", "alg": -7}], options=opts or None)
        cid = r.auth_data.credential_data.credential_id
        say(ok=True, flags=flags(r.auth_data), cred_id=cid.hex(), id_len=len(cid), seconds=round(time.time() - t0, 2))
    elif a.cmd == "get":
        opts = {}
        if a.uv: opts["uv"] = True
        if a.up0: opts["up"] = False
        allow = [{"type": "public-key", "id": bytes.fromhex(a.allow)}] if a.allow else None
        cdh = os.urandom(32)
        for n in range(a.times):
            r = ctap.get_assertion(a.rp, cdh, allow_list=allow, options=opts or None)
            say(ok=True, n=n + 1, flags=flags(r.auth_data), number_of_credentials=r.number_of_credentials, user=r.user,
                sig=len(r.signature), seconds=round(time.time() - t0, 2))
            if r.number_of_credentials and n == 0 and not allow:
                for _ in range(r.number_of_credentials - 1):
                    r = ctap.get_next_assertion()
                    say(ok=True, next=True, flags=flags(r.auth_data), user=r.user, sig=len(r.signature))
except CtapError as e:
    say(ok=False, error=str(e), code=hex(int(e.code)), seconds=round(time.time() - t0, 2))
    sys.exit(1)
