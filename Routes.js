var maxStops = 25 // CalculateRoutes accepts 23 intermediate waypoints.

function validPosition(p) {
    return Array.isArray(p) && p.length >= 2 && Number.isFinite(p[0])
        && Number.isFinite(p[1]) && Math.abs(p[0]) <= 180 && Math.abs(p[1]) <= 90
}

function requestBody(stops) {
    if (stops.length < 2 || stops.length > maxStops || !stops.every(s => validPosition(s.position)))
        throw new Error("有効な地点を2〜25件指定してください。")
    return {
        Origin: stops[0].position,
        Destination: stops[stops.length - 1].position,
        Waypoints: stops.slice(1, -1).map(s => ({ Position: s.position })),
        TravelMode: "Car",
        OptimizeRoutingFor: "ShortestRoute",
        LegGeometryFormat: "Simple"
    }
}

function routeWkt(response, legCount) {
    const route = response.Routes && response.Routes[0]
    if (!route || !Array.isArray(route.Legs) || route.Legs.length !== legCount)
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
