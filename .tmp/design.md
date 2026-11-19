# 詳細設計書 - 訪問順の最適化（ウェイポイント最適化）

要件：`.tmp/requirements.md`

## 1. アーキテクチャ概要

### 1.1 システム構成図

```
┌────────────────────────── main.qml（状態と表示） ──────────────────────────┐
│  stops / travelMode / fixedEnd / undoStops / optimizeNote / message       │
│                                                                           │
│  [訪問順を最適化] ─ optimize() ─┐              [経路を検索] ─ search() ─┐   │
│                                │                                      │   │
│        optimizeRequest (LocationRequest)          routeRequest (既存)  │   │
└────────────────────────────────┼──────────────────────────────────────┼───┘
                                 │ POST /v2/optimize-waypoints          │ POST /v2/routes
                                 ▼                                      ▼
                       Amazon Location Service（routes.geo.<region>.amazonaws.com）

┌────────────────────────── Routes.js（純粋な関数） ─────────────────────────┐
│  optimizeBody()      リクエストの組み立て                                   │
│  optimizedStops()    応答 → 並べ替えた stops、変更の有無、距離・時間の要約    │
│  optimizeRejection() HTTP ステータス → 案内文                               │
│  minOptimizeStops() / boundsPerimeterKm() / tripSummary()                 │
└───────────────────────────────────────────────────────────────────────────┘
```

最適化は一覧（`stops`）を並べ替えるだけで、経路は描かない。経路の検索は既存の `search()` をそのまま使う。

### 1.2 技術スタック

- 言語：QML（Qt 6）、JavaScript（QML から import する素の JS）
- 実行環境：QField のプラグイン。外部ライブラリは追加しない
- 外部 API：Amazon Location Service Routes v2 の `OptimizeWaypoints`（API キー認証）
- テスト：Node.js 標準の `node:test`（`node --test tests/`）、`qmllint`

## 2. コンポーネント設計

### 2.1 コンポーネント一覧

| コンポーネント | 責務 | 変更 |
| --- | --- | --- |
| `Routes.js` | リクエストの組み立て、応答の解釈、案内文、定数 | 関数を追加（既存の関数は変更しない） |
| `main.qml` | 状態の保持、最適化の実行と取り消し、「訪問順」の UI | 状態・関数・UI を追加 |
| `LocationRequest.qml` | 1件の POST、中断、タイムアウト | 変更なし（インスタンスを1つ追加して使う） |
| `tests/optimize-waypoints.test.cjs` | `Routes.js` に追加した関数のテスト | 新規 |
| `README.md` / `metadata.txt` / ZIP | 利用者向けの説明、バージョン、配布物 | 更新 |

### 2.2 `Routes.js` に追加する関数

```js
// OptimizeWaypoints は、全地点を囲む矩形の周長がこの値を超えると HTTP 400 で拒否する。
var optimizePerimeterKm = 500

// 最適化に必要な地点数。並べ替える地点が2つ以上になる数。
function minOptimizeStops(fixedEnd)            // fixedEnd ? 4 : 3

// stops: [{ position: [lon, lat], label }], mode: "Car" など, fixedEnd: 最後の地点を目的地として固定するか
// 条件を満たさない場合は Error を投げる（非対応の移動手段、地点数の不足・超過、不正な座標）。
function optimizeBody(stops, mode, fixedEnd)   // → リクエストボディ

// response: API の応答, stops / fixedEnd: optimizeBody に渡したもの
// → { stops: 並べ替えた配列, changed: 順序が変わったか, summary: "（約12.3 km・約35分）" または "" }
// 応答を読み取れない場合や、到達できない地点がある場合は Error を投げる。
function optimizedStops(response, stops, fixedEnd)

// status: HTTP ステータス, stops: 送信した地点 → 画面に出す案内文
function optimizeRejection(status, stops)

function boundsPerimeterKm(positions)          // 全地点を囲む経緯度の矩形の周長（km、幅は中央の緯度で測る）
function tripSummary(distance, duration)       // メートル・秒 → "（約12.3 km・約35分）"。値がなければ ""
```

