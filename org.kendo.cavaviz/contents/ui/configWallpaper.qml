import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import QtQuick.Dialogs as QtDialogs
import org.kde.kirigami as Kirigami
import org.kde.kcmutils as KCM

KCM.SimpleKCM {
    id: page

    property alias cfg_rotationEnabled: rotationEnabled.checked
    property alias cfg_rotationDir: rotationDir.text
    property alias cfg_rotationOrder: rotationOrder.currentIndex
    // Se guarda en segundos; los tres SpinBox lo muestran como horas, minutos y segundos
    property int cfg_rotationIntervalSec

    function updateInterval() {
        cfg_rotationIntervalSec = Math.max(10, hours.value * 3600 + minutes.value * 60 + seconds.value)
    }

    Kirigami.FormLayout {

        QQC2.CheckBox { id: rotationEnabled; text: "Cava Viz cambia el wallpaper" }

        RowLayout {
            Kirigami.FormData.label: "Carpeta:"
            enabled: rotationEnabled.checked
            QQC2.TextField {
                id: rotationDir
                placeholderText: "Vacío = carpeta de la presentación de Plasma"
                Layout.preferredWidth: Kirigami.Units.gridUnit * 16
            }
            QQC2.Button {
                icon.name: "document-open-folder"
                onClicked: folderDialog.open()
            }
        }

        QtDialogs.FolderDialog {
            id: folderDialog
            // selectedFolder es una URL (file:///...); se guarda como ruta normal
            onAccepted: rotationDir.text = decodeURIComponent(selectedFolder.toString().replace(/^file:\/\//, ""))
        }

        QQC2.ComboBox {
            id: rotationOrder
            Kirigami.FormData.label: "Orden:"
            enabled: rotationEnabled.checked
            model: ["Aleatorio", "Alfabético", "Más recientes primero"]
        }

        RowLayout {
            Kirigami.FormData.label: "Cambiar cada:"
            enabled: rotationEnabled.checked
            QQC2.SpinBox {
                id: hours; from: 0; to: 168
                value: Math.floor(page.cfg_rotationIntervalSec / 3600)
                onValueModified: page.updateInterval()
            }
            QQC2.Label { text: "horas" }
            QQC2.SpinBox {
                id: minutes; from: 0; to: 59
                value: Math.floor(page.cfg_rotationIntervalSec % 3600 / 60)
                onValueModified: page.updateInterval()
            }
            QQC2.Label { text: "minutos" }
            QQC2.SpinBox {
                id: seconds; from: 0; to: 59
                value: page.cfg_rotationIntervalSec % 60
                onValueModified: page.updateInterval()
            }
            QQC2.Label { text: "segundos" }
        }

        QQC2.Label {
            text: "Mínimo 10 segundos"
            opacity: 0.7
        }

        QQC2.Button {
            text: "Siguiente wallpaper ahora"
            icon.name: "go-next"
            enabled: rotationEnabled.checked
            onClicked: {
                var x = new XMLHttpRequest()
                x.open("GET", "http://127.0.0.1:8765/next")
                x.send()
            }
        }
    }
}
