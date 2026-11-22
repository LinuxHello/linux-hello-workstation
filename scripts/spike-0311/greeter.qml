// Spike 0311's greeter window: what pam_linuxhello says, with its kind. Throwaway spike code.
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

ApplicationWindow {
    visible: true
    // No visibility: FullScreen: cage 0.2.1 asserts on a fullscreen request before the first
    // frame (surface->initialized), and it shows its one window full screen anyway.
    color: "#1b1e20"

    ColumnLayout {
        anchors.centerIn: parent
        width: 520
        spacing: 14

        Label {
            text: "Linux Hello — greetd spike"
            color: "#fcfcfc"
            font.pixelSize: 28
        }
        RowLayout {
            Label { text: "User"; color: "#bdc3c7" }
            TextField {
                id: user
                text: "lhpam"
                Layout.fillWidth: true
                onAccepted: greeter.login(text)
            }
            Button { text: "Sign in"; onClicked: greeter.login(user.text) }
        }
        // Each information and error line the module sent, in its own colour.
        Repeater {
            model: greeter.lines
            delegate: Label {
                required property var modelData
                text: (modelData.kind === "error" ? "Error: " : "Info: ") + modelData.text
                color: modelData.kind === "error" ? "#ed1515" : "#3daee9"
                wrapMode: Text.WordWrap
                Layout.fillWidth: true
                font.pixelSize: 18
            }
        }
        // The module's own question, word for word, above the field.
        Label {
            text: greeter.question
            visible: greeter.state === "asking"
            color: "#fcfcfc"
            font.pixelSize: 20
        }
        TextField {
            id: answer
            visible: greeter.state === "asking"
            echoMode: greeter.secret ? TextInput.Password : TextInput.Normal
            Layout.fillWidth: true
            onAccepted: { greeter.answer(text); text = "" }
        }
        RowLayout {
            visible: greeter.state === "signed-in"
            Label { text: "Signed in. Desktop:"; color: "#27ae60"; font.pixelSize: 20 }
            ComboBox { id: desktop; model: greeter.desktopNames; Layout.fillWidth: true }
            Button { text: "Start"; onClicked: greeter.start(desktop.currentIndex) }
        }
        Label {
            text: "state: " + greeter.state
            color: "#7f8c8d"
        }
    }
}