**`optimizeBody` の組み立て**

| | スイッチがオフ（終点は自動） | スイッチがオン（目的地を固定） |
| --- | --- | --- |
| `Origin` | `stops[0]` | `stops[0]` |
| `Waypoints` | `stops[1..n-1]` | `stops[1..n-2]` |
| `Destination` | 指定しない | `stops[n-1]` |

- 共通：`TravelMode: mode`、`OptimizeSequencingFor: "ShortestRoute"`。
- 各 `Waypoints` には `Id` として、`stops` 内の添字を文字列にしたもの（`"1"`、`"2"`…）を付ける。地点の名前は送らない。
- `OriginOptions` / `DestinationOptions` は指定しない。出発地・目的地は API の既定の ID（`"Origin"`、`"Destination"`）で返る。対応付けには不要で、目的地の制約オプションは Premium 料金の条件になるため、送る項目を最小限にする。
- `DepartureTime`、`Traffic`、`Avoid`、`Clustering` は指定しない（料金区分を上げないため、また今回の要件にないため）。

**`optimizedStops` の解釈**

1. `ImpedingWaypoints` が空でなければ、ID から地点名を引いて Error を投げる（`"Origin"` → `stops[0]`、`"Destination"` → 最後の地点、数字 → その添字の地点）。
2. `OptimizedWaypoints` から、自分が付けた ID を持つ要素だけを順に取り出す（`"Origin"`、`"Destination"` は読み飛ばす）。
3. 取り出した ID が、送った ID の並べ替え（過不足・重複なし）になっていなければ Error を投げる。
4. `[stops[0], ...並べ替えた地点, (fixedEnd なら最後の地点)]` を返す。`changed` は ID の列が元の順（`"1"`、`"2"`…）と違うかどうか。
5. `summary` は `tripSummary(response.Distance, response.Duration)`。

### 2.3 `main.qml` の変更

**状態**

```qml
property bool fixedEnd: false        // 最後の地点を目的地として固定する
property var undoStops: null         // 最適化の直前の stops。取り消せる間だけ保持する
property string optimizeNote: ""     // 最適化の結果の表示文
readonly property var pending: routeRequest.pending || optimizeRequest.pending   // 既存の定義を拡張
readonly property bool optimizing: !!optimizeRequest.pending
readonly property bool optimizable: Routes.supportsWaypoints(travelMode.id)
    && stops.length >= Routes.minOptimizeStops(false) && stops.length <= maxStops   // 操作部を表示する条件
readonly property bool canOptimize: optimizable && stops.length >= Routes.minOptimizeStops(fixedEnd)
    && !connectionHint && !pending                                                  // ボタンを有効にする条件
```

**関数**

```qml
function optimize() {
    if (!canOptimize) return
    const before = stops
    const fixed = fixedEnd
    message = ""
    try {
        optimizeRequest.post("routes", "optimize-waypoints", Routes.optimizeBody(before, travelMode.id, fixed), text => {
            try {
                const result = Routes.optimizedStops(JSON.parse(text), before, fixed)
                if (result.changed) stops = result.stops   // onStopsChanged が経路・取り消し・結果表示を消す
                undoStops = result.changed ? before : null
                optimizeNote = (result.changed ? "最適な順に並べ替えました" : "すでに最適な順序です") + result.summary
            } catch (error) {
                message = error.message
            }
        })
    } catch (error) {
        message = error.message
    }
}

function undoOptimize() {
    if (pending || !undoStops) return
    stops = undoStops   // onStopsChanged が取り消し用の状態を消す
}
```

**状態を破棄するタイミング**

| きっかけ | `undoStops` | `optimizeNote` | 経路 |
| --- | --- | --- | --- |
| 最適化で順序が変わった | 直前の順序を保持 | 結果を表示 | 消える（`stops` の変更による） |
| 最適化したが順序は同じ | `null` | 「すでに最適な順序です」 | 残る（`stops` を代入しない） |
| 地点の追加・削除・手動の並べ替え・取り消し（`onStopsChanged`） | `null` | 空 | 消える（既存） |
| 移動手段の変更・スイッチの切り替え | そのまま | 空 | 移動手段の変更では消える（既存） |

