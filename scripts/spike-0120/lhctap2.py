#!/usr/bin/env python3
"""Spike #120 prototype: the 0094 virtual CTAP2 authenticator, extended with resident keys, a presence
prompt on every request, user verification bound to a verification event, and one signature per request.

Not production code. Run as root in the test VM (see scripts/vm-test-uvup.sh):

    LH_PIN=123456 python3 lhctap2.py

What is added to spike 0094 (lhctap.py):
  * getInfo options rk, up and uv are true.
  * A Credential Index (index.json in the state directory) holds resident credentials: the credential
    ID of a resident key is a random handle, the TPM blobs and the user entity live in the index.
  * A stub Prompt UI. The Agent starts the prompt process, accepts its connection only if the peer is
    that child AND carries the AppArmor label of the prompt profile (SO_PEERSEC), shows the relying-party
    id from the request and nothing else, and takes the presence decision from one of three gestures:
      click   an Allow button in the prompt (what a session can synthesise)
      pin     the PIN typed into the prompt, checked by the TPM (a wrong PIN counts as an attempt)
      sensor  a match event on a socket only root can write (stand-in for fprintd's verified event)
  * UV is reported only when the user was verified for this request (pin, sensor) or, when the request
    asks for UV, within min(policy, 60) seconds of the last verification event. A click is never a
    verification. The 60 s cap is in the code, not in the policy.
  * One signature per request: an identical request repeated on the same channel within 30 s gets the
    stored response; nothing is prompted or signed twice.
  * Keepalives while it waits, "channel busy" for other channels, structured events in events.jsonl.
"""
import base64, hashlib, hmac, json, os, pwd, select, socket, struct, subprocess, sys, tempfile, time

import cbor2
from cryptography.hazmat.primitives.asymmetric.utils import encode_dss_signature
from cryptography.hazmat.primitives.serialization import load_pem_public_key

PIN = os.environ.get("LH_PIN", "123456")
STATE = os.environ.get("LH_STATE", "/var/lib/lhctap2")
RUN = os.environ.get("LH_RUN", "/run/lhctap2")
PROMPT_CMD = os.environ.get("LH_PROMPT_CMD", "/usr/local/libexec/linuxhello/lh-prompt-stub")
PROMPT_USER = os.environ.get("LH_PROMPT_USER", "lh")
PROMPT_LABEL = os.environ.get("LH_PROMPT_LABEL", "")        # expected AppArmor label; empty = do not check
DISPLAY = os.environ.get("LH_DISPLAY", ":99")
GESTURE_TIMEOUT = float(os.environ.get("LH_GESTURE_TIMEOUT", "15"))
UV_HARD_CAP = 60.0                                           # decision on #139: policy may shorten, never exceed
DEDUPE_TTL = 30.0
UHID_EVENT = 4380
UHID_DESTROY, UHID_START, UHID_STOP, UHID_OPEN, UHID_CLOSE, UHID_OUTPUT = 1, 2, 3, 4, 5, 6
UHID_CREATE2, UHID_INPUT2 = 11, 12
RDESC = bytes([0x06, 0xD0, 0xF1, 0x09, 0x01, 0xA1, 0x01,
               0x09, 0x20, 0x15, 0x00, 0x26, 0xFF, 0x00, 0x75, 0x08, 0x95, 0x40, 0x81, 0x02,
               0x09, 0x21, 0x15, 0x00, 0x26, 0xFF, 0x00, 0x75, 0x08, 0x95, 0x40, 0x91, 0x02,
               0xC0])
CTAPHID_PING, CTAPHID_MSG, CTAPHID_INIT, CTAPHID_WINK, CTAPHID_CBOR = 0x01, 0x03, 0x06, 0x08, 0x10
CTAPHID_CANCEL, CTAPHID_KEEPALIVE, CTAPHID_ERROR = 0x11, 0x3B, 0x3F
BROADCAST = b"\xff\xff\xff\xff"
E_OK, E_INVALID_OPTION, E_UNSUPPORTED_OPTION, E_OPERATION_DENIED = 0x00, 0x2C, 0x2B, 0x27
E_NO_CREDENTIALS, E_UNSUPPORTED_ALG, E_ACTION_TIMEOUT, E_NOT_ALLOWED = 0x2E, 0x26, 0x3A, 0x30
E_UV_BLOCKED, E_CREDENTIAL_EXCLUDED, E_PIN_INVALID = 0x32, 0x19, 0x31


