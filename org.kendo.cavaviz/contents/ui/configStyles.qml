import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.kcmutils as KCM
import "palettes.js" as Palettes

// Estilos: guardar la forma y los colores actuales con un nombre y volver a ellos con un clic.
// Plasma guarda solo la página abierta, por eso esta página tiene su propia copia (cfg_) de
// todas las claves de forma y color: al elegir un estilo se cambian aquí y se guardan con Aplicar.
KCM.SimpleKCM {
    id: page

    // Lo que entra en un estilo (no entran fps, pausas, audio ni rotación del wallpaper)
    readonly property var styleKeys: ["shape", "smoothing", "barWidth", "barGap", "orientation", "mirrorLine",
        "mirrorOpacity", "showPeaks", "peakFall", "glowEnabled", "glowStrength", "glowColorMode", "colorStyle",
        "colorBlend", "zoneSwap", "fixedColor", "paletteIndex", "customPalette", "twoColorsCustom",
        "twoColorLow", "twoColorHigh"]

    property int cfg_shape
    property real cfg_smoothing
    property int cfg_barWidth
    property int cfg_barGap
    property int cfg_orientation
    property real cfg_mirrorLine
    property real cfg_mirrorOpacity
    property bool cfg_showPeaks
    property real cfg_peakFall
    property bool cfg_glowEnabled
    property real cfg_glowStrength
    property int cfg_glowColorMode
    property int cfg_colorStyle
    property real cfg_colorBlend
    property bool cfg_zoneSwap
    property string cfg_fixedColor
    property int cfg_paletteIndex
    property string cfg_customPalette
    property bool cfg_twoColorsCustom
    property string cfg_twoColorLow
    property string cfg_twoColorHigh
    property string cfg_savedStyles

    // Estilos que vienen con el widget: solo cambian lo que nombran
    readonly property var builtIn: [
        { name: "Clásico", cfg: { shape: 0, orientation: 0, colorStyle: 0, twoColorsCustom: false, glowEnabled: false, smoothing: 0 } },
        { name: "Espejo con glow", cfg: { shape: 0, orientation: 1, colorStyle: 1, glowEnabled: true, glowStrength: 0.7, smoothing: 0 } },
        { name: "Onda neón", cfg: { shape: 2, orientation: 0, colorStyle: 5, paletteIndex: 0, glowEnabled: true, glowStrength: 0.8, smoothing: 0.4 } },
        { name: "Círculo", cfg: { shape: 3, colorStyle: 2, glowEnabled: true, glowStrength: 0.6, smoothing: 0.3 } },
        { name: "Fuego", cfg: { shape: 1, orientation: 0, colorStyle: 5, paletteIndex: 3, glowEnabled: true, glowStrength: 0.6, smoothing: 0 } }
    ]

    readonly property var saved: {
        try {
            var l = JSON.parse(cfg_savedStyles || "[]")
            return Array.isArray(l) ? l : []
        } catch (e) {
            return []
        }
    }
    property string lastApplied: ""
    property string notice: ""

    function current() {
        var c = {}
        for (var i = 0; i < styleKeys.length; i++) c[styleKeys[i]] = page["cfg_" + styleKeys[i]]
        return c
    }
    function apply(st) {
        for (var k in st.cfg)
            if (styleKeys.indexOf(k) >= 0) page["cfg_" + k] = st.cfg[k]
        lastApplied = st.name
        notice = "Pulsa Aplicar o Aceptar para ver «" + st.name + "» en el escritorio."
    }
    function store(list) { cfg_savedStyles = JSON.stringify(list) }
    function saveCurrent(name) {
        name = name.trim()
        if (name === "") return
        var l = saved.filter(function (s) { return s.name !== name })   // mismo nombre: se reemplaza
        l.push({ name: name, cfg: current() })
        store(l)
        lastApplied = name
        notice = "«" + name + "» guardado. Pulsa Aplicar o Aceptar para que quede guardado."
    }

    // "Onda · Paleta Neón", para reconocer cada estilo sin abrirlo
    function summary(cfg) {
        var shapes = ["Barras redondeadas", "Barras rectas", "Onda", "Circular"]
        var modes = ["Dos colores", "Por zona", "Degradado del fondo", "Por intensidad", "Color fijo", "Paleta"]
        var parts = []
        if (cfg.shape !== undefined) parts.push(shapes[cfg.shape] || "")
        if (cfg.colorStyle !== undefined) {
            var m = modes[Math.max(0, cfg.colorStyle)] || ""
            if (cfg.colorStyle === 5 && cfg.paletteIndex !== undefined)
                m += " " + (cfg.paletteIndex < 0 ? "propia" : (Palettes.list[cfg.paletteIndex] || {}).name || "")
            parts.push(m)
        }
        if (cfg.glowEnabled) parts.push("glow")
        if (cfg.smoothing > 0) parts.push("suave")
        return parts.join(" · ")
    }

    component StyleRow: Rectangle {
        id: rowItem
        property var style
        property bool removable: false
        Layout.fillWidth: true
        Layout.maximumWidth: Kirigami.Units.gridUnit * 26
        implicitHeight: rowLayout.implicitHeight + Kirigami.Units.smallSpacing * 2
        radius: Kirigami.Units.cornerRadius
        color: "transparent"
        border.width: page.lastApplied === style.name ? 2 : 1
        border.color: page.lastApplied === style.name ? Kirigami.Theme.highlightColor
                      : Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.2)

        RowLayout {
            id: rowLayout
            anchors.fill: parent
            anchors.margins: Kirigami.Units.smallSpacing
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 0
                QQC2.Label { text: rowItem.style.name; font.bold: true; Layout.fillWidth: true; elide: Text.ElideRight }
                QQC2.Label { text: page.summary(rowItem.style.cfg); opacity: 0.7; Layout.fillWidth: true; elide: Text.ElideRight }
            }
            QQC2.Button {
                text: "Usar"
                onClicked: page.apply(rowItem.style)
            }
            QQC2.ToolButton {
                visible: rowItem.removable
                icon.name: "document-save"
                onClicked: page.saveCurrent(rowItem.style.name)
                QQC2.ToolTip.text: "Reemplazar con lo actual"
                QQC2.ToolTip.visible: hovered
            }
            QQC2.ToolButton {
                visible: rowItem.removable
                icon.name: "edit-delete"
                onClicked: {
                    page.store(page.saved.filter(function (s) { return s.name !== rowItem.style.name }))
                    page.notice = "«" + rowItem.style.name + "» borrado. Pulsa Aplicar o Aceptar para confirmarlo."
                }
                QQC2.ToolTip.text: "Borrar"
                QQC2.ToolTip.visible: hovered
            }
        }
    }

    ColumnLayout {
        spacing: Kirigami.Units.smallSpacing

        Kirigami.Heading { level: 4; text: "Guardar el estilo actual" }
        RowLayout {
            QQC2.TextField {
                id: nameField
                Layout.preferredWidth: Kirigami.Units.gridUnit * 14
                placeholderText: "Nombre (ej. Noche)"
                onAccepted: if (text.trim() !== "") { page.saveCurrent(text); text = "" }
            }
            QQC2.Button {
                text: "Guardar"
                icon.name: "document-save"
                enabled: nameField.text.trim() !== ""
                onClicked: { page.saveCurrent(nameField.text); nameField.text = "" }
            }
        }
        QQC2.Label {
            text: "Guarda la forma, los colores, el glow y el movimiento de las páginas Wave y Color."
            opacity: 0.7
        }

        Kirigami.Heading { level: 4; text: "Tus estilos"; Layout.topMargin: Kirigami.Units.largeSpacing }
        QQC2.Label {
            visible: page.saved.length === 0
            text: "Todavía no guardaste ninguno."
            opacity: 0.7
        }
        Repeater {
            model: page.saved
            StyleRow { required property var modelData; style: modelData; removable: true }
        }

        Kirigami.Heading { level: 4; text: "Estilos listos"; Layout.topMargin: Kirigami.Units.largeSpacing }
        Repeater {
            model: page.builtIn
            StyleRow { required property var modelData; style: modelData }
        }

        QQC2.Label {
            visible: page.notice !== ""
            Layout.topMargin: Kirigami.Units.largeSpacing
            text: page.notice
            color: Kirigami.Theme.positiveTextColor
        }
    }
}
