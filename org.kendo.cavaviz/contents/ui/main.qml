import QtQuick
import QtQuick.Layouts
import QtQuick.Shapes
import QtQuick.Effects
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.kirigami as Kirigami
import org.kde.taskmanager as TaskManager
import "palettes.js" as Palettes

PlasmoidItem {
    id: root

    // ---------- Valores fijos ----------
    readonly property int fps: Plasmoid.configuration.fps
    readonly property int pollMs: Math.round(1000 / fps)
    readonly property int colorsMs: 2000        // cada cuánto se revisan los colores (el puente usa caché)
    readonly property int liveColorsMs: 500     // con fondo de video, los colores se piden así de seguido
    property bool liveVideo: false              // el puente avisa si el fondo es un video ("live")
    readonly property int silenceFrames: fps * 2   // 2 segundos, sin importar los fps
    readonly property string bridgeUrl: "http://127.0.0.1:8765/"

    // ---------- Valores del panel de configuración (main.xml) ----------
    readonly property int barWidth: Plasmoid.configuration.barWidth
    readonly property int barGap: Plasmoid.configuration.barGap
    readonly property int orientation: Plasmoid.configuration.orientation   // 0 abajo, 1 espejo, 2 flotante
    readonly property real mirrorLine: Plasmoid.configuration.mirrorLine
    readonly property real mirrorOpacity: Plasmoid.configuration.mirrorOpacity
    // 0 dos colores, 1 por zona, 2 degradado del fondo, 3 por intensidad, 4 color fijo, 5 paleta
    readonly property int colorStyle: Math.max(0, Plasmoid.configuration.colorStyle)
    readonly property int shape: Plasmoid.configuration.shape                 // 0 redondeadas, 1 rectas, 2 onda, 3 circular
    readonly property bool barsShape: shape <= 1
    readonly property real smoothing: Plasmoid.configuration.smoothing
    readonly property color fixedColor: Plasmoid.configuration.fixedColor
    readonly property int paletteIndex: Plasmoid.configuration.paletteIndex      // -1 = paleta propia
    readonly property string customPalette: Plasmoid.configuration.customPalette
    readonly property bool twoColorsCustom: Plasmoid.configuration.twoColorsCustom
    readonly property color twoColorLow: Plasmoid.configuration.twoColorLow
    readonly property color twoColorHigh: Plasmoid.configuration.twoColorHigh
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
    readonly property bool terminalPause: Plasmoid.configuration.terminalPause
    readonly property int pauseRule: Plasmoid.configuration.pauseRule   // 0 nunca, 1 pantalla completa, 2 + maximizada, 3 ventana tapa el widget

    // ---------- Color ----------
    readonly property color baseColor: Kirigami.Theme.highlightColor
    // Respaldo mientras llega el color del wallpaper (o si el puente no puede leerlo)
    property color wallSecond: Qt.lighter(Kirigami.Theme.highlightColor, 1.6)
    property var zoneColors: []                 // [[r,g,b], ...] uno por barra
    property var wallColors: []                 // colores vivos del fondo [[r,g,b], ...] (degradado, intensidad)
    // Color de cada barra. Se calcula solo cuando cambia un color o el modo, nunca en cada frame.
    property var barColors: []
    property var waveStops: []                  // 9 colores de izquierda a derecha (onda)
    property color lowColor: baseColor          // por intensidad: barra baja
    property color highColor: wallSecond        // por intensidad: barra alta

    // ---------- Geometría (la actualiza fullRepresentation) ----------
    property real areaWidth: 1200
    property real areaHeight: 200
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
    property var rawLevels: []                  // último frame sin suavizar (movimiento suave)
    property bool easing: false                 // movimiento suave: las barras todavía no llegan al frame
    property string wavePath: ""                // onda: contorno relleno (PathSvg)
    property string waveLine: ""                // onda: línea de arriba
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
    onAudioChannelsChanged: { barsDebounce.restart(); glowDebounce.restart() }
    onFpsChanged: barsDebounce.restart()
    Timer {
        id: barsDebounce
        interval: 600
        onTriggered: root.get("bars?n=" + root.barCount + "&ch=" + (root.audioChannels === 1 ? "mono" : "stereo")
                              + "&fps=" + root.fps, function () { root.fetchColors() })
    }

    onColorStyleChanged: { fetchColors(); glowDebounce.restart() }
    // ---------- Colores de las barras y del glow ----------
    // Cuando cambia cualquier cosa que afecta el color de las barras, se recalcula
    // (con 100 ms de espera para no repetir el cálculo varias veces seguidas)
    onZoneColorsChanged: glowDebounce.restart()
    onWallColorsChanged: glowDebounce.restart()
    onWallSecondChanged: glowDebounce.restart()
    onBaseColorChanged: glowDebounce.restart()
    onColorBlendChanged: glowDebounce.restart()
    onBassLayoutChanged: glowDebounce.restart()
    onFixedColorChanged: glowDebounce.restart()
    onPaletteIndexChanged: glowDebounce.restart()
    onCustomPaletteChanged: glowDebounce.restart()
    onTwoColorsCustomChanged: { fetchColors(); glowDebounce.restart() }
    onTwoColorLowChanged: glowDebounce.restart()
    onTwoColorHighChanged: glowDebounce.restart()
    onGlowEnabledChanged: glowDebounce.restart()
    onGlowColorModeChanged: glowDebounce.restart()
    Timer {
        id: glowDebounce
        interval: 100
        onTriggered: { root.recomputeColors(); root.recomputeGlow() }
    }

    // Antes había 4 modos (contraste y automático ya no existen): se pasa una sola vez al modo nuevo
    Component.onCompleted: {
        if (Plasmoid.configuration.colorStyle < 0)
            Plasmoid.configuration.colorStyle = Plasmoid.configuration.colorMode === 0 ? 0 : 1
        coverCheck.restart()   // primer aviso al puente (por si quedó una pausa vieja)
        recomputeColors()
    }

    function rgb(c) { return Qt.rgba(c[0] / 255, c[1] / 255, c[2] / 255, 1) }
    function mix(a, b, t) { return Qt.rgba(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t, 1) }
    // Color en la posición t (0-1) de una lista de colores repartidos parejo
    function along(stops, t) {
        if (stops.length === 1) return stops[0]
        var x = Math.max(0, Math.min(1, t)) * (stops.length - 1)
        var k = Math.min(stops.length - 2, Math.floor(x))
        return mix(stops[k], stops[k + 1], x - k)
    }
    // Hasta `max` colores del fondo bien distintos entre sí (la paleta del puente viene del más vivo al menos)
    function distinctWall(max) {
        var out = []
        for (var i = 0; i < wallColors.length && out.length < max; i++) {
            var c = rgb(wallColors[i]), dup = false
            for (var k = 0; k < out.length; k++) if (colorDist(c, out[k]) < 0.3) { dup = true; break }
            if (!dup) out.push(c)
        }
        if (out.length < 2) out = [baseColor, wallSecond]   // sin fondo legible: accent y 2do color
        return out
    }

    // Paleta elegida: una de palettes.js o la propia (-1)
    function paletteStops() {
        var hex = paletteIndex < 0 ? customPalette.split(",")
                : (Palettes.list[paletteIndex] || Palettes.list[0]).colors
        var out = []
        for (var k = 0; k < hex.length; k++) {
            var h = hex[k].trim()
            if (/^#[0-9a-fA-F]{6}$/.test(h)) out.push(Qt.lighter(h, 1))
        }
        return out.length ? out : [baseColor, wallSecond]
    }

    function luminance(c) {
        function lin(v) { return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
    }
    function contrast(la, lb) { return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05) }
    // Solo si hace falta: fondo claro (o blanco) y la barra casi no se distingue de él. Entonces
    // pasa a casi negra con un poco de su tono (un gris queda negro). En cualquier otro caso se
    // queda su color: elegir siempre "la que más contrasta" volvía negras barras que se veían bien.
    function readable(c, bgRgb) {
        var lb = luminance(rgb(bgRgb))
        if (lb < 0.4) return c                                   // fondo oscuro o medio
        if (contrast(luminance(c), lb) >= 1.6) return c          // ya se distingue
        // Se baja el brillo lo justo para llegar a 2.5:1 (queda del mismo tono, más oscuro y algo
        // más saturado); si ni así, casi negra
        var h = c.hsvHue < 0 ? 0 : c.hsvHue, sat = Math.min(1, c.hsvSaturation * 1.2)
        if (sat < 0.15) return Qt.hsva(0, 0, 0.12, 1)              // barra gris sobre fondo claro: negra
        for (var v = c.hsvValue - 0.05; v > 0.14; v -= 0.05) {
            var d = Qt.hsva(h, sat, v, 1)
            if (contrast(luminance(d), lb) >= 2.5) return d
        }
        return Qt.hsva(h, sat, 0.14, 1)
    }

    function recomputeColors() {
        var n = barCount, cols = [], i
        // Dos colores: los que eligió el usuario, o el acento de Plasma y el color del fondo
        var lowTwo = twoColorsCustom ? twoColorLow : baseColor
        var highTwo = twoColorsCustom ? twoColorHigh : wallSecond
        var stops = colorStyle === 2 ? distinctWall(4) : colorStyle === 5 ? paletteStops() : null
        if (colorStyle === 3) {
            var two = distinctWall(2)
            lowColor = two[0]
            highColor = two[1]
        }
        for (i = 0; i < n; i++) {
            if (colorStyle === 1 && zoneColors.length === n) cols.push(rgb(zoneColors[i]))
            else if (stops) cols.push(along(stops, bassT(i)))       // graves -> agudos
            else if (colorStyle === 3) cols.push(mix(lowColor, highColor, 0.5))   // glow y onda; las barras usan el degradado vertical
            else if (colorStyle === 4) cols.push(Qt.rgba(fixedColor.r, fixedColor.g, fixedColor.b, 1))
            // Dos colores (y por zona mientras llegan los colores): el primero sigue a los graves
            else cols.push(mix(lowTwo, highTwo, bassT(i) * colorBlend))
        }
        // Modos que salen del fondo: si una barra casi no se distingue de lo que tiene detrás
        // (fondo claro o blanco), pasa a casi negro conservando el tono.
        var fromWall = colorStyle <= 3 && !(colorStyle === 0 && twoColorsCustom)
        if (fromWall && wallBg.length === n) {
            for (i = 0; i < n; i++) cols[i] = readable(cols[i], wallBg[i])
            if (colorStyle === 3) {   // intensidad: el degradado vertical usa dos colores para todas
                var mid = wallBg[Math.floor(n / 2)]
                lowColor = readable(lowColor, mid)
                highColor = readable(highColor, mid)
            }
        }
        barColors = cols
        var ws = []
        for (i = 0; i < 9; i++) ws.push(cols[Math.round(i / 8 * (n - 1))])
        waveStops = ws
    }

    function colorDist(a, b) {
        var dr = a.r - b.r, dg = a.g - b.g, db = a.b - b.b
        return Math.sqrt(dr * dr + dg * dg + db * db)   // 0 iguales, ~1.73 blanco vs negro
    }

    function recomputeGlow() {
        if (!glowEnabled || glowColorMode !== 1) { glowColors = []; return }
        var n = barCount, cols = barColors, i, k
        if (cols.length !== n) return
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
    // Glow de la onda y del círculo: un solo color (el que más contrasta con el centro)
    readonly property color glowSingle: glowColorMode === 1 && glowColors.length > 0
                                        ? glowColors[Math.floor(glowColors.length / 2)] : barColor(Math.floor(barCount / 2))
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

    // El puente pierde esta opción si se reinicia: se reenvía junto con la rotación
    function syncTerminal() { get("terminal?pause=" + (terminalPause ? 1 : 0), null) }
    onTerminalPauseChanged: syncTerminal()

    function setWallColors(c) {
        if (!c || c.length === 0) return       // sin imagen legible: se quedan los últimos
        wallColors = c
        setSecondColor(c)
    }
    function setZoneColors(c) {
        // Lista vacía = el puente no sabe qué imagen hay (ej. presentación de Plasma): se usa el accent
        zoneColors = (c && c.length === barCount) ? c : []
    }
    function setSecondColor(c) {
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
    }
    // Fondo de video preparado: el puente manda tambien los colores del siguiente tramo y en
    // cuantos ms empieza; se programa el cambio para ese momento (no se espera a otra consulta)
    property var nextColors: null
    property var nextBg: null
    // Fondo detrás de cada barra [[r,g,b], ...] (lo manda el puente): para no dejar barras claras
    // sobre un fondo claro (o blanco), que no se ven
    property var wallBg: []
    function setBg(b) {
        if (b && b.length === barCount && JSON.stringify(b) !== JSON.stringify(wallBg)) {
            wallBg = b
            glowDebounce.restart()
        }
    }
    property var nextApply: null
    function applyResponse(t, apply) {
        if (!t) return
        var res
        try { res = JSON.parse(t) } catch (e) { return }   // el puente se estaba reiniciando
        if (!res || !res.colors) return
        root.liveVideo = !!res.live
        if (res.next && res.in !== undefined && res.in < 150) {
            setBg(res.next_bg)
            apply(res.next)                 // el corte es ya: evita volver un instante al color anterior
            nextSwitch.stop()
            return
        }
        setBg(res.bg)
        apply(res.colors)
        if (res.next && res.in !== undefined) {
            root.nextBg = res.next_bg || null
            root.nextColors = res.next
            root.nextApply = apply
            nextSwitch.interval = Math.max(1, res.in)
            nextSwitch.restart()
        } else {
            nextSwitch.stop()
        }
    }
    Timer {
        id: nextSwitch
        repeat: false
        onTriggered: if (root.nextColors && root.nextApply) { root.setBg(root.nextBg); root.nextApply(root.nextColors) }
    }
    function applyColors(t) { applyResponse(t, setZoneColors) }

    function fetchColors() {
        var cid = Plasmoid.containment ? Plasmoid.containment.id : -1
        var common = "cid=" + cid + "&aspect=" + screenAspect.toFixed(4)
        var span = "n=" + barCount + "&l=" + areaLeft.toFixed(4) + "&r=" + areaRight.toFixed(4)
                   + "&t=" + areaTop.toFixed(4) + "&b=" + areaBottom.toFixed(4)
        if (colorStyle === 4 || colorStyle === 5 || (colorStyle === 0 && twoColorsCustom)) {
            // Color fijo, paleta y dos colores elegidos no dependen del fondo
            liveVideo = false
            nextSwitch.stop()
        } else if (colorStyle === 1) {
            get("zones?" + span + "&swap=" + (zoneSwap ? 1 : 0) + "&" + common, applyColors)
        } else {
            get("palette?" + span + "&" + common, function (t) { root.applyResponse(t, root.setWallColors) })
        }
    }

    function barColor(i) {
        return barColors[i] || baseColor
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
            // Movimiento suave: las barras siguen acercándose al último frame
            if (easing) updateLevels(rawLevels)
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
        var raw = []
        var sum = 0
        for (var i = 0; i < barCount; i++) {
            var v = parseInt(parts[srcIndex(i)]) || 0
            raw.push(v)
            sum += v
        }
        silentCount = (sum === 0) ? silentCount + 1 : 0
        lastSum = sum
        rawLevels = raw
        updateLevels(raw)
    }

    // Aplica un frame a las barras (con el movimiento suave, si está activo), los peaks, la onda y el glow
    function updateLevels(raw) {
        var lv = [], pk = []
        var bassSum = 0, bassN = 0, moving = false
        // Suave: cada frame recorre solo una parte del camino. Sube más rápido de lo que baja,
        // así los golpes se siguen notando.
        var down = 1 - smoothing * 0.88, up = Math.min(1, down * 1.8)
        for (var i = 0; i < barCount; i++) {
            var v = raw[i] || 0
            if (smoothing > 0) {
                var prev = levels[i] || 0, d = v - prev
                v = prev + d * (d > 0 ? up : down)
                if (Math.abs(v - raw[i]) < 0.5) v = raw[i]
                else moving = true
            }
            lv.push(v)
            // "|| 0": tras cambiar la cantidad de barras, peaks puede ser más corto
            pk.push(Math.max(v, (peaks[i] || 0) - peakFall))
            if (bassT(i) < 0.15) { bassSum += v; bassN++ }   // el 15% más grave
        }
        easing = moving
        peaksActive = true
        levels = lv
        peaks = pk
        if (shape === 2) buildWave(lv)
        // Glow: se normaliza contra el pico reciente (el golpe más fuerte de los últimos
        // segundos vale 1), así pulsa con todo el rango aunque los graves nunca lleguen a 100
        var bass = bassN ? bassSum / bassN / 100 : 0
        bassPeak = Math.max(bass, bassPeak * 0.997, 0.05)
        var norm = Math.min(1, bass / bassPeak)
        // Sube de golpe con el bajo y cae despacio, así "pulsa"
        bassEnergy = norm > bassEnergy ? norm : bassEnergy * 0.9
    }

    // Onda: un contorno suave (curvas entre los puntos medios) en lugar de ~190 rectángulos.
    // Se arma una vez por frame como texto SVG; Shape lo dibuja en un solo trazo.
    function buildWave(lv) {
        var w = areaWidth, h = areaHeight, n = lv.length
        if (w <= 0 || h <= 0 || n < 2) { wavePath = ""; waveLine = ""; return }
        var m = Math.max(8, Math.min(n, Math.floor(w / 8)))   // un punto cada ~8 px
        var base = orientation === 0 ? h : orientation === 1 ? h * mirrorLine : h / 2
        var amp = orientation === 2 ? h / 2 - 2 : base - 3
        var xs = [], ys = []
        for (var k = 0; k < m; k++) {
            // El punto toma la barra más alta de su tramo (con menos puntos no se pierden golpes)
            var a = Math.floor(k * n / m), b = Math.max(a + 1, Math.floor((k + 1) * n / m)), top = 0
            for (var i = a; i < b; i++) if (lv[i] > top) top = lv[i]
            xs.push(k * w / (m - 1))
            ys.push(top / 100 * amp)
        }
        function curve(sign, from, to, step) {
            var out = (xs[from]).toFixed(1) + " " + (base - sign * ys[from]).toFixed(1)
            for (var k = from + step; k !== to; k += step) {
                var mx = (xs[k] + xs[k + step]) / 2, my = base - sign * (ys[k] + ys[k + step]) / 2
                out += " Q " + xs[k].toFixed(1) + " " + (base - sign * ys[k]).toFixed(1) + " " + mx.toFixed(1) + " " + my.toFixed(1)
            }
            return out + " L " + xs[to].toFixed(1) + " " + (base - sign * ys[to]).toFixed(1)
        }
        var upper = curve(1, 0, m - 1, 1)
        if (orientation === 2) {
            var lower = curve(-1, m - 1, 0, -1)
            wavePath = "M " + upper + " L " + lower + " Z"
            waveLine = "M " + upper + " M " + lower
        } else {
            wavePath = "M 0 " + base.toFixed(1) + " L " + upper + " L " + w.toFixed(1) + " " + base.toFixed(1) + " Z"
            waveLine = "M " + upper
        }
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
            root.areaHeight = height
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
        onHeightChanged: updateGeometry()
        Component.onCompleted: updateGeometry()

        // Fondo de video: solo los colores, cada medio segundo, para seguir al video (el resto
        // del trabajo de abajo sigue cada colorsMs). Con fondo de imagen no corre.
        Timer {
            interval: root.liveColorsMs
            running: root.liveVideo && !root.coveredActive && !root.manualOff
            repeat: true
            onTriggered: root.fetchColors()
        }

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
                root.syncTerminal()
                // Si el puente se reinició volvió a las barras/fps de raw.conf: se reenvían
                // (el puente no reinicia cava si ya coinciden). No durante un ajuste de tamaño.
                if (!barsDebounce.running) barsDebounce.restart()
            }
        }

        readonly property real slotWidth: width / root.barCount

        // Glow: capa aparte, dibujada antes (debajo) de las barras.
        // La opacidad se calcula UNA vez para toda la capa en cada frame, en lugar de una vez
        // por cada rectángulo (antes ~380 cálculos por frame, el 60% del CPU del widget).
        Item {
            id: glowLayer
            anchors.fill: parent
            visible: root.glowEnabled && root.barsShape
            opacity: root.glowStrength * (0.1 + 0.9 * root.bassEnergy) * 0.45

            Repeater {
                model: root.glowEnabled && root.barsShape ? root.barCount : 0   // apagado: no crea ningún rectángulo

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

        // Por intensidad: las barras se dibujan aparte (sin mostrarse) y sirven de máscara sobre un
        // degradado vertical; así el color depende de la altura sin calcular un color por barra.
        readonly property bool intensityBars: root.colorStyle === 3 && root.barsShape

        Item {
            id: barsLayer
            anchors.fill: parent
            visible: !area.intensityBars
            layer.enabled: area.intensityBars

            Repeater {
                model: root.barsShape ? root.barCount : 0

                Item {
                    id: slot
                    x: index * area.slotWidth
                    width: area.slotWidth
                    height: area.height

                    property color c: root.barColor(index)
                    Behavior on c { ColorAnimation { duration: root.liveVideo ? 250 : 600 } }   // al cambiar wallpaper o modo, el color se desliza en vez de saltar
                    readonly property real lv: (root.levels[index] || 0) / 100
                    readonly property real pk: (root.peaks[index] || 0) / 100
                    readonly property real barW: Math.min(root.barWidth, width)
                    // Espejo: altura de la línea. Arriba de ella van las barras, abajo el reflejo.
                    readonly property real line: height * root.mirrorLine

                    // Barra principal
                    Rectangle {
                        width: slot.barW
                        anchors.horizontalCenter: parent.horizontalCenter
                        radius: root.shape === 1 ? 0 : width / 2
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
                        radius: root.shape === 1 ? 0 : width / 2
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

        // Degradado de "por intensidad": bajo en la base, alto arriba (espejo: desde la línea; flotante: desde el centro)
        Rectangle {
            id: intensitySource
            anchors.fill: parent
            visible: false
            layer.enabled: area.intensityBars
            gradient: Gradient {
                GradientStop { position: 0.0; color: root.highColor }
                GradientStop { position: root.orientation === 1 ? root.mirrorLine : root.orientation === 2 ? 0.5 : 1.0; color: root.lowColor }
                GradientStop { position: 1.0; color: root.orientation === 2 ? root.highColor : root.lowColor }
            }
        }
        MultiEffect {
            anchors.fill: parent
            visible: area.intensityBars
            source: area.intensityBars ? intensitySource : null
            maskEnabled: true
            maskSource: area.intensityBars ? barsLayer : null
            // Probado: con 0.5 / 1.0 el borde y el reflejo conservan su transparencia (con 0 / 1 no recorta nada)
            maskThresholdMin: 0.5
            maskSpreadAtMin: 1.0
        }

        // ---------- Onda ----------
        Item {
            id: wave
            anchors.fill: parent
            visible: root.shape === 2
            readonly property real base: root.orientation === 0 ? height : root.orientation === 1 ? height * root.mirrorLine : height / 2

            // Glow: la línea de arriba, gruesa y transparente; pulsa con los graves como el de las barras
            Shape {
                anchors.fill: parent
                visible: root.glowEnabled
                opacity: root.glowStrength * (0.1 + 0.9 * root.bassEnergy) * 0.5
                preferredRendererType: Shape.CurveRenderer
                ShapePath {
                    strokeColor: root.glowSingle
                    strokeWidth: Math.max(6, root.barWidth * 2.5)
                    fillColor: "transparent"
                    capStyle: ShapePath.RoundCap
                    joinStyle: ShapePath.RoundJoin
                    PathSvg { path: wave.visible && root.glowEnabled ? root.waveLine : "" }
                }
            }

            // Reflejo (solo espejo): la misma onda volteada bajo la línea
            Shape {
                anchors.fill: parent
                visible: root.orientation === 1
                opacity: root.mirrorOpacity * 0.6
                preferredRendererType: Shape.CurveRenderer
                transform: Scale { origin.y: wave.base; yScale: -(wave.height - wave.base) / Math.max(1, wave.base) }
                ShapePath {
                    strokeColor: "transparent"
                    strokeWidth: -1       // sin trazo (solo relleno)
                    fillGradient: waveFill
                    PathSvg { path: wave.visible && root.orientation === 1 ? root.wavePath : "" }
                }
            }

            Shape {
                anchors.fill: parent
                preferredRendererType: Shape.CurveRenderer
                ShapePath {
                    strokeColor: "transparent"
                    strokeWidth: -1       // sin trazo (solo relleno)
                    // Horizontal: los colores de las barras de izquierda a derecha.
                    // Por intensidad: vertical, de la base hacia arriba (flotante: espejado al centro).
                    fillGradient: LinearGradient {
                        id: waveFill
                        readonly property bool vertical: root.colorStyle === 3
                        x1: 0; y1: vertical ? wave.base : 0
                        x2: vertical ? 0 : wave.width
                        y2: vertical ? wave.base - (root.orientation === 2 ? wave.height / 2 : wave.base) : 0
                        spread: ShapeGradient.ReflectSpread
                        GradientStop { position: 0.0;   color: root.waveStops[0] || root.baseColor }
                        GradientStop { position: 0.125; color: root.waveStops[1] || root.baseColor }
                        GradientStop { position: 0.25;  color: root.waveStops[2] || root.baseColor }
                        GradientStop { position: 0.375; color: root.waveStops[3] || root.baseColor }
                        GradientStop { position: 0.5;   color: root.waveStops[4] || root.baseColor }
                        GradientStop { position: 0.625; color: root.waveStops[5] || root.baseColor }
                        GradientStop { position: 0.75;  color: root.waveStops[6] || root.baseColor }
                        GradientStop { position: 0.875; color: root.waveStops[7] || root.baseColor }
                        GradientStop { position: 1.0;   color: root.waveStops[8] || root.baseColor }
                    }
                    PathSvg { path: wave.visible ? root.wavePath : "" }
                }
                // Brillo en el borde de arriba (blanco translúcido: queda bien sobre cualquier color)
                ShapePath {
                    strokeColor: Qt.rgba(1, 1, 1, 0.45)
                    strokeWidth: 1.5
                    fillColor: "transparent"
                    capStyle: ShapePath.RoundCap
                    joinStyle: ShapePath.RoundJoin
                    PathSvg { path: wave.visible ? root.waveLine : "" }
                }
            }
        }

        // ---------- Circular ----------
        // Barras alrededor de un círculo. Cada barra está girada una sola vez; en cada frame solo
        // cambia su largo, igual que las barras normales.
        Item {
            id: circle
            anchors.fill: parent
            visible: root.shape === 3
            readonly property real d: Math.min(width, height)
            readonly property real r0: d * 0.3
            readonly property real len: d / 2 - r0 - 2
            readonly property int count: Math.max(24, Math.min(root.barCount,
                                                  Math.floor(2 * Math.PI * r0 / (root.barWidth + root.barGap))))
            readonly property real barW: Math.max(2, Math.min(root.barWidth, 2 * Math.PI * r0 / count - 1))

            // Por intensidad: punta del color alto, base del color bajo
            Gradient {
                id: radialIntensity
                GradientStop { position: 0.0; color: root.highColor }
                GradientStop { position: 1.0; color: root.lowColor }
            }

            // Glow: un disco al centro que late con los graves
            Rectangle {
                visible: root.glowEnabled
                anchors.centerIn: parent
                width: 2 * Math.max(2, circle.r0 - 4)
                height: width
                radius: width / 2
                color: root.glowSingle
                opacity: root.glowStrength * (0.1 + 0.9 * root.bassEnergy) * 0.35
                scale: 1 + 0.08 * root.bassEnergy
            }

            Repeater {
                model: root.shape === 3 ? circle.count : 0

                Item {
                    id: ray
                    x: (circle.width - width) / 2
                    y: (circle.height - height) / 2
                    width: circle.barW
                    height: 2 * (circle.r0 + circle.len)
                    rotation: index * 360 / circle.count     // 0 = arriba; stereo deja los graves abajo
                    readonly property int src: Math.min(root.barCount - 1, Math.floor((index + 0.5) * root.barCount / circle.count))
                    property color c: root.barColor(src)
                    Behavior on c { ColorAnimation { duration: root.liveVideo ? 250 : 600 } }

                    Rectangle {
                        width: parent.width
                        radius: root.colorStyle === 3 ? 0 : width / 2
                        height: Math.max(2, circle.len * (root.levels[ray.src] || 0) / 100)
                        y: ray.height / 2 - circle.r0 - height
                        color: ray.c
                        gradient: root.colorStyle === 3 ? radialIntensity : null
                    }
                }
            }
        }
    }
}