def log(*a):
    print(time.strftime("%H:%M:%S"), *a, file=sys.stderr, flush=True)


def b64(b):
    return base64.b64encode(b).decode()


# ---- TPM (tpm2-tools process calls, as in 0094) -----------------------------------------------------
class Tpm:
    def __init__(self):
        os.makedirs(STATE, exist_ok=True)
        self.prim, self.root = f"{STATE}/prim.ctx", f"{STATE}/r.ctx"
        self.run("tpm2_createprimary", "-C", "o", "-G", "ecc", "-c", self.prim)
        if not os.path.exists(f"{STATE}/r.pub"):
            self.run("tpm2_create", "-C", self.prim, "-G", "ecc256:null:aes128cfb",
                     "-a", "restricted|decrypt|fixedtpm|fixedparent|sensitivedataorigin|userwithauth",
                     "-p", PIN, "-u", f"{STATE}/r.pub", "-r", f"{STATE}/r.priv")
        self.run("tpm2_load", "-C", self.prim, "-u", f"{STATE}/r.pub", "-r", f"{STATE}/r.priv", "-c", self.root)
        # A verifier key: loading it with a PIN succeeds only if the PIN is right (a wrong PIN counts as a
        # dictionary-attack attempt in the TPM, which is the point of using the TPM to check it).
        if not os.path.exists(f"{STATE}/v.pub"):
            self.run("tpm2_create", "-C", self.root, "-P", PIN, "-G", "ecc256:ecdsa-sha256",
                     "-a", "sign|fixedtpm|fixedparent|sensitivedataorigin|userwithauth",
                     "-u", f"{STATE}/v.pub", "-r", f"{STATE}/v.priv")

    def run(self, *cmd):
        p = subprocess.run(cmd, capture_output=True, text=True)
        if p.returncode != 0:
            raise RuntimeError(f"{cmd[0]} failed: {p.stderr.strip()[:300]}")
        return p.stdout

    def check_pin(self, pin):
        with tempfile.TemporaryDirectory() as d:
            try:
                self.run("tpm2_load", "-C", self.root, "-P", pin, "-u", f"{STATE}/v.pub", "-r", f"{STATE}/v.priv", "-c", f"{d}/v.ctx")
                return True
            except RuntimeError:
                return False

    def new_credential(self):
        with tempfile.TemporaryDirectory() as d:
            self.run("tpm2_create", "-C", self.root, "-P", PIN, "-G", "ecc256:ecdsa-sha256",
                     "-a", "sign|fixedtpm|fixedparent|sensitivedataorigin|userwithauth",
                     "-u", f"{d}/c.pub", "-r", f"{d}/c.priv")
            self.run("tpm2_load", "-C", self.root, "-P", PIN, "-u", f"{d}/c.pub", "-r", f"{d}/c.priv", "-c", f"{d}/c.ctx")
            self.run("tpm2_readpublic", "-c", f"{d}/c.ctx", "-f", "pem", "-o", f"{d}/c.pem")
            nums = load_pem_public_key(open(f"{d}/c.pem", "rb").read()).public_numbers()
            return open(f"{d}/c.pub", "rb").read(), open(f"{d}/c.priv", "rb").read(), nums.x, nums.y

    def sign(self, pub, priv, message):
        with tempfile.TemporaryDirectory() as d:
            open(f"{d}/c.pub", "wb").write(pub)
            open(f"{d}/c.priv", "wb").write(priv)
            open(f"{d}/m", "wb").write(message)
            self.run("tpm2_load", "-C", self.root, "-P", PIN, "-u", f"{d}/c.pub", "-r", f"{d}/c.priv", "-c", f"{d}/c.ctx")
            self.run("tpm2_sign", "-c", f"{d}/c.ctx", "-g", "sha256", "-s", "ecdsa", "-f", "plain", "-o", f"{d}/sig", f"{d}/m")
            raw = open(f"{d}/sig", "rb").read()
        if len(raw) == 64:
            return encode_dss_signature(int.from_bytes(raw[:32], "big"), int.from_bytes(raw[32:], "big"))
        return raw


