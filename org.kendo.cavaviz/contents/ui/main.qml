import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.kirigami as Kirigami
import org.kde.taskmanager as TaskManager

PlasmoidItem {
    id: root

    // ---------- Valores fijos ----------
    readonly property int fps: Plasmoid.configuration.fps
    readonly property int pollMs: Math.round(1000 / fps)
    readonly property int colorsMs: 2000        // cada cuánto se revisan los colores (el puente usa caché)
    readonly property int silenceFrames: fps * 2   // 2 segundos, sin importar los fps
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
    readonly property int glowColorMode: Plasmoid.configuration.glowColorMode   // 0 igual a la barra, 1 contraste con la barra
    readonly property bool showPeaks: Plasmoid.configuration.showPeaks
    readonly property real peakFall: Plasmoid.configuration.peakFall
    readonly property bool hideOnSilence: Plasmoid.configuration.hideOnSilence
    readonly property bool zoneSwap: Plasmoid.configuration.zoneSwap
    readonly property bool rotationEnabled: Plasmoid.configuration.rotationEnabled
    readonly property string rotationDir: Plasmoid.configuration.rotationDir
    readonly property int rotationIntervalSec: Plasmoid.configuration.rotationIntervalSec
    readonly property int rotationOrder: Plasmoid.configuration.rotationOrder
    readonly property int pauseRule: Plasmoid.configuration.pauseRule   // 0 nunca, 1 pantalla completa, 2 + maximizada, 3 ventana tapa el widget

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
    property rect areaRect: Qt.rect(0, 0, 0, 0)  // el widget en coordenadas de pantalla (para saber si una ventana lo tapa)

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
    property string lastFrame: ""               // para no redibujar si el puente devuelve el mismo frame
    property int lastSum: -1                    // suma del último frame (0 = silencio)
    property bool peaksActive: false            // si queda algún peak por caer
    property bool bridgePaused: false           // el puente congeló cava (pantalla bloqueada, ventana encima o apagado a mano)
    property bool manualOff: false              // apagado a mano (/disable, /toggle o clic derecho)
    property real bassEnergy: 0                 // 0-1, energía de los graves para el glow
    property real bassPeak: 0.2                 // pico reciente de graves, para normalizar el glow
    property var glowColors: []                 // un color por barra: el que más contrasta con esa barra
    property bool coveredActive: false          // una ventana tapa el widget según pauseRule
    property bool coverSent: false              // ya se avisó al puente al menos una vez

    Plasmoid.backgroundHints: PlasmaCore.Types.NoBackground
    preferredRepresentation: fullRepresentation

    // Clic derecho sobre el widget > Desactivar/Activar visualizer, Siguiente wallpaper
    Plasmoid.contextualActions: [
        PlasmaCore.Action {
            text: root.manualOff ? "Activar visualizer" : "Desactivar visualizer"
            icon.name: root.manualOff ? "media-playback-start" : "media-playback-pause"
            // El puente responde con el frame actual o "D": se aplica para cambiar el texto al instante
            onTriggered: root.get(root.manualOff ? "enable" : "disable", function (t) { root.applyFrame(t || "") })
        },
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
    onBarCountChanged: { barsDebounce.restart(); glowDebounce.restart() }
    onAudioChannelsChanged: barsDebounce.restart()
    onFpsChanged: barsDebounce.restart()
    Timer {
        id: barsDebounce
        interval: 600
        onTriggered: root.get("bars?n=" + root.barCount + "&ch=" + (root.audioChannels === 1 ? "mono" : "stereo")
                              + "&fps=" + root.fps, function () { root.fetchColors() })
    }

    onColorModeChanged: fetchColors()
    // ---------- Color del glow por contraste con la barra ----------
    // Cuando cambia cualquier cosa que afecta el color de las barras, se recalcula
    // (con 100 ms de espera para no repetir el cálculo varias veces seguidas)
    onZoneColorsChanged: glowDebounce.restart()
    onWallSecondChanged: glowDebounce.restart()
    onBaseColorChanged: glowDebounce.restart()
    onColorBlendChanged: glowDebounce.restart()
    onBassLayoutChanged: glowDebounce.restart()
    onGlowEnabledChanged: glowDebounce.restart()
    onGlowColorModeChanged: glowDebounce.restart()
    Timer {
        id: glowDebounce
        interval: 100
        onTriggered: root.recomputeGlow()
    }

    function colorDist(a, b) {
        var dr = a.r - b.r, dg = a.g - b.g, db = a.b - b.b
        return Math.sqrt(dr * dr + dg * dg + db * db)   // 0 iguales, ~1.73 blanco vs negro
    }

    function recomputeGlow() {
        if (!glowEnabled || glowColorMode !== 1) { glowColors = []; return }
        var n = barCount, cols = [], i, k
        for (i = 0; i < n; i++) cols.push(barColor(i))
        // Colores distintos presentes en las barras (se agrupan los casi iguales)
        var pool = []
        for (i = 0; i < n && pool.length < 6; i++) {
            var dup = false
            for (k = 0; k < pool.length; k++) if (colorDist(cols[i], pool[k]) < 0.25) { dup = true; break }
            if (!dup) pool.push(cols[i])
        }
        var white = Qt.rgba(1, 1, 1, 1)
        var out = []
        for (i = 0; i < n; i++) {
            var best = null, bestD = -1
            for (k = 0; k < pool.length; k++) {
                var d = colorDist(cols[i], pool[k])
                if (d > bestD) { bestD = d; best = pool[k] }
            }
            if (bestD < 0.25) {
                // Todas las barras casi del mismo color: blanco, o el accent si la barra ya es clara
                var lum = 0.2126 * cols[i].r + 0.7152 * cols[i].g + 0.0722 * cols[i].b
                best = (lum < 0.6 || colorDist(cols[i], baseColor) < 0.25) ? white : baseColor
            }
            out.push(best)
        }
        glowColors = out
    }
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

    // ---------- Pausa cuando una ventana tapa el widget ----------
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
        // Mover o redimensionar una ventana dispara muchos cambios: se revisa una vez al terminar
        onDataChanged: coverCheck.restart()
        onCountChanged: coverCheck.restart()
    }
    onPauseRuleChanged: coverCheck.restart()
    onAreaRectChanged: coverCheck.restart()
    Component.onCompleted: coverCheck.restart()   // primer aviso al puente (por si quedó una pausa vieja)

    Timer {
        id: coverCheck
        interval: 250
        onTriggered: root.checkCovered()
    }

    function checkCovered() {
        var covered = false
        var wins = []   // ventanas para la regla 3
        for (var i = 0; i < tasks.count && !covered && pauseRule > 0; i++) {
            var idx = tasks.index(i, 0)
            if (tasks.data(idx, TaskManager.AbstractTasksModel.IsMinimized)) continue
            if (tasks.data(idx, TaskManager.AbstractTasksModel.IsFullScreen)) covered = true
            else if (pauseRule >= 2 && tasks.data(idx, TaskManager.AbstractTasksModel.IsMaximized)) covered = true
            else if (pauseRule === 3) wins.push(tasks.data(idx, TaskManager.AbstractTasksModel.Geometry))
        }
        if (!covered && pauseRule === 3) covered = coveredFraction(wins) >= 0.9
        if (covered !== coveredActive || !coverSent) {
            coveredActive = covered
            coverSent = true
            get(covered ? "pause" : "resume", null)
        }
    }

    // Qué parte del widget tapan las ventanas (0-1). Se revisa una cuadrícula de puntos en vez de
    // calcular la unión exacta de rectángulos: con tiling hay varias ventanas y huecos entre ellas,
    // y el 90% deja pasar esos huecos.
    function coveredFraction(wins) {
        var a = areaRect
        if (wins.length === 0 || a.width <= 0 || a.height <= 0) return 0
        var cols = 24, rows = 4, hit = 0
        for (var cx = 0; cx < cols; cx++) {
            var x = a.x + (cx + 0.5) * a.width / cols
            for (var cy = 0; cy < rows; cy++) {
                var y = a.y + (cy + 0.5) * a.height / rows
                for (var k = 0; k < wins.length; k++) {
                    var g = wins[k]
                    if (x >= g.x && x < g.x + g.width && y >= g.y && y < g.y + g.height) { hit++; break }
                }
            }
        }
        return hit / (cols * rows)
    }

    // ---------- Datos de audio ----------
    function applyFrame(text) {
        // Mismo frame que el anterior (el widget consultó antes de que cava generara uno nuevo):
        // no se toca nada, así las ~190 barras no se recalculan para quedar igual
        if (text === lastFrame && text !== "") {
            // Mismo frame: las barras no cambian, pero en silencio hay que seguir contando
            // (para ocultar el widget) y dejar caer peaks y glow hasta 0
            if (lastSum === 0) {
                silentCount++
                if (peaksActive) {
                    var pk2 = [], any = false
                    for (var j = 0; j < peaks.length; j++) {
                        var p = Math.max(0, peaks[j] - peakFall)
                        pk2.push(p)
                        if (p > 0) any = true
                    }
                    peaks = pk2
                    peaksActive = any   // cuando todos llegan a 0, deja de redibujar
                }
                if (bassEnergy > 0.01) bassEnergy *= 0.9
            }
            return
        }
        lastFrame = text
        manualOff = (text === "D")
        bridgePaused = (text === "P" || manualOff)   // en pausa o apagado: se consulta 1 vez por segundo
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
        lastSum = sum
        peaksActive = true
        levels = lv
        peaks = pk
        // Glow: se normaliza contra el pico reciente (el golpe más fuerte de los últimos
        // segundos vale 1), así pulsa con todo el rango aunque los graves nunca lleguen a 100
        var bass = bassN ? bassSum / bassN / 100 : 0
        bassPeak = Math.max(bass, bassPeak * 0.997, 0.05)
        var norm = Math.min(1, bass / bassPeak)
        // Sube de golpe con el bajo y cae despacio, así "pulsa"
        bassEnergy = norm > bassEnergy ? norm : bassEnergy * 0.9
    }

    Timer {
        interval: root.bridgePaused ? 1000 : root.pollMs
        running: !root.coveredActive
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

        // Oculto en pausa, apagado o tapado: así no quedan barras congeladas a la vista
        opacity: (root.bridgePaused || root.coveredActive
                  || (root.hideOnSilence && root.silentCount > root.silenceFrames)) ? 0 : 1
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
                // La vista del escritorio ocupa toda su pantalla: se suma la posición de esa pantalla
                var sg = Plasmoid.containment ? Plasmoid.containment.screenGeometry : Qt.rect(0, 0, 0, 0)
                root.areaRect = Qt.rect(sg.x + p.x, sg.y + p.y, width, height)
            }
        }

        onWidthChanged: updateGeometry()
        Component.onCompleted: updateGeometry()

        // Revisa cada pocos segundos: detecta si moviste el widget o cambiaste el wallpaper
        Timer {
            interval: root.colorsMs
            running: !root.coveredActive && !root.manualOff
            repeat: true
            triggeredOnStart: true
            onTriggered: {
                area.updateGeometry()
                root.fetchColors()
                root.syncRotation()
            }
        }

        readonly property real slotWidth: width / root.barCount

        // Glow: capa aparte, dibujada antes (debajo) de las barras.
        // La opacidad se calcula UNA vez para toda la capa en cada frame, en lugar de una vez
        // por cada rectángulo (antes ~380 cálculos por frame, el 60% del CPU del widget).
        Item {
            id: glowLayer
            anchors.fill: parent
            visible: root.glowEnabled
            opacity: root.glowStrength * (0.1 + 0.9 * root.bassEnergy) * 0.45

            Repeater {
                model: root.glowEnabled ? root.barCount : 0   // apagado: no crea ningún rectángulo

                Rectangle {
                    readonly property real lv: (root.levels[index] || 0) / 100
                    readonly property real barW: Math.min(root.barWidth, area.slotWidth)
                    readonly property real spread: Math.max(2, barW)
                    readonly property real line: area.height * root.mirrorLine
                    readonly property real h: root.orientation === 1
                                              ? Math.max(1, line * lv)
                                              : Math.max(2, area.height * lv)
                    x: index * area.slotWidth + (area.slotWidth - barW) / 2 - spread
                    width: barW + 2 * spread
                    height: h + 2 * spread
                    y: (root.orientation === 0 ? area.height - h
                        : root.orientation === 1 ? line - h
                        : (area.height - h) / 2) - spread
                    radius: width / 2
                    color: (root.glowColorMode === 1 && root.glowColors.length === root.barCount)
                           ? root.glowColors[index] : root.barColor(index)
                }
            }
        }

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
