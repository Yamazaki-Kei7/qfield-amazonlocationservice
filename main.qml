import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts
import org.qgis
import org.qfield.core
import org.qfield.gui
import "Routes.js" as Routes
import "ButtonColors.js" as Colors

Item {
    id: plugin
    readonly property var window: iface.mainWindow()
    readonly property var canvas: iface.mapCanvas()
    readonly property var handler: iface.findItemByObjectName("pointHandler")
    readonly property var wgs84: QfCoordinateReferenceSystemUtils.wgs84Crs()
    readonly property var gnss: iface.findItemByObjectName("positionSource")
    readonly property var currentPosition: {
        if (!gnss || !gnss.active || !gnss.valid || !gnss.currentness) return null
        const fix = gnss.positionInformation
        if (!fix || !fix.isValid || !fix.longitudeValid || !fix.latitudeValid) return null
        const p = toWgs84(gnss.projectedPosition, canvas.mapSettings.destinationCrs)
        return Routes.validPosition(p) ? p : null
    }
    property var preview: null
    property bool needsOrigin: false
    property var stops: []
    property var travelMode: Routes.travelModes[0]
    readonly property var pending: routeRequest.pending
    property bool picking: false
    property string message: ""
    readonly property string handlerName: "AmazonLocationRoutes"
    readonly property string serviceName: "Amazon Location Service"
    readonly property url serviceIcon: Qt.resolvedUrl("Arch_Amazon-Location-Service_32.svg")

    readonly property color ink: "#232f3e"
    readonly property color accent: Colors.foreground(QfTheme.darkTheme)
    readonly property int gutter: 16
    readonly property int touchHeight: 44
    readonly property real overlayBottomMargin: Math.max(window.sceneBottomMargin, canvas.bottomMargin) + gutter
    readonly property string region: regionField.text.trim()
    readonly property string apiKey: keyField.text.trim()
    readonly property int maxStops: Routes.stopLimit(travelMode.id)
    readonly property bool atLimit: stops.length >= maxStops
    readonly property bool canAddStop: !atLimit && !pending
    readonly property bool reorderable: stops.length > 1
    readonly property string statusText: message || searchHint
    readonly property string searchHint: {
        if (stops.length > maxStops) return travelMode.label + "は2地点までです。地点を減らすか、移動手段を変更してください。"
        if (stops.length === 0) return "出発地と目的地を、訪問する順に追加してください。"
        if (needsOrigin) return "目的地を選択済みです。出発地を追加してください。"
        if (stops.length === 1) return "目的地をあと1地点追加してください。"
        return connectionHint
    }
    readonly property string connectionHint: {
        if (!regionField.validRegion) return "AWS リージョンを入力してください（例：ap-northeast-1）。"
        if (!apiKey) return "Amazon Location API キーを入力してください。"
        return ""
    }

    Component.onCompleted: {
        iface.addItemToPluginsToolbar(serviceButton)
        iface.addItemToPluginsToolbar(placeButton)
        iface.addItemToPluginsToolbar(routeButton)
        handler.registerHandler(handlerName, pickPoint, QfMapCanvasPointHandler.Priority.High)
    }
    Component.onDestruction: {
        if (handler) handler.deregisterHandler(handlerName)
    }

    function pickPoint(screenPoint, device, interaction) {
        if (!picking || interaction !== "clicked") return false
        if (pending) return true
        const mapPoint = canvas.mapSettings.screenToCoordinate(screenPoint)
        addStop(mapPoint, canvas.mapSettings.destinationCrs, "地図上の地点")
        return true
    }

    function toWgs84(point, crs) {
        const p = QfGeometryUtils.reprojectPointToWgs84(point, crs)
        return [p.x, p.y]
    }

    function addStop(point, crs, label) {
        addPosition(toWgs84(point, crs), label)
    }

    function addPosition(position, label, asDestination = false) {
        if (pending) return
        if (atLimit) {
            window.displayToast(travelMode.label + "で指定できる地点は" + maxStops + "件までです。")
            return
        }
        // QML list delegates can supply a QVariantList instead of a JavaScript array.
        const coordinates = position && [position[0], position[1]]
        if (!Routes.validPosition(coordinates)) {
            window.displayToast("地点の座標を取得できませんでした。")
            return
        }
        const stop = { position: coordinates, label: label }
        if (asDestination && (!stops.length || needsOrigin)) {
            needsOrigin = true
            stops = [stop]
        } else if (needsOrigin) {
            needsOrigin = false
            stops = [stop].concat(stops)
        } else {
            stops = stops.concat([stop])
        }
        window.displayToast(label + "を経路に追加しました。")
    }

    function mapCenter() {
        return toWgs84(canvas.mapSettings.center, canvas.mapSettings.destinationCrs)
    }

    function showPlace(place) {
        preview = place
        const p = QfGeometryUtils.point(place.position[0], place.position[1])
        canvas.mapSettings.setCenter(QfGeometryUtils.reprojectPoint(p, wgs84, canvas.mapSettings.destinationCrs), true)
    }

    function openPlaces(forRoute) {
        picking = false
        preview = null
        places.forRoute = forRoute
        placeSearch.reset()
        places.open()
    }

    function usePreview() {
        if (!preview || !canAddStop) return
        const place = preview
        preview = null
        if (!stops.length && currentPosition) addPosition(currentPosition, "現在地")
        addPosition(place.position, place.label, true)
        panel.open()
    }

    function moveStop(from, to) {
        if (pending || from < 0 || from >= stops.length || to < 0 || to >= stops.length || from === to) return
        const reordered = stops.slice()
        const stop = reordered.splice(from, 1)[0]
        reordered.splice(to, 0, stop)
        stops = reordered
    }

    onStopsChanged: {
        if (!stops.length) needsOrigin = false
        if (stopRows) stopRows.dragIndex = -1
        clearRoute()
    }

    function clearRoute() {
        routeRequest.cancel()
        route.geometryWrapper.clear()
        message = ""
    }

    onMessageChanged: {
        if (picking && message) window.displayToast(message)
    }

    function search() {
        if (pending || searchHint) return
        const body = Routes.requestBody(stops, travelMode.id)
        const legCount = stops.length - 1
        message = ""
        routeRequest.post("routes", "routes", body, text => {
            try {
                const data = JSON.parse(text)
                const geometry = QfGeometryUtils.createGeometryFromWkt(Routes.routeWkt(data, legCount, body.TravelMode))
                route.geometryWrapper.crs = wgs84
                route.geometryWrapper.qgsGeometry = geometry
                const projected = QfGeometryUtils.reprojectGeometry(geometry, wgs84, canvas.mapSettings.destinationCrs)
                iface.setMapExtent(QfGeometryUtils.boundingBox(projected))
                picking = false
                panel.close()
                window.displayToast(travelMode.label + "で" + stops.length + "地点の経路を表示しました。")
            } catch (error) {
                message = error.message
            }
        })
    }

    LocationRequest {
        id: routeRequest
        region: plugin.region
        apiKey: plugin.apiKey
        onFailed: reason => plugin.message = reason
        onRejected: status => plugin.message = "検索できませんでした（HTTP " + status + "）。地点、リージョン、キーの権限を確認してください。"
    }

    Connections {
        target: iface
        function onLoadProjectTriggered() {
            plugin.picking = false
            serviceButton.checked = false
            settingsPopup.close()
            places.close()
            plugin.preview = null
            features.close()
            panel.close()
            matches.clear()
            plugin.stops = []
        }
    }

    QfToolButton {
        id: serviceButton
        readonly property int iconSize: Math.round(width * 0.7)
        round: true
        checkable: true
        bgcolor: "#dd344c"
        padding: 0
        iconSource: plugin.serviceIcon
        iconColor: "transparent"
        icon.width: serviceButton.iconSize
        icon.height: serviceButton.iconSize
        bottomRightIndicatorText: plugin.picking ? String(plugin.stops.length) : (checked ? "▴" : "▾")
        bottomRightIndicatorBgColor: Colors.surface(QfTheme.darkTheme)
        bottomRightIndicatorFgColor: plugin.accent
        statusBadge.bottomMargin: 0
        statusBadge.rightMargin: 0
        Accessible.name: plugin.serviceName
        Accessible.description: checked ? "検索ボタンを収納する" : "検索ボタンを表示する"
        ToolTip.text: plugin.serviceName
        ToolTip.visible: hovered && !checked
        ToolTip.delay: 600
    }

    component SearchToolButton: QfToolButton {
        round: true
        visible: serviceButton.checked
        display: AbstractButton.IconOnly
        bgcolor: QfTheme.toolButtonBackgroundColor
        opacity: enabled ? 1 : 0.4
        Accessible.name: text
        ToolTip.text: text
        ToolTip.visible: hovered
        ToolTip.delay: serviceButton.ToolTip.delay
        onClicked: serviceButton.checked = false
    }

    SearchToolButton {
        id: placeButton
        text: "POI検索"
        iconSource: Qt.resolvedUrl("poi-search.svg")
        enabled: !plugin.pending
        onClicked: plugin.openPlaces(false)
    }

    SearchToolButton {
        id: routeButton
        text: "経路検索"
        iconSource: Qt.resolvedUrl("icon.svg")
        onClicked: {
            plugin.picking = false
            plugin.preview = null
            panel.open()
        }
    }

    QfGeometryRenderer {
        id: route
        parent: plugin.canvas
        anchors.fill: parent
        mapSettings: plugin.canvas.mapSettings
        color: "#0079bd"
        lineWidth: 5
    }

    Item {
        parent: plugin.canvas
        anchors.fill: parent
        z: route.z + 1
        Repeater {
            model: plugin.preview ? plugin.stops.concat([plugin.preview]) : plugin.stops
            delegate: Rectangle {
                required property var modelData
                required property int index
                CoordinateTransformer {
                    id: transformPoint
                    sourceCrs: plugin.wgs84
                    sourcePosition: QfGeometryUtils.point(modelData.position[0], modelData.position[1])
                    destinationCrs: plugin.canvas.mapSettings.destinationCrs
                    transformContext: qgisProject.transformContext
                }
                QfMapToScreen {
                    id: marker
                    mapSettings: plugin.canvas.mapSettings
                    mapPoint: transformPoint.projectedPosition
                }
                readonly property bool isPlace: index === plugin.stops.length
                width: isPlace ? 30 : 24
                height: width
                radius: width / 2
                x: marker.screenPoint.x - width / 2
                y: marker.screenPoint.y - height / 2
                color: isPlace ? plugin.accent : plugin.ink
                border.color: "white"
                Text { anchors.centerIn: parent; text: isPlace ? "●" : index + 1; color: "white" }
            }
        }
    }

    Pane {
        parent: plugin.canvas.parent
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: plugin.overlayBottomMargin
        width: Math.min(410, parent.width - 2 * plugin.gutter)
        visible: !!plugin.preview
        padding: 12
        background: Rectangle { radius: 8; color: QfTheme.groupBoxSurfaceColor; border.color: QfTheme.controlBorderColor }
        contentItem: ColumnLayout {
            RowLayout {
                Layout.fillWidth: true
                Label {
                    Layout.fillWidth: true
                    text: plugin.preview ? plugin.preview.label : ""
                    textFormat: Text.PlainText
                    font: QfTheme.strongResultFont
                    wrapMode: Text.Wrap
                }
                LocationButton {
                    text: "×"
                    horizontalPadding: 0
                    Accessible.name: "場所の表示を閉じる"
                    Layout.minimumWidth: plugin.touchHeight
                    Layout.minimumHeight: plugin.touchHeight
                    onClicked: plugin.preview = null
                }
            }
            Label {
                Layout.fillWidth: true
                text: plugin.preview ? plugin.preview.address : ""
                visible: !!text
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                color: QfTheme.secondaryTextColor
            }
            RowLayout {
                LocationButton {
                    text: plugin.atLimit ? "地点数が上限です" :
                        !plugin.stops.length && plugin.currentPosition ? "現在地からの経路" :
                        plugin.stops.length && !plugin.needsOrigin ? "目的地として追加" : "ここへの経路"
                    enabled: plugin.canAddStop
                    Layout.minimumHeight: plugin.touchHeight
                    primary: true
                    onClicked: plugin.usePreview()
                }
                LocationButton {
                    text: "候補に戻る"
                    onClicked: {
                        plugin.preview = null
                        places.open()
                    }
                }
            }
        }
    }

    QfMultiFeatureListModel { id: matches }

    LocationButton {
        parent: plugin.canvas.parent
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: plugin.overlayBottomMargin
        height: Math.max(implicitHeight, plugin.touchHeight)
        visible: plugin.picking && plugin.stops.length >= 2
        enabled: !plugin.pending
        text: plugin.pending ? "経路を検索中…" : plugin.searchHint ? "接続設定を入力" : "経路を検索"
        Accessible.description: plugin.statusText
        primary: true
        onClicked: {
            if (plugin.searchHint) {
                plugin.picking = false
                panel.open()
                settingsPopup.open()
            } else {
                plugin.search()
            }
        }
    }

    component RoutePopup: Popup {
        parent: plugin.window.contentItem
        anchors.centerIn: parent
        width: Math.min(440, parent.width - 16)
        height: Math.min(640, parent.height - 16)
        padding: 0
        modal: true
        focus: true
        Material.accent: plugin.accent
    }

    component PanelHeader: Rectangle {
        id: header
        property string title
        property string dismissText: "閉じる"
        signal dismissed()
        Layout.fillWidth: true
        implicitHeight: headerRow.implicitHeight + 16
        color: plugin.ink
        RowLayout {
            id: headerRow
            anchors.fill: parent
            anchors.leftMargin: plugin.gutter
            anchors.rightMargin: 8
            spacing: 10
            Image {
                source: plugin.serviceIcon
                Layout.preferredWidth: 32
                Layout.preferredHeight: 32
            }
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 1
                Label { text: plugin.serviceName; color: "white"; font: QfTheme.tipFont }
                Label { text: header.title; color: "white"; font: QfTheme.strongTitleFont }
            }
            LocationButton {
                text: header.dismissText
                Layout.minimumHeight: plugin.touchHeight
                onClicked: header.dismissed()
            }
        }
    }

    component SectionTitle: Label {
        Layout.fillWidth: true
        Layout.topMargin: 12
        font: QfTheme.strongResultFont
    }

    component MoveButton: LocationButton {
        required property int stopIndex
        required property int step
        readonly property int target: stopIndex + step
        horizontalPadding: 0
        text: step < 0 ? "↑" : "↓"
        visible: plugin.reorderable
        enabled: !plugin.pending && target >= 0 && target < plugin.stops.length
        Accessible.name: (stopIndex + 1) + "番目の地点を1つ" + (step < 0 ? "上" : "下") + "へ"
        onClicked: plugin.moveStop(stopIndex, target)
        Layout.preferredWidth: plugin.touchHeight
        Layout.minimumHeight: plugin.touchHeight
        ToolTip.visible: hovered || pressed
        ToolTip.text: Accessible.name
        ToolTip.delay: 600
    }

    component StopCard: Pane {
        id: card
        required property int index
        readonly property var stop: plugin.stops[index]
        readonly property string roleLabel: plugin.needsOrigin ? "目的地" : index === 0 ? "出発地" :
            index === plugin.stops.length - 1 ? "目的地" : "経由地"
        Layout.fillWidth: true
        Layout.minimumWidth: 0
        Layout.topMargin: 4
        readonly property bool held: stopRows.dragIndex === index
        z: held ? 1 : 0
        transform: Translate { y: stopRows.displacement(card.index) }
        padding: 10
        background: Rectangle {
            radius: 8
            color: QfTheme.groupBoxSurfaceColor
            border.color: card.held ? plugin.accent : QfTheme.controlBorderColor
            border.width: card.held ? 2 : 1
        }
        contentItem: RowLayout {
            spacing: 6
            MouseArea {
                Layout.preferredWidth: plugin.touchHeight
                Layout.preferredHeight: Math.max(plugin.touchHeight, gripLabels.implicitHeight)
                enabled: plugin.reorderable && !plugin.pending
                preventStealing: true
                cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                onPressed: mouse => {
                    form.contentItem.cancelFlick()
                    stopRows.pressY = mapToItem(form, mouse.x, mouse.y).y
                    stopRows.pointerY = stopRows.pressY
                    stopRows.startScroll = form.contentItem.contentY
                }
                onPositionChanged: mouse => {
                    if (!pressed) return
                    stopRows.pointerY = mapToItem(form, mouse.x, mouse.y).y
                    if (!card.held && Math.abs(stopRows.pointerY - stopRows.pressY) >= Qt.styleHints.startDragDistance)
                        stopRows.dragIndex = card.index
                }
                onReleased: mouse => {
                    if (!card.held) return
                    stopRows.pointerY = mapToItem(form, mouse.x, mouse.y).y
                    const target = stopRows.targetIndex
                    stopRows.dragIndex = -1
                    plugin.moveStop(card.index, target)
                }
                onCanceled: if (card.held) stopRows.dragIndex = -1
                ColumnLayout {
                    id: gripLabels
                    anchors.centerIn: parent
                    spacing: 2
                    Label {
                        text: card.index + 1
                        font: QfTheme.strongResultFont
                        color: "white"
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                        Layout.alignment: Qt.AlignHCenter
                        Layout.preferredWidth: Math.max(26, implicitWidth + 8, implicitHeight)
                        Layout.preferredHeight: Layout.preferredWidth
                        background: Rectangle { radius: height / 2; color: plugin.ink }
                    }
                    Label {
                        visible: plugin.reorderable
                        Layout.alignment: Qt.AlignHCenter
                        text: "⠿"
                        color: QfTheme.secondaryTextColor
                        Accessible.ignored: true
                    }
                }
            }
            ColumnLayout {
                Layout.fillWidth: true
                Layout.minimumWidth: 0
                spacing: 2
                Label { text: card.roleLabel; color: plugin.accent; font: QfTheme.tipFont }
                Label {
                    Layout.fillWidth: true
                    Layout.minimumWidth: 0
                    text: card.stop ? card.stop.label : ""
                    textFormat: Text.PlainText
                    wrapMode: Text.Wrap
                    font: QfTheme.strongResultFont
                }
                Label {
                    Layout.fillWidth: true
                    Layout.minimumWidth: 0
                    text: card.stop ? card.stop.position[1].toFixed(5) + ", " + card.stop.position[0].toFixed(5) : ""
                    color: QfTheme.secondaryTextColor
                    wrapMode: Text.Wrap
                    font: QfTheme.tipFont
                }
            }
            MoveButton { stopIndex: card.index; step: -1 }
            MoveButton { stopIndex: card.index; step: 1 }
        }
    }

    RoutePopup {
        id: panel
        onAboutToHide: {
            stopRows.dragIndex = -1
            routeRequest.cancel()
        }
        ColumnLayout {
            anchors.fill: parent
            spacing: 0
            PanelHeader { title: "経路検索"; onDismissed: panel.close() }
            ScrollView {
                id: form
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.minimumHeight: 0
                clip: true
                contentWidth: availableWidth
                leftPadding: plugin.gutter
                rightPadding: plugin.gutter
                ColumnLayout {
                    width: form.availableWidth
                    spacing: 4
                    RowLayout {
                        Layout.fillWidth: true
                        SectionTitle { text: "移動手段"; Layout.topMargin: 0 }
                        LocationButton { text: "接続設定"; enabled: !plugin.pending; onClicked: settingsPopup.open() }
                    }
                    GridLayout {
                        id: travelModeGrid
                        readonly property int iconSize: 18
                        Layout.fillWidth: true
                        columns: width < 280 ? 2 : 3
                        columnSpacing: 4
                        rowSpacing: 0
                        enabled: !plugin.pending
                        Repeater {
                            model: Routes.travelModes
                            delegate: LocationButton {
                                required property var modelData
                                Layout.fillWidth: true
                                Layout.preferredWidth: 1
                                Layout.minimumHeight: plugin.touchHeight
                                Layout.preferredHeight: Math.max(plugin.touchHeight, implicitContentHeight + verticalPadding * 2)
                                horizontalPadding: 4
                                verticalPadding: 2
                                spacing: 4
                                text: modelData.label
                                icon.source: Qt.resolvedUrl("icons/" + modelData.id + ".svg")
                                icon.width: travelModeGrid.iconSize
                                icon.height: travelModeGrid.iconSize
                                icon.color: Material.foreground
                                display: AbstractButton.TextBesideIcon
                                checkable: true
                                autoExclusive: true
                                checked: plugin.travelMode.id === modelData.id
                                Accessible.role: Accessible.RadioButton
                                onClicked: {
                                    if (plugin.travelMode.id === modelData.id) return
                                    plugin.travelMode = modelData
                                    plugin.clearRoute()
                                }
                            }
                        }
                    }
                    SectionTitle { text: plugin.needsOrigin ? "出発地を選択" : "地点を追加" }
                    LocationButton {
                        Layout.fillWidth: true
                        Layout.minimumHeight: plugin.touchHeight
                        enabled: plugin.canAddStop
                        text: plugin.needsOrigin ? "出発地をPOI検索" : plugin.stops.length > 1 ? "次の目的地をPOI検索" : "目的地をPOI検索"
                        onClicked: plugin.openPlaces(true)
                    }
                    LocationButton {
                        Layout.fillWidth: true
                        Layout.minimumHeight: plugin.touchHeight
                        enabled: !!plugin.currentPosition && plugin.canAddStop
                        text: plugin.needsOrigin || !plugin.stops.length ? "現在地を出発地にする" : "現在地を次の地点に追加"
                        onClicked: plugin.addPosition(plugin.currentPosition, "現在地")
                    }
                    Label {
                        Layout.fillWidth: true
                        visible: !plugin.currentPosition
                        wrapMode: Text.Wrap
                        text: plugin.gnss && plugin.gnss.active ? "現在地の測位を待っています。" : "現在地を使うにはQFieldの測位をオンにしてください。"
                        color: QfTheme.secondaryTextColor
                        font: QfTheme.tipFont
                    }
                    LocationButton {
                        text: "地図をタップして地点を追加"
                        Layout.fillWidth: true
                        Layout.minimumHeight: plugin.touchHeight
                        enabled: plugin.canAddStop
                        onClicked: {
                            panel.close()
                            plugin.picking = true
                            plugin.window.displayToast("訪問順に地図をタップしてください。2地点以上で地図から経路を検索できます。")
                        }
                    }
                    LocationButton {
                        id: layerToggle
                        checkable: true
                        Layout.fillWidth: true
                        text: checked ? "レイヤから追加 ▴" : "レイヤから追加 ▾"
                    }
                    Label { id: layerLabel; text: "地物を選ぶレイヤ"; visible: layerToggle.checked }
                    ComboBox {
                        id: layers
                        visible: layerToggle.checked
                        Layout.fillWidth: true
                        Accessible.name: layerLabel.text
                        model: QfMapLayerModel { project: qgisProject; filters: Qgis.LayerFilters.HasGeometry }
                        textRole: "Name"
                        valueRole: "LayerPointer"
                        displayText: count ? currentText : "対象のレイヤがありません"
                    }
                    LocationButton {
                        visible: layerToggle.checked
                        text: "レイヤの地物を選択"
                        Layout.fillWidth: true
                        Layout.minimumHeight: plugin.touchHeight
                        enabled: !!layers.currentValue && plugin.canAddStop
                        onClicked: {
                            matches.setFeatures(layers.currentValue, "")
                            features.open()
                        }
                    }
                    SectionTitle {
                        Layout.topMargin: 8
                        text: "訪問順（" + plugin.stops.length + " / " + plugin.maxStops + "）"
                    }
                    Label {
                        visible: plugin.reorderable
                        Layout.fillWidth: true
                        wrapMode: Text.Wrap
                        text: "左の番号を上下にドラッグして並べ替え"
                        color: QfTheme.secondaryTextColor
                    }
                    Repeater {
                        id: stopRows
                        property int dragIndex: -1
                        property real pressY
                        property real pointerY
                        property real startScroll
                        readonly property real offset: dragIndex < 0 ? 0 :
                            pointerY - pressY + form.contentItem.contentY - startScroll
                        readonly property int targetIndex: {
                            if (dragIndex < 0 || dragIndex >= count) return -1
                            const held = itemAt(dragIndex)
                            const center = held.y + held.height / 2 + offset
                            let target = dragIndex
                            while (target < count - 1 && center > midpoint(target + 1)) ++target
                            while (target > 0 && center < midpoint(target - 1)) --target
                            return target
                        }
                        function midpoint(index) {
                            const item = itemAt(index)
                            return item.y + item.height / 2
                        }
                        function displacement(index) {
                            if (dragIndex < 0 || dragIndex >= count) return 0
                            const held = itemAt(dragIndex)
                            if (index === dragIndex)
                                return Math.max(itemAt(0).y - held.y,
                                    Math.min(offset, itemAt(count - 1).y + itemAt(count - 1).height - held.y - held.height))
                            const step = held.height + held.Layout.topMargin + held.parent.spacing
                            if (index > dragIndex && index <= targetIndex) return -step
                            if (index < dragIndex && index >= targetIndex) return step
                            return 0
                        }
                        model: plugin.stops.length
                        delegate: StopCard {}
                    }
                    RowLayout {
                        visible: plugin.stops.length > 0
                        enabled: !plugin.pending
                        LocationButton { text: "末尾の地点を削除"; onClicked: plugin.stops = plugin.stops.slice(0, -1) }
                        LocationButton { text: "全消去"; onClicked: plugin.stops = [] }
                    }
                }
            }
            Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: QfTheme.controlBorderColor }
            ColumnLayout {
                Layout.fillWidth: true
                Layout.margins: plugin.gutter
                spacing: 6
                ProgressBar {
                    Layout.fillWidth: true
                    visible: !!plugin.pending
                    indeterminate: visible
                    Accessible.name: "経路を検索中"
                }
                Label {
                    Layout.fillWidth: true
                    visible: text.length > 0
                    wrapMode: Text.Wrap
                    text: plugin.statusText
                    color: plugin.message ? plugin.accent : QfTheme.mainTextColor
                }
                LocationButton {
                    Layout.fillWidth: true
                    Layout.minimumHeight: 48
                    enabled: !plugin.pending && !plugin.searchHint
                    Accessible.description: plugin.statusText
                    text: plugin.pending ? "経路を検索中…" : Routes.supportsWaypoints(plugin.travelMode.id)
                          ? "指定順で最短経路を検索" : plugin.travelMode.label + "の経路を検索"
                    topInset: 0
                    bottomInset: 0
                    font: QfTheme.strongTitleFont
                    primary: true
                    onClicked: plugin.search()
                }
            }
        }
    }

    Timer {
        interval: 24
        repeat: true
        running: stopRows.dragIndex >= 0 && (stopRows.pointerY < plugin.touchHeight ||
            stopRows.pointerY > form.height - plugin.touchHeight)
        onTriggered: {
            const view = form.contentItem
            const first = stopRows.itemAt(0)
            const last = stopRows.itemAt(stopRows.count - 1)
            const edge = plugin.touchHeight
            const up = stopRows.pointerY < edge
            if (up && first.parent.mapToItem(form, 0, first.y).y >= 0) return
            if (!up && last.parent.mapToItem(form, 0, last.y + last.height).y <= form.height) return
            const step = edge / 5
            view.contentY = Math.max(view.originY, Math.min(view.contentY + (up ? -step : step),
                view.originY + view.contentHeight - view.height))
        }
    }

    RoutePopup {
        id: places
        property bool forRoute: false
        onAboutToHide: placeSearch.cancel()
        ColumnLayout {
            anchors.fill: parent
            spacing: 0
            PanelHeader {
                title: places.forRoute ? (plugin.needsOrigin ? "出発地を検索" : "目的地を検索") : "POI検索"
                dismissText: places.forRoute ? "戻る" : "閉じる"
                onDismissed: places.close()
            }
            PlaceSearch {
                id: placeSearch
                Layout.fillWidth: true
                Layout.fillHeight: true
                region: plugin.region
                apiKey: plugin.apiKey
                connectionHint: plugin.connectionHint
                searchCenter: plugin.mapCenter
                gutter: plugin.gutter
                touchHeight: plugin.touchHeight
                selectionHint: places.forRoute ? "経路に追加する場所を選択してください。" : "場所を選択すると地図に表示します。"
                onSettingsRequested: settingsPopup.open()
                onChosen: place => {
                    places.close()
                    if (places.forRoute) plugin.addPosition(place.position, place.label, !plugin.needsOrigin)
                    else plugin.showPlace(place)
                }
            }
        }
    }

    RoutePopup {
        id: settingsPopup
        height: Math.min(340, parent.height - 16)
        ColumnLayout {
            anchors.fill: parent
            spacing: 0
            PanelHeader { title: "接続設定"; dismissText: "完了"; onDismissed: settingsPopup.close() }
            ScrollView {
                id: settingsForm
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                padding: plugin.gutter
                contentWidth: availableWidth
                ColumnLayout {
                    width: settingsForm.availableWidth
                    Label { id: regionLabel; text: "AWS リージョン" }
                    TextField {
                        id: regionField
                        Layout.fillWidth: true
                        Accessible.name: regionLabel.text
                        text: "ap-northeast-1"
                        readOnly: !!plugin.pending
                        readonly property bool validRegion: /^[a-z]{2}(-[a-z0-9]+)+-[0-9]+$/.test(text.trim())
                        onTextEdited: plugin.message = ""
                    }
                    Label { id: keyLabel; text: "Amazon Location API キー" }
                    TextField {
                        id: keyField
                        Layout.fillWidth: true
                        Layout.bottomMargin: 12
                        Accessible.name: keyLabel.text
                        echoMode: TextInput.Password
                        readOnly: !!plugin.pending
                        onTextEdited: plugin.message = ""
                    }
                    Label {
                        Layout.fillWidth: true
                        wrapMode: Text.Wrap
                        text: plugin.connectionHint || "POI検索と経路検索で共通の設定です。"
                        color: QfTheme.secondaryTextColor
                    }
                }
            }
        }
    }

    RoutePopup {
        id: features
        onClosed: matches.clear()
        ColumnLayout {
            anchors.fill: parent
            spacing: 0
            PanelHeader { title: "地物を選択"; dismissText: "選択を終了"; onDismissed: features.close() }
            Label {
                Layout.fillWidth: true
                Layout.margins: plugin.gutter
                wrapMode: Text.Wrap
                text: plugin.atLimit ? "地点数が上限に達しました（" + plugin.maxStops + "地点）。"
                    : "訪問順に地物をタップ（現在 " + plugin.stops.length + " 地点）"
            }
            Label {
                Layout.leftMargin: plugin.gutter
                visible: matches.count === 0
                text: "このレイヤに地物はありません。"
            }
            ListView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                model: matches
                delegate: ItemDelegate {
                    width: ListView.view.width
                    implicitHeight: Math.max(plugin.touchHeight, implicitContentHeight + topPadding + bottomPadding)
                    enabled: !plugin.atLimit
                    Material.foreground: Material.accent
                    text: model.featureName || ("FID " + model.featureId)
                    onClicked: plugin.addStop(QfGeometryUtils.centroid(model.geometry), model.crs, text)
                }
                ScrollBar.vertical: ScrollBar {}
            }
        }
    }
}
