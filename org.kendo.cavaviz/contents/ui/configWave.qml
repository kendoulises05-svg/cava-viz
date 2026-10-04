import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.kcmutils as KCM

KCM.SimpleKCM {
    property alias cfg_barWidth: barWidth.value
    property alias cfg_barGap: barGap.value
    property alias cfg_orientation: orientation.currentIndex
    property alias cfg_mirrorLine: mirrorLine.value
    property alias cfg_mirrorOpacity: mirrorOpacity.value
    property alias cfg_showPeaks: showPeaks.checked
    property alias cfg_peakFall: peakFall.value
    property alias cfg_hideOnSilence: hideOnSilence.checked

    Kirigami.FormLayout {

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