`onStopsChanged` は代入と同期して走るので、`optimize()` では `stops` を代入したあとに `undoStops` と `optimizeNote` を設定する。フラグは使わない。

**通信**

```qml
LocationRequest {
    id: optimizeRequest
    region: plugin.region
    apiKey: plugin.apiKey
    onFailed: reason => plugin.message = reason
    onRejected: status => plugin.message = Routes.optimizeRejection(status, plugin.stops)
}
```

既存の `routeRequest` と分けるのは、拒否されたときの案内文が違うため（種別のフラグを持たずに済む）。`pending` を両方の論理和にすることで、最適化中も既存の操作抑止（地点の追加、並べ替え、移動手段、検索ボタン、設定欄）がそのまま効く。`panel.onAboutToHide` では両方を `cancel()` する。

**UI（「訪問順」セクション）**

操作部は一覧の上に置く。25 地点あっても、スクロールせずに最適化を実行できるようにするため。

```
訪問順（5 / 25）
左の番号を上下にドラッグして並べ替え
┌────────────────────────────────────────────┐
│ [          訪問順を最適化          ]         │ ← LocationButton（幅いっぱい、高さ 44 以上）
│ 最後の地点を目的地として固定          (○ )   │ ← Label + Switch
│ 出発地を固定し、ほかの地点を総距離が最短に     │ ← 補足文（小さい文字、状態で切り替え）
│ なる順に並べ替えます。                       │
│ 最適な順に並べ替えました（約12.3 km・約35分）  │ ← optimizeNote があるとき
│                         [元の順序に戻す]     │ ← undoStops があるとき
└────────────────────────────────────────────┘
[1 出発地 …] [2 経由地 …] …（既存のカード）
[末尾の地点を削除] [全消去]
```

- 表示条件：`plugin.optimizable`（経由地を使える移動手段で、3 地点以上）。2 地点以下、公共交通・複合移動では出さない。
- ボタン：`enabled: plugin.canOptimize`、文言は `optimizing ? "最適化中…" : "訪問順を最適化"`。画面全体の主ボタンは下部の検索ボタンなので、塗りつぶしにはしない。
- スイッチ：`QtQuick.Controls` の `Switch`。`checked: plugin.fixedEnd`、`onToggled: plugin.fixedEnd = checked`、`enabled: !plugin.pending`。文言は折り返せるように別の `Label` に置き、`Accessible.name` に同じ文言を設定する。
- 補足文（上から順に判定）：
  1. 3 地点でスイッチがオン：「目的地を固定する場合は、4地点以上で最適化できます。」
  2. スイッチがオン：「出発地と目的地を固定し、経由地を総距離が最短になる順に並べ替えます。」
  3. スイッチがオフ：「出発地を固定し、ほかの地点を総距離が最短になる順に並べ替えます。」
- 結果の表示はトーストではなく画面内に置く。取り消しボタンと並べて見せるためと、モーダルの上でトーストが見えるかどうかに依存しないため。
- 下部の進捗表示：`Accessible.name` を `optimizing ? "訪問順を最適化中" : "経路を検索中"` にする。検索ボタンの文言「経路を検索中…」は `routeRequest.pending` のときだけにする（最適化中は通常の文言のまま無効）。
- エラーは既存と同じく下部のステータス欄（`plugin.message`）に出す。下部は固定表示なので、一覧をスクロールしていても見える。

## 3. データフロー

### 3.1 データフロー図

```
[訪問順を最適化] をタップ
  → optimize()：stops と fixedEnd を控える
  → Routes.optimizeBody()            → { Origin, Waypoints:[{Id,Position}], Destination?, TravelMode, OptimizeSequencingFor }
  → optimizeRequest.post()           → POST https://routes.geo.<region>.amazonaws.com/v2/optimize-waypoints?key=…
      ├ 200 → Routes.optimizedStops() ├ 成功 → stops を並べ替え、undoStops・optimizeNote を設定
      │                               └ 例外 → message（一覧は変更しない）
      ├ 200 以外 → onRejected → Routes.optimizeRejection() → message
      └ 応答なし → onFailed → message
[経路を検索] をタップ（既存）
  → search() → CalculateRoutes → 地図に経路を表示
```

