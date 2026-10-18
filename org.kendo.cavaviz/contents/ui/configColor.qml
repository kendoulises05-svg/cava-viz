import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.kcmutils as KCM
import org.kde.kquickcontrols as KQControls
import "palettes.js" as Palettes

KCM.SimpleKCM {
    // -1 = el widget todavía no pasó la config vieja al modo nuevo (lo hace al arrancar)
    property int cfg_colorStyle
    property alias cfg_colorBlend: colorBlend.value
    property alias cfg_zoneSwap: zoneSwap.checked
    property string cfg_fixedColor
    property int cfg_paletteIndex

    readonly property int style: Math.max(0, cfg_colorStyle)

    Kirigami.FormLayout {

        QQC2.ComboBox {
            Kirigami.FormData.label: "Modo:"
            model: ["Dos colores", "Por zona del fondo", "Degradado del fondo", "Por intensidad", "Color fijo", "Paleta"]
            currentIndex: style
            onActivated: index => cfg_colorStyle = index
        }

        QQC2.Label {
            Layout.maximumWidth: Kirigami.Units.gridUnit * 22
            wrapMode: Text.WordWrap
            opacity: 0.7
            text: [
                "El color de acento en los graves se mezcla hacia el color más distinto del fondo en los agudos.",
                "Cada barra toma el color del fondo que tiene encima, siempre vivo y claro para que se vea.",
                "Los colores principales del fondo, repartidos de graves a agudos.",
                "Las barras bajas usan un color del fondo y las altas otro: el color sube con el volumen.",
                "Un solo color para todo.",
                "Una paleta lista, de graves a agudos."
            ][style]
        }

        // ---------- Opciones de cada modo ----------

        RowLayout {
            Kirigami.FormData.label: "Mezcla hacia agudos:"
            visible: style === 0
            QQC2.Slider { id: colorBlend; from: 0.0; to: 1.0; stepSize: 0.05 }
            QQC2.Label { text: Math.round(colorBlend.value * 100) + "%" }
        }

        QQC2.CheckBox {
            id: zoneSwap
            visible: style === 1
            text: "Invertir colores (intercambiar entre zonas)"
        }

        KQControls.ColorButton {
            Kirigami.FormData.label: "Color:"
            visible: style === 4
            showAlphaChannel: false
            dialogTitle: "Color de las barras"
            color: cfg_fixedColor
            onAccepted: c => cfg_fixedColor = c.toString()
        }

        GridLayout {
            Kirigami.FormData.label: "Paleta:"
            visible: style === 5
            columns: 2
            columnSpacing: Kirigami.Units.smallSpacing
            rowSpacing: Kirigami.Units.smallSpacing

            Repeater {
                model: Palettes.list

                // Muestra de la paleta: clic para elegirla
                Rectangle {
                    id: swatch
                    required property var modelData
                    required property int index
                    readonly property bool chosen: cfg_paletteIndex === index
                    implicitWidth: Kirigami.Units.gridUnit * 9
                    implicitHeight: Kirigami.Units.gridUnit * 2.4
                    radius: Kirigami.Units.cornerRadius
                    color: "transparent"
                    border.width: chosen ? 2 : 1
                    border.color: chosen ? Kirigami.Theme.highlightColor
                                         : Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.2)

                    Row {
                        id: chips
                        anchors { left: parent.left; right: parent.right; top: parent.top; margins: 5 }
                        height: parent.height * 0.38
                        Repeater {
                            model: swatch.modelData.colors
                            Rectangle {
                                required property string modelData
                                width: chips.width / swatch.modelData.colors.length
                                height: chips.height
                                color: modelData
                            }
                        }
                    }
                    QQC2.Label {
                        anchors { left: parent.left; bottom: parent.bottom; leftMargin: 6; bottomMargin: 2 }
                        text: swatch.modelData.name
                        font.bold: swatch.chosen
                    }
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: cfg_paletteIndex = swatch.index
                    }
                }
            }
        }

        QQC2.Label {
            visible: style <= 3
            Layout.maximumWidth: Kirigami.Units.gridUnit * 22
            wrapMode: Text.WordWrap
            text: "Los colores del fondo necesitan que Cava Viz controle el wallpaper (o el fondo de video). Con la presentación de Plasma se usa el color de acento."
            opacity: 0.7
        }
    }
}
