import QtQuick
import QtWebView

WebView {
    id: view
    readonly property url localPage: Qt.resolvedUrl("map/index.html")
    signal ready()
    signal failed()
    settings.javaScriptEnabled: true
    settings.allowFileAccess: true
    settings.localContentCanAccessFileUrls: true
    settings.localStorageEnabled: false
    url: localPage

    function invoke(method, args, callback) {
        // An attribution link can navigate the web view. Credentials belong
        // only to our bundled document, including when a navigation races this call.
        const script = "location.href === " + JSON.stringify(localPage.toString())
            + " && window[" + JSON.stringify(method) + "](" + args.map(arg => JSON.stringify(arg)).join(",") + ")"
        if (url.toString() === localPage.toString()) {
            if (callback) runJavaScript(script, callback)
            else runJavaScript(script)
        }
    }

    onLoadingChanged: request => {
        if (request.status === WebView.LoadSucceededStatus && url.toString() === localPage.toString()) ready()
        else if (request.status === WebView.LoadFailedStatus) failed()
    }
}
