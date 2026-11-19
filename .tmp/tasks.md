# タスクリスト - 訪問順の最適化（ウェイポイント最適化）

要件：`.tmp/requirements.md` ／ 設計：`.tmp/design.md`

## 概要

- 総タスク数: 9
- 推定作業時間: 2〜3 時間（Task 1.1 の認証情報の更新待ちを除く）
- 優先度: 高

## タスク一覧

### Phase 1: 準備・調査

#### Task 1.1: 実 API で前提を確認する

- [ ] AWS の認証情報を更新してもらう（現在は期限切れで呼び出せない）
- [ ] `OptimizeWaypoints` を 3 回呼ぶ（ap-northeast-1、車、`ShortestRoute`、経由地に `Id` を付ける）
  1. `Destination` なし：`Connections` と `Distance` から、出発地に戻らない順序かどうかを見る
  2. `Destination` あり：付けた `Id` と、`"Origin"`・`"Destination"` の返り方を見る
  3. 直線距離の合計が 100 km を超える地点：エラーの種類と HTTP ステータスを見る
- [ ] 結果を `.tmp/design.md` の「10. 実装上の注意事項」に反映する
- **完了条件**: 設計書の未確認の前提 2 つについて、成り立つかどうかが実際の応答で確定している
- **依存**: なし（利用者による認証情報の更新が必要）
- **推定時間**: 15 分
- **前提が外れた場合**: 実装に進まず、設計の見直しを提案する（特に `Destination` なしが周回になる場合は、スイッチがオフのときの方式を変える必要がある）

#### Task 1.2: 作業ブランチとベースライン

- [ ] `feat/optimize-waypoints` ブランチを作る
- [ ] `node --test tests/` が通ることを確認する
- [ ] `qmllint main.qml` の変更前の出力を、比較用にスクラッチパッドへ保存する
- **完了条件**: 既存のテストが通り、変更前の `qmllint` の出力が保存されている
- **依存**: なし
- **推定時間**: 5 分

### Phase 2: 実装

#### Task 2.1: `Routes.js` の関数とテスト（テストを先に書く）

- [ ] `tests/optimize-waypoints.test.cjs` を作り、設計書 7.1 のケースを書く（この時点では失敗する）
- [ ] `optimizePerimeterKm`、`minOptimizeStops`、`optimizeBody` を実装する
- [ ] `boundsPerimeterKm`、`tripSummary` を実装する
- [ ] `optimizedStops`（ID の対応付け、過不足・重複の検出、`ImpedingWaypoints`）を実装する
- [ ] `optimizeRejection`（403、400 で周長 500 km 超、その他）を実装する
- **完了条件**: `node --test tests/` で新旧のテストがすべて通る。既存の関数は変更していない
- **依存**: Task 1.1（応答の形式）、Task 1.2
- **推定時間**: 45 分

#### Task 2.2: `main.qml` の状態・通信・関数

- [ ] `fixedEnd`、`undoStops`、`optimizeNote`、`optimizing`、`optimizable`、`canOptimize` を追加する
- [ ] `pending` を `routeRequest.pending || optimizeRequest.pending` にする
- [ ] `optimizeRequest`（`LocationRequest`）を追加する
- [ ] `optimize()`、`undoOptimize()` を追加する
- [ ] `onStopsChanged` で `undoStops` と `optimizeNote` を消す。`onTravelModeChanged` と `onFixedEndChanged` で `optimizeNote` を消す
- [ ] `panel.onAboutToHide` で `optimizeRequest.cancel()` も呼ぶ
- **完了条件**: 設計書 2.3 の「状態を破棄するタイミング」の表どおりに状態が変わる実装になっている
- **依存**: Task 2.1
- **推定時間**: 30 分

#### Task 2.3: `main.qml` の UI

- [ ] 「訪問順」の見出しと一覧の間に、操作部（ボタン、スイッチと文言、補足文、結果と「元の順序に戻す」）を追加する
- [ ] 操作部は `plugin.optimizable` のときだけ表示する
- [ ] 下部の進捗表示の `Accessible.name` と、検索ボタンの「経路を検索中…」の条件を、最適化中と区別する
- [ ] タップ領域 44 px 以上、文言の折り返し、ダークテーマの色（既存の `QfTheme` と `LocationButton` を使う）を確認する
- **完了条件**: 設計書 2.3 の UI の図と表示条件どおりになっている
- **依存**: Task 2.2
- **推定時間**: 30 分

