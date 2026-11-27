// EPSG:3857 coordinates use the WGS84 semi-major axis.
const radius = 6378137
const worldEdge = Math.PI * radius
const minImage = 64
const maxImage = 1400
const overscan = 1.15
const clamp = (value, low, high) => Math.max(low, Math.min(high, value))

function frameFor(points, width, height) {
    if (!(width > 0 && height > 0) || !points.length
            || !points.every(p => Number.isFinite(p.x) && Number.isFinite(p.y))) return null
    const xs = points.map(p => clamp(p.x, -worldEdge, worldEdge))
    const ys = points.map(p => clamp(p.y, -worldEdge, worldEdge))
    const west = Math.min.apply(null, xs), east = Math.max.apply(null, xs)
    const south = Math.min.apply(null, ys), north = Math.max.apply(null, ys)
    const spanX = east - west, spanY = north - south
    if (!(spanX > 0 && spanY > 0)) return null

    // Cover the rotated viewport in Mercator, keeping a margin for short pans.
    // Each AWS image has square Mercator pixels, even for a projected QField project.
    const viewResolution = Math.sqrt(spanX * spanY / (width * height))
    const resolution = Math.max(viewResolution, overscan * Math.max(spanX, spanY) / maxImage)
    const pixels = span => clamp(Math.ceil(span * overscan / resolution), minImage, maxImage)
    const w = pixels(spanX), h = pixels(spanY)
    const dx = Math.min(2 * worldEdge, resolution * w)
    const dy = Math.min(2 * worldEdge, resolution * h)
    const left = clamp((east + west - dx) / 2, -worldEdge, worldEdge - dx)
    const bottom = clamp((north + south - dy) / 2, -worldEdge, worldEdge - dy)
    return {west: left, east: left + dx, south: bottom, north: bottom + dy, width: w, height: h,
            view: {west, east, south, north, resolution: viewResolution}}
}

function covers(frame, view) {
    const ratio = frame.view.resolution / view.resolution
    return ratio >= 0.8 && ratio <= 1.25 && frame.west <= view.west && frame.east >= view.east
        && frame.south <= view.south && frame.north >= view.north
}

function rasterSource(f, style, region, key) {
    const lon = x => (x / radius * 180 / Math.PI).toFixed(9)
    const lat = y => (Math.atan(Math.sinh(y / radius)) * 180 / Math.PI).toFixed(9)
    const box = [lon(f.west), lat(f.south), lon(f.east), lat(f.north)].join(",")
    const url = "https://maps.geo." + region + ".amazonaws.com/v2/static/map"
        + "?style=${layer}"
        + "&amp;bounding-box=" + box + "&amp;width=" + f.width + "&amp;height=" + f.height
        + "&amp;key=" + encodeURIComponent(key)
    // One GDAL block is one AWS image. The native renderer reprojects it and
    // composites all user-enabled project layers above it. No GDAL disk cache.
    return '<GDAL_WMS><Service name="TMS"><Layer>' + style + '</Layer><ServerUrl>' + url + '</ServerUrl></Service>'
        + '<DataWindow><UpperLeftX>' + f.west + '</UpperLeftX><UpperLeftY>' + f.north + '</UpperLeftY>'
        + '<LowerRightX>' + f.east + '</LowerRightX><LowerRightY>' + f.south + '</LowerRightY>'
        + '<SizeX>' + f.width + '</SizeX><SizeY>' + f.height + '</SizeY></DataWindow>'
        + '<Projection>EPSG:3857</Projection><BandsCount>3</BandsCount><OverviewCount>0</OverviewCount>'
        + '<BlockSizeX>' + f.width + '</BlockSizeX><BlockSizeY>' + f.height + '</BlockSizeY></GDAL_WMS>'
}
