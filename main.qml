import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import org.qgis
import org.qfield.core
import org.qfield.gui
import "Routes.js" as Routes

Item {
    id: plugin
    readonly property var window: iface.mainWindow()
    readonly property var canvas: iface.mapCanvas()
    readonly property var handler: iface.findItemByObjectName("pointHandler")
    readonly property var wgs84: QfCoordinateReferenceSystemUtils.wgs84Crs()
    property var stops: []
    property var pending: null
    property bool picking: false
    property string message: ""
    readonly property string handlerName: "AmazonLocationRoutes"

    Component.onCompleted: {
        iface.addItemToPluginsToolbar(toolButton)
        handler.registerHandler(handlerName, pickPoint, QfMapCanvasPointHandler.Priority.High)
    }
    Component.onDestruction: {
        if (handler) handler.deregisterHandler(handlerName)
        cancelRequest()
    }

    function pickPoint(screenPoint, device, interaction) {
        if (!picking || interaction !== "clicked") return false
        const mapPoint = canvas.mapSettings.screenToCoordinate(screenPoint)
        addStop(mapPoint, canvas.mapSettings.destinationCrs, "地図上の地点")
        return true
    }

    function addStop(point, crs, label) {
        if (stops.length >= Routes.maxStops) {
            window.displayToast("指定できる地点は25件までです。")
            return
        }
        const p = QfGeometryUtils.reprojectPointToWgs84(point, crs)
        if (!Routes.validPosition([p.x, p.y])) {
            window.displayToast("地点の座標を取得できませんでした。")
            return
        }
        stops = stops.concat([{ position: [p.x, p.y], label: label }])
        window.displayToast(stops.length + "番目に追加 · " + label)
    }

    function cancelRequest() {
        const request = pending
        pending = null
        timeout.stop()
        if (request) request.abort()
    }

    onStopsChanged: {
        cancelRequest()
        route.geometryWrapper.clear()
        message = ""
    }

    function search() {
        const region = regionField.text.trim()
        const key = keyField.text.trim()
        if (!/^[a-z]{2}(-[a-z0-9]+)+-[0-9]+$/.test(region) || !key) {
            message = "AWS リージョンと API キーを入力してください。"
            return
        }
        const body = Routes.requestBody(stops)
        const legCount = stops.length - 1
        const request = new XMLHttpRequest()
        pending = request
        message = "経路を検索中…"
        request.onreadystatechange = function() {
            if (request.readyState !== XMLHttpRequest.DONE || pending !== request) return
            pending = null
            timeout.stop()
            if (request.status !== 200) {
                message = request.status === 0 ? "通信できません。接続を確認してください。"
                    : "検索できませんでした（HTTP " + request.status + "）。地点、リージョン、キーの権限を確認してください。"
                return
            }
            try {
                const data = JSON.parse(request.responseText)
                const geometry = QfGeometryUtils.createGeometryFromWkt(Routes.routeWkt(data, legCount))
                route.geometryWrapper.crs = wgs84
                route.geometryWrapper.qgsGeometry = geometry
                const projected = QfGeometryUtils.reprojectGeometry(geometry, wgs84, canvas.mapSettings.destinationCrs)
                iface.setMapExtent(QfGeometryUtils.boundingBox(projected))
                message = stops.length + "地点の経路を表示しました。"
                panel.close()
                window.displayToast(message)
            } catch (error) {
                message = error.message
            }
        }
        try {
            request.open("POST", "https://routes.geo." + region + ".amazonaws.com/v2/routes?key=" + encodeURIComponent(key))
            request.setRequestHeader("Content-Type", "application/json")
            timeout.start()
            request.send(JSON.stringify(body))
        } catch (error) {
            cancelRequest()
            message = "検索を開始できませんでした。"
        }
    }

    Timer {
        id: timeout
        interval: 45000
        onTriggered: {
            plugin.cancelRequest()
            plugin.message = "応答がありません。接続を確認して再検索してください。"
        }
    }

    Connections {
        target: iface
        function onLoadProjectTriggered() {
            plugin.picking = false
            features.close()
            panel.close()
            matches.clear()
            plugin.stops = []
        }
    }

    QfToolButton {
        id: toolButton
        round: true
        bgcolor: QfTheme.darkGray
        iconSource: Qt.resolvedUrl("icon.svg")
        iconColor: QfTheme.mainColor
        Accessible.name: "Amazon Location 経路検索"
        onClicked: {
            plugin.picking = false
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
        Repeater {
            model: plugin.stops
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
                width: 24
                height: width
                radius: width / 2
                x: marker.screenPoint.x - width / 2
                y: marker.screenPoint.y - height / 2
                color: "#124d68"
                border.color: "white"
                Text { anchors.centerIn: parent; text: index + 1; color: "white" }
            }
        }
    }

    QfMultiFeatureListModel { id: matches }

    Popup {
        id: panel
        parent: plugin.window.contentItem
        anchors.centerIn: parent
        width: Math.min(420, parent.width - 16)
        height: Math.min(560, parent.height - 16)
        modal: true
        ScrollView {
            anchors.fill: parent
            contentWidth: availableWidth
            ColumnLayout {
                width: parent.width
                Label { text: "Amazon Location 経路検索"; font.bold: true }
                Label { text: "AWS リージョン" }
                TextField { id: regionField; Layout.fillWidth: true; text: "ap-northeast-1" }
                Label { text: "Amazon Location API キー" }
                TextField { id: keyField; Layout.fillWidth: true; echoMode: TextInput.Password }
                Button {
                    text: "地図をタップして地点を追加"
                    onClicked: {
                        panel.close()
                        plugin.picking = true
                        plugin.window.displayToast("訪問順に地図をタップし、経路ボタンで戻ってください。")
                    }
                }
                Label { text: "地物を選ぶレイヤ" }
                ComboBox {
                    id: layers
                    Layout.fillWidth: true
                    model: QfMapLayerModel { project: qgisProject; filters: Qgis.LayerFilters.HasGeometry }
                    textRole: "Name"
                    valueRole: "LayerPointer"
                }
                Button {
                    text: "レイヤの地物を選択"
                    enabled: !!layers.currentValue
                    onClicked: {
                        matches.setFeatures(layers.currentValue, "")
                        features.open()
                    }
                }
                Label { text: "訪問順（" + plugin.stops.length + " / " + Routes.maxStops + "）" }
                Repeater {
                    model: plugin.stops
                    Label {
                        required property int index
                        required property var modelData
                        Layout.fillWidth: true
                        elide: Text.ElideRight
                        text: (index + 1) + ". " + modelData.label + "  "
                            + modelData.position[1].toFixed(5) + ", " + modelData.position[0].toFixed(5)
                    }
                }
                RowLayout {
                    Button { text: "1件戻す"; enabled: plugin.stops.length > 0; onClicked: plugin.stops = plugin.stops.slice(0, -1) }
                    Button { text: "全消去"; enabled: plugin.stops.length > 0; onClicked: plugin.stops = [] }
                }
                Button { text: "指定順で最短経路を検索"; enabled: plugin.stops.length >= 2 && !plugin.pending; onClicked: plugin.search() }
                Label { Layout.fillWidth: true; wrapMode: Text.Wrap; text: plugin.message; visible: text.length > 0 }
                Button { text: "閉じる"; onClicked: panel.close() }
            }
        }
    }

    Popup {
        id: features
        parent: plugin.window.contentItem
        anchors.centerIn: parent
        width: panel.width
        height: panel.height
        modal: true
        onClosed: matches.clear()
        ColumnLayout {
            anchors.fill: parent
            Label { text: "訪問順に地物をタップ（現在 " + plugin.stops.length + " 地点）" }
            Label { visible: matches.count === 0; text: "このレイヤに地物はありません。" }
            ListView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                model: matches
                delegate: ItemDelegate {
                    width: ListView.view.width
                    text: model.featureName || ("FID " + model.featureId)
                    onClicked: plugin.addStop(QfGeometryUtils.centroid(model.geometry), model.crs, text)
                }
            }
            Button { text: "選択を終了"; onClicked: features.close() }
        }
    }
}
