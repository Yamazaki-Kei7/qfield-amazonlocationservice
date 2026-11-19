const { test } = require("node:test")
const assert = require("node:assert/strict")
const { readFileSync } = require("node:fs")
const { join } = require("node:path")
const { runInNewContext } = require("node:vm")

// QML imports plain JS files as namespaces.
const routes = {}
runInNewContext(readFileSync(join(__dirname, "../Routes.js"), "utf8"), routes)
const stops = [[139, 35], [140, 36], [141, 37]].map(position => ({ position }))
const legs = stops.slice(1).map((stop, i) => ({
    Geometry: { LineString: [stops[i].position, stop.position] }
}))

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
    const message = routes.rejection("検索できませんでした", 400, JSON.stringify({ message: detail }))
    assert.match(message, /HTTP 400/)
    assert.ok(message.includes(detail))
    for (const reply of ["", "<html>Bad Request</html>", "null"]) {
        const fallback = routes.rejection("検索できませんでした", 400, reply)
        assert.match(fallback, /HTTP 400/)
        assert.doesNotMatch(fallback, /<html>|キーの権限/)
    }
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
