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
    required property color accent
    required property color ink
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
            feedback = "地図の中心座標を取得できません。地図を移動して再検索してください。"
            return
        }
        Qt.inputMethod.hide()
        feedback = ""
        request.post("places", "search-text", { QueryText: term, BiasPosition: center, Language: "ja" }, text => {
            try {
                results = Routes.placeResults(JSON.parse(text))
                feedback = results.length ? results.length + "件 · " + selectionHint : "該当する場所がありません。施設名や地域名を変えて検索してください。"
            } catch (error) {
                feedback = "検索結果を読み取れませんでした。もう一度検索してください。"
            }
        })
    }
    LocationRequest {
        id: request
        region: search.region
        apiKey: search.apiKey
        onFailed: reason => search.feedback = reason
        onRejected: status => search.feedback = "POIを検索できませんでした（HTTP " + status + "）。リージョンとキーの geo-places:SearchText 権限を確認してください。"
    }

    spacing: 0
    ColumnLayout {
        Layout.fillWidth: true
        Layout.margins: search.gutter
        spacing: 6
        Label {
            text: "施設名・住所"
            font: QfTheme.strongResultFont
        }
        RowLayout {
            Layout.fillWidth: true
            TextField {
                id: query
                Layout.fillWidth: true
                Layout.minimumWidth: 0
                placeholderText: "例：東京駅、コンビニ"
                Accessible.name: "施設名・住所"
                maximumLength: 200
                onAccepted: search.submit()
                onTextEdited: search.clearResults()
            }
            Button {
                text: "検索"
                Layout.minimumHeight: search.touchHeight
                enabled: !!query.text.trim() && !search.pending && !search.connectionHint
                Material.background: enabled ? search.accent : QfTheme.controlBackgroundDisabledColor
                Material.foreground: QfTheme.darkTheme ? search.ink : "white"
                onClicked: search.submit()
            }
        }
        Label {
            Layout.fillWidth: true
            wrapMode: Text.Wrap
            text: search.connectionHint || (search.pending ? "検索中…" :
                search.feedback || "地図の中心に近い場所を優先します。")
            color: QfTheme.secondaryTextColor
        }
        Button {
            text: "接続設定"
            flat: true
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
            Accessible.name: [modelData.label, modelData.address].filter(Boolean).join("、")
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
                    color: QfTheme.secondaryTextColor
                    font: QfTheme.strongTitleFont
                    Accessible.ignored: true
                }
            }
            onClicked: search.chosen(modelData)
        }
        ScrollBar.vertical: ScrollBar {}
    }
}