### 3.2 データ変換

- 入力：`stops`（`[{ position: [経度, 緯度], label }]`）、`travelMode.id`、`fixedEnd`。
- 応答（公式ドキュメントの例より）：`OptimizedWaypoints: [{ Id: "Origin", … }, { Id: "<送った ID>", … }, …, { Id: "Destination", … }]`、`Distance`（m）、`Duration`（秒）、`ImpedingWaypoints`。
- 出力：並べ替えた `stops`（地点のオブジェクトは元のものを使い回す）、`changed`、`summary`。

## 4. APIインターフェース

### 4.1 内部API

2.2、2.3 のとおり。

### 4.2 外部API

`POST /v2/optimize-waypoints?key=<API キー>`（[API リファレンス](https://docs.aws.amazon.com/location/latest/APIReference/API_OptimizeWaypoints.html)）

- 必要な許可：`geo-routes:OptimizeWaypoints`
- 上限：経由地 50（このプラグインでは最大 24）、全地点を囲む矩形の周長 500 km（超えると HTTP 400。実際の呼び出しで確認済み）
- ドキュメントには「指定順の直線距離の合計 100 km」という上限もあるが、合計が約 170 km の呼び出しは成功した。このプラグインでは判定に使わない。
- 料金区分（[Routes pricing](https://docs.aws.amazon.com/location/latest/developerguide/routes-pricing.html)）：車・徒歩・トラックで、全地点を囲む矩形が 200 km 以内なら Advanced。スクーター、または 200 km を超える場合は Premium（周長が約 245 km の呼び出しが Premium になることを確認済み）。

## 5. エラーハンドリング

### 5.1 エラー分類

| 状況 | 検出 | 案内文 |
| --- | --- | --- |
| HTTP 403 | `optimizeRejection` | 訪問順を最適化できませんでした（HTTP 403）。API キーに `geo-routes:OptimizeWaypoints` の許可があるか確認してください。 |
| HTTP 400 で、全地点を囲む矩形の周長が 500 km 超 | `optimizeRejection` + `boundsPerimeterKm` | 訪問順を最適化できませんでした。全地点を囲む範囲の周長が約 N km で、上限の 500 km を超えています。地点を減らすか、範囲を狭めてください。 |
| その他の HTTP 400 | `optimizeRejection` | 訪問順を最適化できませんでした（HTTP 400）。地点が道路から大きく離れていないか、広い範囲（周長 500 km 超）に散らばっていないか確認してください。 |
| その他の HTTP エラー | `optimizeRejection` | 訪問順を最適化できませんでした（HTTP N）。地点、リージョン、キーの権限を確認してください。 |
| 到達できない地点（`ImpedingWaypoints`） | `optimizedStops` | 「A」「B」を通る順序が見つからず、訪問順を最適化できませんでした。 |
| 応答を読み取れない | `optimizedStops` | 最適化の結果を読み取れませんでした。 |
| 通信不可・タイムアウト | `LocationRequest`（既存） | 既存の文言 |

**範囲超過をリクエストの前に弾かない理由**：サービス側の周長の測り方は公開されておらず、クライアントの計算とは差が出る。事前に弾くと、境界付近で通るはずのリクエストを止めるおそれがある。また、上限が将来引き上げられた場合に、プラグイン側だけが古い上限で止め続けることになる。そのため、拒否されたあとに原因を推定して案内する。計算した周長が上限以下でも、400 の案内文には範囲の上限を含める（境界付近の差を吸収するため）。

### 5.2 エラー通知

すべて `plugin.message` に入れ、経路検索画面の下部に表示する。どの場合も `stops` は変更しない。ログ出力はしない。

## 6. セキュリティ設計

### 6.1 認証・認可

API キーを URL のクエリに付ける既存の方式（`LocationRequest`）をそのまま使う。キーは保存もログ出力もしない。

### 6.2 データ保護

送信するのは座標・移動手段・連番の ID のみ。地点の名前は送らない。画面に出す文字列は、自前の文言と利用者が登録した地点名だけで、API の応答に含まれる文字列は表示しない。

## 7. テスト戦略

### 7.1 単体テスト（`tests/optimize-waypoints.test.cjs`）

- `optimizeBody`：スイッチのオフ／オンでの `Origin`・`Waypoints`・`Destination`・`Id`、`ShortestRoute`、移動手段。公共交通・複合移動、地点数の不足（オフで 2、オンで 3）、不正な座標で例外。
- `optimizedStops`：並べ替え（`Origin`・`Destination` の要素を含む応答）、スイッチがオンのとき最後の地点が残ること、順序が同じなら `changed` が偽、ID の欠落・重複・`OptimizedWaypoints` がない応答で例外、`ImpedingWaypoints` で地点名を含む例外。
- `optimizeRejection`：403、400 で周長 500 km 超、400 で 500 km 以内、その他。
- `boundsPerimeterKm`：実際の呼び出しで使った地点（拒否された約 1,390 km、成功した約 245 km）で、想定どおりの値になること。
- `tripSummary`：1 km 未満、1 km 以上、60 分未満、60 分以上、値がない場合。
- 既存の `tests/travel-modes.test.cjs` が通ること。

### 7.2 統合テスト

- `qmllint main.qml`：変更前の警告を控えておき、変更後に増えていないことを確認する（QField のモジュールは解決できないため、警告そのものは残る）。
- 実機と実 API での確認は利用者に依頼する（要件 5.2）。

## 8. パフォーマンス最適化

- 最適化 1 回につきリクエストは 1 回。自動実行・再試行はしない。
- 地点は最大 25 なので、並べ替えや距離の計算のコストは無視できる。

## 9. デプロイメント

- `metadata.txt` の `version` を `1.8.1` → `1.9.0` にする（機能追加）。
- README の手順どおりに `amazon-location-service.zip` を作り直す。ZIP に入れるファイルの一覧は変わらない（テストは含めない）。
- README：API キーの表に `geo-routes:OptimizeWaypoints` を追加、「訪問順を確認して検索する」に最適化の手順、「知っておくと便利なこと」に周回の方法と範囲の上限、「うまくいかないとき」に 2 行、注意事項に料金（スクーターと広域は Premium）と API 仕様へのリンク。

## 10. 実装上の注意事項

- **実際の呼び出しで確認した結果（2026-11-19、ap-northeast-1、車、`ShortestRoute`、4 回）**
  1. `Destination` を省略すると、出発地に戻らない順序が返る（`Connections` の最後は経由地で終わる）。前提どおり。
  2. `Waypoints` に付けた `Id` は、応答の `OptimizedWaypoints` と `Connections` にそのまま返る。出発地は `"Origin"`、目的地は `"Destination"` で返る。前提どおり。
  3. 指定順の直線距離の合計が約 170 km の呼び出しは成功した（周長 約 245 km、料金区分は Premium）。ドキュメントの「100 km」の上限では拒否されなかった。
  4. 周長が約 1,390 km の呼び出しは HTTP 400（`ValidationException`、周長 500 km 超という内容）で拒否された。
  - 3 と 4 を受けて、範囲超過の判定を「直線距離の合計 100 km」から「矩形の周長 500 km」に変更した。
- `stops` には QML の事情で JS の配列でない値が入ることがある（既存コードのコメント参照）。`Routes.js` 側では添字と `length` だけでアクセスし、結果は新しい JS の配列で返す。
- `Switch` はポップアップの `Material.accent` を引き継ぐ。ダークテーマで視認できることを実機で確認する。
- 既存の `requestBody`・`routeWkt`・`search()` は変更しない。
- README の `img/visit-order-editor.png` は撮り直せないため、画像は差し替えず、利用者に依頼する。
