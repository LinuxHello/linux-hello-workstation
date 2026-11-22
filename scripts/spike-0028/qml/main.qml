import QtQuick
import io.github.LinuxHello.Plasma

Item {
    AgentState {
        id: agent
        Component.onCompleted: {
            ping();
            console.log("REACHABLE", reachable);
            Qt.quit();
        }
    }
}
