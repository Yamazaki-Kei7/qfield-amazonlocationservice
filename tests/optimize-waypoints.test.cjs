const { test } = require("node:test")
const assert = require("node:assert/strict")
const routes = require("./load-routes.cjs")()

const stops = [
    { position: [139.7671, 35.6812], label: "東京駅" },
    { position: [139.8139, 35.6967], label: "錦糸町" },
    { position: [139.7006, 35.6896], label: "新宿" },
    { position: [139.7745, 35.6840], label: "日本橋" },
    { position: [139.7933, 35.6969], label: "両国" }
]
// Stops the service accepted (about 245 km around) and rejected (about 1,393 km around).
const wide = [[139.7671, 35.6812], [139.6380, 35.4437], [140.1233, 35.6074], [139.6239, 35.9062], [139.3389, 35.6558]]
const tooWide = [[139.7671, 35.6812], [136.9066, 35.1815], [140.8719, 38.2682], [139.0364, 37.9161]]

// Values built inside the VM context have their own Array prototype.
const labels = list => Array.from(list, stop => stop.label)
const waypoints = body => Array.from(body.Waypoints, w => ({ Id: w.Id, Position: w.Position }))
const unusable = /travel mode and stops/
const reply = (ids, extra) => Object.assign({ OptimizedWaypoints: ids.map(Id => ({ Id })), ImpedingWaypoints: [] }, extra)

test("a free end sends every stop after the origin as a numbered waypoint", () => {
    const body = routes.optimizeBody(stops, "Car", false)
    assert.deepEqual(body.Origin, stops[0].position)
    assert.deepEqual(waypoints(body), [1, 2, 3, 4].map(i => ({ Id: String(i), Position: stops[i].position })))
    assert.ok(!("Destination" in body))
})

test("a fixed end sends the last stop as the destination", () => {
    const body = routes.optimizeBody(stops, "Car", true)
    assert.deepEqual(body.Origin, stops[0].position)
    assert.deepEqual(waypoints(body), [1, 2, 3].map(i => ({ Id: String(i), Position: stops[i].position })))
    assert.deepEqual(body.Destination, stops[4].position)
})

test("stop names stay on the device", () => {
    assert.ok(!JSON.stringify(routes.optimizeBody(stops, "Car", true)).includes("label"))
    for (const stop of stops) assert.ok(!JSON.stringify(routes.optimizeBody(stops, "Car", false)).includes(stop.label))
})

for (const mode of ["Car", "Pedestrian", "Scooter", "Truck"]) {
    test(mode + " can optimize visit order by distance or time", () => {
        const body = routes.optimizeBody(stops, mode, false)
        assert.equal(body.TravelMode, mode)
        assert.equal(body.OptimizeSequencingFor, "ShortestRoute")
        assert.equal(routes.optimizeBody(stops, mode, false, "FastestRoute").OptimizeSequencingFor, "FastestRoute")
    })
}

for (const mode of ["Transit", "Intermodal"]) {
    test(mode + " cannot optimize the order", () => {
        assert.throws(() => routes.optimizeBody(stops, mode, false), unusable)
    })
}

test("optimizing needs two stops between the fixed ends", () => {
    assert.equal(routes.minOptimizeStops(false), 3)
    assert.equal(routes.minOptimizeStops(true), 4)
    assert.equal(routes.optimizeBody(stops.slice(0, 3), "Car", false).Waypoints.length, 2)
    assert.throws(() => routes.optimizeBody(stops.slice(0, 2), "Car", false), unusable)
    assert.equal(routes.optimizeBody(stops.slice(0, 4), "Car", true).Waypoints.length, 2)
    assert.throws(() => routes.optimizeBody(stops.slice(0, 3), "Car", true), unusable)
})

test("optimizing rejects more stops than a route accepts and invalid positions", () => {
    const many = Array.from({ length: routes.stopLimit("Car") + 1 }, () => stops[1])
    assert.throws(() => routes.optimizeBody(many, "Car", false), unusable)
    assert.throws(() => routes.optimizeBody(stops.slice(0, 3).concat([{ position: [200, 95], label: "?" }]), "Car", false), unusable)
})

test("a free end reorders every stop after the origin", () => {
    const result = routes.optimizedStops(reply(["Origin", "2", "3", "4", "1"], { Distance: 21938, Duration: 3076 }), stops, false)
    assert.deepEqual(labels(result.stops), ["東京駅", "新宿", "日本橋", "両国", "錦糸町"])
    assert.equal(result.changed, true)
    assert.equal(result.summary, " (about 21.9 km, 51 min)")
})

test("a fixed end keeps the last stop as the destination", () => {
    const result = routes.optimizedStops(reply(["Origin", "2", "3", "1", "Destination"], { Distance: 23645, Duration: 3317 }), stops, true)
    assert.deepEqual(labels(result.stops), ["東京駅", "新宿", "日本橋", "錦糸町", "両国"])
    assert.equal(result.changed, true)
    assert.equal(result.summary, " (about 23.6 km, 55 min)")
})

