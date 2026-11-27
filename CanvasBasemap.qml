import QtQuick
import org.qfield.core
import "Basemap.js" as Basemap

Item {
    id: background
    required property var canvas
    required property string region
    required property string apiKey
    property string style: "Standard"
    property bool active: false
    property var surface: null
    property var frame: null
    readonly property var mercator: QfCoordinateReferenceSystemUtils.fromDescription("EPSG:3857")
    signal failed()

    // A raster belongs to this short-lived QObject parent, outside the project.
    Component { id: owner; Item { property var raster: null } }
    function attach() {
        if (!surface || !canvas) return
        const settings = canvas.mapSettings
        const layers = settings.layers
        if (!layers.includes(surface.raster)) settings.layers = layers.concat([surface.raster])
    }
    function release() {
        const old = surface
        surface = null
        frame = null
        if (!old) return
        if (canvas) canvas.mapSettings.layers = canvas.mapSettings.layers.filter(layer => layer !== old.raster)
        old.destroy()
    }
    function renderFailed(layerId) {
        if (surface && surface.raster.id === layerId) {
            release()
            failed()
        }
    }
    function refresh() {
        if (!active || !region || !apiKey || !canvas) return
        const map = canvas.mapSettings
        const points = []
        for (const x of [0, canvas.width / 2, canvas.width]) {
            for (const y of [0, canvas.height / 2, canvas.height]) {
                const p = map.screenToCoordinate(Qt.point(x, y))
                points.push(QfGeometryUtils.reprojectPoint(p, map.destinationCrs, mercator))
            }
        }
        const next = Basemap.frameFor(points, canvas.width, canvas.height)
        if (!next || (frame && Basemap.covers(frame, next.view))) return
        const source = Basemap.rasterSource(next, style, region, apiKey)
        const holder = owner.createObject(background)
        const raster = QfLayerUtils.loadRasterLayer(source, "Amazon Location Service", "gdal")
        if (raster) holder.data.push(raster)
        if (!raster || !raster.isValid) {
            holder.destroy()
            failed()
            return
        }
        holder.raster = raster
        release()
        frame = next
        surface = holder
        attach()
    }
    function selectStyle(value) {
        if (style === value) invalidate()
        else style = value
    }
    function invalidate() {
        frame = null
        if (active) updateTimer.restart()
    }
    onActiveChanged: { if (active) invalidate(); else release() }
    onStyleChanged: invalidate()
    onRegionChanged: invalidate()
    onApiKeyChanged: invalidate()
    Component.onDestruction: release()
    Timer { id: updateTimer; interval: 300; onTriggered: background.refresh() }
    // Network and API errors occur during the native render, after the GDAL
    // provider has opened. QField prefixes render errors with the layer ID.
    Connections {
        target: messageLogModel
        enabled: !!background.surface
        function onRowsInserted(parent, first, last) {
            if (!background.surface) return
            const id = background.surface.raster.id
            for (let row = first; row <= last; ++row) {
                const message = messageLogModel.data(messageLogModel.index(row, 0), Qt.UserRole)
                if (typeof message === "string" && message.startsWith(id + " :: ")) {
                    Qt.callLater(background.renderFailed, id)
                    return
                }
            }
        }
    }
    Connections {
        target: background.canvas.mapSettings
        function onExtentChanged() { if (background.active) updateTimer.restart() }
        function onRotationChanged() { if (background.active) updateTimer.restart() }
        function onOutputSizeChanged() { if (background.active) updateTimer.restart() }
        function onDestinationCrsChanged() { background.invalidate() }
        function onLayersChanged() { if (background.active) Qt.callLater(background.attach) }
    }
}
