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

function placeResults(response) {
    if (!Array.isArray(response.ResultItems)) throw new Error("検索結果を読み取れませんでした。")
    return response.ResultItems.filter(item => item && validPosition(item.Position)).map(item => {
        const address = (item.Address && item.Address.Label) || ""
        const label = item.Title || address
        // An address that only repeats the label is dropped so views show it once.
        return { label: label, address: address === label ? "" : address, position: item.Position }
    }).filter(place => place.label)
}
