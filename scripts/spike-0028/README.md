# Spike for ADR-0028: a cxx-qt object that QML uses to reach the Linux Hello Agent

Spike code, never shipped. It answers ADR-0028's two questions in the architecture repository: does `#![forbid(unsafe_code)]` hold in a crate that uses cxx-qt (no: the bridge needs one module allowed `unsafe` code), and does cxx-qt pass `linux-hello`'s cargo-deny rules (yes, with zbus 6).

In the desktop test VM (`make vm-desktop`), after `sudo apt install cargo rustc qt6-base-dev qt6-declarative-dev qt6-base-dev-tools`:

```sh
cd scripts/spike-0028 && QMAKE=/usr/lib/qt6/bin/qmake cargo build
QT_QPA_PLATFORM=offscreen ./target/debug/linuxhello-plasma-spike    # prints: qml: REACHABLE true
```

`src/bridge.rs` is the only module allowed `unsafe` code and holds only the bridge declaration; `src/agent_state.rs` holds the Rust behind the object under `deny(unsafe_code)`. Changing `#![deny(unsafe_code)]` in `src/main.rs` to `forbid` shows the failure.
