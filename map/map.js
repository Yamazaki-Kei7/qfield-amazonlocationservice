"use strict";

// QField sends a new snapshot when this local page opens. Only the style changes
// while the page is open, so switching imagery never refits or repeats a search.
let map;
let snapshot;
let markers = [];
let styleReady = false;

function showFailure() {
    document.getElementById("error").hidden = false;
}

function updateOverlays(stopsVisible, lineVisible) {
    if (!snapshot) return;
    snapshot.stopsVisible = stopsVisible;
    snapshot.lineVisible = lineVisible;
    for (const marker of markers) marker.remove();
    markers = [];
    if (!styleReady) return;
    function mark(position, label) {
        const el = document.createElement("div");
        el.className = "stop";
        el.textContent = label;
        markers.push(new maplibregl.Marker({element: el}).setLngLat(position).addTo(map));
    }
    if (stopsVisible) snapshot.stops.forEach((p, i) => mark(p, String(i + 1)));
    if (map.getLayer("qfield-route"))
        map.setLayoutProperty("qfield-route", "visibility", lineVisible ? "visible" : "none");
}

function styleUrl(style) {
    const url = new URL("/v2/styles/" + style + "/descriptor", snapshot.endpoint);
    url.searchParams.set("key", snapshot.key);
    return url.href;
}

function changeStyle(style) {
    if (!map) return;
    document.getElementById("error").hidden = true;
    styleReady = false;
    updateOverlays(snapshot.stopsVisible, snapshot.lineVisible);
    map.setStyle(styleUrl(style), {diff: false});
}

function openMap(data) {
    snapshot = data;
    document.getElementById("error").textContent = data.errorText;
    try {
        map = new maplibregl.Map({
            container: "map", style: styleUrl(data.style),
            center: data.stops[0],
            attributionControl: {compact: false},
            transformRequest(url) {
                const request = new URL(url, document.baseURI);
                if (request.origin === data.endpoint) request.searchParams.set("key", data.key);
                return {url: request.href, cache: "no-store"};
            }
        });
        map.addControl(new maplibregl.NavigationControl({showCompass: false}), "top-left");
        map.on("error", showFailure);
        map.on("style.load", () => {
            if (data.lines.length) {
                map.addSource("qfield-route", {type: "geojson",
                    data: {type: "MultiLineString", coordinates: data.lines}});
                map.addLayer({id: "qfield-route", type: "line", source: "qfield-route",
                    layout: {"line-join": "round", "line-cap": "round"},
                    paint: {"line-width": 5, "line-color": "#0079bd"}});
            }
            styleReady = true;
            updateOverlays(data.stopsVisible, data.lineVisible);
        });
        const bounds = new maplibregl.LngLatBounds();
        const origin = data.stops[0][0];
        // Keep a route crossing the date line in the same copy of the world.
        const extend = p => bounds.extend([origin + ((p[0] - origin + 540) % 360) - 180, p[1]]);
        data.stops.forEach(extend);
        data.lines.forEach(leg => leg.forEach(extend));
        const canvas = map.getCanvas();
        const padding = Math.min(36, canvas.clientWidth / 4, canvas.clientHeight / 4);
        map.fitBounds(bounds, {padding, maxZoom: 16, duration: 0});
        return true;
    } catch (error) {
        showFailure();
        return false;
    }
}
