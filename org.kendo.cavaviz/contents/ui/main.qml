import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.kirigami as Kirigami
import org.kde.taskmanager as TaskManager

PlasmoidItem {
    id: root

    // ---------- Valores fijos ----------
    readonly property int pollMs: 16            // ~60 fps
    readonly property int colorsMs: 2000        // cada cuánto se revisan los colores (el puente usa caché)
    readonly property int silenceFrames: 120    // ~2 s
    readonly property string bridgeUrl: "http://127.0.0.1:8765/"

    // ---------- Valores del panel de configuración (main.xml) ----------
    readonly property int barWidth: Plasmoid.configuration.barWidth
    readonly property int barGap: Plasmoid.configuration.barGap
    readonly property int orientation: Plasmoid.configuration.orientation   // 0 abajo, 1 espejo, 2 flotante
    readonly property real mirrorLine: Plasmoid.configuration.mirrorLine
    readonly property real mirrorOpacity: Plasmoid.configuration.mirrorOpacity
    readonly property int colorMode: Plasmoid.configuration.colorMode       // 0 accent+2do, 1 zona
    readonly property real colorBlend: Plasmoid.configuration.colorBlend
    readonly property int audioChannels: Plasmoid.configuration.audioChannels   // 0 stereo, 1 mono
    readonly property int bassLayout: Plasmoid.configuration.bassLayout         // 0 normal, 1 invertida
    readonly property bool glowEnabled: Plasmoid.configuration.glowEnabled
    readonly property real glowStrength: Plasmoid.configuration.glowStrength
    readonly property bool showPeaks: Plasmoid.configuration.showPeaks
    readonly property real peakFall: Plasmoid.configuration.peakFall
    readonly property bool hideOnSilence: Plasmoid.configuration.hideOnSilence
    readonly property bool zoneSwap: Plasmoid.configuration.zoneSwap
    readonly property bool rotationEnabled: Plasmoid.configuration.rotationEnabled
    readonly property string rotationDir: Plasmoid.configuration.rotationDir
    readonly property int rotationIntervalSec: Plasmoid.configuration.rotationIntervalSec
    readonly property int rotationOrder: Plasmoid.configuration.rotationOrder

    // ---------- Color ----------
    readonly property color baseColor: Kirigami.Theme.highlightColor
    // Respaldo mientras llega el color del wallpaper (o si el puente no puede leerlo)
    property color wallSecond: Qt.lighter(Kirigami.Theme.highlightColor, 1.6)
    property var zoneColors: []                 // [[r,g,b], ...] uno por barra

    // ---------- Geometría (la actualiza fullRepresentation) ----------
    property real areaWidth: 1200
    property real areaLeft: 0                   // borde izquierdo del widget en la pantalla (0-1)
    property real areaRight: 1                  // borde derecho del widget en la pantalla (0-1)
    property real areaTop: 0.75                 // borde superior del widget en la pantalla (0-1)
    property real areaBottom: 1                 // borde inferior del widget en la pantalla (0-1)
    property real screenAspect: 16 / 9

    // Cuántas barras caben con el grosor y hueco elegidos. Par, porque cava stereo reparte mitad y mitad.
    readonly property int barCount: {
        var n = Math.floor((areaWidth + barGap) / (barWidth + barGap))
        n = Math.max(16, Math.min(300, n))
        return n - (n % 2)
    }

    property var levels: []
    property var peaks: []
    property int silentCount: 0
    property bool busy: false
    property bool bridgePaused: false           // el puente congeló cava (pantalla bloqueada o completa)
    property real bassEnergy: 0                 // 0-1, energía de los graves para el glow
    property bool fullscreenActive: false

    Plasmoid.backgroundHints: PlasmaCore.Types.NoBackground
    preferredRepresentation: fullRepresentation

    // Clic derecho sobre el widget > Siguiente wallpaper
    Plasmoid.contextualActions: [
        PlasmaCore.Action {
            text: "Siguiente wallpaper"
            icon.name: "go-next"
            visible: root.rotationEnabled
            onTriggered: root.get("next", null)
        }
    ]

    // Atajo de teclado: Configure > Keyboard Shortcuts del widget
    Connections {
        target: Plasmoid
        function onActivated() {
            if (root.rotationEnabled) root.get("next", null)
        }
    }

    // ---------- Comunicación con el puente ----------
    function get(path, callback) {
        var x = new XMLHttpRequest()
        x.open("GET", bridgeUrl + path)
        x.onreadystatechange = function () {
            if (x.readyState !== 4) return
            if (callback) callback(x.status === 200 ? x.responseText : null)
        }
        x.send()
    }

    // Al cambiar el ancho o el grosor, espera a que termine el ajuste antes de reiniciar cava
    onBarCountChanged: barsDebounce.restart()
    onAudioChannelsChanged: barsDebounce.restart()
    Timer {
        id: barsDebounce
        interval: 600
        onTriggered: root.get("bars?n=" + root.barCount + "&ch=" + (root.audioChannels === 1 ? "mono" : "stereo"),
                              function () { root.fetchColors() })
    }

    onColorModeChanged: fetchColors()
    onZoneSwapChanged: fetchColors()

    // Envía la config de rotación al puente (él solo la guarda si cambió)
    function syncRotation() {
        get("rotation?enabled=" + (rotationEnabled ? 1 : 0)
            + "&dir=" + encodeURIComponent(rotationDir)
            + "&seconds=" + rotationIntervalSec
            + "&order=" + rotationOrder, null)
    }
    onRotationEnabledChanged: syncRotation()
    onRotationDirChanged: syncRotation()
    onRotationIntervalSecChanged: syncRotation()
    onRotationOrderChanged: syncRotation()

    function applyColors(t) {
        if (!t) return
        var c = JSON.parse(t).colors
        // Lista vacía = el puente no sabe qué imagen hay (ej. presentación de Plasma): se usa el accent
        zoneColors = (c.length === barCount) ? c : []
    }

    function fetchColors() {
        var cid = Plasmoid.containment ? Plasmoid.containment.id : -1
        var common = "cid=" + cid + "&aspect=" + screenAspect.toFixed(4)
        var span = "n=" + barCount + "&l=" + areaLeft.toFixed(4) + "&r=" + areaRight.toFixed(4)
        if (colorMode === 1) {
            get("zones?" + span + "&swap=" + (zoneSwap ? 1 : 0) + "&" + common, applyColors)
        } else if (colorMode === 2) {
            get("contrast?" + span + "&t=" + areaTop.toFixed(4) + "&b=" + areaBottom.toFixed(4)
                + "&" + common, applyColors)
        } else if (colorMode === 3) {
            // Experimental: color de su zona, ajustado para que se distinga del fondo detrás del widget
            get("auto?" + span + "&t=" + areaTop.toFixed(4) + "&b=" + areaBottom.toFixed(4)
                + "&swap=" + (zoneSwap ? 1 : 0) + "&" + common, applyColors)
        } else {
            get("palette?" + common, function (t) {
                if (!t) return
                var c = JSON.parse(t).colors
                if (c.length === 0) return
                // De los colores vivos del wallpaper, el más distinto al accent (que ya cubre los graves)
                var best = c[0], bestD = -1
                for (var i = 0; i < Math.min(c.length, 5); i++) {
                    var dr = c[i][0] / 255 - root.baseColor.r
                    var dg = c[i][1] / 255 - root.baseColor.g
                    var db = c[i][2] / 255 - root.baseColor.b
                    var d = dr * dr + dg * dg + db * db
                    if (d > bestD) { bestD = d; best = c[i] }
                }
                root.wallSecond = Qt.rgba(best[0] / 255, best[1] / 255, best[2] / 255, 1)
            })
        }
    }

    function barColor(i) {
        if (colorMode !== 0 && zoneColors.length === barCount) {
            var z = zoneColors[i]
            return Qt.rgba(z[0] / 255, z[1] / 255, z[2] / 255, 1)
        }
        // El gradiente sigue a los graves estén donde estén (centro, bordes o un lado)
        var t = bassT(i)
        return Qt.tint(baseColor, Qt.rgba(wallSecond.r, wallSecond.g, wallSecond.b, t * colorBlend))
    }

    // ---------- Distribución de frecuencias ----------
    // 0 = graves, 1 = agudos, según la posición de la barra en pantalla
    function bassT(i) {
        var t
        if (audioChannels === 1) {
            t = i / (barCount - 1)                    // mono: graves a la izquierda
        } else {
            var c = (barCount - 1) / 2
            t = Math.abs(i - c) / c                   // stereo: graves al centro
        }
        return bassLayout === 1 ? 1 - t : t
    }

    // Qué dato de cava va en la barra i. cava entrega stereo con graves al centro y mono con
    // graves a la izquierda; "invertida" voltea cada mitad (stereo) o todo (mono).
    function srcIndex(i) {
        if (bassLayout === 0) return i
        if (audioChannels === 1) return barCount - 1 - i
        var half = barCount / 2
        return i < half ? half - 1 - i : barCount - 1 - (i - half)
    }

    // ---------- Detección de pantalla completa ----------
    TaskManager.VirtualDesktopInfo { id: vdInfo }
    TaskManager.ActivityInfo { id: actInfo }

    TaskManager.TasksModel {
        id: tasks
        groupMode: TaskManager.TasksModel.GroupDisabled
        filterByVirtualDesktop: true
        filterByActivity: true
        filterByScreen: true
        filterHidden: true
        virtualDesktop: vdInfo.currentDesktop
        activity: actInfo.currentActivity
        screenGeometry: Plasmoid.containment ? Plasmoid.containment.screenGeometry : Qt.rect(0, 0, 0, 0)
        onDataChanged: root.checkFullscreen()
        onCountChanged: root.checkFullscreen()
    }

    function checkFullscreen() {
        var fs = false
        for (var i = 0; i < tasks.count; i++) {
            if (tasks.data(tasks.index(i, 0), TaskManager.AbstractTasksModel.IsFullScreen)) {
                fs = true
                break
            }
        }
        fullscreenActive = fs
    }

    onFullscreenActiveChanged: get(fullscreenActive ? "pause" : "resume", null)

    // ---------- Datos de audio ----------
    function applyFrame(text) {
        bridgePaused = (text === "P")   // "P": cava en pausa, se consulta 1 vez por segundo
        var parts = bridgePaused ? [] : text.split(";")
        var lv = []
        var pk = []
        var sum = 0
        var bassSum = 0, bassN = 0
        for (var i = 0; i < barCount; i++) {
            var v = parseInt(parts[srcIndex(i)]) || 0
            lv.push(v)
            sum += v
            // "|| 0": tras cambiar la cantidad de barras, peaks puede ser más corto
            pk.push(Math.max(v, (peaks[i] || 0) - peakFall))
            if (bassT(i) < 0.15) { bassSum += v; bassN++ }   // el 15% más grave
        }
        silentCount = (sum === 0) ? silentCount + 1 : 0
        levels = lv
        peaks = pk
        // Glow: sube de golpe con un golpe de bajo y cae despacio, así "pulsa"
        var bass = bassN ? bassSum / bassN / 100 : 0
        bassEnergy = bass > bassEnergy ? bass : bassEnergy * 0.9
    }

    Timer {
        interval: root.bridgePaused ? 1000 : root.pollMs
        running: !root.fullscreenActive
        repeat: true
        onTriggered: {
            if (root.busy) return
            root.busy = true
            root.get("", function (t) {
                root.busy = false
                root.applyFrame(t || "")
            })
        }
    }

    // ---------- Dibujo ----------
    fullRepresentation: Item {
        id: area
        Layout.preferredWidth: 1200
        Layout.preferredHeight: 200
        Layout.minimumWidth: 300
        Layout.minimumHeight: 80

        opacity: (root.hideOnSilence && root.silentCount > root.silenceFrames) ? 0 : 1
        Behavior on opacity { NumberAnimation { duration: 600 } }

        // Calcula qué parte de la pantalla ocupa el widget (para el modo por zona)
        function updateGeometry() {
            root.areaWidth = width
            var w = area.Window.width
            var h = area.Window.height
            if (w > 0 && h > 0) {
                var p = area.mapToItem(null, 0, 0)
                root.areaLeft = Math.max(0, p.x / w)
                root.areaRight = Math.min(1, (p.x + width) / w)
                root.areaTop = Math.max(0, p.y / h)
                root.areaBottom = Math.min(1, (p.y + height) / h)
                root.screenAspect = w / h
            }
        }

        onWidthChanged: updateGeometry()
        Component.onCompleted: updateGeometry()

        // Revisa cada pocos segundos: detecta si moviste el widget o cambiaste el wallpaper
        Timer {
            interval: root.colorsMs
            running: !root.fullscreenActive
            repeat: true
            triggeredOnStart: true
            onTriggered: {
                area.updateGeometry()
                root.fetchColors()
                root.syncRotation()
            }
        }

        readonly property real slotWidth: width / root.barCount

        Repeater {
            model: root.barCount

            Item {
                id: slot
                x: index * area.slotWidth
                width: area.slotWidth
                height: area.height

                property color c: root.barColor(index)
                Behavior on c { ColorAnimation { duration: 600 } }   // al cambiar wallpaper o modo, el color se desliza en vez de saltar
                readonly property real lv: (root.levels[index] || 0) / 100
                readonly property real pk: (root.peaks[index] || 0) / 100
                readonly property real barW: Math.min(root.barWidth, width)
                // Espejo: altura de la línea. Arriba de ella van las barras, abajo el reflejo.
                readonly property real line: height * root.mirrorLine

                // Barra principal
                Rectangle {
                    width: slot.barW
                    anchors.horizontalCenter: parent.horizontalCenter
                    radius: width / 2
                    color: slot.c
                    height: root.orientation === 1
                            ? Math.max(1, slot.line * slot.lv)
                            : Math.max(2, slot.height * slot.lv)
                    y: root.orientation === 0 ? slot.height - height
                     : root.orientation === 1 ? slot.line - height
                     : (slot.height - height) / 2

                    // Glow: halo del mismo color detrás de la barra (z: -1 lo dibuja debajo).
                    // Un rectángulo semitransparente es mucho más barato que un blur real.
                    Rectangle {
                        visible: root.glowEnabled && opacity > 0.01
                        z: -1
                        anchors.centerIn: parent
                        readonly property real spread: Math.max(2, slot.barW)
                        width: parent.width + 2 * spread
                        height: parent.height + 2 * spread
                        radius: width / 2
                        color: slot.c
                        opacity: root.glowStrength * root.bassEnergy * 0.5
                    }
                }

                // Reflejo (solo espejo): usa el espacio bajo la línea y se desvanece
                Rectangle {
                    visible: root.orientation === 1
                    width: slot.barW
                    anchors.horizontalCenter: parent.horizontalCenter
                    radius: width / 2
                    y: slot.line + 1
                    height: Math.max(1, (slot.height - slot.line - 1) * slot.lv)
                    gradient: Gradient {
                        GradientStop { position: 0.0; color: Qt.rgba(slot.c.r, slot.c.g, slot.c.b, root.mirrorOpacity) }
                        GradientStop { position: 1.0; color: "transparent" }
                    }
                }

                // Peak superior
                Rectangle {
                    visible: root.showPeaks
                    width: slot.barW
                    anchors.horizontalCenter: parent.horizontalCenter
                    height: 2
                    radius: 1
                    color: slot.c
                    opacity: 0.85
                    y: root.orientation === 0 ? Math.max(0, slot.height - slot.height * slot.pk - 4)
                     : root.orientation === 1 ? Math.max(0, slot.line - slot.line * slot.pk - 4)
                     : Math.max(0, (slot.height - slot.height * slot.pk) / 2 - 4)
                }

                // Peak inferior (solo flotante)
                Rectangle {
                    visible: root.showPeaks && root.orientation === 2
                    width: slot.barW
                    anchors.horizontalCenter: parent.horizontalCenter
                    height: 2
                    radius: 1
                    color: slot.c
                    opacity: 0.85
                    y: Math.min(slot.height - 2, (slot.height + slot.height * slot.pk) / 2 + 2)
                }
            }
        }
    }
}
