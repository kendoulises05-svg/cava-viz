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
    property alias cfg_audioChannels: audioChannels.currentIndex
    property alias cfg_bassLayout: bassLayout.currentIndex
    property alias cfg_glowEnabled: glowEnabled.checked
    property alias cfg_glowStrength: glowStrength.value
    property alias cfg_glowColorMode: glowColorMode.currentIndex
    // fps se guarda como número (30/45/60), no como posición en la lista
    property int cfg_fps

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

        Item { Kirigami.FormData.isSection: true; Kirigami.FormData.label: "Audio" }

        QQC2.ComboBox {
            id: audioChannels
            Kirigami.FormData.label: "Canales:"
            model: ["Stereo", "Mono"]
        }

        QQC2.ComboBox {
            id: bassLayout
            Kirigami.FormData.label: "Distribución:"
            // Modelo fijo: si cambiara con los canales, ComboBox podría reiniciar la selección
            model: ["Normal", "Invertida"]
        }

        QQC2.Label {
            // Explica dónde quedan los graves con la combinación elegida
            text: "Graves: " + (audioChannels.currentIndex === 0
                  ? (bassLayout.currentIndex === 0 ? "al centro" : "a los extremos")
                  : (bassLayout.currentIndex === 0 ? "a la izquierda" : "a la derecha"))
            opacity: 0.7
        }

        QQC2.Label {
            text: "Cambiar los canales reinicia cava (corte de menos de un segundo)"
            opacity: 0.7
        }

        Item { Kirigami.FormData.isSection: true; Kirigami.FormData.label: "Glow" }

        QQC2.CheckBox { id: glowEnabled; text: "Glow que pulsa con los graves" }

        RowLayout {
            Kirigami.FormData.label: "Intensidad:"
            enabled: glowEnabled.checked
            QQC2.Slider { id: glowStrength; from: 0.1; to: 1.0; stepSize: 0.05 }
            QQC2.Label { text: Math.round(glowStrength.value * 100) + "%" }
        }

        QQC2.ComboBox {
            id: glowColorMode
            Kirigami.FormData.label: "Color del glow:"
            enabled: glowEnabled.checked
            model: ["Igual a la barra", "Contraste con la barra (automático)"]
        }

        QQC2.Label {
            visible: glowColorMode.currentIndex === 1
            text: "Cada barra usa el color de otra barra que más se diferencia del suyo\n(rojas con glow blanco, blancas con glow rojo)."
            opacity: 0.7
        }

        Item { Kirigami.FormData.isSection: true; Kirigami.FormData.label: "Rendimiento" }

        QQC2.ComboBox {
            id: fpsBox
            Kirigami.FormData.label: "Cuadros por segundo:"
            model: [30, 45, 60]
            currentIndex: Math.max(0, model.indexOf(cfg_fps))
            onActivated: cfg_fps = model[currentIndex]
        }

        QQC2.Label {
            text: "30 fps usa cerca de la mitad de CPU que 60 y a simple vista se nota poco.\nEl glow es la opción que más CPU consume."
            opacity: 0.7
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
