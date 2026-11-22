//! Spike for ADR-0028: a cxx-qt object that QML uses to reach the Linux Hello Agent.
#![deny(unsafe_code)]

mod agent_state;
mod bridge;

use cxx_qt_lib::{QGuiApplication, QQmlApplicationEngine, QUrl};

fn main() {
    let mut app = QGuiApplication::new();
    let mut engine = QQmlApplicationEngine::new();
    if let Some(engine) = engine.as_mut() {
        engine.load(&QUrl::from("qrc:/qt/qml/io/github/LinuxHello/Plasma/qml/main.qml"));
    }
    if let Some(app) = app.as_mut() {
        app.exec();
    }
}
