# hvw-cdk — HOOPS Visualize Web + リバースプロキシ を AWS CDK で構築

HOOPS Visualize Web（HVW）の Stream Cache サーバを、NGINX リバースプロキシの
背後に配置して構築する AWS CDK (TypeScript) プロジェクトです。SC サーバの
`11182` ポートを**インターネットに公開せず**、80/443 経由でストリーミング配信
します。SDK のダウンロード・設置まで自動化しているのが特徴です。

構成の着想は TechSoft3D フォーラム記事
[HOOPS Visualize Web HTTPS server with reverse proxy](https://forum.techsoft3d.com/t/hoops-visualize-web-https-server-with-reverse-proxy/1682)
（前提記事 [How to setup HTTPS server with AWS](https://forum.techsoft3d.com/t/how-to-setup-https-server-with-aws/1680)）
に由来しますが、配置・プロキシ方式・自動化は本プロジェクト独自に再設計しています。

## リバースプロキシの 2 方式

`11182` を隠蔽したまま、2 種類のクライアントに対応します。

- **ヘッダ方式（現代版・クライアント非依存）**：標準ポート（80/443）のルート `/`
  に来た **WebSocket アップグレード要求**だけを `127.0.0.1:11182` へ中継し、
  それ以外は静的ファイルを配信します。接続先を `host:port`（パス無し）でしか
  組み立てられない**現行の demo-app** でも、`scPort=80`（HTTPS なら `443`）を
  渡すだけでプロキシ経由ストリーミングが動きます。
- **パス方式（古典・記事準拠）**：`/wsproxy/<port>` で中継します。同梱の
  `sample.html` や、接続先をパスで指定できる従来クライアント向けです。
  `<port>` は**任意ポートではなく `11182` / `11180` に限定**しており（許可外は
  404）、localhost の任意ポートへ中継されるのを防いでいます。

どちらも `11182` は非公開のままです。

## 配置設計

SDK の相対構成を崩さないよう、サーバ本体と静的アセットを分離しています。

| パス | 内容 | 配信元 |
| --- | --- | --- |
| `/opt/hvw/HOOPS_Visualize_Web_<ver>/` | SDK ツリー丸ごと。SC サーバはここから起動 | systemd `onboot.service` |
| `/opt/hvw/current` | 上記への symlink（バージョン更新を容易に） | — |
| `/var/www/html/` | 静的アセットのみ（`demo-app/`, `hoops-web-viewer.mjs`, `engine.esm.wasm`, `sample.html`） | NGINX |

ストリーミングモデル（`.scz`）は SDK ツリー内に残し、SC サーバが `Config.js` の
`modelDirs` 経由で配信します（NGINX では配信しません）。

## ビューワの入口

SDK インストール完了後、以下にアクセスできます。

- `http://<ElasticIP>/sample.html` … 最小サンプル（パス方式のストリーミング）
- `http://<ElasticIP>/demo-app/?viewer=csr&scPort=80&model=microengine`
  … SDK 同梱のフル機能デモ（ヘッダ方式のストリーミング / csr）。HTTPS なら
  `viewer=csr&scPort=443`。ローカル SCS ファイルを直接開く場合は
  `?viewer=scs&model=models/scs/<name>.scs`（SC サーバ不要）。

## CDK が作成するもの

- 最小構成の VPC（パブリックサブネット 1つ、NAT なし）
- セキュリティグループ：**22 / 80 / 443 のみ**（`11182` は非公開）
- Ubuntu Server 24.04 LTS の EC2 インスタンス
  - UserData で NGINX・certbot を導入
  - リバースプロキシ設定（ヘッダ方式の `/` + パス方式 `/wsproxy/<port>`, `/httpproxy/<port>/<path>`）
  - `.mjs` の MIME タイプ追加
  - 最小サンプル `sample.html` 配置
  - 起動時に HVW サーバを立ち上げる systemd サービス `onboot.service`
- Elastic IP（インスタンスに関連付け。ドメインの A レコード先に使用）
- Session Manager 接続用の IAM ロール（SSH 鍵なしでも接続可）

> **手動で行う手順**：ドメイン取得、certbot による SSL 証明書発行。
> HVW SDK 本体は `HVW_SDK_URL` を渡せば自動設置されます（下記「デプロイ手順」参照）。

## 前提

- Node.js / npm（確認済み: v22）
- AWS CDK v2（`npx cdk` で利用）
- AWS 認証情報（`aws configure` 済みのプロファイル、または環境変数）
- HOOPS Visualize Web の Linux 版 SDK（`.tar.gz`。ライセンス取得者のみ）

## AWS 認証

CDK 標準の認証がそのまま使えます。IAM ユーザーのアクセスキーなら `aws configure`
で設定するだけです（CDK 利用者には周知のため詳細は割愛）。

**SSO（IAM Identity Center）の場合**は、以下だけ注意してください。

```bash
aws configure sso --profile hvw   # プロファイル作成（このマシンで一度だけ）
aws sso login --profile hvw       # デプロイ前にログイン（トークンは数時間で失効）
aws sts get-caller-identity --profile hvw   # 疎通確認
```

各コマンドの実行頻度と保存場所は次のとおりです。

| コマンド / 設定 | 実行頻度 | 保存場所・有効範囲 |
| --- | --- | --- |
| `aws configure sso --profile hvw` | このマシンで**一度だけ** | `~/.aws/config`（ディスク） |
| `aws sso login --profile hvw` | **トークン失効時のみ**（数時間ごと） | `~/.aws/sso/cache`（ディスク・**全ウィンドウ共通**） |
| `$env:AWS_PROFILE = "hvw"`（または各コマンドに `--profile hvw`） | **ターミナルを開くたび** | 環境変数（**そのウィンドウのみ**） |

> **よくあるハマり**：`aws sso login` に成功しても、後続コマンドに `--profile hvw`
> も `$env:AWS_PROFILE` も付けないと、既定プロファイル（認証情報なし）を見て
> `NoCredentials: Unable to locate credentials` になります。**ログイン＝トークン取得**と
> **プロファイル指定＝どの認証情報を使うか**は別物です。新しいウィンドウでは、まず
> `$env:AWS_PROFILE = "hvw"` を設定してから `aws sts get-caller-identity` で確認する
> のが確実です（`NoCredentials`/`expired` が出た時だけ `aws sso login` を足す）。

> **落とし穴（重要）**：`aws configure sso` で聞かれる **SSO region** は、
> **IAM Identity Center が設置されたリージョン**であり、HVW をデプロイする
> リージョン（本手順では `ap-northeast-1`）とは**別物**です。ここを取り違えると
> `RegisterClient` / `StartDeviceAuthorization` が `InvalidRequestException:
> invalid_request` で失敗します。設置リージョンが不明なら、AWS access portal に
> ログインした際のブラウザ（F12 → Network の `portal.sso.<region>.amazonaws.com`）
> で確認するか、管理者に確認してください。

新しいターミナルでの定番手順（このウィンドウのみ有効）:

```powershell
$env:AWS_PROFILE = "hvw"
aws sts get-caller-identity   # Account が返れば OK。失効時のみ aws sso login --profile hvw
```

## 設定（context で上書き可能）

| context キー      | 既定値        | 説明 |
|-------------------|---------------|------|
| `instanceType`    | `t3.large`    | EC2 インスタンスタイプ |
| `volumeSize`      | `30`          | ルート EBS サイズ (GiB) |
| `allowedSshCidr`  | `0.0.0.0/0`   | SSH(22) を許可する CIDR。**自分のグローバル IP に絞る事を推奨**（下記参照） |
| `keyName`         | （未指定）    | 既存の EC2 キーペア名。未指定なら Session Manager で接続 |
| `sdkUrl`          | （未指定）    | HVW SDK の tar.gz ダウンロード URL。指定すると SDK を**自動インストール**（未指定ならインフラのみ構築）。環境変数 `HVW_SDK_URL` でも指定可 |
| `hvwLicense`      | （未指定）    | HVW ライセンスキー。指定すると SDK の `server/node/Config.js` に埋め込まれた評価ライセンスを上書き（`sdkUrl` による自動インストール時のみ有効）。**未指定なら SDK 同梱の評価ライセンスをそのまま使用**。環境変数 `HVW_LICENSE` でも指定可 |
| `webappPackage`   | （未指定）    | 独自 Web サービスの再頒布パッケージ（圧縮ファイル）への**ローカルパス**。指定すると CDK が S3 アセットとして自動アップロードし、デプロイ時にサーバへ展開。環境変数 `WEBAPP_PACKAGE` でも指定可。**約 1.9 GiB を超えるファイルは指定不可**（CDK アセットは synth 時に丸ごと読み込むため 2 GiB 制約に抵触。大容量は `webappS3Uri` を使用）。**`sdkUrl` の有無に影響されず独立に動作**（下記「独自 Web サービスの同梱デプロイ」参照） |
| `webappS3Uri`     | （未指定）    | 事前に自分の S3 バケットへアップロード済みの再頒布パッケージの `s3://bucket/key` URI。CDK はアセット化せず、EC2 ロールに当該オブジェクトの `s3:GetObject` のみ付与して `aws s3 cp` で取得。**大容量（数 GB）向けの推奨方式**（2 GiB 制約・毎 synth の巨大コピーを回避）。環境変数 `WEBAPP_S3_URI` でも指定可。`webappPackage` とは**排他**（両方指定はエラー） |

### 自分のグローバル IP の調べ方（`allowedSshCidr` 用）

SSH を自分だけに限定するには、自分のグローバル IP を調べて末尾に `/32` を付けます。

```powershell
(Invoke-RestMethod https://checkip.amazonaws.com).Trim()   # 例: 14.3.142.47
```

返った値を `-c allowedSshCidr=<返った IP>/32` に使います。`/32` は「その IP 1 つ
だけ許可」の意味です。`ipconfig` で出る `192.168.x.x` / `10.x.x.x` は LAN 内の
プライベート IP なので使いません。IP は回線再起動やテザリング切替で変わることが
あるため、デプロイ直前に確認するのが確実です。

### EC2 キーペアの確認・作成（`keyName` 用）

SSH / SCP でサーバに接続するには、デプロイ先リージョンに存在する EC2 キーペア名を
`keyName` に指定します。既存のキーペア一覧は次で確認できます。

```powershell
aws ec2 describe-key-pairs --region ap-northeast-1 --query "KeyPairs[].KeyName" --output table
```

> **注意**: `keyName` に渡すのは **AWS 上のキーペア「名」だけ**です。`.pem` 拡張子やファイルパスは付けません（例: `toshi-key-pair` ○ / `toshi-key-pair.pem` ✗ / `C:\...\toshi-key-pair.pem` ✗）。`.pem` のフルパスは後述の SSH/SCP の `-i` オプションでのみ使います。

手元に対応する秘密鍵（`.pem`）があるものを選びます。無ければ新規作成して保存します。

```powershell
aws ec2 create-key-pair --region ap-northeast-1 --key-name my-hvw-key `
  --query KeyMaterial --output text | Out-File -Encoding ascii $HOME\.ssh\my-hvw-key.pem
```

例（`<キーペア名>` `<自分のIP>` は自分の値に置換）:

```bash
npx cdk deploy \
  -c keyName=<キーペア名> \
  -c allowedSshCidr=<自分のIP>/32 \
  -c instanceType=g4dn.xlarge
```

> **GPU について**：サーバサイドレンダリング（SSR）を使う場合は GPU 付き
> インスタンス（例 `g4dn.xlarge`）が必要です。サンプルの `csr`（クライアント
> サイドレンダリング）だけなら `t3.large` 程度で動作します。

## SDK の自動インストール

HVW SDK 本体（tar.gz、非公開・ライセンス取得者のみ）は、Developer Zone の
署名付き S3 URL を `HVW_SDK_URL`（または context `sdkUrl`）で渡すだけで、
UserData がダウンロード〜展開〜配置〜`Config.js` 設定〜サーバ起動まで自動で
行います（SCP 不要）。具体的なコマンドは下記「デプロイ手順」を参照してください。

> **注意**：署名付き URL は有効期限付き（通常数時間）かつ署名を含むため、
> **リポジトリにコミットしないでください**。デプロイ時のみ環境変数で渡します。
> URL は EC2 の UserData に埋め込まれるため、PoC / 検証用途を想定しています。

> `HVW_SDK_URL` を指定せずにデプロイした場合は、インフラ（NGINX / リバース
> プロキシ / systemd）のみが構築され、SDK は設置されません（`onboot.service` は
> enable 済みのため、後から手動で SDK を `/opt/hvw` に置いて起動できます）。

### ライセンスキーの上書き（任意）

SDK 同梱の `server/node/Config.js` には**期限付きの評価ライセンス**が埋め込まれ
ています。デプロイ時に `HVW_LICENSE`（または context `hvwLicense`）を渡すと、
自動インストール中に `Config.js` の `license: '...'` を指定した値へ置き換えます。
**未指定の場合は SDK 同梱の評価ライセンスをそのまま使用**します（上書きなし）。

```powershell
$env:HVW_LICENSE = '<longer-lived-license-key>'
```

> ライセンスキーも UserData 経由で EC2 に渡るため、**リポジトリにはコミットせず**
> デプロイ時のみ環境変数で渡してください。`HVW_SDK_URL` 未指定（インフラのみ構築）
> の場合は `Config.js` が存在しないため `HVW_LICENSE` は無視されます。

## 独自 Web サービスの同梱デプロイ

HVW SDK とは別に、**自作の Web サービスの再頒布パッケージ（圧縮ファイル）**を
デプロイ時にサーバへ同梱・展開できます。渡し方は**排他の 2 通り**です。

1. **`WEBAPP_S3_URI`（context `webappS3Uri`）＝ 事前アップロード済み S3 参照（大容量の推奨方式）**
   自分の S3 バケットへ先にアップロードし、`s3://bucket/key` URI を渡します。
   CDK はファイルをアセット化・ハッシュ化せず、EC2 ロールに**当該オブジェクトの
   `s3:GetObject` のみ**を付与し、EC2 起動時に `aws s3 cp` で取得します。**数 GB 級の
   アーカイブはこちらを使用**してください（下記の 2 GiB 制約と、synth ごとの巨大な
   `cdk.out` コピーを回避できます）。

2. **`WEBAPP_PACKAGE`（context `webappPackage`）＝ ローカルパス（手軽・小容量向け）**
   ローカルの圧縮ファイルへのパスを渡すと、CDK が**S3 アセットとして自動アップロード**
   し、EC2 起動時に取得して展開します（SCP 不要）。**約 1.9 GiB を超えるファイルは
   エラー**になります。CDK は synth 時の検証でアセットを丸ごと `fs.readFileSync` する
   ため、Node.js の 2 GiB（`ERR_FS_FILE_TOO_LARGE`）制約に抵触するためです。大容量は
   上記 `webappS3Uri` を使ってください。

どちらの方式でも、以降の展開処理（`assets/install-webapp.sh`）は共通です。

- **展開先**：アーカイブの**トップ構成がそのまま `/var/www/html/`（NGINX の
  HTTP ルート）へ展開**されます。トップは単一フォルダである必要はなく、複数の
  ファイル・フォルダでも可です。例：アーカイブのトップに `myWebService/` が
  あれば `/var/www/html/myWebService/...` に配置されます。
- **`HVW_SDK_URL` と独立**：SDK URL の指定有無に関わらず動作します。
- **実行順序と上書き**：Web サービスの展開は、`sample.html`（UserData が生成）
  および `demo-app`（`HVW_SDK_URL` 指定時に配置）の**後**に行われ、**既存ファイルを
  上書き更新**します。アーカイブのトップに `sample.html` や `demo-app/` を含めると、
  先に配置されたそれらを差し替えられます。
- **ビルド・起動はユーザー責務**：既定では**展開のみ**を行います。ビルドや
  サービス起動が必要な場合は、デプロイ後にユーザーが実施してください。あるいは
  `assets/install-webapp.sh` は**編集可能なテンプレート**なので、末尾の
  「User customization」セクションに、展開後のビルドやサービス起動コマンドを
  追記できます（EC2 ブートストラップ末尾に root で実行されます）。

```powershell
# 方式 1: 大容量向け。事前に自分の S3 バケットへアップロードしてから URI を渡す
aws s3 cp 'C:\path\to\my-web-service.zip' s3://my-bucket/webapp/my-web-service.zip
$env:WEBAPP_S3_URI = 's3://my-bucket/webapp/my-web-service.zip'

# 方式 2: 小容量向け。ローカルパスを直接指定（約 1.9 GiB 以下）
$env:WEBAPP_PACKAGE = 'C:\path\to\my-web-service.zip'
```

> **注意**：`WEBAPP_PACKAGE` / `WEBAPP_S3_URI` を変更して再デプロイすると UserData が
> 変化するため、`userDataCausesReplacement: true` によりインスタンスが置換されます
> （`HVW_SDK_URL` と同様）。取得には EC2 ロールの権限で `aws s3 cp` を使うため、
> UserData 側で `awscli` を導入しています。`webappS3Uri` を使う場合、ロールには
> 指定したオブジェクトの `s3:GetObject` のみが付与されます（最小権限）。

## デプロイ手順

クローン直後から通しで実行する例（PowerShell）です。

```powershell
# 1. リポジトリへ移動して依存をインストール（初回のみ）
cd hvw-cdk
npm install

# 2. AWS プロファイル / リージョン（SSO はトークン失効時 aws sso login --profile hvw）
$env:AWS_PROFILE = "hvw"
$env:CDK_DEFAULT_REGION = "ap-northeast-1"
aws sts get-caller-identity   # 疎通確認（アカウント/ロールが返れば OK）

# 3. （初回のみ）CDK bootstrap ※実施済みならスキップ
#    npx cdk bootstrap aws://<ACCOUNT_ID>/ap-northeast-1

# 4. SDK の署名付き URL をセット（& を含むためシングルクォート必須）
$env:HVW_SDK_URL = 'https://.../HOOPS_Visualize_Web_2026.6.0_Linux_x86-64.tar.gz?X-Amz-...'

# 4b. ライセンスキーをセット（未指定なら SDK 同梱の評価ライセンスを使用）（任意）
$env:HVW_LICENSE = '<longer-lived-license-key>'

# 4c. 独自 Web サービスの圧縮ファイルを同梱（任意 / HVW_SDK_URL とは独立）
#     小容量: ローカルパス / 大容量(数GB): 事前アップロード済み S3 URI（排他）
$env:WEBAPP_PACKAGE = 'C:\path\to\my-web-service.zip'
# $env:WEBAPP_S3_URI = 's3://my-bucket/webapp/my-web-service.zip'

# 5. デプロイ（keyName / allowedSshCidr は上記「設定」で調べた自分の値に置換）
npx cdk deploy -c keyName=<キーペア名> -c allowedSshCidr=<自分のIP>/32 --require-approval never
```

bash の場合は 2〜4 を `export AWS_PROFILE=hvw` / `export HVW_SDK_URL='...'`（必要なら `export HVW_LICENSE='...'`）に置換。

デプロイ完了後、出力（Outputs）に以下が表示されます。

- `ElasticIP` … 割り当てられた固定 IP
- `InstanceId` … Session Manager 接続に使用
- `SshCommand` … SSH 接続コマンド（keyName 指定時）
- `SampleUrl` … サンプル URL（SDK 設置後にアクセス可能）

> **重要（少し待つ）**：`cdk deploy` 完了直後は、まだ EC2 内部で
> **SDK のダウンロード・展開・配置や apt のセットアップが進行中**です。
> `ElasticIP` が表示されても、ビューワにアクセスできるまで**通常 3〜5 分**かかります。
> 早すぎると `hoops-web-viewer.mjs` が **404** になったり真っ白になります。
> **数分待ってから**ブラウザを再読込してください。進捗は SSH で
> `sudo tail -f /var/log/cloud-init-output.log`（`HVW SDK installed ... and server
> started.` が出れば完了）で確認できます。
>
> なお `userDataCausesReplacement: true` のため、user-data / install-sdk を変更して
> 再デプロイすると**インスタンスが置換され InstanceId が変わります**（bootstrap を
> 再実行させるための意図的な挙動）。同様に初回起動待ちが発生します。

## サーバへの接続（トラブルシュート）

デプロイ後の確認やログ調査でサーバに入りたい場合:

キーペア指定時:

```bash
ssh -i <path-to-your-key>.pem ubuntu@<ElasticIP>
```

またはキーなし（Session Manager）:

```bash
aws ssm start-session --target <InstanceId>
```

### ログ・状態の確認

自動インストールの進捗やサーバ状態は次で確認できます。

```bash
# UserData / SDK 自動インストールのログ（"HVW SDK installed ... started." で完了）
sudo tail -n 50 /var/log/cloud-init-output.log

# SC サーバ（onboot.service）の状態と待受ポート
sudo systemctl status onboot.service --no-pager
sudo ss -ltnp | grep -E '11182|11180'

# 静的アセットと SDK ツリーの配置確認
ls -l /var/www/html /opt/hvw/current/web_viewer/
```

ビューワの入口 URL は上記「ビューワの入口」を参照してください
（`/sample.html` と `/demo-app/?viewer=csr&scPort=80&model=microengine`）。

## （任意）HTTPS 化：ドメイン取得 + certbot

本番運用で暗号化したい場合は、Let's Encrypt 証明書を certbot で発行します。
certbot + Let's Encrypt は 2026 年時点でも主流の手法です（下記「代替手段」も参照）。

> **ドメイン無しでも可能に**：かつては「IP アドレスには証明書を発行できない」
> ため独自ドメインが必須でしたが、2025〜2026 年に Let's Encrypt が
> **IP アドレス証明書**を一般提供しました（`http-01` / `tls-alpn-01` で検証）。
> ただし**有効期間 6 日の短命証明書**で、**自動更新が必須**です。最新版 certbot の
> `shortlived` プロファイルで Elastic IP のまま HTTPS 化できます。安定運用には
> 引き続き独自ドメイン（90 日証明書・自動更新）が無難です。

### A. ドメイン取得と DNS 設定（ドメイン利用時）

`ElasticIP` を指す A レコードを作成します（Route 53 など）。
`dig <YOUR_DOMAIN>` で Elastic IP が返ることを確認してください。

### B. certbot で SSL 証明書を発行

DNS が Elastic IP を指した後に実行します。

```bash
sudo certbot --nginx -d <YOUR_DOMAIN> -m <YOUR_EMAIL> --agree-tos
```

certbot が NGINX に 443 の server ブロックと HTTP→HTTPS リダイレクトを追加します。
本プロジェクトのリバースプロキシ設定・`.mjs` MIME 設定は保持されます。
`sample.html` は自動で `wss://` に切り替わります。demo-app はヘッダ方式で
`?viewer=csr&scPort=443&model=microengine` を使います。

### C. 動作確認（HTTPS）

```
https://<YOUR_DOMAIN>/sample.html
```

### 代替手段（参考）

| 方式 | 特徴 | 向き |
| --- | --- | --- |
| **certbot + Let's Encrypt**（本手順） | 無料・枯れている・IP 証明書 / 6 日証明書対応 | 単一 VM（本構成） |
| **Caddy**（NGINX 代替） | HTTPS の取得・更新を内蔵し完全自動 | 単一ボックスを最小構成で |
| **ACM + ALB / CloudFront** | AWS が TLS 終端・自動更新。証明書を EC2 に置かない | AWS ネイティブ（ALB は月額課金増） |
| **acme.sh** | 軽量なシェル ACME クライアント | certbot 依存を避けたい場合 |

## リバースプロキシの仕組み（参考）

`/etc/nginx/sites-available/default` に以下を設定しています。

- **ヘッダ方式**：`location /` で `Upgrade: websocket` の要求のみ
  `http://127.0.0.1:11182` へ中継し、それ以外は静的配信（`try_files`）。
  demo-app（`ws://host:<80|443>/?...`）はこれで動きます。
- **パス方式**：`/wsproxy/<port>` → `ws://127.0.0.1:<port>`（sample.html 用）
- `/httpproxy/<port>/<path>` → `http://127.0.0.1:<port>/<path>`
  - `<port>` は正規表現 location で **`11182` / `11180` のみ許可**（それ以外は
    404）。任意ポートへの中継を防ぐためのホワイトリストです。なお正規表現
    location は前方一致の `location /` より優先されるため、ヘッダ方式には影響
    しません。
- `client_max_body_size 200M;`

いずれの方式でも `11182` は公開せず、NGINX が `127.0.0.1:11182` へ中継します。

## 後始末

```bash
npx cdk destroy
```

## ファイル構成

```
hvw-cdk/
├── bin/hvw-cdk.ts            # CDK アプリのエントリ
├── lib/hvw-cdk-stack.ts      # スタック定義（VPC/SG/EC2/EIP/IAM）
├── assets/user-data.sh       # EC2 ブートストラップ（NGINX/certbot/systemd）
├── assets/install-sdk.sh     # SDK 自動ダウンロード・設置（sdkUrl 指定時に実行）
├── assets/install-webapp.sh  # 独自 Web サービス圧縮ファイルの展開（webappPackage 指定時に実行）
├── test/hvw-cdk.test.ts      # スタックの簡易テスト
└── README.md
```
