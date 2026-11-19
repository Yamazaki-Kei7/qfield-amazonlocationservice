import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import org.qfield.gui
import "ButtonColors.js" as Colors

Button {
    property bool primary: false
    property bool destructive: false
    readonly property var colors: Colors.forTheme(QfTheme.darkTheme)
    readonly property var buttonColors: primary ? Colors.primary : checked ? colors.selected :
                                        destructive ? colors.danger : colors.secondary

    readonly property int iconSize: 18
    icon.width: iconSize
    icon.height: iconSize
    spacing: 4
    Material.roundedScale: Material.SmallScale
    Material.elevation: 0
    Material.foreground: buttonColors.foreground
    // Material uses the accent color for a checked button's label.
    Material.accent: Material.foreground
    Material.background: enabled ? buttonColors.background : QfTheme.controlBackgroundDisabledColor
}
