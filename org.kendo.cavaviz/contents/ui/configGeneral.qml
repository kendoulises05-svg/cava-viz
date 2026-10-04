import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.kcmutils as KCM
import org.kde.kquickcontrols as KQControls

KCM.SimpleKCM {
    // Cada cfg_<nombre> se enlaza con la entrada del mismo nombre en main.xml.
    // Plasma lee y guarda estos valores al abrir y al pulsar Apply/OK.
    property alias cfg_barFill: barFill.value
    property alias cfg_orientation: orientation.currentIndex
    property alias cfg_mirrorOpacity: mirrorOpacity.value
    property alias cfg_secondaryColor: secondaryColor.color
    property alias cfg_colorBlend: colorBlend.value
    property alias cfg_bassCenter: bassCenter.checked
    property alias cfg_showPeaks: showPeaks.checked
    property alias cfg_peakFall: peakFall.value
    property alias cfg_hideOnSilence: hideOnSilence.checked

    Kirigami.FormLayout {

        // ---------- Forma ----------
        Item { Kirigami.FormData.isSection: true; Kirigami.FormData.label: "Forma" }

        RowLayout {
            Kirigami.FormData.label: "Grosor de barras:"
            QQC2.Slider { id: barFill; from: 0.1; to: 1.0; stepSize: 0.05 }
            QQC2.Label { text: Math.round(barFill.value * 100) + "%" }
        }

        QQC2.ComboBox {
            id: orientation
            Kirigami.FormData.label: "Orientación:"
            model: ["Desde abajo", "Espejo (con reflejo)", "Flotante (centrada)"]
        }

        RowLayout {
            Kirigami.FormData.label: "Opacidad del reflejo:"
            enabled: orientation.currentIndex === 1   // solo aplica en modo espejo
            QQC2.Slider { id: mirrorOpacity; from: 0.1; to: 1.0; stepSize: 0.05 }
            QQC2.Label { text: Math.round(mirrorOpacity.value * 100) + "%" }
        }

        // ---------- Color ----------
        Item { Kirigami.FormData.isSection: true; Kirigami.FormData.label: "Color" }

        QQC2.Label {
            Kirigami.FormData.label: "Graves:"
            text: "Accent del tema (sigue al wallpaper)"
        }

        KQControls.ColorButton {
            id: secondaryColor
            Kirigami.FormData.label: "Agudos:"
            showAlphaChannel: false
        }

        RowLayout {
            Kirigami.FormData.label: "Mezcla hacia agudos:"
            QQC2.Slider { id: colorBlend; from: 0.0; to: 1.0; stepSize: 0.05 }
            QQC2.Label { text: Math.round(colorBlend.value * 100) + "%" }
        }

        QQC2.CheckBox { id: bassCenter; Kirigami.FormData.label: "Distribución:"; text: "Graves al centro" }

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
