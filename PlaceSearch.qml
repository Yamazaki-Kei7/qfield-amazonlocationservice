import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts
import org.qfield.core
import org.qfield.gui
import "Routes.js" as Routes

ColumnLayout {
    id: search
    required property string region
    required property string apiKey
    required property string connectionHint
    required property var searchCenter
    required property int gutter
    required property int touchHeight
    required property string selectionHint
    signal settingsRequested()
    signal chosen(var place)

    readonly property var pending: request.pending
    property var results: []
    property string feedback: ""

    function cancel() {
        request.cancel()
    }

    function clearResults() {
        cancel()
        results = []
        feedback = ""
    }

    function reset() {
        clearResults()
        query.clear()
    }

    function submit() {
        const term = query.text.trim()
        if (!term || connectionHint || pending) return
        const center = searchCenter()
        results = []
        if (!Routes.validPosition(center)) {
            feedback = qsTranslate("AmazonLocationService", "Could not get the map center. Move the map and search again.")
            return
        }
        Qt.inputMethod.hide()
        feedback = ""
        //: BCP 47 language code requested for place names and addresses.
        const language = qsTranslate("AmazonLocationService", "en", "SearchText language code")
        request.post("places", "search-text", { QueryText: term, BiasPosition: center, Language: language }, text => {
            try {
                results = Routes.placeResults(JSON.parse(text))
                if (!results.length) {
                    feedback = qsTranslate("AmazonLocationService", "No places found. Try another place name or area.")
                } else if (results.length === 1) {
                    feedback = qsTranslate("AmazonLocationService", "1 result · %1").arg(selectionHint)
                } else {
                    feedback = qsTranslate("AmazonLocationService", "%1 results · %2").arg(results.length).arg(selectionHint)
                }
            } catch (error) {
                feedback = qsTranslate("AmazonLocationService", "Could not read the search results. Try again.")
            }
        })
    }
    LocationRequest {
        id: request
        region: search.region
        apiKey: search.apiKey
        onFailed: reason => search.feedback = reason
        onRejected: status => search.feedback = qsTranslate("AmazonLocationService", "Place search failed (HTTP %1). Check the Region and the key's geo-places:SearchText permission.").arg(status)
    }

    spacing: 0
    ColumnLayout {
        Layout.fillWidth: true
        Layout.margins: search.gutter
        spacing: 6
        Label {
            text: qsTranslate("AmazonLocationService", "Place or address")
            font: QfTheme.strongResultFont
        }
        RowLayout {
            Layout.fillWidth: true
            TextField {
                id: query
                Layout.fillWidth: true
                Layout.minimumWidth: 0
                placeholderText: qsTranslate("AmazonLocationService", "e.g. station, cafe")
                Accessible.name: qsTranslate("AmazonLocationService", "Place or address")
                maximumLength: 200
                onAccepted: search.submit()
                onTextEdited: search.clearResults()
            }
            LocationButton {
                text: qsTranslate("AmazonLocationService", "Search")
                Layout.minimumHeight: search.touchHeight
                enabled: !!query.text.trim() && !search.pending && !search.connectionHint
                primary: true
                onClicked: search.submit()
            }
        }
        Label {
            Layout.fillWidth: true
            wrapMode: Text.Wrap
            text: search.connectionHint || (search.pending ? qsTranslate("AmazonLocationService", "Searching…") :
                search.feedback || qsTranslate("AmazonLocationService", "Places near the map center are prioritized."))
            color: QfTheme.secondaryTextColor
        }
        LocationButton {
            text: qsTranslate("AmazonLocationService", "Settings")
            visible: !!search.connectionHint || (!search.pending && !search.results.length)
            onClicked: search.settingsRequested()
        }
        ProgressBar {
            Layout.fillWidth: true
            visible: !!search.pending
            indeterminate: visible
        }
    }
    ListView {
        Layout.fillHeight: true
        Layout.fillWidth: true
        clip: true
        model: search.results
        delegate: ItemDelegate {
            required property var modelData
            width: ListView.view.width
            leftPadding: search.gutter
            rightPadding: search.gutter
            implicitHeight: Math.max(search.touchHeight, implicitContentHeight + topPadding + bottomPadding)
            Accessible.name: [modelData.label, modelData.address].filter(Boolean).join(", ")
            contentItem: RowLayout {
                spacing: 8
                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.minimumWidth: 0
                    spacing: 3
                    Label {
                        Layout.fillWidth: true
                        text: modelData.label
                        textFormat: Text.PlainText
                        wrapMode: Text.Wrap
                        font: QfTheme.strongResultFont
                    }
                    Label {
                        Layout.fillWidth: true
                        visible: !!text
                        text: modelData.address
                        textFormat: Text.PlainText
                        wrapMode: Text.Wrap
                        color: QfTheme.secondaryTextColor
                    }
                }
                Label {
                    text: "›"
                    color: Material.accent
                    font: QfTheme.strongTitleFont
                    Accessible.ignored: true
                }
            }
            onClicked: search.chosen(modelData)
        }
        ScrollBar.vertical: ScrollBar {}
    }
}