# ---- Credential Index ---------------------------------------------------------------------------------
class Index:
    """Resident credentials, kept by the Agent. Entries: id (hex handle), rp, rpHash, user, pub, priv, created."""

    def __init__(self):
        self.path = f"{STATE}/index.json"
        self.items = json.load(open(self.path)) if os.path.exists(self.path) else []

    def save(self):
        tmp = self.path + ".tmp"
        json.dump(self.items, open(tmp, "w"))
        os.replace(tmp, self.path)

    def add(self, rp_id, rp_hash, user, pub, priv, provider="tpm"):
        # CTAP: a resident credential for the same rp and user id replaces the earlier one
        self.items = [i for i in self.items if not (i["rpHash"] == rp_hash.hex() and i["user"]["id"] == b64(user["id"]))]
        handle = os.urandom(16)
        self.items.append({"id": handle.hex(), "rp": rp_id, "rpHash": rp_hash.hex(),
                           "user": {"id": b64(user["id"]), "name": user.get("name", ""), "displayName": user.get("displayName", "")},
                           "pub": b64(pub), "priv": b64(priv), "created": time.time(), "provider": provider})
        self.save()
        return b"LHR" + handle

    def by_handle(self, cid):
        if cid[:3] != b"LHR":
            return None
        return next((i for i in self.items if i["id"] == cid[3:].hex()), None)

    def for_rp(self, rp_hash):
        return sorted((i for i in self.items if i["rpHash"] == rp_hash.hex()), key=lambda i: -i["created"])


