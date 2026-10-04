import QtQuick
import org.kde.plasma.configuration

// Cada categoría es una página en la barra lateral de Configure
ConfigModel {
    ConfigCategory {
        name: "Wave"
        icon: "audio-volume-high"
        source: "configWave.qml"
    }
    ConfigCategory {
        name: "Color"
        icon: "color-management"
        source: "configColor.qml"
    }
    ConfigCategory {
        name: "Wallpaper"
        icon: "preferences-desktop-wallpaper"
        source: "configWallpaper.qml"
    }
}
