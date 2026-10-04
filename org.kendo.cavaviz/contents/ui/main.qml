import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.kirigami as Kirigami
import org.kde.taskmanager as TaskManager

PlasmoidItem {
    id: root

    // ---------- Valores fijos (no están en el panel) ----------
    readonly property int barCount: 80          // debe coincidir con bars en raw.conf
    readonly property int pollMs: 16            // ~60 fps
    readonly property real barSpacing: 2
    readonly property int silenceFrames: 120    // ~2 s
    readonly property string bridgeUrl: "http://127.0.0.1:8765/"

    // ---------- Valores del panel de configuración (main.xml) ----------
    readonly property real barFill: Plasmoid.configuration.barFill
    readonly property int orientation: Plasmoid.configuration.orientation   // 0 abajo, 1 espejo, 2 flotante
    readonly property real mirrorOpacity: Plasmoid.configuration.mirrorOpacity
    readonly property color secondaryColor: Plasmoid.configuration.secondaryColor
    readonly property real colorBlend: Plasmoid.configuration.colorBlend
    readonly property bool bassCenter: Plasmoid.configuration.bassCenter
    readonly property bool showPeaks: Plasmoid.configuration.showPeaks
    readonly property real peakFall: Plasmoid.configuration.peakFall
    readonly property bool hideOnSilence: Plasmoid.configuration.hideOnSilence

    // Color de graves: accent del tema
    readonly property color baseColor: Kirigami.Theme.highlightColor

    property var levels: new Array(barCount).fill(0)
    property var peaks: new Array(barCount).fill(0)
    property int silentCount: 0
    property bool busy: false
    property bool fullscreenActive: false

    Plasmoid.backgroundHints: PlasmaCore.Types.NoBackground
    preferredRepresentation: fullRepresentation

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

    onFullscreenActiveChanged: {
        var x = new XMLHttpRequest()
        x.open("GET", bridgeUrl + (fullscreenActive ? "pause" : "resume"))
        x.send()
    }

    // ---------- Color ----------
    // t = 0 en graves (accent puro), t = 1 en agudos (mezclado con secondaryColor).
    // Qt.tint usa el alpha del segundo color como cantidad de mezcla.
    function barColor(i) {
        var center = (barCount - 1) / 2
        var t = Math.abs(i - center) / center
        if (!bassCenter) t = 1 - t
        return Qt.tint(baseColor, Qt.rgba(secondaryColor.r, secondaryColor.g, secondaryColor.b, t * colorBlend))
    }

    // ---------- Datos ----------
    function applyFrame(text) {
        var parts = text.split(";")
        var lv = []
        var pk = peaks.slice()
        var sum = 0
        for (var i = 0; i < barCount; i++) {
            var v = parseInt(parts[i]) || 0
            lv.push(v)
            sum += v
            pk[i] = Math.max(v, pk[i] - peakFall)
        }
        silentCount = (sum === 0) ? silentCount + 1 : 0
        levels = lv
        peaks = pk
    }

    Timer {
        interval: root.pollMs
        running: !root.fullscreenActive
        repeat: true
        onTriggered: {
            if (root.busy) return
            root.busy = true
            var x = new XMLHttpRequest()
            x.open("GET", root.bridgeUrl)
            x.onreadystatechange = function () {
                if (x.readyState !== 4) return
                root.busy = false
                root.applyFrame(x.status === 200 ? x.responseText : "")
            }
            x.send()
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

        readonly property real slotWidth:
            Math.max(1, (width - root.barSpacing * (root.barCount - 1)) / root.barCount)

        Repeater {
            model: root.barCount

            Item {
                id: slot
                x: index * (area.slotWidth + root.barSpacing)
                width: area.slotWidth
                height: area.height

                readonly property color c: root.barColor(index)
                readonly property real lv: root.levels[index] / 100
                readonly property real pk: root.peaks[index] / 100
                readonly property real half: height / 2
                readonly property real barW: width * root.barFill

                // Barra principal
                // abajo: crece desde el borde inferior
                // espejo: crece hacia arriba desde la línea central
                // flotante: centrada, crece igual hacia arriba y abajo
                Rectangle {
                    width: slot.barW
                    anchors.horizontalCenter: parent.horizontalCenter
                    radius: width / 2
                    color: slot.c
                    height: root.orientation === 1
                            ? Math.max(1, slot.half * slot.lv)
                            : Math.max(2, slot.height * slot.lv)
                    y: root.orientation === 0 ? slot.height - height
                     : root.orientation === 1 ? slot.half - height
                     : (slot.height - height) / 2
                }

                // Reflejo (solo espejo): misma altura, se desvanece hacia abajo
                Rectangle {
                    visible: root.orientation === 1
                    width: slot.barW
                    anchors.horizontalCenter: parent.horizontalCenter
                    radius: width / 2
                    y: slot.half + 1
                    height: Math.max(1, slot.half * slot.lv)
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
                     : root.orientation === 1 ? Math.max(0, slot.half - slot.half * slot.pk - 4)
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
