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
    Material.foreground: filled ? "white" : Colors.foreground(QfTheme.darkTheme)
    // Material uses the accent color for a checked button's label.
    Material.accent: Material.foreground
    Material.background: !enabled ? QfTheme.controlBackgroundDisabledColor :
                         filled ? Colors.red : Colors.surface(QfTheme.darkTheme)
}
