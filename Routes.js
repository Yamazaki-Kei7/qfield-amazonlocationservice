var travelModes = [
    { id: "Car", label: "車" },
    { id: "Pedestrian", label: "徒歩" },
    { id: "Scooter", label: "スクーター" },
    { id: "Truck", label: "トラック" },
    { id: "Transit", label: "公共交通" },
    { id: "Intermodal", label: "複合移動" }
]

function supportsWaypoints(mode) {
    return mode !== "Transit" && mode !== "Intermodal"
}

function stopLimit(mode) {
    return supportsWaypoints(mode) ? 25 : 2 // CalculateRoutes accepts 23 intermediate waypoints.
}

function validPosition(p) {
    return Array.isArray(p) && p.length >= 2 && Number.isFinite(p[0])
        && Number.isFinite(p[1]) && Math.abs(p[0]) <= 180 && Math.abs(p[1]) <= 90
}

function requestBody(stops, mode) {
    if (stops.length < 2 || stops.length > stopLimit(mode) || !stops.every(s => validPosition(s.position)))
        throw new Error("選択した移動手段で利用できる地点を指定してください。")
    const body = {
        Origin: stops[0].position,
        Destination: stops[stops.length - 1].position,
        TravelMode: mode,
        LegGeometryFormat: "Simple"
    }
    if (supportsWaypoints(mode)) {
        body.Waypoints = stops.slice(1, -1).map(s => ({ Position: s.position }))
        body.OptimizeRoutingFor = "ShortestRoute"
    } else {
        body.DepartNow = true
    }
    return body
}

function routeWkt(response, body) {
    const route = response.Routes && response.Routes[0]
    if (!route || !Array.isArray(route.Legs) || !route.Legs.length
            || (body.Waypoints && route.Legs.length !== body.Waypoints.length + 1))
        throw new Error("全区間を通る経路が見つかりませんでした。")
    const legs = route.Legs.map(leg => {
        const line = leg.Geometry && leg.Geometry.LineString
        if (!Array.isArray(line) || line.length < 2 || !line.every(validPosition))
            throw new Error("経路の座標を読み取れませんでした。")
        return "(" + line.map(p => p[0] + " " + p[1]).join(",") + ")"
    })
    return "MULTILINESTRING(" + legs.join(",") + ")"
}

var optimizePerimeterKm = 500 // OptimizeWaypoints rejects stops inside a bounding box with a longer perimeter.

function minOptimizeStops(fixedEnd) {
    return fixedEnd ? 4 : 3 // Reordering needs two stops that are not a fixed end.
}

function optimizeBody(stops, mode, fixedEnd) {
    if (!supportsWaypoints(mode) || stops.length < minOptimizeStops(fixedEnd) || stops.length > stopLimit(mode)
            || !stops.every(s => validPosition(s.position)))
        throw new Error("訪問順を最適化できる移動手段と地点を指定してください。")
    const end = fixedEnd ? stops.length - 1 : stops.length
    const body = {
        Origin: stops[0].position,
        // Each Id is the stop's index, so optimizedStops() can map the reply back without sending names.
        Waypoints: stops.slice(1, end).map((s, i) => ({ Id: String(i + 1), Position: s.position })),
        TravelMode: mode,
        OptimizeSequencingFor: "ShortestRoute"
    }
    if (fixedEnd) body.Destination = stops[end].position
    return body
}

function optimizedStops(response, stops, fixedEnd) {
    const end = fixedEnd ? stops.length - 1 : stops.length
    if (Array.isArray(response.ImpedingWaypoints) && response.ImpedingWaypoints.length) {
        // The service names the fixed ends "Origin" and "Destination".
        const names = response.ImpedingWaypoints
            .map(w => w && stops[w.Id === "Origin" ? 0 : w.Id === "Destination" ? stops.length - 1 : Number(w.Id)])
            .filter(Boolean).map(s => "「" + s.label + "」")
        throw new Error((names.length ? names.join("") + "を通る順序が見つからず、" : "") + "訪問順を最適化できませんでした。")
    }
    const order = (Array.isArray(response.OptimizedWaypoints) ? response.OptimizedWaypoints : [])
        .map(w => Number(w && w.Id)).filter(i => Number.isInteger(i) && i >= 1 && i < end)
    if (order.length !== end - 1 || order.some((id, i) => order.indexOf(id) !== i))
        throw new Error("最適化の結果を読み取れませんでした。")
    return {
        stops: [stops[0]].concat(order.map(i => stops[i]), stops.slice(end)),
        changed: order.some((id, i) => id !== i + 1),
        summary: tripSummary(response.Distance, response.Duration)
    }
}

function optimizeRejection(status, stops) {
    const failed = "訪問順を最適化できませんでした"
    if (status === 403)
        return failed + "（HTTP 403）。API キーの期限とリージョン、geo-routes:OptimizeWaypoints の許可を確認してください。"
    if (status !== 400)
        return failed + "（HTTP " + status + "）。地点、リージョン、キーの権限を確認してください。"
    // The service measures the perimeter its own way, so only a clear excess is reported as the cause.
    const perimeter = Math.round(boundsPerimeterKm(stops.map(s => s.position)))
    return perimeter > optimizePerimeterKm
        ? failed + "。全地点を囲む範囲の周長が約" + perimeter + " kmで、上限の" + optimizePerimeterKm
            + " kmを超えています。地点を減らすか、範囲を狭めてください。"
        : failed + "（HTTP 400）。地点が道路から大きく離れていないか、広い範囲（周長" + optimizePerimeterKm
            + " km超）に散らばっていないか確認してください。"
}

// Perimeter of the longitude-latitude box around the positions, with its width taken at the middle latitude.
function boundsPerimeterKm(positions) {
    const lons = positions.map(p => p[0])
    const lats = positions.map(p => p[1])
    const south = Math.min.apply(null, lats)
    const north = Math.max.apply(null, lats)
    const width = (Math.max.apply(null, lons) - Math.min.apply(null, lons)) * Math.cos((south + north) * Math.PI / 360)
    return 2 * (width + north - south) * 6371.0088 * Math.PI / 180
}

function tripSummary(distance, duration) {
    if (!Number.isFinite(distance) || !Number.isFinite(duration)) return ""
    const minutes = Math.max(1, Math.round(duration / 60))
    const hours = Math.floor(minutes / 60)
    return "（約" + (distance < 1000 ? Math.round(distance) + " m" : (distance / 1000).toFixed(1) + " km")
        + "・約" + (hours ? hours + "時間" : "") + (hours && minutes % 60 === 0 ? "" : minutes % 60 + "分") + "）"
}

function placeResults(response) {
    if (!Array.isArray(response.ResultItems)) throw new Error("検索結果を読み取れませんでした。")
    return response.ResultItems.filter(item => item && validPosition(item.Position)).map(item => {
        const address = (item.Address && item.Address.Label) || ""
        const label = item.Title || address
        // An address that only repeats the label is dropped so views show it once.
        return { label: label, address: address === label ? "" : address, position: item.Position }
    }).filter(place => place.label)
}
