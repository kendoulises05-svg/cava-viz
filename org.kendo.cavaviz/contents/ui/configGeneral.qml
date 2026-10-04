import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import QtQuick.Dialogs as QtDialogs
import org.kde.kirigami as Kirigami
import org.kde.kcmutils as KCM

KCM.SimpleKCM {
    // Cada cfg_<nombre> se enlaza con la entrada del mismo nombre en main.xml
    property alias cfg_barWidth: barWidth.value
    property alias cfg_barGap: barGap.value
    property alias cfg_orientation: orientation.currentIndex
    property alias cfg_mirrorLine: mirrorLine.value
    property alias cfg_mirrorOpacity: mirrorOpacity.value
    property alias cfg_colorMode: colorMode.currentIndex
    property alias cfg_colorBlend: colorBlend.value
    property alias cfg_bassCenter: bassCenter.checked
    property alias cfg_contrastComplementary: contrastComplementary.checked
    property alias cfg_showPeaks: showPeaks.checked
    property alias cfg_peakFall: peakFall.value
    property alias cfg_hideOnSilence: hideOnSilence.checked
    property alias cfg_rotationEnabled: rotationEnabled.checked
    property alias cfg_rotationDir: rotationDir.text
    property alias cfg_rotationInterval: rotationInterval.value
    property alias cfg_rotationOrder: rotationOrder.currentIndex

    Kirigami.FormLayout {

        // ---------- Forma ----------
        Item { Kirigami.FormData.isSection: true; Kirigami.FormData.label: "Forma" }

        RowLayout {
            Kirigami.FormData.label: "Grosor de barra:"
            QQC2.SpinBox { id: barWidth; from: 1; to: 20 }
            QQC2.Label { text: "px" }
        }

        RowLayout {
            Kirigami.FormData.label: "Hueco entre barras:"
            QQC2.SpinBox { id: barGap; from: 0; to: 10 }
            QQC2.Label { text: "px" }
        }

        QQC2.Label {
            text: "La cantidad de barras se ajusta sola al ancho del widget"
            opacity: 0.7
        }

        QQC2.ComboBox {
            id: orientation
            Kirigami.FormData.label: "Orientación:"
            model: ["Desde abajo", "Espejo (con reflejo)", "Flotante (centrada)"]
        }

        RowLayout {
            Kirigami.FormData.label: "Línea del espejo:"
            enabled: orientation.currentIndex === 1
            QQC2.Slider { id: mirrorLine; from: 0.5; to: 0.95; stepSize: 0.05 }
            QQC2.Label { text: Math.round(mirrorLine.value * 100) + "% desde arriba" }
        }

        RowLayout {
            Kirigami.FormData.label: "Opacidad del reflejo:"
            enabled: orientation.currentIndex === 1
            QQC2.Slider { id: mirrorOpacity; from: 0.1; to: 1.0; stepSize: 0.05 }
            QQC2.Label { text: Math.round(mirrorOpacity.value * 100) + "%" }
        }

        // ---------- Color ----------
        Item { Kirigami.FormData.isSection: true; Kirigami.FormData.label: "Color" }

        QQC2.ComboBox {
            id: colorMode
            Kirigami.FormData.label: "Modo:"
            model: ["Accent + 2do color del wallpaper", "Por zona del wallpaper", "Contraste (invertido)"]
        }

        RowLayout {
            Kirigami.FormData.label: "Mezcla hacia agudos:"
            enabled: colorMode.currentIndex === 0
            QQC2.Slider { id: colorBlend; from: 0.0; to: 1.0; stepSize: 0.05 }
            QQC2.Label { text: Math.round(colorBlend.value * 100) + "%" }
        }

        QQC2.CheckBox {
            id: bassCenter
            Kirigami.FormData.label: "Distribución:"
            text: "Graves al centro"
            enabled: colorMode.currentIndex === 0
        }

        QQC2.CheckBox {
            id: contrastComplementary
            Kirigami.FormData.label: "Contraste:"
            text: "Tono complementario (si no, mismo tono)"
            enabled: colorMode.currentIndex === 2
        }

        QQC2.Label {
            text: "Los modos por zona y contraste necesitan que Cava Viz controle el wallpaper.\nCon la presentación de Plasma se usa el accent."
            opacity: 0.7
        }

        // ---------- Wallpaper ----------
        Item { Kirigami.FormData.isSection: true; Kirigami.FormData.label: "Wallpaper" }

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

        RowLayout {
            Kirigami.FormData.label: "Cambiar cada:"
            enabled: rotationEnabled.checked
            QQC2.SpinBox { id: rotationInterval; from: 1; to: 10080 }
            QQC2.Label { text: "minutos" }
        }

        QQC2.ComboBox {
            id: rotationOrder
            Kirigami.FormData.label: "Orden:"
            enabled: rotationEnabled.checked
            model: ["Aleatorio", "Alfabético", "Más recientes primero"]
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

        // ---------- Comportamiento ----------
        Item { Kirigami.FormData.isSection: true; Kirigami.FormData.label: "Comportamiento" }

        QQC2.CheckBox { id: showPeaks; text: "Mostrar peaks" }

        RowLayout {
            Kirigami.FormData.label: "Caída de peaks:"
            enabled: showPeaks.checked
            QQC2.Slider { id: peakFall; from: 0.2; to: 3.0; stepSize: 0.1 }
            QQC2.Label { text: peakFall.value.toFixed(1) }
        }

        QQC2.CheckBox { id: hideOnSilence; text: "Ocultar en silencio" }
    }
}