### Phase 3: 検証・テスト

#### Task 3.1: 静的チェックと差分の見直し

- [ ] `node --test tests/` がすべて通る
- [ ] `qmllint main.qml` の出力を Task 1.2 のものと比べ、今回の変更による警告が増えていないことを確認する
- [ ] 差分を要件 2.1 の各項目と突き合わせる（抜けと、要件にない変更の両方を見る）
- [ ] 最適化を使わない場合の動作が変わっていないことを、差分で確認する（`search()`、`requestBody`、`routeWkt`、地図タップ画面）
- **完了条件**: 要件 5.1 のうち、この環境で確認できる項目がすべて満たされている
- **依存**: Task 2.3
- **推定時間**: 20 分

### Phase 4: 仕上げ

#### Task 4.1: README の更新

- [ ] API キーの表に `geo-routes:OptimizeWaypoints` を追加する
- [ ] 「訪問順を確認して検索する」に、最適化の手順とスイッチの説明を追加する
- [ ] 「知っておくと便利なこと」に、周回の方法と範囲の上限（周長 500 km）を追加する
- [ ] 「うまくいかないとき」に、権限不足と範囲超過の行を追加する
- [ ] 注意事項に、料金（別課金、スクーターと広域は Premium）と API 仕様へのリンクを追加する
- **完了条件**: README だけを読んで、キーの設定から最適化の実行、失敗時の対処までがわかる
- **依存**: Task 2.3（文言を実装と一致させるため）
- **推定時間**: 20 分

#### Task 4.2: バージョンと配布用 ZIP

- [ ] `metadata.txt` の `version` を `1.9.0` にする
- [ ] README のコマンドで `amazon-location-service.zip` を作り直し、中身の一覧とファイルの内容が作業ツリーと一致することを確認する
- **完了条件**: ZIP の中の `main.qml`・`Routes.js`・`metadata.txt` が作業ツリーと同じ内容になっている
- **依存**: Task 3.1
- **推定時間**: 5 分

#### Task 4.3: 実機確認の依頼をまとめる

- [ ] 要件 5.2 の受け入れテストに、設計書 10 の確認事項（スイッチのダークテーマでの見え方など）を加えた確認手順を報告する
- [ ] `img/visit-order-editor.png` の撮り直しを依頼する
- **完了条件**: 利用者が、実機で何をどの順に確認すればよいかがわかる
- **依存**: Task 4.2
- **推定時間**: 5 分

## 実装順序

1. Task 1.1（認証情報の更新待ち）と Task 1.2 は並行して進められる
2. Task 2.1 → 2.2 → 2.3 は順番に進める（同じファイルと前段の関数に依存するため）
3. Task 3.1 のあと、Task 4.1 → 4.2 → 4.3

クリティカルパスは Task 1.1。前提が外れると、Task 2.1 以降の内容が変わる。

## リスクと対策

- **Task 1.1 で前提が外れる**：実装に進まず、設計の見直しを提案する。
- **認証情報に `geo-routes:OptimizeWaypoints` の権限がない**：確認できない旨を報告し、方法 B（ドキュメントの例をもとに実装）に切り替えるかどうかを相談する。
- **`qmllint` が QField のモジュールを解決できない**：警告は変更前との差分で判断する。
- **QML の動作は実機でしか確認できない**：ロジックは `Routes.js` に寄せてテストし、QML は既存の書き方に沿った最小限の変更にとどめる。

## 注意事項

- コミットとプッシュは、依頼があった場合だけ行う。作業は `feat/optimize-waypoints` ブランチで行い、`main` には直接変更を入れない
- `.tmp/` の文書はコミットに含めない
- 既存の `requestBody`・`routeWkt`・`search()` は変更しない
- 不明点は実装前に確認する

## 実装開始ガイド

1. このタスクリストに従って順次実装を進めてください
2. 各タスクの開始時にTodoWriteでin_progressに更新
3. 完了時はcompletedに更新
4. 問題発生時は速やかに報告してください
