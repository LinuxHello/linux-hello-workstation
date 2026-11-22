//! Builds the QML module of the spike with cxx-qt-build.
use cxx_qt_build::{CxxQtBuilder, QmlModule};

fn main() {
    CxxQtBuilder::new_qml_module(
        QmlModule::new("io.github.LinuxHello.Plasma").qml_files(["qml/main.qml"]),
    )
    .files(["src/bridge.rs"])
    .build();
}
