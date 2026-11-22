//! The Rust behind the spike's QML object: whether the Linux Hello Agent answers on the system
//! bus. Safe code only.

use core::pin::Pin;

use crate::bridge::qobject;

/// The Rust side of `AgentState`.
#[derive(Default)]
pub struct AgentStateRust {
    /// Whether the Agent answered the last ping.
    pub(crate) reachable: bool,
}

impl qobject::AgentState {
    /// Asks the Agent `org.freedesktop.DBus.Peer.Ping` over the system bus.
    pub fn ping(self: Pin<&mut Self>) {
        let answered = futures_lite::future::block_on(async {
            let connection = zbus::Connection::system().await?;
            connection
                .call_method(
                    Some("io.github.LinuxHello.Agent1"),
                    "/io/github/LinuxHello/Agent1",
                    Some("org.freedesktop.DBus.Peer"),
                    "Ping",
                    &(),
                )
                .await
        })
        .is_ok();
        self.set_reachable(answered);
    }
}
