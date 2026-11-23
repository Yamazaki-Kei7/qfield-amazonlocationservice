import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts
import QtQml.Models
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
    property string routePreference: "ShortestRoute"
    readonly property string routeCriterion: Routes.routeCriterion(travelMode.id, routePreference)
    property string visitOrderOverride: ""
    readonly property string visitOrderCriterion: visitOrderOverride || routeCriterion
    // Optimizing the visit order always keeps the first stop; this keeps the last one too.
    property bool fixedEnd: false
    // The order replaced by the last optimization, for as long as it can be restored.
    property var undoStops: null
    property string optimizeNote: ""
    property string routeSummary: ""
    property bool summaryDismissed: false
    property alias showRouteStops: stopsSwitch.checked
    property alias showRouteLine: routeLineSwitch.checked
    readonly property var pending: routeRequest.pending || optimizeRequest.pending
    readonly property bool optimizing: !!optimizeRequest.pending
    property string pickMode: ""
    readonly property bool picking: pickMode !== ""
    readonly property bool pickingPoint: pickMode === "point"
    readonly property bool pickingFeatures: pickMode === "features"
    property var featureLayer: null
    readonly property bool featureLayerVisible: !!featureLayer && canvas.mapSettings.layers.includes(featureLayer)
    onPickModeChanged: {
        if (pickMode !== "features") {
            featureLayer = null
            mapHits.clear()
        }
    }
    property string message: ""
    readonly property string handlerName: "AmazonLocationRoutes"
    readonly property string serviceName: "Amazon Location Service"
    readonly property url serviceIcon: Qt.resolvedUrl("Arch_Amazon-Location-Service_32.svg")

    readonly property var colors: Colors.forTheme(QfTheme.darkTheme)
    readonly property int gutter: 16
    readonly property int stopMarkerSize: 24
    readonly property int touchHeight: 44
    readonly property real overlayBottomMargin: Math.max(window.sceneBottomMargin, canvas.bottomMargin) + gutter
    readonly property string region: regionField.text.trim()
    readonly property string apiKey: keyField.text.trim()
    readonly property int maxStops: Routes.stopLimit(travelMode.id)
    readonly property bool atLimit: stops.length >= maxStops
    readonly property string limitText: qsTranslate("AmazonLocationService", "%1 supports up to %2 stops.").arg(travelMode.label).arg(maxStops)
    readonly property bool canAddStop: !atLimit && !pending
    readonly property bool reorderable: stops.length > 1
    readonly property bool optimizable: Routes.supportsWaypoints(travelMode.id)
        && stops.length >= Routes.minOptimizeStops(false)
    readonly property bool canOptimize: optimizable && stops.length >= Routes.minOptimizeStops(fixedEnd)
        && !connectionHint && !pending
    readonly property string statusText: message || searchHint
    readonly property string searchHint: {
        if (stops.length > maxStops) return qsTranslate("AmazonLocationService", "%1 supports up to %2 stops. Remove stops or change the travel mode.").arg(travelMode.label).arg(maxStops)
        if (stops.length === 0) return qsTranslate("AmazonLocationService", "Add an origin and destination in visit order.")
        if (needsOrigin) return qsTranslate("AmazonLocationService", "Destination selected. Add an origin.")
        if (stops.length === 1) return qsTranslate("AmazonLocationService", "Add one more stop as the destination.")
        return connectionHint
    }
    readonly property string connectionHint: {
        if (!regionField.validRegion) return qsTranslate("AmazonLocationService", "Enter an AWS Region (e.g. ap-northeast-1).")
        if (!apiKey) return qsTranslate("AmazonLocationService", "Enter an Amazon Location API key.")
        return ""
    }

    Component.onCompleted: {
        iface.addItemToPluginsToolbar(searchGroup)
        handler.registerHandler(handlerName, pickPoint, QfMapCanvasPointHandler.Priority.High)
    }
    Component.onDestruction: {
        if (handler) handler.deregisterHandler(handlerName)
    }

    function pickPoint(screenPoint, device, interaction) {
        if (interaction !== "clicked" || !picking) return false
        if (pickingFeatures) identifyFeature(screenPoint)
        else addMapPoint(screenPoint)
        return true
    }

    function addMapPoint(screenPoint) {
        const mapPoint = canvas.mapSettings.screenToCoordinate(screenPoint)
        addStop(mapPoint, canvas.mapSettings.destinationCrs, qsTranslate("AmazonLocationService", "Map point"))
    }

    function identifyFeature(screenPoint) {
        if (!canAddStop || !featureLayerVisible) return
        const map = canvas.mapSettings
        // Identify only the chosen layer, using the current map scale and touch location.
        hitSettings.layers = [featureLayer]
        hitSettings.destinationCrs = map.destinationCrs
        hitSettings.outputSize = map.outputSize
        hitSettings.outputDpi = map.outputDpi
        hitSettings.extent = map.extent
        hitSettings.rotation = map.rotation
        hitSettings.isTemporal = map.isTemporal
        hitSettings.temporalBegin = map.temporalBegin
        hitSettings.temporalEnd = map.temporalEnd
        hitTool.identify(hitSettings.coordinateToScreen(map.screenToCoordinate(screenPoint)))
        if (mapHits.count === 1) {
            addFeature(hitChoices.items.get(0).model)
            mapHits.clear()
        } else if (!mapHits.count) {
            window.displayToast(qsTranslate("AmazonLocationService", "No feature from %1 here. Try another spot.").arg(featureLayer.name))
        } else {
            candidateList.positionViewAtBeginning()
        }
    }

    function featureKey(feature) {
        return feature.currentLayer ? feature.currentLayer.id + ":" + feature.featureId : ""
    }

    function featureLabel(feature) {
        return feature.featureName || ("FID " + feature.featureId)
    }

    function addFeature(feature) {
        addStop(QfGeometryUtils.centroid(feature.geometry), feature.crs, featureLabel(feature), featureKey(feature))
    }

    function toWgs84(point, crs) {
        const p = QfGeometryUtils.reprojectPointToWgs84(point, crs)
        return [p.x, p.y]
    }

    function toMapCrs(position) {
        const p = QfGeometryUtils.point(position[0], position[1])
        return QfGeometryUtils.reprojectPoint(p, wgs84, canvas.mapSettings.destinationCrs)
    }

    function addStop(point, crs, label, featureKey = "") {
        addPosition(toWgs84(point, crs), label, false, featureKey)
    }

    function addPosition(position, label, asDestination = false, featureKey = "") {
        if (pending) return
        if (atLimit) {
            window.displayToast(limitText)
            return
        }
        // QML list delegates can supply a QVariantList instead of a JavaScript array.
        const coordinates = position && [position[0], position[1]]
        if (!Routes.validPosition(coordinates)) {
            window.displayToast(qsTranslate("AmazonLocationService", "Could not get coordinates for this stop."))
            return
        }
        const stop = { position: coordinates, label: label, featureKey: featureKey }
        if (asDestination && (!stops.length || needsOrigin)) {
            needsOrigin = true
            stops = [stop]
        } else if (needsOrigin) {
            needsOrigin = false
            stops = [stop].concat(stops)
        } else {
            stops = stops.concat([stop])
        }
        window.displayToast(qsTranslate("AmazonLocationService", "Added %1 to the route.").arg(label))
    }

    function mapCenter() {
        return toWgs84(canvas.mapSettings.center, canvas.mapSettings.destinationCrs)
    }

    function showPlace(place) {
        preview = place
        canvas.mapSettings.setCenter(toMapCrs(place.position), true)
    }

    function backToPanel() {
        pickMode = ""
        panel.open()
    }

    function openPlaces(forRoute) {
        pickMode = ""
        preview = null
        places.forRoute = forRoute
        placeSearch.reset()
        places.open()
    }

    function usePreview() {
        if (!preview || !canAddStop) return
        const place = preview
        preview = null
        if (!stops.length && currentPosition) addPosition(currentPosition, qsTranslate("AmazonLocationService", "Current location"))
        addPosition(place.position, place.label, true)
        panel.open()
    }

    function removeStop(index) {
        if (pending || index < 0 || index >= stops.length) return
        const remaining = stops.slice()
        const removed = remaining.splice(index, 1)[0]
        stops = remaining
        window.displayToast(qsTranslate("AmazonLocationService", "Removed %1 from the route.").arg(removed.label))
    }

    function moveStop(from, to) {
        if (pending || from < 0 || from >= stops.length || to < 0 || to >= stops.length || from === to) return
        const reordered = stops.slice()
        const stop = reordered.splice(from, 1)[0]
        reordered.splice(to, 0, stop)
        stops = reordered
    }

    function stopRole(index) {
        if (needsOrigin) return qsTranslate("AmazonLocationService", "Destination")
        if (index === 0) return qsTranslate("AmazonLocationService", "Origin")
        return index === stops.length - 1 ? qsTranslate("AmazonLocationService", "Destination") : qsTranslate("AmazonLocationService", "Stop")
    }

    onStopsChanged: {
        if (!stops.length) needsOrigin = false
        if (stopRows) stopRows.dragIndex = -1
        undoStops = null
        clearRoute()
    }
    onTravelModeChanged: clearRoute()
    onRoutePreferenceChanged: clearRoute()
    onVisitOrderOverrideChanged: {
        optimizeNote = ""
        message = ""
    }
    onFixedEndChanged: optimizeNote = ""

    function clearRoute() {
        routeRequest.cancel()
        optimizeRequest.cancel()
        route.geometryWrapper.clear()
        routeSummary = ""
        message = ""
        optimizeNote = ""
    }

    onMessageChanged: {
        if (picking && message) window.displayToast(message)
    }

    function fitRouteOnMap(geometry) {
        const settings = canvas.mapSettings
        const projected = QfGeometryUtils.reprojectGeometry(geometry, wgs84, settings.destinationCrs)
        const bounds = QfGeometryUtils.boundingBox(projected)
        // A selected stop can be outside the route when the service snaps it to a road.
        for (const stop of stops) {
            const p = toMapCrs(stop.position)
            bounds.xMinimum = Math.min(bounds.xMinimum, p.x)
            bounds.xMaximum = Math.max(bounds.xMaximum, p.x)
            bounds.yMinimum = Math.min(bounds.yMinimum, p.y)
            bounds.yMaximum = Math.max(bounds.yMaximum, p.y)
        }

        // Measure the bounds along the screen axes, including when the map is rotated.
        const angle = settings.rotation * Math.PI / 180
        const cos = Math.abs(Math.cos(angle))
        const sin = Math.abs(Math.sin(angle))
        const inset = stopMarkerSize / 2 + gutter
        // Fit the numbered stops in the part of the map above the result card.
        const cardTop = resultCard.mapToItem(canvas, 0, 0).y
        const covered = Math.max(0, Math.min(canvas.height - 2 * inset - 1, canvas.height - cardTop))
        const unitsPerPoint = Math.max(
            (bounds.width * cos + bounds.height * sin) / Math.max(1, canvas.width - 2 * inset),
            (bounds.width * sin + bounds.height * cos) / Math.max(1, canvas.height - covered - 2 * inset))
        const center = bounds.center
        if (!unitsPerPoint) {
            settings.setCenter(QfGeometryUtils.point(center.x, center.y))
            return
        }
        const halfWidth = unitsPerPoint * canvas.width / 2
        const halfHeight = unitsPerPoint * canvas.height / 2
        const shift = covered * unitsPerPoint / 2
        const x = center.x + Math.sin(angle) * shift
        const y = center.y - Math.cos(angle) * shift
        iface.setMapExtent(QfGeometryUtils.createRectangleFromPoints(
            QfGeometryUtils.point(x - halfWidth, y - halfHeight),
            QfGeometryUtils.point(x + halfWidth, y + halfHeight)))
    }

    function search() {
        if (pending || searchHint) return
        const body = Routes.requestBody(stops, travelMode.id, routePreference)
        message = ""
        routeRequest.post("routes", "routes", body, text => {
            try {
                const data = JSON.parse(text)
                const geometry = QfGeometryUtils.createGeometryFromWkt(Routes.routeWkt(data, body))
                route.geometryWrapper.crs = wgs84
                route.geometryWrapper.qgsGeometry = geometry
                routeSummary = Routes.routeSummary(data.Routes[0])
                summaryDismissed = false
                pickMode = ""
                panel.close()
                fitRouteOnMap(geometry)
            } catch (error) {
                message = error instanceof SyntaxError ? qsTranslate("AmazonLocationService", "Could not read the route response.") : error.message
            }
        })
    }

    function optimize() {
        if (!canOptimize) return
        const before = stops
        const fixed = fixedEnd
        message = ""
        const body = Routes.optimizeBody(before, travelMode.id, fixed, visitOrderCriterion)
        optimizeRequest.post("routes", "optimize-waypoints", body, text => {
            try {
                const result = Routes.optimizedStops(JSON.parse(text), before, fixed)
                if (result.changed) {
                    // Changing the stops clears the undo order and the note, so both are set afterwards.
                    stops = result.stops
                    undoStops = before
                }
                optimizeNote = (result.changed ? qsTranslate("AmazonLocationService", "Visit order optimized%1.") : qsTranslate("AmazonLocationService", "Visit order is already optimal%1.")).arg(result.summary)
            } catch (error) {
                message = error instanceof SyntaxError ? qsTranslate("AmazonLocationService", "Could not read the optimization result.") : error.message
            }
        })
    }

    function undoOptimize() {
        if (pending || !undoStops) return
        stops = undoStops
    }

    LocationRequest {
        id: routeRequest
        region: plugin.region
        apiKey: plugin.apiKey
        onFailed: reason => plugin.message = reason
        onRejected: (status, responseText) => plugin.message = Routes.rejection(qsTranslate("AmazonLocationService", "Could not find a route"), status, responseText)
    }

    LocationRequest {
        id: optimizeRequest
        region: plugin.region
        apiKey: plugin.apiKey
        onFailed: reason => plugin.message = reason
        onRejected: status => plugin.message = Routes.optimizeRejection(status, plugin.stops)
    }

    Connections {
        target: iface
        function onLoadProjectTriggered() {
            plugin.pickMode = ""
            settingsPopup.close()
            places.close()
            plugin.preview = null
            features.close()
            panel.close()
            matches.clear()
            plugin.stops = []
        }
    }

    component SearchToolButton: QfToolButton {
        anchors.horizontalCenter: parent.horizontalCenter
        round: true
        bgcolor: Colors.blue
        opacity: enabled ? 1 : 0.4
        Accessible.name: text
        display: AbstractButton.IconOnly
        ToolTip.text: text
        ToolTip.visible: hovered || pressed
        ToolTip.delay: serviceButton.ToolTip.delay
    }

    component MapVisibilitySwitch: Switch {
        id: control
        checked: true
        anchors.horizontalCenter: parent.horizontalCenter
        implicitWidth: Math.max(plugin.touchHeight, caption.implicitWidth + 8)
        implicitHeight: Math.max(plugin.touchHeight, caption.contentHeight + track.height + 6)
        padding: 0
        indicator: Rectangle {
            id: track
            anchors.horizontalCenter: parent.horizontalCenter
            y: (control.height + caption.contentHeight - height) / 2 + 2
            width: 32
            height: 18
            radius: height / 2
            color: control.checked ? Colors.orange : Colors.capsuleSurface
            border.color: control.checked ? Colors.orange : Colors.capsuleBorder
            Rectangle {
                x: control.checked ? parent.width - width - 3 : 3
                anchors.verticalCenter: parent.verticalCenter
                width: 12
                height: width
                radius: width / 2
                color: control.checked ? Colors.ink : "white"
                Behavior on x { NumberAnimation { duration: 100 } }
            }
        }
        contentItem: Label {
            id: caption
            text: control.text
            font: QfTheme.tipFont
            color: "white"
            bottomPadding: track.height + 4
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
        }
    }

    Item {
        id: searchGroup
        implicitWidth: capsule.width + 8
        implicitHeight: capsule.height + 8
        Rectangle {
            id: capsule
            x: 4
            y: 4
            width: serviceButton.checked ? Math.max(serviceButton.width, menu.implicitWidth) + 8 : serviceButton.width
            height: serviceButton.height + (serviceButton.checked ? menu.implicitHeight + 10 : 0)
            radius: width / 2
            color: Colors.ink
            border.color: serviceButton.checked ? Colors.capsuleBorder : "transparent"
            QfToolButton {
                id: serviceButton
                anchors.horizontalCenter: parent.horizontalCenter
                readonly property int logoSize: Math.round(width * 0.7)
                round: true
                checkable: true
                bgcolor: Colors.serviceRed
                padding: 0
                iconSource: plugin.serviceIcon
                iconColor: "transparent"
                icon.width: logoSize
                icon.height: logoSize
                bottomRightIndicatorText: plugin.picking ? String(plugin.stops.length) : ""
                bottomRightIndicatorBgColor: Colors.orange
                bottomRightIndicatorFgColor: Colors.ink
                statusBadge.bottomMargin: 0
                statusBadge.rightMargin: 0
                Accessible.name: plugin.serviceName
                Accessible.description: checked ? qsTranslate("AmazonLocationService", "Close map tools") : qsTranslate("AmazonLocationService", "Open map tools")
                ToolTip.text: plugin.serviceName
                ToolTip.visible: hovered && !checked
                ToolTip.delay: 600
            }
            Column {
                id: menu
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.top: serviceButton.bottom
                spacing: 4
                visible: serviceButton.checked
                SearchToolButton {
                    text: qsTranslate("AmazonLocationService", "Place Search")
                    iconSource: Qt.resolvedUrl("poi-search.svg")
                    enabled: !plugin.pending
                    onClicked: plugin.openPlaces(false)
                }
                SearchToolButton {
                    text: qsTranslate("AmazonLocationService", "Route Search")
                    iconSource: Qt.resolvedUrl("icon.svg")
                    onClicked: {
                        plugin.pickMode = ""
                        plugin.preview = null
                        panel.open()
                    }
                }
                Rectangle {
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: serviceButton.width / 2
                    height: 1
                    color: Colors.capsuleBorder
                }
                MapVisibilitySwitch {
                    id: stopsSwitch
                    text: qsTranslate("AmazonLocationService", "Stops")
                }
                MapVisibilitySwitch {
                    id: routeLineSwitch
                    text: qsTranslate("AmazonLocationService", "Route line")
                }
            }
        }
    }

    QfGeometryRenderer {
        id: route
        visible: plugin.showRouteLine
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
                visible: isPlace || plugin.showRouteStops
                width: isPlace ? 30 : plugin.stopMarkerSize
                height: width
                radius: width / 2
                x: marker.screenPoint.x - width / 2
                y: marker.screenPoint.y - height / 2
                color: isPlace ? Colors.blue : Colors.ink
                border.color: "white"
                Text { anchors.centerIn: parent; text: isPlace ? "●" : index + 1; color: "white" }
            }
        }
        Image {
            id: aim
            anchors.centerIn: parent
            visible: plugin.pickingPoint && plugin.canAddStop
            source: Qt.resolvedUrl("icons/Crosshair.svg")
            Accessible.ignored: true
        }
    }

    MapCard {
        visible: !!plugin.preview
        padding: 12
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
                CloseButton {
                    Accessible.name: qsTranslate("AmazonLocationService", "Close place details")
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
            ColumnLayout {
                Layout.fillWidth: true
                LocationButton {
                    text: plugin.atLimit ? qsTranslate("AmazonLocationService", "Stop limit reached") :
                        !plugin.stops.length && plugin.currentPosition ? qsTranslate("AmazonLocationService", "Route from current location") :
                        plugin.stops.length && !plugin.needsOrigin ? qsTranslate("AmazonLocationService", "Add as destination") : qsTranslate("AmazonLocationService", "Route to here")
                    Layout.fillWidth: true
                    leftPadding: 8
                    rightPadding: 8
                    enabled: plugin.canAddStop
                    Layout.minimumHeight: plugin.touchHeight
                    primary: true
                    onClicked: plugin.usePreview()
                }
                LocationButton {
                    text: qsTranslate("AmazonLocationService", "Back to results")
                    Layout.fillWidth: true
                    onClicked: {
                        plugin.preview = null
                        places.open()
                    }
                }
            }
        }
    }

    QfMultiFeatureListModel { id: matches }

    MapSettings { id: hitSettings; project: qgisProject }
    QfMultiFeatureListModel { id: mapHits }
    QfIdentifyTool { id: hitTool; mapSettings: hitSettings; model: mapHits }
    DelegateModel {
        id: hitChoices
        model: mapHits
        delegate: ItemDelegate {
            width: ListView.view.width
            implicitHeight: Math.max(plugin.touchHeight, implicitContentHeight + topPadding + bottomPadding)
            enabled: plugin.canAddStop
            text: model.featureName ? model.featureName + " · FID " + model.featureId : "FID " + model.featureId
            contentItem: Label {
                text: parent.text
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                color: QfTheme.mainTextColor
            }
            onClicked: {
                plugin.addFeature(model)
                mapHits.clear()
            }
        }
    }

    MapCard {
        visible: plugin.pickingFeatures
        clearsCornerControls: true
        padding: 8
        contentItem: ColumnLayout {
            Label {
                Layout.fillWidth: true
                font: QfTheme.strongResultFont
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                text: plugin.featureLayer ? plugin.featureLayer.name : ""
            }
            Label {
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                text: !plugin.featureLayerVisible ? qsTranslate("AmazonLocationService", "Show this layer on the map to select its features.")
                    : plugin.atLimit ? plugin.limitText
                    : candidateList.count > 1 ? qsTranslate("AmazonLocationService", "Choose a feature to add, or tap elsewhere.")
                    : qsTranslate("AmazonLocationService", "Tap a feature to add it to the route.")
            }
            ListView {
                id: candidateList
                Layout.fillWidth: true
                Layout.preferredHeight: Math.min(contentHeight, plugin.canvas.height / 4)
                visible: candidateList.count > 1 && plugin.featureLayerVisible
                clip: true
                model: hitChoices
                ScrollBar.vertical: ScrollBar {}
            }
            RowLayout {
                Layout.fillWidth: true
                LocationButton {
                    Layout.fillWidth: true
                    Layout.minimumHeight: plugin.touchHeight
                    text: qsTranslate("AmazonLocationService", "Back to list")
                    onClicked: {
                        plugin.backToPanel()
                        features.open()
                    }
                }
                LocationButton {
                    Layout.fillWidth: true
                    Layout.minimumHeight: plugin.touchHeight
                    primary: true
                    text: qsTranslate("AmazonLocationService", "Done")
                    onClicked: plugin.backToPanel()
                }
            }
        }
    }

    MapCard {
        id: resultCard
        visible: !!plugin.routeSummary && !plugin.summaryDismissed && !plugin.picking && !plugin.preview
                 && !panel.visible && !places.visible
        width: Math.min(implicitWidth, parent.width - 2 * plugin.gutter)
        clearsCornerControls: true
        padding: 8
        contentItem: RowLayout {
            ColumnLayout {
                Layout.fillWidth: true
                Layout.leftMargin: 4
                spacing: 2
                Label {
                    Layout.fillWidth: true
                    text: qsTranslate("AmazonLocationService", "%1 · %2 stops").arg(plugin.travelMode.label).arg(plugin.stops.length)
                    font: QfTheme.tipFont
                    color: QfTheme.secondaryTextColor
                    wrapMode: Text.Wrap
                }
                Label {
                    Layout.fillWidth: true
                    text: plugin.routeSummary
                    font: QfTheme.strongResultFont
                    color: QfTheme.mainTextColor
                    wrapMode: Text.Wrap
                }
            }
            CloseButton {
                Accessible.name: qsTranslate("AmazonLocationService", "Close route summary")
                onClicked: plugin.summaryDismissed = true
            }
        }
    }

    MapCard {
        id: guide
        clearsCornerControls: true
        visible: plugin.pickingPoint
        padding: 8
        contentItem: ColumnLayout {
            spacing: 0
            RowLayout {
                Layout.fillWidth: true
                Label {
                    Layout.fillWidth: true
                    Layout.leftMargin: 4
                    wrapMode: Text.Wrap
                    color: QfTheme.mainTextColor
                    text: plugin.pending ? qsTranslate("AmazonLocationService", "Finding route…")
                        : plugin.atLimit ? plugin.limitText
                        : !plugin.stops.length || plugin.needsOrigin ? qsTranslate("AmazonLocationService", "Tap the origin on the map, or move the map to align it with the crosshair.")
                        : qsTranslate("AmazonLocationService", "Tap the next destination, or move the map to align it with the crosshair.")
                }
                LocationButton {
                    text: qsTranslate("AmazonLocationService", "Back")
                    Layout.minimumHeight: plugin.touchHeight
                    enabled: !plugin.pending
                    onClicked: plugin.backToPanel()
                }
            }
            GridLayout {
                Layout.fillWidth: true
                columns: centerButton.implicitWidth + columnSpacing + mapRouteButton.implicitWidth <= width ? 2 : 1
                rowSpacing: 0
                LocationButton {
                    id: centerButton
                    Layout.fillWidth: true
                    Layout.minimumHeight: plugin.touchHeight
                    enabled: plugin.canAddStop
                    primary: !mapRouteButton.visible
                    text: qsTranslate("AmazonLocationService", "Add at center")
                    icon.source: Qt.resolvedUrl("icons/MapPin.svg")
                    onClicked: plugin.addMapPoint(aim.mapToItem(plugin.canvas, aim.width / 2, aim.height / 2))
                }
                LocationButton {
                    id: mapRouteButton
                    Layout.fillWidth: true
                    Layout.minimumHeight: plugin.touchHeight
                    visible: plugin.stops.length >= 2
                    enabled: !plugin.pending
                    text: plugin.pending ? qsTranslate("AmazonLocationService", "Finding route…") : plugin.searchHint ? qsTranslate("AmazonLocationService", "Enter settings") : qsTranslate("AmazonLocationService", "Find route")
                    Accessible.description: plugin.statusText
                    primary: true
                    onClicked: {
                        if (plugin.searchHint) {
                            plugin.backToPanel()
                            settingsPopup.open()
                        } else {
                            plugin.search()
                        }
                    }
                }
            }
        }
    }

    component MapCard: Pane {
        // On narrow maps, keep the card above QField's bottom corner controls.
        property bool clearsCornerControls: false
        parent: plugin.canvas.parent
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: plugin.overlayBottomMargin + (clearsCornerControls && parent.width - width < 2 * (plugin.touchHeight + plugin.gutter) ? plugin.touchHeight : 0)
        width: Math.min(410, parent.width - 2 * plugin.gutter)
        background: Rectangle { radius: 8; color: QfTheme.groupBoxSurfaceColor; border.color: QfTheme.controlBorderColor }
    }

    component CloseButton: LocationButton {
        text: "×"
        horizontalPadding: 0
        leftPadding: horizontalPadding
        rightPadding: horizontalPadding
        Layout.minimumWidth: plugin.touchHeight
        Layout.minimumHeight: plugin.touchHeight
    }

    component RoutePopup: Popup {
        parent: plugin.window.contentItem
        anchors.centerIn: parent
        width: Math.min(440, parent.width - 16)
        height: Math.min(640, parent.height - 16)
        padding: 0
        modal: true
        focus: true
        Material.accent: plugin.colors.selected.background
    }

    component PanelHeader: Rectangle {
        id: header
        property string title
        property string dismissText: qsTranslate("AmazonLocationService", "Close")
        property bool primaryDismiss: false
        property alias actions: headerActions.data
        signal dismissed()
        Layout.fillWidth: true
        implicitHeight: headerRow.implicitHeight + 16
        color: Colors.ink
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
                Layout.minimumWidth: 0
                spacing: 1
                Label { Layout.fillWidth: true; text: plugin.serviceName; color: "white"; font: QfTheme.tipFont; wrapMode: Text.Wrap }
                Label { Layout.fillWidth: true; text: header.title; color: "white"; font: QfTheme.strongTitleFont; wrapMode: Text.Wrap }
            }
            RowLayout {
                id: headerActions
                visible: children.length > 0
            }
            LocationButton {
                text: header.dismissText
                primary: header.primaryDismiss
                Layout.minimumHeight: plugin.touchHeight
                onClicked: header.dismissed()
            }
        }
    }

    component RouteSection: Pane {
        id: section
        required property string title
        default property alias fields: sectionLayout.data
        Layout.fillWidth: true
        Layout.minimumWidth: 0
        padding: 12
        background: Rectangle {
            radius: 8
            color: plugin.colors.surface
            border.color: QfTheme.controlBorderColor
        }
        contentItem: ColumnLayout {
            id: sectionLayout
            spacing: 4
            Label {
                Layout.fillWidth: true
                Layout.bottomMargin: 4
                text: section.title
                font: QfTheme.strongTitleFont
                wrapMode: Text.Wrap
                Accessible.role: Accessible.Heading
            }
        }
    }

    component CircleBadge: Label {
        id: badge
        property color fill
        property int minimumSize: 26
        font: QfTheme.strongResultFont
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        Layout.preferredWidth: Math.max(minimumSize, implicitWidth + 8, implicitHeight)
        Layout.preferredHeight: Layout.preferredWidth
        background: Rectangle { radius: height / 2; color: badge.fill }
    }

    component MoveButton: LocationButton {
        required property int stopIndex
        required property int step
        readonly property int target: stopIndex + step
        horizontalPadding: 0
        leftPadding: horizontalPadding
        rightPadding: horizontalPadding
        text: step < 0 ? "↑" : "↓"
        visible: plugin.reorderable
        enabled: !plugin.pending && target >= 0 && target < plugin.stops.length
        Accessible.name: (step < 0 ? qsTranslate("AmazonLocationService", "Move stop %1 up") : qsTranslate("AmazonLocationService", "Move stop %1 down")).arg(stopIndex + 1)
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
            border.color: card.held ? plugin.colors.selected.background : QfTheme.controlBorderColor
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
                    CircleBadge {
                        text: card.index + 1
                        color: "white"
                        fill: Colors.ink
                        Layout.alignment: Qt.AlignHCenter
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
                Label {
                    Layout.fillWidth: true
                    Layout.minimumWidth: 0
                    text: plugin.stopRole(card.index)
                    wrapMode: Text.Wrap
                    color: QfTheme.secondaryTextColor
                    font: QfTheme.tipFont
                }
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
            CloseButton {
                destructive: true
                enabled: !plugin.pending
                Layout.preferredWidth: plugin.touchHeight
                Accessible.name: qsTranslate("AmazonLocationService", "Remove visit %1 to %2").arg(card.index + 1).arg(card.stop ? card.stop.label : "")
                ToolTip.visible: hovered || pressed
                ToolTip.text: Accessible.name
                ToolTip.delay: 600
                onClicked: plugin.removeStop(card.index)
            }
        }
    }

    RoutePopup {
        id: panel
        onAboutToHide: {
            stopRows.dragIndex = -1
            routeRequest.cancel()
            optimizeRequest.cancel()
        }
        ColumnLayout {
            anchors.fill: parent
            spacing: 0
            PanelHeader {
                title: qsTranslate("AmazonLocationService", "Route Search")
                actions: LocationButton {
                    text: qsTranslate("AmazonLocationService", "Settings")
                    Layout.minimumHeight: plugin.touchHeight
                    enabled: !plugin.pending
                    onClicked: settingsPopup.open()
                }
                onDismissed: panel.close()
            }
            ScrollView {
                id: form
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.minimumHeight: 0
                clip: true
                contentWidth: availableWidth
                padding: 8
                background: Rectangle { color: plugin.colors.canvas }
                ColumnLayout {
                    width: form.availableWidth
                    spacing: 12
                    RouteSection {
                        title: qsTranslate("AmazonLocationService", "Travel mode")
                        GridLayout {
                            id: travelModeGrid
                            Layout.fillWidth: true
                            columns: width < 250 ? 1 : width < 390 ? 2 : 3
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
                                    Layout.preferredHeight: implicitContentHeight + verticalPadding * 2
                                    horizontalPadding: 4
                                    leftPadding: horizontalPadding
                                    rightPadding: horizontalPadding
                                    verticalPadding: 2
                                    text: modelData.label
                                    icon.source: Qt.resolvedUrl("icons/" + modelData.id + ".svg")
                                    checkable: true
                                    autoExclusive: true
                                    checked: plugin.travelMode.id === modelData.id
                                    font.bold: checked
                                    Accessible.role: Accessible.RadioButton
                                    onClicked: if (plugin.travelMode.id !== modelData.id) plugin.travelMode = modelData
                                }
                            }
                        }
                        GridLayout {
                            id: routeChoices
                            Layout.fillWidth: true
                            visible: Routes.allowsShortestRoute(plugin.travelMode.id)
                            enabled: !plugin.pending
                            columns: 2
                            rowSpacing: 0
                            Label {
                                Layout.columnSpan: routeChoices.columns
                                text: qsTranslate("AmazonLocationService", "Route preference")
                            }
                            Repeater {
                                model: Routes.routeCriteria
                                RadioButton {
                                    required property string modelData
                                    Layout.minimumHeight: plugin.touchHeight
                                    text: Routes.criterionLabel(modelData)
                                    Accessible.name: qsTranslate("AmazonLocationService", "Route preference: %1").arg(text)
                                    checked: plugin.routeCriterion === modelData
                                    onClicked: plugin.routePreference = modelData
                                }
                            }
                        }
                        Label {
                            visible: !routeChoices.visible
                            Layout.fillWidth: true
                            wrapMode: Text.Wrap
                            color: QfTheme.secondaryTextColor
                            text: plugin.routeCriterion ? qsTranslate("AmazonLocationService", "%1 routes prioritize travel time.").arg(plugin.travelMode.label)
                                : qsTranslate("AmazonLocationService", "Choose an origin and destination. Departure is now.")
                        }
                    }
                    RouteSection {
                        title: plugin.needsOrigin ? qsTranslate("AmazonLocationService", "Choose origin") : qsTranslate("AmazonLocationService", "Add stops")
                        LocationButton {
                            Layout.fillWidth: true
                            Layout.minimumHeight: plugin.touchHeight
                            enabled: plugin.canAddStop
                            text: plugin.needsOrigin ? qsTranslate("AmazonLocationService", "Search for origin") : plugin.stops.length > 1 ? qsTranslate("AmazonLocationService", "Search for next destination") : qsTranslate("AmazonLocationService", "Search for destination")
                            icon.source: Qt.resolvedUrl("icons/Search.svg")
                            onClicked: plugin.openPlaces(true)
                        }
                        LocationButton {
                            Layout.fillWidth: true
                            Layout.minimumHeight: plugin.touchHeight
                            enabled: !!plugin.currentPosition && plugin.canAddStop
                            text: plugin.needsOrigin || !plugin.stops.length ? qsTranslate("AmazonLocationService", "Use current location as origin") : qsTranslate("AmazonLocationService", "Add current location")
                            icon.source: Qt.resolvedUrl("icons/CurrentLocation.svg")
                            leftPadding: 8
                            rightPadding: 8
                            onClicked: plugin.addPosition(plugin.currentPosition, qsTranslate("AmazonLocationService", "Current location"))
                        }
                        Label {
                            Layout.fillWidth: true
                            visible: !plugin.currentPosition
                            wrapMode: Text.Wrap
                            text: plugin.gnss && plugin.gnss.active ? qsTranslate("AmazonLocationService", "Waiting for a location fix.") : qsTranslate("AmazonLocationService", "Turn on positioning in QField to use your current location.")
                            color: QfTheme.secondaryTextColor
                            font: QfTheme.tipFont
                        }
                        LocationButton {
                            text: qsTranslate("AmazonLocationService", "Add stops from map")
                            icon.source: Qt.resolvedUrl("icons/MapPin.svg")
                            Layout.fillWidth: true
                            Layout.minimumHeight: plugin.touchHeight
                            enabled: plugin.canAddStop
                            onClicked: {
                                panel.close()
                                plugin.pickMode = "point"
                            }
                        }
                        Pane {
                            Layout.fillWidth: true
                            Layout.minimumWidth: 0
                            padding: 0
                            background: Rectangle {
                                visible: layerToggle.checked
                                radius: 6
                                color: plugin.colors.canvas
                                border.color: QfTheme.controlBorderColor
                            }
                            contentItem: ColumnLayout {
                                spacing: 0
                                LocationButton {
                                    id: layerToggle
                                    checkable: true
                                    Layout.minimumHeight: plugin.touchHeight
                                    Layout.fillWidth: true
                                    text: checked ? qsTranslate("AmazonLocationService", "Add from layer ▴") : qsTranslate("AmazonLocationService", "Add from layer ▾")
                                    topInset: 0
                                    bottomInset: 0
                                    icon.source: Qt.resolvedUrl("icons/Layers.svg")
                                }
                                ColumnLayout {
                                    visible: layerToggle.checked
                                    Layout.fillWidth: true
                                    Layout.margins: 12
                                    spacing: 4
                                    Label {
                                        id: layerLabel
                                        Layout.fillWidth: true
                                        wrapMode: Text.Wrap
                                        text: qsTranslate("AmazonLocationService", "Layer for feature selection")
                                    }
                                    ComboBox {
                                        id: layers
                                        Layout.fillWidth: true
                                        Accessible.name: layerLabel.text
                                        model: QfMapLayerModel { project: qgisProject; filters: Qgis.LayerFilters.HasGeometry }
                                        textRole: "Name"
                                        valueRole: "LayerPointer"
                                        displayText: {
                                            if (count === 0) return qsTranslate("AmazonLocationService", "No suitable layers")
                                            if (currentIndex < 0) return qsTranslate("AmazonLocationService", "Select a layer")
                                            return currentText
                                        }
                                    }
                                    LocationButton {
                                        text: qsTranslate("AmazonLocationService", "Select layer features")
                                        icon.source: Qt.resolvedUrl("icons/SelectFeatures.svg")
                                        Layout.fillWidth: true
                                        Layout.minimumHeight: plugin.touchHeight
                                        enabled: !!layers.currentValue && !plugin.pending
                                        onClicked: {
                                            featureFilter.clear()
                                            features.open()
                                        }
                                    }
                                }
                            }
                        }
                    }
                    RouteSection {
                        title: qsTranslate("AmazonLocationService", "Visit order (%1 / %2)").arg(plugin.stops.length).arg(plugin.maxStops)
                        ColumnLayout {
                            visible: plugin.optimizable
                            Layout.fillWidth: true
                            spacing: 4
                            Label {
                                id: visitOrderLabel
                                text: qsTranslate("AmazonLocationService", "Visit order preference")
                            }
                            ComboBox {
                                id: orderChoice
                                Layout.fillWidth: true
                                Layout.minimumHeight: plugin.touchHeight
                                enabled: !plugin.pending
                                Accessible.name: visitOrderLabel.text
                                readonly property var criteria: [""].concat(Routes.routeCriteria)
                                model: criteria.map(value => value ? Routes.criterionLabel(value)
                                    : qsTranslate("AmazonLocationService", "Same as route (%1)").arg(Routes.criterionLabel(plugin.routeCriterion)))
                                currentIndex: criteria.indexOf(plugin.visitOrderOverride)
                                onActivated: index => plugin.visitOrderOverride = criteria[index]
                            }
                            RowLayout {
                                Layout.fillWidth: true
                                Label {
                                    id: fixedEndLabel
                                    Layout.fillWidth: true
                                    text: qsTranslate("AmazonLocationService", "Keep last stop as destination")
                                    wrapMode: Text.Wrap
                                }
                                Switch {
                                    Layout.minimumHeight: plugin.touchHeight
                                    enabled: !plugin.pending
                                    checked: plugin.fixedEnd
                                    Accessible.name: fixedEndLabel.text
                                    onToggled: plugin.fixedEnd = checked
                                }
                            }
                            Label {
                                Layout.fillWidth: true
                                wrapMode: Text.Wrap
                                text: plugin.fixedEnd && plugin.stops.length < Routes.minOptimizeStops(true)
                                    ? qsTranslate("AmazonLocationService", "At least %1 stops are needed to keep the destination fixed.").arg(Routes.minOptimizeStops(true))
                                    : plugin.fixedEnd ? qsTranslate("AmazonLocationService", "Keep the origin and destination fixed; reorder the stops in between.")
                                    : qsTranslate("AmazonLocationService", "Keep the origin fixed; reorder the remaining stops.")
                                color: QfTheme.secondaryTextColor
                                font: QfTheme.tipFont
                            }
                            LocationButton {
                                Layout.fillWidth: true
                                Layout.minimumHeight: plugin.touchHeight
                                enabled: plugin.canOptimize
                                icon.source: Qt.resolvedUrl("icons/OptimizeOrder.svg")
                                text: plugin.optimizing ? qsTranslate("AmazonLocationService", "Optimizing…") : qsTranslate("AmazonLocationService", "Optimize order")
                                onClicked: plugin.optimize()
                            }
                            Label {
                                Layout.fillWidth: true
                                visible: text.length > 0
                                wrapMode: Text.Wrap
                                text: plugin.optimizeNote
                            }
                            LocationButton {
                                visible: !!plugin.undoStops
                                enabled: !plugin.pending
                                text: qsTranslate("AmazonLocationService", "Restore original order")
                                Layout.minimumHeight: plugin.touchHeight
                                onClicked: plugin.undoOptimize()
                            }
                        }
                        Label {
                            visible: plugin.reorderable
                            Layout.fillWidth: true
                            wrapMode: Text.Wrap
                            text: qsTranslate("AmazonLocationService", "Drag the numbers up or down to reorder.")
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
                        LocationButton {
                            visible: plugin.stops.length > 0
                            enabled: !plugin.pending
                            Layout.alignment: Qt.AlignLeft
                            text: qsTranslate("AmazonLocationService", "Clear all")
                            destructive: true
                            onClicked: plugin.stops = []
                        }
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
                    Accessible.name: plugin.optimizing ? qsTranslate("AmazonLocationService", "Optimizing visit order") : qsTranslate("AmazonLocationService", "Finding route")
                }
                Label {
                    Layout.fillWidth: true
                    visible: text.length > 0
                    wrapMode: Text.Wrap
                    text: plugin.statusText || (plugin.pending ? "" : plugin.routeSummary)
                    textFormat: Text.PlainText
                    color: plugin.message ? plugin.colors.danger.foreground : QfTheme.mainTextColor
                }
                LocationButton {
                    Layout.fillWidth: true
                    Layout.minimumHeight: 48
                    enabled: !plugin.pending && !plugin.searchHint
                    Accessible.description: plugin.statusText
                    text: {
                        if (routeRequest.pending) return qsTranslate("AmazonLocationService", "Finding route…")
                        const details = plugin.routeCriterion
                            ? qsTranslate("AmazonLocationService", "%1 · %2", "Travel mode and route preference").arg(plugin.travelMode.label).arg(Routes.criterionLabel(plugin.routeCriterion))
                            : plugin.travelMode.label
                        return width < 250
                            ? qsTranslate("AmazonLocationService", "Find route\n%1").arg(details)
                            : qsTranslate("AmazonLocationService", "Find route · %1").arg(details)
                    }
                    topInset: 0
                    bottomInset: 0
                    leftPadding: 8
                    rightPadding: 8
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
                title: places.forRoute ? (plugin.needsOrigin ? qsTranslate("AmazonLocationService", "Find Origin") : qsTranslate("AmazonLocationService", "Find Destination")) : qsTranslate("AmazonLocationService", "Place Search")
                dismissText: places.forRoute ? qsTranslate("AmazonLocationService", "Back") : qsTranslate("AmazonLocationService", "Close")
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
                selectionHint: places.forRoute ? qsTranslate("AmazonLocationService", "Select a place to add to the route.") : qsTranslate("AmazonLocationService", "Select a place to show it on the map.")
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
            PanelHeader { title: qsTranslate("AmazonLocationService", "Settings"); dismissText: qsTranslate("AmazonLocationService", "Done"); primaryDismiss: true; onDismissed: settingsPopup.close() }
            ScrollView {
                id: settingsForm
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                padding: plugin.gutter
                contentWidth: availableWidth
                ColumnLayout {
                    width: settingsForm.availableWidth
                    Label { id: regionLabel; text: qsTranslate("AmazonLocationService", "AWS Region") }
                    TextField {
                        id: regionField
                        Layout.fillWidth: true
                        Accessible.name: regionLabel.text
                        text: "ap-northeast-1"
                        readOnly: !!plugin.pending
                        readonly property bool validRegion: /^[a-z]{2}(-[a-z0-9]+)+-[0-9]+$/.test(text.trim())
                        onTextEdited: plugin.message = ""
                    }
                    Label { id: keyLabel; text: qsTranslate("AmazonLocationService", "Amazon Location API key") }
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
                        text: plugin.connectionHint || qsTranslate("AmazonLocationService", "These settings apply to place and route searches.")
                        color: QfTheme.secondaryTextColor
                    }
                }
            }
        }
    }

    RoutePopup {
        id: features
        readonly property var visitsByFeature: {
            const visits = {}
            plugin.stops.forEach((stop, index) => {
                if (!stop.featureKey) return
                if (!visits[stop.featureKey]) visits[stop.featureKey] = []
                visits[stop.featureKey].push(index)
            })
            return visits
        }
        function refreshList() {
            const layer = layers.currentValue
            if (!layer) {
                matches.clear()
                return
            }
            matches.setFeatures(layer, Routes.featureFilterExpression(featureFilter.text, layer.displayExpression))
            featureList.positionViewAtBeginning()
        }
        onAboutToShow: refreshList()
        onAboutToHide: filterDelay.stop()
        onClosed: matches.clear()
        Timer {
            id: filterDelay
            interval: 200
            onTriggered: features.refreshList()
        }
        ColumnLayout {
            anchors.fill: parent
            spacing: 0
            PanelHeader { title: qsTranslate("AmazonLocationService", "Select Features"); dismissText: qsTranslate("AmazonLocationService", "Done"); primaryDismiss: true; onDismissed: features.close() }
            RowLayout {
                Layout.fillWidth: true
                Layout.leftMargin: plugin.gutter
                Layout.rightMargin: plugin.gutter
                Layout.topMargin: plugin.gutter
                Label {
                    Layout.fillWidth: true
                    text: layers.currentText
                    textFormat: Text.PlainText
                    font: QfTheme.strongResultFont
                    wrapMode: Text.Wrap
                }
                Label {
                    text: qsTranslate("AmazonLocationService", "%1 / %2 route stops").arg(plugin.stops.length).arg(plugin.maxStops)
                    font: QfTheme.tipFont
                    color: QfTheme.secondaryTextColor
                }
            }
            LocationButton {
                Layout.fillWidth: true
                Layout.leftMargin: plugin.gutter
                Layout.rightMargin: plugin.gutter
                Layout.minimumHeight: plugin.touchHeight
                text: qsTranslate("AmazonLocationService", "Select on map")
                icon.source: Qt.resolvedUrl("icons/SelectFeatures.svg")
                enabled: !!layers.currentValue && plugin.canAddStop
                onClicked: {
                    Qt.inputMethod.hide()
                    plugin.featureLayer = layers.currentValue
                    plugin.pickMode = "features"
                    features.close()
                    panel.close()
                }
            }
            Label {
                Layout.fillWidth: true
                Layout.margins: plugin.gutter
                Layout.topMargin: 4
                Layout.bottomMargin: 4
                wrapMode: Text.Wrap
                text: plugin.atLimit ? qsTranslate("AmazonLocationService", "Stop limit reached (%1). Tap × on a visit to remove it.").arg(plugin.maxStops)
                    : qsTranslate("AmazonLocationService", "Tap a feature to add or revisit it. Tap × on a visit to remove it.")
            }
            RowLayout {
                Layout.fillWidth: true
                Layout.leftMargin: plugin.gutter
                Layout.rightMargin: plugin.gutter
                Layout.bottomMargin: 8
                TextField {
                    id: featureFilter
                    Layout.fillWidth: true
                    placeholderText: qsTranslate("AmazonLocationService", "Filter by name or ID")
                    Accessible.name: placeholderText
                    onTextEdited: filterDelay.restart()
                    onAccepted: Qt.inputMethod.hide()
                }
                LocationButton {
                    text: qsTranslate("AmazonLocationService", "Clear")
                    Layout.minimumHeight: plugin.touchHeight
                    Accessible.name: qsTranslate("AmazonLocationService", "Clear feature filter")
                    visible: featureFilter.text.length > 0
                    onClicked: {
                        featureFilter.clear()
                        filterDelay.restart()
                    }
                }
            }
            Label {
                Layout.leftMargin: plugin.gutter
                visible: matches.count === 0
                text: featureFilter.text.trim() ? qsTranslate("AmazonLocationService", "No matching features.") : qsTranslate("AmazonLocationService", "There are no features in this layer.")
            }
            ListView {
                id: featureList
                enabled: !filterDelay.running
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.leftMargin: plugin.gutter
                Layout.rightMargin: plugin.gutter
                Layout.bottomMargin: plugin.gutter
                spacing: 8
                clip: true
                model: matches
                delegate: Rectangle {
                    id: featureCard
                    readonly property string featureKey: plugin.featureKey(model)
                    readonly property var visits: features.visitsByFeature[featureKey] || []
                    readonly property bool added: visits.length > 0
                    width: ListView.view.width
                    height: cardContents.implicitHeight
                    radius: 8
                    color: addVisit.down || added ? plugin.colors.secondary.background : QfTheme.groupBoxSurfaceColor
                    border.color: added || addVisit.visualFocus ? plugin.colors.selected.background : QfTheme.controlBorderColor
                    border.width: addVisit.visualFocus ? 2 : 1

                    Column {
                        id: cardContents
                        width: parent.width
                        ItemDelegate {
                            id: addVisit
                            width: parent.width
                            padding: 12
                            implicitHeight: Math.max(plugin.touchHeight, implicitContentHeight + topPadding + bottomPadding)
                            enabled: plugin.canAddStop
                            opacity: !enabled && !featureCard.added ? 0.6 : 1
                            text: plugin.featureLabel(model)
                            Accessible.description: featureCard.added ? qsTranslate("AmazonLocationService", "Add another visit") : qsTranslate("AmazonLocationService", "Add to route")
                            background: null
                            contentItem: RowLayout {
                                spacing: 12
                                CircleBadge {
                                    minimumSize: 28
                                    text: featureCard.added ? "✓" : "+"
                                    color: featureCard.added ? plugin.colors.selected.foreground : plugin.colors.secondary.foreground
                                    fill: featureCard.added ? plugin.colors.selected.background : plugin.colors.secondary.background
                                    Accessible.ignored: true
                                }
                                Label {
                                    Layout.fillWidth: true
                                    Layout.minimumWidth: 0
                                    text: addVisit.text
                                    textFormat: Text.PlainText
                                    font: QfTheme.strongResultFont
                                    color: QfTheme.mainTextColor
                                    wrapMode: Text.Wrap
                                }
                            }
                            onClicked: plugin.addFeature(model)
                        }
                        Flow {
                            leftPadding: addVisit.leftPadding
                            rightPadding: addVisit.rightPadding
                            bottomPadding: 6
                            width: parent.width
                            spacing: 4
                            visible: featureCard.added
                            Repeater {
                                model: featureCard.visits
                                delegate: LocationButton {
                                    required property int modelData
                                    text: qsTranslate("AmazonLocationService", "Visit %1 · %2").arg(modelData + 1).arg(plugin.stopRole(modelData)) + "  ×"
                                    Accessible.name: qsTranslate("AmazonLocationService", "Remove visit %1 to %2").arg(modelData + 1).arg(addVisit.text)
                                    height: Math.max(implicitHeight, plugin.touchHeight)
                                    destructive: true
                                    enabled: !plugin.pending
                                    onClicked: plugin.removeStop(modelData)
                                }
                            }
                        }
                    }
                }
                ScrollBar.vertical: ScrollBar {}
            }
        }
    }
}