# ---- Agent: unlock state, gestures, the stub Prompt UI -------------------------------------------------
class Agent:
    def __init__(self, tpm):
        self.tpm, self.index = tpm, Index()
        self.mode = os.environ.get("LH_MODE", "click")
        self.policy_window = float(os.environ.get("LH_UV_WINDOW", "60"))
        self.silent = os.environ.get("LH_SILENT", "stub")      # up=false requests: stub | refuse | sign
        self.dedupe = os.environ.get("LH_DEDUPE", "1") == "1"
        self.provider = "tpm"          # provider tag for new resident credentials: a stand-in for a second provider (KeePassXC)
        self.choose = os.environ.get("LH_CHOOSE", "1") == "1"   # several discoverable credentials: the Prompt UI asks which one
        self.last_verified = None                              # monotonic time of the last verification event
        self.ev = open(f"{STATE}/events.jsonl", "a")
        os.makedirs(RUN, exist_ok=True)
        os.chmod(RUN, 0o755)
        self.sensor = self.bind(f"{RUN}/sensor", 0o600, socket.SOCK_DGRAM)    # root only: nobody in the session can write it
        self.ctl = self.bind(f"{RUN}/ctl", 0o600, socket.SOCK_DGRAM)
        self.ps = self.bind(f"{RUN}/prompt.sock", 0o600, socket.SOCK_STREAM)   # only the prompt's user may connect
        pw = pwd.getpwnam(PROMPT_USER)
        os.chown(f"{RUN}/prompt.sock", pw.pw_uid, pw.pw_gid)
        self.ps.listen(8)

    def bind(self, path, mode, kind):
        if os.path.exists(path):
            os.unlink(path)
        s = socket.socket(socket.AF_UNIX, kind)
        s.bind(path)
        os.chmod(path, mode)
        s.setblocking(False)
        return s

    def event(self, **kw):
        kw["t"] = round(time.time(), 3)
        self.ev.write(json.dumps(kw) + "\n")
        self.ev.flush()

    # UV window: min(policy, hard cap), never negative
    def window(self):
        w = self.policy_window
        return 0.0 if not (w > 0) else min(w, UV_HARD_CAP)

    def in_window(self):
        return self.last_verified is not None and (time.monotonic() - self.last_verified) <= self.window()

    def mark_verified(self, why):
        self.last_verified = time.monotonic()
        self.event(ev="verified", why=why)

    def handle_ctl(self):
        try:
            msg = self.ctl.recv(256).decode().split()
        except BlockingIOError:
            return
        if not msg:
            return
        c, a = msg[0], msg[1:]
        if c == "mode":
            self.mode = a[0]
        elif c == "window":
            self.policy_window = float(a[0])
        elif c == "silent":
            self.silent = a[0]
        elif c == "provider":
            self.provider = a[0]
        elif c == "choose":
            self.choose = a[0] == "1"
        elif c == "dedupe":
            self.dedupe = a[0] == "1"
        elif c == "unlock":             # the session was unlocked with a verification (PAM/face/PIN): a verification event
            self.mark_verified("unlock")
        elif c == "forget":
            self.last_verified = None
        self.event(ev="ctl", cmd=" ".join(msg), mode=self.mode, policy_window=self.policy_window, window=self.window())

    # -- prompt process, accepted only if it is our child with the expected AppArmor label
    def start_prompt(self, rp_id, mode, choices=None):
        env = {"PATH": "/usr/bin:/bin", "DISPLAY": DISPLAY, "XAUTHORITY": f"/home/{PROMPT_USER}/.Xauthority",
               "HOME": f"/home/{PROMPT_USER}", "LH_PROMPT_SOCK": f"{RUN}/prompt.sock",
               "LH_PROMPT_DUMPABLE": os.environ.get("LH_PROMPT_DUMPABLE", "")}
        child = subprocess.Popen(["setpriv", "--reuid", PROMPT_USER, "--regid", PROMPT_USER, "--init-groups", PROMPT_CMD],
                                 env=env, stdout=subprocess.DEVNULL, stderr=open(f"{STATE}/prompt.err", "a"))
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            r, _, _ = select.select([self.ps], [], [], 0.2)
            if not r:
                continue
            conn, _ = self.ps.accept()
            pid, uid, gid = struct.unpack("3i", conn.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i")))
            try:
                label = conn.getsockopt(socket.SOL_SOCKET, 31, 256).split(b"\0")[0].decode()      # SO_PEERSEC
            except OSError:
                label = "?"
            ok = pid == child.pid and (not PROMPT_LABEL or label == PROMPT_LABEL)
            self.event(ev="prompt_connection", pid=pid, expected_pid=child.pid, label=label, accepted=ok)
            if not ok:
                conn.close()            # an impostor answering the prompt: dropped, the real one is still awaited
                continue
            conn.setblocking(False)
            conn.sendall((json.dumps({"mode": mode, "rp": rp_id, "choices": choices or []}) + "\n").encode())
            return child, conn
        child.kill()
        return None, None

    def stop_prompt(self, child, conn):
        try:
            if conn:
                conn.sendall(b'{"close":true}\n')
                conn.close()
        except OSError:
            pass
        if child:
            try:
                child.wait(timeout=2)
            except subprocess.TimeoutExpired:
                child.kill()

    def gesture(self, dev, cid, rp_id, choices=None):
        """Returns (present, verified_now, chosen_index). Blocks with keepalives; the Prompt UI shows rp_id
        (and, when asked to choose, the credential labels the Agent holds)."""
        mode, t0 = self.mode, time.monotonic()
        self.chosen = 0
        if mode == "none":
            return True, False, 0
        child, conn = self.start_prompt(rp_id, mode, choices)
        if conn is None:
            self.event(ev="gesture", mode=mode, result="no_prompt")
            return False, False, 0
        present = verified = False
        buf, result = b"", "timeout"
        try:
            while time.monotonic() - t0 < GESTURE_TIMEOUT:
                if dev.cancelled(cid):
                    result = "cancelled"
                    break
                fds = [conn] + ([self.sensor] if mode == "sensor" else [])
                ready = dev.poll(cid, fds, 0.1)
                if conn in ready:
                    try:
                        chunk = conn.recv(4096)
                    except BlockingIOError:
                        continue
                    if not chunk:
                        result = "prompt_closed"
                        break
                    buf += chunk
                    if b"\n" in buf:
                        reply = json.loads(buf.split(b"\n")[0])
                        buf = b""
                        if isinstance(reply.get("choice"), int) and choices and 0 <= reply["choice"] < len(choices):
                            self.chosen = reply["choice"]
                            if mode != "click":      # sensor, PIN: choosing is not the authorisation, keep waiting for it
                                continue
                        if mode == "click":
                            present = bool(reply.get("allow"))
                            result = "allow" if present else "deny"
                        elif mode == "pin":
                            pin = reply.get("pin")
                            if isinstance(pin, str) and pin and self.tpm.check_pin(pin):
                                present = verified = True
                                result = "pin_ok"
                            else:
                                result = "pin_wrong"
                        break
                if self.sensor in ready:
                    msg = self.sensor.recv(64)
                    present = verified = msg.strip() == b"match"
                    result = "sensor_match" if present else "sensor_nomatch"
                    break
        finally:
            self.stop_prompt(child, conn)
        self.event(ev="gesture", mode=mode, rp=rp_id, result=result, seconds=round(time.monotonic() - t0, 2))
        if verified:
            self.mark_verified(result)
        return present, verified, self.chosen

    def uv_decision(self, uv_requested, verified_now):
        """The rule decided on #139: UV only for this request's verification, or, if the request asks for UV,
        within min(policy, 60 s) of a verification event. A presence click alone is never verification."""
        if verified_now:
            return True, "this_request"
        if uv_requested and self.in_window():
            return True, "window"
        return False, ("denied" if uv_requested else "not_requested")


# ---- CTAP2 -------------------------------------------------------------------------------------------
class Ctap:
    def __init__(self, agent):
        self.a, self.tpm = agent, agent.tpm
        self.counter_file = f"{STATE}/counter"
        self.replay = {}            # (cid, sha256(request)) -> (monotonic time, response)
        self.next_state = {}        # cid -> pending getNextAssertion entries

    def counter(self):
        n = int(open(self.counter_file).read()) + 1 if os.path.exists(self.counter_file) else 1
        open(self.counter_file, "w").write(str(n))
        return n

    def handle(self, dev, cid, req):
        cmd = req[0]
        body = cbor2.loads(req[1:]) if len(req) > 1 else {}
        if cmd == 0x04:
            # uv is advertised only if the Agent can verify the user now: a verifying gesture (pin, sensor) is
            # configured, or a verification event is still inside the window. A click-only Agent says no.
            can_uv = self.a.mode in ("pin", "sensor") or self.a.in_window()
            return b"\x00" + cbor2.dumps({1: ["FIDO_2_0"], 3: bytes(16), 4: {"rk": True, "up": True, "uv": can_uv, "plat": False},
                                          5: 1200, 10: [{"alg": -7, "type": "public-key"}]}, canonical=True)
        if cmd == 0x01:
            return self.make_credential(dev, cid, body)
        if cmd == 0x02:
            key = (cid, hashlib.sha256(req).digest())
            now = time.monotonic()
            self.replay = {k: v for k, v in self.replay.items() if now - v[0] <= DEDUPE_TTL}
            if self.a.dedupe and key in self.replay:
                self.a.event(ev="replayed", cmd="getAssertion", rp=body.get(1))
                return self.replay[key][1]
            resp = self.get_assertion(dev, cid, body)
            if resp[:1] == b"\x00":
                self.replay[key] = (now, resp)
            return resp
        if cmd == 0x08:
            return self.get_next(cid)
        self.a.event(ev="unsupported", cmd=hex(cmd))
        return b"\x01"

    @staticmethod
    def opts(body, k):
        o = body.get(k, {})
        return o if isinstance(o, dict) else {}

    def make_credential(self, dev, cid, b):
        a = self.a
        rp_id = b[2]["id"]
        o = self.opts(b, 7)
        rk, uv, up = bool(o.get("rk")), bool(o.get("uv")), o.get("up", True)
        if rp_id in (".dummy", "make.me.blink"):       # Chromium's and Firefox's "touch to select this device" probes: not credential requests
            a.event(ev="request", cmd="makeCredential", rp=rp_id, cid=cid.hex(), action="selection_probe_refused")
            return bytes([E_OPERATION_DENIED])
        if up is False:
            return bytes([E_INVALID_OPTION])
        if not any(p.get("alg") == -7 for p in b[4]):
            return bytes([E_UNSUPPORTED_ALG])
        rp_hash = hashlib.sha256(rp_id.encode()).digest()
        a.event(ev="request", cmd="makeCredential", rp=rp_id, cid=cid.hex(), rk=rk, uv=uv, cdh=b[1].hex()[:8])
        present, verified, _ = a.gesture(dev, cid, rp_id)
        if not present:
            return bytes([E_OPERATION_DENIED])
        uv_flag, why = a.uv_decision(uv, verified)
        if uv and not uv_flag:
            a.event(ev="refused", cmd="makeCredential", rp=rp_id, reason="uv_required_but_no_verification")
            return bytes([E_OPERATION_DENIED])
        pub, priv, x, y = self.tpm.new_credential()
        if rk:
            cred_id = a.index.add(rp_id, rp_hash, b[3], pub, priv, a.provider)
        else:
            cred_id = b"LH2" + struct.pack(">H", len(pub)) + pub + struct.pack(">H", len(priv)) + priv
        cose = cbor2.dumps({1: 2, 3: -7, -1: 1, -2: x.to_bytes(32, "big"), -3: y.to_bytes(32, "big")}, canonical=True)
        flags = 0x41 | (0x04 if uv_flag else 0)
        auth = rp_hash + bytes([flags]) + struct.pack(">I", self.counter()) + bytes(16) + struct.pack(">H", len(cred_id)) + cred_id + cose
        sig = self.tpm.sign(pub, priv, auth + b[1])
        a.event(ev="signed", cmd="makeCredential", rp=rp_id, cid=cid.hex(), up=1, uv=int(uv_flag), uv_why=why, rk=rk)
        return b"\x00" + cbor2.dumps({1: "packed", 2: auth, 3: {"alg": -7, "sig": sig}}, canonical=True)

    def resolve(self, rp_hash, b):
        """Credentials for this request: from the allow list (handles resolve through the Index) or, with no
        allow list, every resident credential for the relying party."""
        out = []
        allow = b.get(3)
        if allow:
            for c in allow:
                cid = c["id"]
                hit = self.a.index.by_handle(cid)
                if hit and hit["rpHash"] == rp_hash.hex():
                    out.append((cid, base64.b64decode(hit["pub"]), base64.b64decode(hit["priv"]), hit["user"]))
                elif cid[:3] == b"LH2":
                    n = struct.unpack(">H", cid[3:5])[0]
                    m = struct.unpack(">H", cid[5 + n:7 + n])[0]
                    out.append((cid, cid[5:5 + n], cid[7 + n:7 + n + m], None))
        else:
            for i in self.a.index.for_rp(rp_hash):
                out.append((b"LHR" + bytes.fromhex(i["id"]), base64.b64decode(i["pub"]), base64.b64decode(i["priv"]), i["user"]))
        return out

    def assertion(self, rp_hash, cdh, cred, n_total, uv_flag, up_flag):
        cid, pub, priv, user = cred
        auth = rp_hash + bytes([(0x01 if up_flag else 0) | (0x04 if uv_flag else 0)]) + struct.pack(">I", self.counter())
        sig = self.tpm.sign(pub, priv, auth + cdh)
        r = {1: {"id": cid, "type": "public-key"}, 2: auth, 3: sig}
        if user:
            r[4] = {"id": base64.b64decode(user["id"])}
            if uv_flag and user["name"]:     # user details only when the user was verified (CTAP privacy rule)
                r[4].update({"name": user["name"], "displayName": user["displayName"]})
        if n_total and n_total > 1:
            r[5] = n_total
        return r

    def get_assertion(self, dev, cid, b):
        a = self.a
        rp_id, cdh = b[1], b[2]
        o = self.opts(b, 5)
        uv, up = bool(o.get("uv")), o.get("up", True)
        rp_hash = hashlib.sha256(rp_id.encode()).digest()
        creds = self.resolve(rp_hash, b)
        a.event(ev="request", cmd="getAssertion", rp=rp_id, cid=cid.hex(), allow=len(b.get(3) or []), found=len(creds),
                up=up, uv=uv, cdh=cdh.hex()[:8])
        if not creds:
            return bytes([E_NO_CREDENTIALS])
        if up is False:                  # a "silent" request: the clients use it to probe whether the device knows a credential
            if a.silent == "refuse":
                a.event(ev="refused", cmd="getAssertion", rp=rp_id, reason="up_false_policy")
                return bytes([E_UNSUPPORTED_OPTION])
            if a.silent == "stub":       # answer "I know this credential" without using the key: a well-formed, invalid signature
                c = creds[0]
                r = {1: {"id": c[0], "type": "public-key"}, 2: rp_hash + b"\x00" + struct.pack(">I", 0),
                     3: b"\x30\x06\x02\x01\x00\x02\x01\x00"}
                a.event(ev="silent_probe_answered_without_signing", cmd="getAssertion", rp=rp_id, cid=cid.hex())
                return b"\x00" + cbor2.dumps(r, canonical=True)
            r = self.assertion(rp_hash, cdh, creds[0], len(creds), False, False)
            a.event(ev="signed", cmd="getAssertion", rp=rp_id, cid=cid.hex(), up=0, uv=0, uv_why="none", silent=True)
            return b"\x00" + cbor2.dumps(r, canonical=True)
        choices = None
        if not b.get(3) and len(creds) > 1 and a.choose:
            choices = [f'{c[3]["name"] if c[3] else "?"} ({next((i["provider"] for i in a.index.items if b"LHR" + bytes.fromhex(i["id"]) == c[0]), "tpm")})' for c in creds]
        present, verified, chosen = a.gesture(dev, cid, rp_id, choices)
        if not present:
            return bytes([E_OPERATION_DENIED])
        if choices:
            creds = [creds[chosen]]                 # one credential, one signature: the user chose in the Prompt UI
        uv_flag, why = a.uv_decision(uv, verified)
        if uv and not uv_flag:
            a.event(ev="refused", cmd="getAssertion", rp=rp_id, reason="uv_required_but_no_verification")
            return bytes([E_OPERATION_DENIED])
        r = self.assertion(rp_hash, cdh, creds[0], len(creds), uv_flag, True)
        self.next_state[cid] = (time.monotonic(), rp_hash, cdh, creds[1:], len(creds), uv_flag)
        a.event(ev="signed", cmd="getAssertion", rp=rp_id, cid=cid.hex(), up=1, uv=int(uv_flag), uv_why=why, silent=False)
        return b"\x00" + cbor2.dumps(r, canonical=True)

    def get_next(self, cid):
        st = self.next_state.get(cid)
        if not st or time.monotonic() - st[0] > 30 or not st[3]:
            return bytes([0x30])         # CTAP2_ERR_NOT_ALLOWED
        t, rp_hash, cdh, rest, n, uv_flag = st
        r = self.assertion(rp_hash, cdh, rest[0], 0, uv_flag, True)
        self.next_state[cid] = (t, rp_hash, cdh, rest[1:], n, uv_flag)
        self.a.event(ev="signed", cmd="getNextAssertion", cid=cid.hex(), up=1, uv=int(uv_flag))
        return b"\x00" + cbor2.dumps(r, canonical=True)


# ---- CTAPHID over uhid -------------------------------------------------------------------------------
class Device:
    def __init__(self, ctap):
        self.ctap, self.agent = ctap, ctap.a
        self.fd = os.open("/dev/uhid", os.O_RDWR)
        self.next_cid = 1
        self.pending = {}
        self.busy = None
        self.aborts = set()
        create = struct.pack("<I128s64s64sHHIIII4096s", UHID_CREATE2, b"Linux Hello spike", b"", b"",
                             len(RDESC), 3, 0x1209, 0xF1D0, 1, 0, RDESC.ljust(4096, b"\0"))
        os.write(self.fd, create)
        log("uhid device created")

    def send(self, cid, cmd, data):
        self.input((cid + bytes([0x80 | cmd]) + struct.pack(">H", len(data)) + data[:57]).ljust(64, b"\0"))
        data, seq = data[57:], 0
        while data:
            self.input((cid + bytes([seq]) + data[:59]).ljust(64, b"\0"))
            data, seq = data[59:], seq + 1

    def input(self, pkt):
        os.write(self.fd, struct.pack("<IH4096s", UHID_INPUT2, 64, pkt.ljust(4096, b"\0")))

    def packet(self, pkt):
        cid = pkt[:4]
        if pkt[4] & 0x80:
            cmd, n = pkt[4] & 0x7F, (pkt[5] << 8) | pkt[6]
            if self.busy is not None and cmd != CTAPHID_INIT:
                if cid == self.busy and cmd == CTAPHID_CANCEL:
                    self.aborts.add(cid)
                else:
                    self.send(cid, CTAPHID_ERROR, b"\x06")        # CHANNEL_BUSY
                return
            self.pending[cid] = [cmd, n, bytearray(pkt[7:7 + n])]
        elif cid in self.pending:
            self.pending[cid][2] += pkt[5:64]
        else:
            return
        cmd, n, data = self.pending[cid]
        if len(data) < n:
            return
        del self.pending[cid]
        self.message(cid, cmd, bytes(data[:n]))

    def message(self, cid, cmd, data):
        if cmd == CTAPHID_INIT:
            new = struct.pack(">I", self.next_cid)
            self.next_cid += 1
            self.send(cid, CTAPHID_INIT, data[:8] + new + bytes([2, 1, 0, 0, 0x04 | 0x08]))
        elif cmd == CTAPHID_PING:
            self.send(cid, CTAPHID_PING, data)
        elif cmd == CTAPHID_WINK:
            self.send(cid, CTAPHID_WINK, b"")
        elif cmd == CTAPHID_CBOR:
            self.busy = cid
            try:
                resp = self.ctap.handle(self, cid, data)
            except Exception as e:
                log("CBOR error", repr(e))
                self.agent.event(ev="error", err=repr(e)[:200])
                resp = b"\x7f"
            finally:
                self.busy = None
            if cid in self.aborts:
                self.aborts.discard(cid)
                resp = bytes([0x2D])                                # CTAP2_ERR_KEEPALIVE_CANCEL
            self.send(cid, CTAPHID_CBOR, resp)
        elif cmd == CTAPHID_CANCEL:
            pass
        else:
            self.send(cid, CTAPHID_ERROR, b"\x01")

    def cancelled(self, cid):
        return cid in self.aborts

    def poll(self, cid, fds, timeout):
        """Wait up to timeout for fds; serve the HID side meanwhile (busy channel); send a keepalive when idle."""
        r, _, _ = select.select([self.fd] + fds, [], [], timeout)
        if self.fd in r:
            self.read_event()
        if not r:
            self.send(cid, CTAPHID_KEEPALIVE, b"\x02")           # UPNEEDED
        return [x for x in r if x is not self.fd]

    def read_event(self):
        ev = os.read(self.fd, UHID_EVENT)
        kind = struct.unpack_from("<I", ev)[0]
        if kind == UHID_OUTPUT:
            size = struct.unpack_from("<H", ev, 4 + 4096)[0]
            data = ev[4:4 + size]
            if size == 65 and data[0] == 0:
                data = data[1:]
            self.packet(bytes(data[:64]))

    def loop(self):
        while True:
            r, _, _ = select.select([self.fd, self.agent.ctl], [], [])
            if self.agent.ctl in r:
                self.agent.handle_ctl()
            if self.fd in r:
                self.read_event()


if __name__ == "__main__":
    tpm = Tpm()
    agent = Agent(tpm)
    Device(Ctap(agent)).loop()