test("reordering keeps the same stop objects", () => {
    const result = routes.optimizedStops(reply(["Origin", "2", "3", "4", "1"]), stops, false)
    assert.equal(result.stops[0], stops[0])
    assert.equal(result.stops[1], stops[2])
    assert.equal(result.stops[4], stops[1])
})

test("an order that is already optimal is reported as unchanged", () => {
    const free = routes.optimizedStops(reply(["Origin", "1", "2", "3", "4"]), stops, false)
    assert.equal(free.changed, false)
    assert.deepEqual(labels(free.stops), labels(stops))
    const fixed = routes.optimizedStops(reply(["Origin", "1", "2", "3", "Destination"]), stops, true)
    assert.equal(fixed.changed, false)
    assert.deepEqual(labels(fixed.stops), labels(stops))
})

test("a reply that does not order every waypoint exactly once is rejected", () => {
    const unreadable = /read the optimization result/
    assert.throws(() => routes.optimizedStops(reply(["Origin", "2", "3", "4"]), stops, false), unreadable)
    assert.throws(() => routes.optimizedStops(reply(["Origin", "2", "2", "3", "4"]), stops, false), unreadable)
    assert.throws(() => routes.optimizedStops(reply(["Origin", "2", "3", "4", "1", "1"]), stops, false), unreadable)
    assert.throws(() => routes.optimizedStops(reply(["Origin", "Waypoint0", "Waypoint1", "Waypoint2", "Waypoint3"]), stops, false), unreadable)
    assert.throws(() => routes.optimizedStops(reply(["Origin", "2", "3", "Destination"]), stops, true), unreadable)
    assert.throws(() => routes.optimizedStops({}, stops, false), unreadable)
})

test("stops the service cannot reach are named", () => {
    const blocked = { OptimizedWaypoints: [], ImpedingWaypoints: [{ Id: "2" }, { Id: "Destination" }, { Id: "Origin" }] }
    assert.throws(() => routes.optimizedStops(blocked, stops, true), error => {
        assert.match(error.message, /"新宿", "両国", "東京駅"/)
        assert.match(error.message, /Could not optimize visit order/)
        return true
    })
    assert.throws(() => routes.optimizedStops({ ImpedingWaypoints: [{ Id: "Waypoint9" }] }, stops, false), /Could not optimize visit order/)
    assert.throws(() => routes.optimizedStops({ ImpedingWaypoints: [null, { Id: "3" }] }, stops, false), /Could not optimize visit order.*"日本橋"/)
})

test("the perimeter around the stops matches what the service accepted and rejected", () => {
    assert.ok(Math.abs(routes.boundsPerimeterKm(wide) - 245) < 3)
    assert.ok(Math.abs(routes.boundsPerimeterKm(tooWide) - 1393) < 5)
    assert.equal(routes.boundsPerimeterKm([stops[0].position]), 0)
})

test("a rejected key is told which permission to add", () => {
    assert.match(routes.optimizeRejection(403, stops), /HTTP 403/)
    assert.match(routes.optimizeRejection(403, stops), /geo-routes:OptimizeWaypoints/)
})

test("stops spread too widely are told the perimeter and the limit", () => {
    const message = routes.optimizeRejection(400, tooWide.map(position => ({ position })))
    assert.match(message, /approximately 139\d km/)
    assert.match(message, /500 km limit/)
})

test("another rejected request does not claim the stops are too far apart", () => {
    const nearby = routes.optimizeRejection(400, stops)
    assert.match(nearby, /HTTP 400/)
    assert.doesNotMatch(nearby, /exceeding/)
    const throttled = routes.optimizeRejection(429, tooWide.map(position => ({ position })))
    assert.match(throttled, /HTTP 429/)
    assert.doesNotMatch(throttled, /exceeding/)
})

test("the trip summary uses metres under a kilometre and hours from sixty minutes", () => {
    assert.equal(routes.tripSummary(850, 300), " (about 850 m, 5 min)")
    assert.equal(routes.tripSummary(21938, 3076), " (about 21.9 km, 51 min)")
    assert.equal(routes.tripSummary(64000, 5400), " (about 64.0 km, 1 hr 30 min)")
    assert.equal(routes.tripSummary(98000, 7200), " (about 98.0 km, 2 hr)")
    assert.equal(routes.tripSummary(40, 20), " (about 40 m, 1 min)")
})

test("a reply without totals has no trip summary", () => {
    assert.equal(routes.tripSummary(undefined, undefined), "")
    assert.equal(routes.tripSummary(1200, undefined), "")
    assert.equal(routes.optimizedStops(reply(["Origin", "2", "3", "4", "1"]), stops, false).summary, "")
})
