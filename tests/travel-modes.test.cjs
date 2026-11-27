const { test } = require("node:test")
const assert = require("node:assert/strict")
const routes = require("./load-routes.cjs")()

const stops = [[139, 35], [140, 36], [141, 37]].map(position => ({ position }))
const legs = stops.slice(1).map((stop, i) => ({
    Geometry: { LineString: [stops[i].position, stop.position] }
}))

test("travel modes and routing criteria have short English labels", () => {
    assert.deepEqual(Array.from(routes.travelModes, mode => mode.label),
        ["Car", "Walking", "Scooter", "Truck", "Public transit", "Intermodal"])
    assert.equal(routes.criterionLabel("ShortestRoute"), "Shortest")
    assert.equal(routes.criterionLabel("FastestRoute"), "Fastest")
})

for (const [mode, criterion] of [
    ["Car", "ShortestRoute"], ["Pedestrian", "FastestRoute"],
    ["Scooter", "FastestRoute"], ["Truck", "ShortestRoute"]
]) {
    test(mode + " preserves ordered waypoints and requests " + criterion, () => {
        const body = routes.requestBody(stops, mode)
        assert.equal(body.TravelMode, mode)
        assert.equal(body.OptimizeRoutingFor, criterion)
        assert.equal(body.Waypoints.length, 1)
        assert.deepEqual(body.Waypoints[0].Position, stops[1].position)
        assert.deepEqual(body.Origin, stops[0].position)
        assert.deepEqual(body.Destination, stops[2].position)
    })

    test(mode + " applies supported routing preferences", () => {
        assert.equal(routes.requestBody(stops, mode, "FastestRoute").OptimizeRoutingFor, "FastestRoute")
        assert.equal(routes.requestBody(stops, mode, "ShortestRoute").OptimizeRoutingFor, criterion)
    })
}

test("route validation failures display the service message when available", () => {
    const detail = "'OptimizeRoutingFor' must not have value ShortestRoute when 'TravelMode' has value Pedestrian."
    const message = routes.rejection("Could not find a route", 400, JSON.stringify({ message: detail }))
    assert.match(message, /HTTP 400/)
    assert.ok(message.includes(detail))
    for (const reply of ["", "<html>Bad Request</html>", "null"]) {
        const fallback = routes.rejection("Could not find a route", 400, reply)
        assert.match(fallback, /HTTP 400/)
        assert.match(fallback, /Check the stops and travel mode/)
        assert.doesNotMatch(fallback, /<html>|permissions/)
    }
})

test("all travel modes request summaries with the route geometry", () => {
    for (const mode of routes.travelModes) {
        const body = routes.requestBody(stops.slice(0, 2), mode.id)
        assert.deepEqual(Array.from(body.LegAdditionalFeatures), ["Summary"])
        assert.equal(body.LegGeometryFormat, "Simple")
    }
})

test("route results prefer route-wide totals and sum whole legs before rounding", () => {
    const Legs = ["Pedestrian", "Transit", "Ferry"].map(Type => ({
        Type, [Type + "LegDetails"]: { Summary: { Overview: { Distance: 450, Duration: 30 }, TravelOnly: { Duration: 10 } } }
    }))
    assert.equal(routes.routeSummary({ Legs }), "About 2 min · 1.4 km")
    assert.equal(routes.routeSummary({ Legs, Summary: { Duration: 5400, Distance: 12390 } }), "About 1 hr 30 min · 12.4 km")
    assert.equal(routes.routeSummary({ Legs, Summary: { Duration: 3600 } }), "About 1 hr · 1.4 km")
})

test("route results show only complete totals, including genuine zeros", () => {
    const Legs = [{ Type: "Vehicle", VehicleLegDetails: { Summary: { Overview: { Distance: 400, Duration: 20 } } } }, { Type: "Taxi" }]
    assert.equal(routes.routeSummary({ Legs }), "Distance and travel time unavailable")
    assert.equal(routes.routeSummary({ Legs, Summary: { Distance: 520, Duration: -1 } }), "520 m")
    assert.equal(routes.routeSummary({ Legs, Summary: { Distance: null, Duration: 20 } }), "About 1 min")
    assert.equal(routes.routeSummary({ Legs, Summary: { Distance: 0, Duration: 0 } }), "About 0 min · 0 m")
})

test("route and search failures give English guidance", () => {
    assert.throws(() => routes.requestBody([], "Car"), /valid stops.*travel mode/)
    assert.throws(() => routes.routeWkt({}, {}), /No route.*all legs/)
    assert.throws(() => routes.routeWkt({ Routes: [{ Legs: [{ Geometry: {} }] }] }, {}), /route coordinates/)
    assert.throws(() => routes.placeResults({}), /search results/)
    assert.match(routes.rejection("Could not find a route", 403, ""), /region.*API key permissions/)
})

test("place search preserves multilingual names and addresses", () => {
    const places = routes.placeResults({ ResultItems: [
        { Title: "東京駅", Address: { Label: "東京都千代田区" }, Position: [139.7671, 35.6812] },
        { Title: "São Paulo", Address: { Label: "São Paulo" }, Position: [-46.6333, -23.5505] }
    ] })
    assert.deepEqual(Array.from(places, place => [place.label, place.address]), [
        ["東京駅", "東京都千代田区"], ["São Paulo", ""]
    ])
})

test("feature filter matches display names literally and feature IDs exactly", () => {
    const name = "coalesce(nullif(to_string((\"name\")), ''), to_string($id))"
    assert.equal(routes.featureFilterExpression("  ", '"name"'), "")
    assert.equal(routes.featureFilterExpression(" 駅 ", '"name"'), "strpos(lower(" + name + "), lower('駅')) > 0")
    assert.equal(routes.featureFilterExpression("O'Brien\\%", '"name"'),
        "strpos(lower(" + name + "), lower('O''Brien\\\\%')) > 0")
    for (const [term, id] of [["42", "42"], ["FID 42", "42"], ["fid -3", "-3"]])
        assert.ok(routes.featureFilterExpression(term, '"name"').endsWith(" OR $id = " + id))
    for (const term of ["FID", "42 Main St"])
        assert.ok(!routes.featureFilterExpression(term, '"name"').includes(" OR "))
    assert.match(routes.featureFilterExpression("a", ""), /to_string\(\(NULL\)\)/)
})

for (const mode of ["Transit", "Intermodal"]) {
    test(mode + " uses two stops and displays every transfer leg", () => {
        const body = routes.requestBody(stops.slice(0, 2), mode)
        assert.equal(body.TravelMode, mode)
        assert.equal(body.DepartNow, true)
        assert.ok(!("Waypoints" in body))
        assert.ok(!("OptimizeRoutingFor" in body))
        for (const choice of ["FastestRoute", "ShortestRoute"])
            assert.ok(!("OptimizeRoutingFor" in routes.requestBody(stops.slice(0, 2), mode, choice)))
        assert.throws(() => routes.requestBody(stops, mode))
        assert.equal(routes.routeWkt({ Routes: [{ Legs: legs }] }, body),
            "MULTILINESTRING((139 35,140 36),(140 36,141 37))")
        assert.throws(() => routes.routeWkt({ Routes: [{ Legs: [] }] }, body))
    })
}
