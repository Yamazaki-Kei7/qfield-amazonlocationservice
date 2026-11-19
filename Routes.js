var travelModes = [
    { id: "Car", label: "Car" },
    { id: "Pedestrian", label: "Walking" },
    { id: "Scooter", label: "Scooter" },
    { id: "Truck", label: "Truck" },
    { id: "Transit", label: "Public transit" },
    { id: "Intermodal", label: "Intermodal" }
]

var routeCriteria = ["ShortestRoute", "FastestRoute"]

function supportsWaypoints(mode) {
    return mode !== "Transit" && mode !== "Intermodal"
}

function allowsShortestRoute(mode) {
    return mode === "Car" || mode === "Truck"
}

function routeCriterion(mode, preference) {
    if (!supportsWaypoints(mode)) return ""
    return allowsShortestRoute(mode) && preference !== "FastestRoute" ? "ShortestRoute" : "FastestRoute"
}

function criterionLabel(criterion) {
    return criterion === "ShortestRoute" ? "Shortest" : "Fastest"
}

function stopLimit(mode) {
    return supportsWaypoints(mode) ? 25 : 2 // CalculateRoutes accepts 23 intermediate waypoints.
}

function validPosition(p) {
    return Array.isArray(p) && p.length >= 2 && Number.isFinite(p[0])
        && Number.isFinite(p[1]) && Math.abs(p[0]) <= 180 && Math.abs(p[1]) <= 90
}

function usableStops(stops, mode, min) {
    return stops.length >= min && stops.length <= stopLimit(mode) && stops.every(s => validPosition(s.position))
}

function requestBody(stops, mode, preference) {
    if (!usableStops(stops, mode, 2))
        throw new Error("Select valid stops for the chosen travel mode.")
    const body = {
        Origin: stops[0].position,
        Destination: stops[stops.length - 1].position,
        TravelMode: mode,
        LegGeometryFormat: "Simple"
    }
    const criterion = routeCriterion(mode, preference)
    if (criterion) {
        body.Waypoints = stops.slice(1, -1).map(s => ({ Position: s.position }))
        body.OptimizeRoutingFor = criterion
    } else {
        body.DepartNow = true
    }
    return body
}

function routeWkt(response, body) {
    const route = response.Routes && response.Routes[0]
    if (!route || !Array.isArray(route.Legs) || !route.Legs.length
            || (body.Waypoints && route.Legs.length !== body.Waypoints.length + 1))
        throw new Error("No route was found for all legs.")
    const legs = route.Legs.map(leg => {
        const line = leg.Geometry && leg.Geometry.LineString
        if (!Array.isArray(line) || line.length < 2 || !line.every(validPosition))
            throw new Error("Could not read the route coordinates.")
        return "(" + line.map(p => p[0] + " " + p[1]).join(",") + ")"
    })
    return "MULTILINESTRING(" + legs.join(",") + ")"
}

function rejection(failed, status, responseText) {
    const prefix = failed + " (HTTP " + status + "). "
    if (status === 400) {
        try {
            const error = JSON.parse(responseText)
            const detail = error && (error.message || error.Message)
            if (typeof detail === "string" && detail.trim()) return prefix + detail.trim()
        } catch (e) {
            // A proxy may return plain text or an empty body.
        }
        return prefix + "Check the stops and travel mode."
    }
    return prefix + "Check the stops, region, and API key permissions."
}

var optimizePerimeterKm = 500 // OptimizeWaypoints rejects stops inside a bounding box with a longer perimeter.

function minOptimizeStops(fixedEnd) {
    return fixedEnd ? 4 : 3 // Reordering needs two stops that are not a fixed end.
}

function optimizeBody(stops, mode, fixedEnd, criterion) {
    if (!supportsWaypoints(mode) || !usableStops(stops, mode, minOptimizeStops(fixedEnd)))
        throw new Error("Select a travel mode and stops that support visit order optimization.")
    const end = fixedEnd ? stops.length - 1 : stops.length
    const body = {
        Origin: stops[0].position,
        // Each Id is the stop's index, so optimizedStops() can map the reply back without sending names.
        Waypoints: stops.slice(1, end).map((s, i) => ({ Id: String(i + 1), Position: s.position })),
        TravelMode: mode,
        OptimizeSequencingFor: criterion === "FastestRoute" ? "FastestRoute" : "ShortestRoute"
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
            .filter(Boolean).map(s => '"' + s.label + '"')
        throw new Error("Could not optimize visit order."
            + (names.length ? " No valid order includes " + names.join(", ") + "." : ""))
    }
    const order = (Array.isArray(response.OptimizedWaypoints) ? response.OptimizedWaypoints : [])
        .map(w => Number(w && w.Id)).filter(i => Number.isInteger(i) && i >= 1 && i < end)
    if (order.length !== end - 1 || order.some((id, i) => order.indexOf(id) !== i))
        throw new Error("Could not read the optimization result.")
    return {
        stops: [stops[0]].concat(order.map(i => stops[i]), stops.slice(end)),
        changed: order.some((id, i) => id !== i + 1),
        summary: tripSummary(response.Distance, response.Duration)
    }
}

function optimizeRejection(status, stops) {
    const failed = "Could not optimize visit order"
    if (status === 403)
        return failed + " (HTTP 403). Check the API key's expiration date, region, and geo-routes:OptimizeWaypoints permission."
    if (status !== 400) return rejection(failed, status)
    // The service measures the perimeter its own way, so only a clear excess is reported as the cause.
    const perimeter = Math.round(boundsPerimeterKm(stops.map(s => s.position)))
    return perimeter > optimizePerimeterKm
        ? failed + ". The bounding box around all stops has a perimeter of approximately " + perimeter
            + " km, exceeding the " + optimizePerimeterKm + " km limit. Remove stops or reduce the area."
        : failed + " (HTTP 400). Check whether stops are far from roads or spread across a wide area (perimeter over "
            + optimizePerimeterKm + " km)."
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
    return " (about " + (distance < 1000 ? Math.round(distance) + " m" : (distance / 1000).toFixed(1) + " km")
        + ", " + (hours ? hours + " hr" : "")
        + (hours && minutes % 60 === 0 ? "" : (hours ? " " : "") + minutes % 60 + " min") + ")"
}

function placeResults(response) {
    if (!Array.isArray(response.ResultItems)) throw new Error("Could not read the search results.")
    return response.ResultItems.filter(item => item && validPosition(item.Position)).map(item => {
        const address = (item.Address && item.Address.Label) || ""
        const label = item.Title || address
        // An address that only repeats the label is dropped so views show it once.
        return { label: label, address: address === label ? "" : address, position: item.Position }
    }).filter(place => place.label)
}
