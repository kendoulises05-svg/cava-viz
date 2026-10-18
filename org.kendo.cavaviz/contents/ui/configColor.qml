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
    property string cfg_customPalette
    property alias cfg_twoColorsCustom: twoCustom.checked
    property string cfg_twoColorLow
    property string cfg_twoColorHigh

    // Paleta propia como lista (se guarda como "#aaaaaa,#bbbbbb,...")
    readonly property var customColors: cfg_customPalette.split(",").filter(function (h) { return h.trim() !== "" })
    function setCustom(list) { cfg_customPalette = list.join(",") }

    readonly property int chosenMode: Math.max(0, cfg_colorStyle)

    Kirigami.FormLayout {

        QQC2.ComboBox {
            Kirigami.FormData.label: "Modo:"
            model: ["Dos colores", "Por zona del fondo", "Degradado del fondo", "Por intensidad", "Color fijo", "Paleta"]
            currentIndex: chosenMode
            onActivated: index => cfg_colorStyle = index
        }

        QQC2.Label {
            Layout.maximumWidth: Kirigami.Units.gridUnit * 22
            wrapMode: Text.WordWrap
            opacity: 0.7
            text: [
                "Un color en los graves que se mezcla hacia otro en los agudos.",
                "Cada barra toma el color del fondo que tiene encima, siempre vivo y claro para que se vea.",
                "Los colores principales del fondo, repartidos de graves a agudos.",
                "Las barras bajas usan un color del fondo y las altas otro: el color sube con el volumen.",
                "Un solo color para todo.",
                "Una paleta lista o la tuya, de graves a agudos."
            ][chosenMode]
        }

        // ---------- Opciones de cada modo ----------

        QQC2.CheckBox {
            id: twoCustom
            visible: chosenMode === 0
            text: "Elegir los dos colores yo"
        }

        QQC2.Label {
            visible: chosenMode === 0 && !twoCustom.checked
            text: "Se usan el color de acento de Plasma y el color del fondo más distinto a él."
            opacity: 0.7
        }

        KQControls.ColorButton {
            Kirigami.FormData.label: "Graves:"
            visible: chosenMode === 0 && twoCustom.checked
            showAlphaChannel: false
            dialogTitle: "Color de los graves"
            color: cfg_twoColorLow
            onAccepted: c => cfg_twoColorLow = c.toString()
        }

        KQControls.ColorButton {
            Kirigami.FormData.label: "Agudos:"
            visible: chosenMode === 0 && twoCustom.checked
            showAlphaChannel: false
            dialogTitle: "Color de los agudos"
            color: cfg_twoColorHigh
            onAccepted: c => cfg_twoColorHigh = c.toString()
        }

        RowLayout {
            Kirigami.FormData.label: "Mezcla hacia agudos:"
            visible: chosenMode === 0
            QQC2.Slider { id: colorBlend; from: 0.0; to: 1.0; stepSize: 0.05 }
            QQC2.Label { text: Math.round(colorBlend.value * 100) + "%" }
        }

        QQC2.CheckBox {
            id: zoneSwap
            visible: chosenMode === 1
            text: "Invertir colores (intercambiar entre zonas)"
        }

        KQControls.ColorButton {
            Kirigami.FormData.label: "Color:"
            visible: chosenMode === 4
            showAlphaChannel: false
            dialogTitle: "Color de las barras"
            color: cfg_fixedColor
            onAccepted: c => cfg_fixedColor = c.toString()
        }

        GridLayout {
            Kirigami.FormData.label: "Paleta:"
            visible: chosenMode === 5
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

            // Paleta propia (índice -1)
            Rectangle {
                id: own
                readonly property bool chosen: cfg_paletteIndex < 0
                implicitWidth: Kirigami.Units.gridUnit * 9
                implicitHeight: Kirigami.Units.gridUnit * 2.4
                radius: Kirigami.Units.cornerRadius
                color: "transparent"
                border.width: chosen ? 2 : 1
                border.color: chosen ? Kirigami.Theme.highlightColor
                                     : Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.2)
                Row {
                    id: ownChips
                    anchors { left: parent.left; right: parent.right; top: parent.top; margins: 5 }
                    height: parent.height * 0.38
                    Repeater {
                        model: customColors
                        Rectangle {
                            required property string modelData
                            width: ownChips.width / Math.max(1, customColors.length)
                            height: ownChips.height
                            color: modelData
                        }
                    }
                }
                QQC2.Label {
                    anchors { left: parent.left; bottom: parent.bottom; leftMargin: 6; bottomMargin: 2 }
                    text: "Propia"
                    font.bold: own.chosen
                }
                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: cfg_paletteIndex = -1
                }
            }
        }

        // Editor de la paleta propia: de 2 a 6 colores, de graves a agudos
        RowLayout {
            Kirigami.FormData.label: "Tus colores:"
            visible: chosenMode === 5 && cfg_paletteIndex < 0
            spacing: Kirigami.Units.smallSpacing

            Repeater {
                model: customColors
                KQControls.ColorButton {
                    required property string modelData
                    required property int index
                    showAlphaChannel: false
                    dialogTitle: "Color " + (index + 1) + " de la paleta"
                    color: modelData
                    onAccepted: c => {
                        var l = customColors.slice()
                        l[index] = c.toString()
                        setCustom(l)
                    }
                }
            }
            QQC2.ToolButton {
                icon.name: "list-add"
                enabled: customColors.length < 6
                onClicked: setCustom(customColors.concat([customColors[customColors.length - 1] || "#ffffff"]))
                QQC2.ToolTip.text: "Agregar color"
                QQC2.ToolTip.visible: hovered
            }
            QQC2.ToolButton {
                icon.name: "list-remove"
                enabled: customColors.length > 2
                onClicked: setCustom(customColors.slice(0, -1))
                QQC2.ToolTip.text: "Quitar el último"
                QQC2.ToolTip.visible: hovered
            }
        }

        QQC2.Label {
            visible: chosenMode === 5 && cfg_paletteIndex < 0
            text: "El primero va en los graves y el último en los agudos."
            opacity: 0.7
        }

        QQC2.Label {
            visible: chosenMode <= 3 && !(chosenMode === 0 && twoCustom.checked)
            Layout.maximumWidth: Kirigami.Units.gridUnit * 22
            wrapMode: Text.WordWrap
            text: "Los colores del fondo necesitan que Cava Viz controle el wallpaper (o el fondo de video). Con la presentación de Plasma se usa el color de acento."
            opacity: 0.7
        }
    }
}
