import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.kcmutils as KCM

KCM.SimpleKCM {
    property alias cfg_colorMode: colorMode.currentIndex
    property alias cfg_colorBlend: colorBlend.value
    property alias cfg_zoneSwap: zoneSwap.checked

    Kirigami.FormLayout {

        QQC2.ComboBox {
            id: colorMode
            Kirigami.FormData.label: "Modo:"
            model: ["Accent + 2do color del wallpaper", "Por zona del wallpaper", "Contraste (brillo invertido)", "Automático (experimental)"]
        }

        Item { Kirigami.FormData.isSection: true; Kirigami.FormData.label: "Accent + 2do color" }

        RowLayout {
            Kirigami.FormData.label: "Mezcla hacia agudos:"
            enabled: colorMode.currentIndex === 0
            QQC2.Slider { id: colorBlend; from: 0.0; to: 1.0; stepSize: 0.05 }
            QQC2.Label { text: Math.round(colorBlend.value * 100) + "%" }
        }

        QQC2.Label {
            text: "El color fuerte sigue a los graves según la distribución elegida en Wave."
            opacity: 0.7
        }

        Item { Kirigami.FormData.isSection: true; Kirigami.FormData.label: "Por zona y automático" }

        QQC2.CheckBox {
            id: zoneSwap
            text: "Invertir colores (intercambiar entre zonas)"
            // En contraste se desactiva: invertir deshace el contraste y las barras dejan de verse
            enabled: colorMode.currentIndex === 1 || colorMode.currentIndex === 3
        }

        QQC2.Label {
            visible: colorMode.currentIndex === 3
            text: "Automático: usa el color de cada zona y lo oscurece o aclara\nsolo lo necesario para que se distinga del fondo."
            opacity: 0.7
        }

        QQC2.Label {
            text: "Los modos 2, 3 y 4 necesitan que Cava Viz controle el wallpaper.\nCon la presentación de Plasma se usa el accent."
            opacity: 0.7
        }
    }
}
