import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.kcmutils as KCM

KCM.SimpleKCM {
    property alias cfg_colorMode: colorMode.currentIndex
    property alias cfg_colorBlend: colorBlend.value
    property alias cfg_bassCenter: bassCenter.checked
    property alias cfg_zoneSwap: zoneSwap.checked

    Kirigami.FormLayout {

        QQC2.ComboBox {
            id: colorMode
            Kirigami.FormData.label: "Modo:"
            model: ["Accent + 2do color del wallpaper", "Por zona del wallpaper", "Contraste (brillo invertido)"]
        }

        Item { Kirigami.FormData.isSection: true; Kirigami.FormData.label: "Accent + 2do color" }

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

        Item { Kirigami.FormData.isSection: true; Kirigami.FormData.label: "Por zona y contraste" }

        QQC2.CheckBox {
            id: zoneSwap
            text: "Invertir colores (intercambiar entre zonas)"
            enabled: colorMode.currentIndex !== 0
        }

        QQC2.Label {
            text: "Estos modos necesitan que Cava Viz controle el wallpaper.\nCon la presentación de Plasma se usa el accent."
            opacity: 0.7
        }
    }
}
