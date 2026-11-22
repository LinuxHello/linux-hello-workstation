//! The cxx-qt bridge declaration, and nothing else: cxx-qt's macro expands it into `unsafe` glue
//! between Rust and C++ inside this crate, so this is the one module allowed `unsafe` code.
#![allow(unsafe_code)]

// cxx-qt wants the Rust type beside the bridge; it is defined, safely, in `agent_state`.
pub use crate::agent_state::AgentStateRust;

#[cxx_qt::bridge]
pub mod qobject {
    extern "RustQt" {
        #[qobject]
        #[qml_element]
        #[qproperty(bool, reachable)]
        type AgentState = super::AgentStateRust;

        #[qinvokable]
        fn ping(self: Pin<&mut AgentState>);
    }
}
