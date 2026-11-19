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

for (const mode of ["Car", "Pedestrian", "Scooter", "Truck"]) {
    test(mode + " preserves ordered waypoints and shortest-distance routing", () => {
        const body = routes.requestBody(stops, mode)
        assert.equal(body.TravelMode, mode)
        assert.equal(body.OptimizeRoutingFor, "ShortestRoute")
        assert.equal(body.Waypoints.length, 1)
        assert.deepEqual(body.Waypoints[0].Position, stops[1].position)
        assert.deepEqual(body.Origin, stops[0].position)
        assert.deepEqual(body.Destination, stops[2].position)
    })
}

for (const mode of ["Transit", "Intermodal"]) {
    test(mode + " uses two stops and displays every transfer leg", () => {
        const body = routes.requestBody(stops.slice(0, 2), mode)
        assert.equal(body.TravelMode, mode)
        assert.equal(body.DepartNow, true)
        assert.ok(!("Waypoints" in body))
        assert.ok(!("OptimizeRoutingFor" in body))
        assert.throws(() => routes.requestBody(stops, mode))
        assert.equal(routes.routeWkt({ Routes: [{ Legs: legs }] }, body),
            "MULTILINESTRING((139 35,140 36),(140 36,141 37))")
        assert.throws(() => routes.routeWkt({ Routes: [{ Legs: [] }] }, body))
    })
}
