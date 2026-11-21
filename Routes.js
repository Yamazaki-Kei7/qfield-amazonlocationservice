var travelModes = [
    { id: "Car", label: qsTranslate("AmazonLocationService", "Car") },
    { id: "Pedestrian", label: qsTranslate("AmazonLocationService", "Walking") },
    { id: "Scooter", label: qsTranslate("AmazonLocationService", "Scooter") },
    { id: "Truck", label: qsTranslate("AmazonLocationService", "Truck") },
    { id: "Transit", label: qsTranslate("AmazonLocationService", "Public transit") },
    { id: "Intermodal", label: qsTranslate("AmazonLocationService", "Intermodal") }
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
    return criterion === "ShortestRoute" ? qsTranslate("AmazonLocationService", "Shortest") : qsTranslate("AmazonLocationService", "Fastest")
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
        throw new Error(qsTranslate("AmazonLocationService", "Select valid stops for the chosen travel mode."))
    const body = {
        Origin: stops[0].position,
        Destination: stops[stops.length - 1].position,
        TravelMode: mode,
        LegAdditionalFeatures: ["Summary"],
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
        throw new Error(qsTranslate("AmazonLocationService", "No route was found for all legs."))
    const legs = route.Legs.map(leg => {
        const line = leg.Geometry && leg.Geometry.LineString
        if (!Array.isArray(line) || line.length < 2 || !line.every(validPosition))
            throw new Error(qsTranslate("AmazonLocationService", "Could not read the route coordinates."))
        return "(" + line.map(p => p[0] + " " + p[1]).join(",") + ")"
    })
    return "MULTILINESTRING(" + legs.join(",") + ")"
}

function rejection(failed, status, responseText) {
    //: %1 is the failed action, %2 the HTTP status, and %3 the service's message or what to check.
    const explain = detail => qsTranslate("AmazonLocationService", "%1 (HTTP %2). %3").arg(failed).arg(status).arg(detail)
    if (status === 400) {
        try {
            const error = JSON.parse(responseText)
            const detail = error && (error.message || error.Message)
            if (typeof detail === "string" && detail.trim()) return explain(detail.trim())
        } catch (e) {
            // A proxy may return plain text or an empty body.
        }
        return explain(qsTranslate("AmazonLocationService", "Check the stops and travel mode."))
    }
    return explain(qsTranslate("AmazonLocationService", "Check the stops, region, and API key permissions."))
}

var optimizePerimeterKm = 500 // OptimizeWaypoints rejects stops inside a bounding box with a longer perimeter.

function minOptimizeStops(fixedEnd) {
    return fixedEnd ? 4 : 3 // Reordering needs two stops that are not a fixed end.
}

function optimizeBody(stops, mode, fixedEnd, criterion) {
    if (!supportsWaypoints(mode) || !usableStops(stops, mode, minOptimizeStops(fixedEnd)))
        throw new Error(qsTranslate("AmazonLocationService", "Select a travel mode and stops that support visit order optimization."))
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
            .filter(Boolean).map(s => qsTranslate("AmazonLocationService", "\"%1\"", "Quoted stop name").arg(s.label))
        throw new Error(names.length
            ? qsTranslate("AmazonLocationService", "Could not optimize visit order. No valid order includes %1.")
                .arg(names.join(qsTranslate("AmazonLocationService", ", ", "Between quoted stop names")))
            : qsTranslate("AmazonLocationService", "Could not optimize visit order."))
    }
    const order = (Array.isArray(response.OptimizedWaypoints) ? response.OptimizedWaypoints : [])
        .map(w => Number(w && w.Id)).filter(i => Number.isInteger(i) && i >= 1 && i < end)
    if (order.length !== end - 1 || order.some((id, i) => order.indexOf(id) !== i))
        throw new Error(qsTranslate("AmazonLocationService", "Could not read the optimization result."))
    return {
        stops: [stops[0]].concat(order.map(i => stops[i]), stops.slice(end)),
        changed: order.some((id, i) => id !== i + 1),
        summary: tripSummary(response.Distance, response.Duration)
    }
}

