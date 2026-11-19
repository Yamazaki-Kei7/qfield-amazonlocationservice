import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import org.qfield.gui
import "ButtonColors.js" as Colors

Button {
    property bool primary: false
    readonly property bool filled: primary || checked

    Material.roundedScale: Material.SmallScale
    Material.elevation: 0
    Material.accent: Colors.foreground(QfTheme.darkTheme)
    Material.background: !enabled ? QfTheme.controlBackgroundDisabledColor :
                         filled ? Colors.red : Colors.surface(QfTheme.darkTheme)
    Material.foreground: filled ? "white" : Material.accent
}
