#!/usr/bin/env python3
"""Spike 0311's greeter: the smallest login screen for greetd that shows what pam_linuxhello says.

Throwaway spike code, never shipped (Linux Hello's real greeter is to be QML with a Rust part). The
QML window (greeter.qml) shows each message greetd passes on with its kind: a question above a
field (secret or visible), information and error lines in two colours. This Python part speaks
greetd's socket protocol (greetd-ipc(7)): create_session, post_auth_message_response,
start_session, cancel_session. It starts no program itself; greetd starts the chosen desktop.

For a run without a person, LH_SPIKE_ANSWERS holds the answers to type, separated by "|", and
LH_SPIKE_DELAY the seconds to wait before each (so a screenshot can show the question); with
LH_SPIKE_START set it then starts the desktop named LH_SPIKE_DESKTOP (the first one otherwise). The log of
every message goes to standard error and to /tmp/lh-spike-greeter.log.
"""
import json
import os
import socket
import struct
import sys
import configparser
import glob

from PySide6.QtCore import QObject, Property, QTimer, Signal, Slot
from PySide6.QtGui import QGuiApplication
from PySide6.QtQml import QQmlApplicationEngine


LOG_FILE = "/tmp/lh-spike-greeter.log"


def log(*parts):
    """To standard error (cage's console) and to a file the test reads."""
    print("lh-spike-greeter:", *parts, file=sys.stderr, flush=True)
    try:
        with open(LOG_FILE, "a", encoding="utf-8") as f:
            print("lh-spike-greeter:", *parts, file=f)
    except OSError:
        pass


class Greetd:
    """One connection to greetd's socket ($GREETD_SOCK)."""

    def __init__(self):
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.connect(os.environ["GREETD_SOCK"])

    def talk(self, message):
        data = json.dumps(message).encode()
        self.sock.sendall(struct.pack("=I", len(data)) + data)
        size = struct.unpack("=I", self.sock.recv(4, socket.MSG_WAITALL))[0]
        reply = json.loads(self.sock.recv(size, socket.MSG_WAITALL))
        log("sent", message.get("type"), "got", json.dumps(reply))
        return reply


def desktops():
    """The installed desktops: (name, command) from the session files, as GDM and SDDM read them."""
    found = []
    for path in sorted(glob.glob("/usr/share/wayland-sessions/*.desktop")):
        entry = configparser.ConfigParser(interpolation=None)
        entry.read(path)
        if entry.has_section("Desktop Entry"):
            section = entry["Desktop Entry"]
            if "Exec" in section:
                found.append((section.get("Name", os.path.basename(path)), section["Exec"]))
    return found


class Bridge(QObject):
    """What the QML window shows and what it can ask for."""

    changed = Signal()

    def __init__(self):
        super().__init__()
        self.greetd = Greetd()
        self._question = ""
        self._secret = True
        self._lines = []
        self._state = "idle"
        self._desktops = desktops()
        self.answers = (
            os.environ["LH_SPIKE_ANSWERS"].split("|") if "LH_SPIKE_ANSWERS" in os.environ else []
        )
        self.delay = int(os.environ.get("LH_SPIKE_DELAY", "0"))

    def _get_question(self):
        return self._question

    def _get_secret(self):
        return self._secret

    def _get_lines(self):
        return self._lines

    def _get_state(self):
        return self._state

    def _get_desktops(self):
        return [name for name, _ in self._desktops]

    question = Property(str, _get_question, notify=changed)
    secret = Property(bool, _get_secret, notify=changed)
    lines = Property("QVariantList", _get_lines, notify=changed)
    state = Property(str, _get_state, notify=changed)
    desktopNames = Property("QVariantList", _get_desktops, notify=changed)

    def _handle(self, reply):
        """Shows what greetd said and, for a run without a person, answers it."""
        kind = reply.get("type")
        if kind == "auth_message":
            message_kind, text = reply["auth_message_type"], reply["auth_message"]
            log("MSG", message_kind, repr(text))
            if message_kind in ("secret", "visible"):
                self._question, self._secret, self._state = text, message_kind == "secret", "asking"
                self.changed.emit()
                if self.answers:
                    answer = self.answers.pop(0)
                    QTimer.singleShot(self.delay * 1000, lambda: self.answer(answer))
            else:
                self._lines = self._lines + [{"kind": message_kind, "text": text}]
                self.changed.emit()
                self._handle(self.greetd.talk({"type": "post_auth_message_response"}))
        elif kind == "success":
            self._state, self._question = "signed-in", ""
            self.changed.emit()
            if os.environ.get("LH_SPIKE_START"):
                names = [name for name, _ in self._desktops]
                wanted = os.environ.get("LH_SPIKE_DESKTOP", names[0] if names else "")
                index = names.index(wanted) if wanted in names else 0
                QTimer.singleShot(self.delay * 1000, lambda: self.start(index))
        else:
            self._state = "failed"
            self._lines = self._lines + [{"kind": "error", "text": reply.get("description", kind)}]
            self.changed.emit()
            self.greetd.talk({"type": "cancel_session"})

    @Slot(str)
    def login(self, user):
        self._lines, self._state = [], "starting"
        self.changed.emit()
        self._handle(self.greetd.talk({"type": "create_session", "username": user}))

    @Slot(str)
    def answer(self, text):
        self._handle(self.greetd.talk({"type": "post_auth_message_response", "response": text}))

    @Slot(int)
    def start(self, index):
        name, command = self._desktops[index]
        log("starting", name, command)
        env = ["XDG_SESSION_TYPE=wayland"]
        reply = self.greetd.talk({"type": "start_session", "cmd": command.split(), "env": env})
        if reply.get("type") == "success":
            QGuiApplication.quit()


def main():
    app = QGuiApplication(sys.argv)
    bridge = Bridge()
    engine = QQmlApplicationEngine()
    engine.rootContext().setContextProperty("greeter", bridge)
    engine.load(os.path.join(os.path.dirname(os.path.abspath(__file__)), "greeter.qml"))
    if not engine.rootObjects():
        log("the QML window did not load")
        return 1
    user = os.environ.get("LH_SPIKE_USER")
    if user:
        QTimer.singleShot(2000, lambda: bridge.login(user))
    return app.exec()


if __name__ == "__main__":
    sys.exit(main())
