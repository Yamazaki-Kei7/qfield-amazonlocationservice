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
    required property int gutter
    required property int touchHeight
    required property string selectionHint
    signal settingsRequested()
    signal chosen(var place)

    property var pending: null
    property var results: []
    property string feedback: ""

    function cancel() {
        const request = pending
        pending = null
        timeout.stop()
        if (request) request.abort()
    }

    function reset() {
        cancel()
        query.clear()
        results = []
        feedback = ""
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
        const request = new XMLHttpRequest()
        pending = request
        feedback = ""
        request.onreadystatechange = function() {
            if (request.readyState !== XMLHttpRequest.DONE || pending !== request) return
            pending = null
            timeout.stop()
            if (request.status !== 200) {
                feedback = request.status === 0 ? "通信できません。接続を確認してください。"
                    : "POIを検索できませんでした（HTTP " + request.status + "）。リージョンとキーの geo-places:SearchText 権限を確認してください。"
                return
            }
            try {
                results = Routes.placeResults(JSON.parse(request.responseText))
                feedback = results.length ? results.length + "件 · " + selectionHint : "該当する場所がありません。施設名や地域名を変えて検索してください。"
            } catch (error) {
                feedback = "検索結果を読み取れませんでした。もう一度検索してください。"
            }
        }
        try {
            request.open("POST", "https://places.geo." + region + ".amazonaws.com/v2/search-text?key=" + encodeURIComponent(apiKey))
            request.setRequestHeader("Content-Type", "application/json")
            timeout.start()
            request.send(JSON.stringify({ QueryText: term, BiasPosition: center, Language: "ja" }))
        } catch (error) {
            cancel()
            feedback = "検索を開始できませんでした。"
        }
    }
    Component.onDestruction: cancel()
    Timer {
        id: timeout
        interval: 45000
        onTriggered: {
            search.cancel()
            search.feedback = "応答がありません。接続を確認して再検索してください。"
        }
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
                onTextEdited: {
                    search.cancel()
                    search.results = []
                    search.feedback = ""
                }
            }
            Button {
                text: "検索"
                Layout.minimumHeight: search.touchHeight
                enabled: !!query.text.trim() && !search.pending && !search.connectionHint
                Material.background: enabled ? search.accent : QfTheme.controlBackgroundDisabledColor
                Material.foreground: QfTheme.darkTheme ? "#232f3e" : "white"
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
                        visible: !!text && text !== modelData.label
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