function optimizeRejection(status, stops) {
    if (status === 403)
        return qsTranslate("AmazonLocationService", "Could not optimize visit order (HTTP 403). Check the API key's expiration date, region, and geo-routes:OptimizeWaypoints permission.")
    if (status !== 400) return rejection(qsTranslate("AmazonLocationService", "Could not optimize visit order"), status)
    // The service measures the perimeter its own way, so only a clear excess is reported as the cause.
    const perimeter = Math.round(boundsPerimeterKm(stops.map(s => s.position)))
    return perimeter > optimizePerimeterKm
        ? qsTranslate("AmazonLocationService", "Could not optimize visit order. The bounding box around all stops has a perimeter of approximately %1 km, exceeding the %2 km limit. Remove stops or reduce the area.").arg(perimeter).arg(optimizePerimeterKm)
        : qsTranslate("AmazonLocationService", "Could not optimize visit order (HTTP 400). Check whether stops are far from roads or spread across a wide area (perimeter over %1 km).").arg(optimizePerimeterKm)
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

function formatDistance(distance) {
    return distance < 1000 ? qsTranslate("AmazonLocationService", "%1 m").arg(Math.round(distance))
                           : qsTranslate("AmazonLocationService", "%1 km").arg((distance / 1000).toFixed(1))
}

function formatDuration(duration) {
    const minutes = duration === 0 ? 0 : Math.max(1, Math.round(duration / 60))
    const hours = Math.floor(minutes / 60)
    const remainder = minutes % 60
    if (!hours) return qsTranslate("AmazonLocationService", "%1 min").arg(minutes)
    if (!remainder) return qsTranslate("AmazonLocationService", "%1 hr").arg(hours)
    return qsTranslate("AmazonLocationService", "%1 hr %2 min").arg(hours).arg(remainder)
}

function tripSummary(distance, duration) {
    if (!Number.isFinite(distance) || !Number.isFinite(duration)) return ""
    return qsTranslate("AmazonLocationService", " (about %1, %2)").arg(formatDistance(distance)).arg(formatDuration(duration))
}

function routeSummary(route) {
    // A route total takes precedence. Otherwise every leg must contribute to the total.
    const overviews = route.Legs.map(leg => {
        const details = leg[leg.Type + "LegDetails"]
        return details && details.Summary && details.Summary.Overview
    })
    const valid = value => Number.isFinite(value) && value >= 0
    function total(field) {
        const value = route.Summary && route.Summary[field]
        if (valid(value)) return value
        const values = overviews.map(overview => overview && overview[field])
        return values.length && values.every(valid) ? values.reduce((sum, value) => sum + value, 0) : null
    }
    const distance = total("Distance")
    const duration = total("Duration")
    const time = duration === null ? "" : qsTranslate("AmazonLocationService", "About %1").arg(formatDuration(duration))
    const length = distance === null ? "" : formatDistance(distance)
    if (time && length) return qsTranslate("AmazonLocationService", "%1 · %2").arg(time).arg(length)
    return time || length || qsTranslate("AmazonLocationService", "Distance and travel time unavailable")
}

function placeResults(response) {
    if (!Array.isArray(response.ResultItems)) throw new Error(qsTranslate("AmazonLocationService", "Could not read the search results."))
    return response.ResultItems.filter(item => item && validPosition(item.Position)).map(item => {
        const address = (item.Address && item.Address.Label) || ""
        const label = item.Title || address
        // An address that only repeats the label is dropped so views show it once.
        return { label: label, address: address === label ? "" : address, position: item.Position }
    }).filter(place => place.label)
}

// QGIS filter for features whose display name contains the text or whose ID it names; blank text lists every feature.
function featureFilterExpression(text, displayExpression) {
    const term = text.trim()
    if (!term) return ""
    // Quote the input as a QGIS string literal; strpos treats wildcards literally.
    const needle = "lower('" + term.replace(/\\/g, "\\\\").replace(/'/g, "''") + "')"
    const name = "coalesce(nullif(to_string((" + (displayExpression || "NULL") + ")), ''), to_string($id))"
    const idMatch = /^(?:fid\s+)?(-?\d+)$/i.exec(term)
    return "strpos(lower(" + name + "), " + needle + ") > 0" + (idMatch ? " OR $id = " + idMatch[1] : "")
}
