import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.kirigami as Kirigami
import org.kde.taskmanager as TaskManager

PlasmoidItem {
    id: root

    // ---------- Ajustes (cámbialos aquí) ----------
    readonly property int barCount: 80          // debe coincidir con bars en raw.conf
    readonly property int pollMs: 16            // ~60 fps, igual que framerate de cava
    readonly property real barSpacing: 2        // px entre barras
    readonly property real barFill: 0.6        // fracción del espacio que ocupa cada barra (1 = sin hueco)
    readonly property real peakFall: 0.8        // cuánto cae el peak cap por frame (escala 0-100)
    readonly property int silenceFrames: 120    // frames en silencio antes de ocultar (~2 s)
    readonly property real trebleWhite: 0.75    // 0 = agudos igual que graves, 1 = agudos blancos
    readonly property bool useAccent: true      // false = usar fallbackColor fijo
    readonly property bool bassCenter: true     // false si la prueba de tonos muestra graves en los bordes
    readonly property color fallbackColor: "#00e5ff"
    readonly property string bridgeUrl: "http://127.0.0.1:8765/"

    // Color base: el accent del tema de Plasma (sigue al wallpaper si lo activas en Colors)
    readonly property color baseColor: useAccent ? Kirigami.Theme.highlightColor : fallbackColor

    property var levels: new Array(barCount).fill(0)
    property var peaks: new Array(barCount).fill(0)
    property int silentCount: 0
    property bool busy: false
    property bool fullscreenActive: false

    TaskManager.VirtualDesktopInfo { id: vdInfo }
    TaskManager.ActivityInfo { id: actInfo }

    // Solo ventanas visibles en este escritorio, actividad y pantalla
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

    onFullscreenActiveChanged: {
        var x = new XMLHttpRequest()
        x.open("GET", bridgeUrl + (fullscreenActive ? "pause" : "resume"))
        x.send()
    }

    Plasmoid.backgroundHints: PlasmaCore.Types.NoBackground
    preferredRepresentation: fullRepresentation

    // Stereo de cava: graves al centro, agudos en los extremos.
    // t = 0 en el centro (color puro), t = 1 en los bordes (más blanco)
    function barColor(i) {
        var center = (barCount - 1) / 2
        var t = Math.abs(i - center) / center
        if (!bassCenter) t = 1 - t
            return Qt.tint(baseColor, Qt.rgba(1, 1, 1, t * trebleWhite))
    }

    // Convierte "12;45;80;...;" en arrays de niveles y peaks
    function applyFrame(text) {
        var parts = text.split(";")
        var lv = []
        var pk = peaks.slice()
        var sum = 0
        for (var i = 0; i < barCount; i++) {
            var v = parseInt(parts[i]) || 0     // el ";" final genera un elemento vacío: lo ignora
            lv.push(v)
            sum += v
            pk[i] = Math.max(v, pk[i] - peakFall)
        }
        silentCount = (sum === 0) ? silentCount + 1 : 0
        // Asignar arrays nuevos (no mutar) para que QML detecte el cambio
        levels = lv
        peaks = pk
    }

    Timer {
        interval: root.pollMs
        running: !root.fullscreenActive
        repeat: true
        onTriggered: {
            if (root.busy) return               // no encimar requests si el puente tarda
            root.busy = true
            var x = new XMLHttpRequest()
            x.open("GET", root.bridgeUrl)
            x.onreadystatechange = function () {
                if (x.readyState !== 4) return
                root.busy = false
                // Si el puente no responde (status 0), se trata como silencio:
                // las barras bajan y el widget se oculta solo
                root.applyFrame(x.status === 200 ? x.responseText : "")
            }
            x.send()
        }
    }

    fullRepresentation: Item {
        id: area
        Layout.preferredWidth: 1200
        Layout.preferredHeight: 200
        Layout.minimumWidth: 300
        Layout.minimumHeight: 80

        opacity: root.silentCount > root.silenceFrames ? 0 : 1
        Behavior on opacity { NumberAnimation { duration: 600 } }

        readonly property real barWidth:
            Math.max(1, (width - root.barSpacing * (root.barCount - 1)) / root.barCount)

        Repeater {
            model: root.barCount

            Item {
                x: index * (area.barWidth + root.barSpacing)
                width: area.barWidth
                height: area.height

                readonly property color c: root.barColor(index)

                // Barra
                Rectangle {
                    anchors.bottom: parent.bottom
                    width: parent.width * root.barFill
                    anchors.horizontalCenter: parent.horizontalCenter
                    height: Math.max(2, parent.height * root.levels[index] / 100)
                    radius: width / 2
                    color: parent.c
                }

                // Peak cap: línea fina que cae despacio
                Rectangle {
                    width: parent.width
                    height: 2
                    y: Math.max(0, parent.height - parent.height * root.peaks[index] / 100 - 4)
                    radius: 1
                    color: parent.c
                    opacity: 0.85
                }
            }
        }
    }
}
