# Amazon Location Routes for QField

QField の地図上で、指定した地点を**指定した順番どおり**に車で巡る経路を表示するプラグインです。経路は Amazon Location Service の [CalculateRoutes](https://docs.aws.amazon.com/location/latest/APIReference/API_CalculateRoutes.html) で検索します。

- 地図のタップと、レイヤの地物の選択のどちらでも地点を追加できます。組み合わせることもできます。
- 2〜25 地点を指定できます。最初が出発地、最後が目的地、その間が経由地です。
- 地点はドラッグまたは「↑」「↓」で並べ替えられます。
- 経路は距離優先（ShortestRoute）で検索します。訪問順は自動では最適化しません。
- 経路と地点番号は一時的な表示です。プロジェクトの地物は編集しません。

## 必要なもの

- プラグインに対応した QField
- インターネット接続（経路検索のたびに通信します）
- `geo-routes:CalculateRoutes` を許可した Amazon Location Service の API キーと、そのキーを作成した AWS リージョン名（例：`ap-northeast-1`）

API キーは AWS マネジメントコンソールの Amazon Location Service で作成します。手順は [API キーのドキュメント](https://docs.aws.amazon.com/location/latest/developerguide/using-apikeys.html)を参照してください。許可するアクションは CalculateRoutes だけにしておくと安全です。

## インストール

### URL からインストールする（おすすめ）

1. QField のサイドダッシュボードから設定を開き、プラグインの管理画面を開きます。
2. 「Install plugin from URL（URL からプラグインをインストール）」をタップし、次の URL を入力します。

   ```text
   https://raw.githubusercontent.com/Yamazaki-Kei7/qfield-amazonlocationservice/main/amazon-location-routes.zip
   ```

3. 一覧に追加された「Amazon Location Routes」のスイッチをオンにします。実行の許可を求めるダイアログが出たら許可してください。

プラグイン管理画面の場所やボタンの表記は QField のバージョンによって異なります。見つからない場合は [QField のプラグインのドキュメント](https://docs.qfield.org/how-to/advanced-how-tos/plugins/)を確認してください。

### ZIP を手動で配置する

URL からインストールできない環境では、[amazon-location-routes.zip](https://raw.githubusercontent.com/Yamazaki-Kei7/qfield-amazonlocationservice/main/amazon-location-routes.zip) をダウンロードして展開し、QField のアプリデータ内に `plugins/amazon-location-routes/main.qml` がある構成で配置します。QField を再起動し、プラグイン管理画面で有効にしてください。

## 使い方

1. **検索画面を開く**：プロジェクトを開き、プラグインツールバーの経路ボタンを押します。
2. **地点を追加する**：次のどちらか、または両方で、訪問する順に追加します。
   - **地図で指定**：「地図をタップして地点を追加」を押し、地図を訪問順にタップします。追加中は経路ボタンに地点数が表示されます。終わったら経路ボタンをもう一度押して検索画面へ戻ります。
   - **地物で指定**：「地物を選ぶレイヤ」でレイヤを選び、「レイヤの地物を選択」を押します。一覧から訪問順にタップし、「選択を終了」を押します。
3. **接続設定を入力する**：「AWS リージョン」と「Amazon Location API キー」を入力します。
4. **訪問順を確認する**：「訪問順」に並んだカードで順番を確認します。変更する場合は、カード左端の番号をつかんで上下にドラッグするか、カード右の「↑」「↓」で1つずつ移動します。地図上の番号も同じ順序に変わります。
5. **検索する**：画面下部の「指定順で最短経路を検索」を押します。検索が終わると画面が閉じ、地図に経路と地点番号が表示されます。

地点を取り消すには「末尾の地点を削除」、経路と地点をすべて消すには「全消去」を押します。

### 知っておくと便利なこと

- 「指定順で最短経路を検索」が押せないときは、ボタンの上に不足している項目が表示されます。地点が2つ以上あり、接続設定がそろうとボタンがオレンジ色になります。
- 地物で指定した場合、点はその位置、線・面・マルチパート地物は重心を使います。建物の出入口など特定の位置から検索したいときは、地図をタップして指定してください。
- 地点の追加・並べ替え・削除をすると、表示済みの経路は消えます。新しい順序でもう一度検索してください。
- 別のプロジェクトを開くと、地点と経路はクリアされます。
- API キーは端末に保存しません。QField を再起動したときは入力し直してください。

## うまくいかないとき

| 表示・症状 | 確認すること |
| --- | --- |
| ツールバーに経路ボタンが出ない | プラグイン管理画面でスイッチがオンになっているか、実行を許可したかを確認します。 |
| 「通信できません。接続を確認してください。」 | インターネット接続と、リージョン名の入力ミスがないかを確認します。 |
| 「検索できませんでした（HTTP …）。」 | API キーが正しく有効期限内か、`geo-routes:CalculateRoutes` を許可しているか、キーを作成したリージョンを入力しているかを確認します。地点が道路から大きく離れている場合にも表示されることがあります。 |
| 「全区間を通る経路が見つかりませんでした。」 | 車でたどり着けない地点（海上や道路のない場所など）が含まれていないかを確認します。 |
| 「応答がありません。接続を確認して再検索してください。」 | 45 秒以内に応答がなかった場合に表示されます。通信環境のよい場所で再検索します。 |

## 注意事項

- 経路検索は Amazon Location Service の利用料金の対象です。詳しくは[料金ページ](https://aws.amazon.com/location/pricing/)を確認してください。
- 検索時には、指定した地点の座標と API キーを Amazon Location Service に送信します。
- 移動手段は車のみです。

## 開発者向け

配布用の ZIP は、このディレクトリで次のコマンドを実行して作成します。

```sh
zip -j amazon-location-routes.zip main.qml Routes.js metadata.txt icon.svg LICENSE
```

URL からのインストールでは `main` ブランチの `amazon-location-routes.zip` がそのまま配布されます。ソースを変更したら、`metadata.txt` の `version` を更新し、ZIP を作り直してコミットしてください。

## ライセンス

ライセンスは同梱の [LICENSE](LICENSE)（GNU GPL v2）を参照してください。
