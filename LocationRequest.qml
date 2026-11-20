import QtQuick

// One in-flight JSON POST to an Amazon Location Service v2 endpoint, with abort and timeout.
QtObject {
    id: api
    required property string region
    required property string apiKey
    property var pending: null
    // No usable reply: offline, timed out, or the request could not be started.
    signal failed(string reason)
    // The service replied with a status other than 200.
    signal rejected(int status, string responseText)

    function cancel() {
        const request = pending
        pending = null
        timeout.stop()
        if (request) request.abort()
    }

    function post(service, path, body, loaded) {
        const request = new XMLHttpRequest()
        pending = request
        request.onreadystatechange = function() {
            if (request.readyState !== XMLHttpRequest.DONE || pending !== request) return
            pending = null
            timeout.stop()
            if (request.status === 200) loaded(request.responseText)
            else if (request.status === 0) api.failed(qsTranslate("AmazonLocationService", "Could not connect. Check your connection."))
            else api.rejected(request.status, request.responseText)
        }
        try {
            request.open("POST", "https://" + service + ".geo." + region + ".amazonaws.com/v2/" + path + "?key=" + encodeURIComponent(apiKey))
            request.setRequestHeader("Content-Type", "application/json")
            timeout.start()
            request.send(JSON.stringify(body))
        } catch (error) {
            cancel()
            api.failed(qsTranslate("AmazonLocationService", "Could not start the request."))
        }
    }

    Component.onDestruction: cancel()

    readonly property Timer timeout: Timer {
        interval: 45000
        onTriggered: {
            api.cancel()
            api.failed(qsTranslate("AmazonLocationService", "Request timed out. Check your connection and try again."))
        }
    }
}
