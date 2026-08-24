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

> **落とし穴（重要）**：`aws configure sso` で聞かれる **SSO region** は、
> **IAM Identity Center が設置されたリージョン**であり、HVW をデプロイする
> リージョン（本手順では `ap-northeast-1`）とは**別物**です。ここを取り違えると
> `RegisterClient` / `StartDeviceAuthorization` が `InvalidRequestException:
> invalid_request` で失敗します。設置リージョンが不明なら、AWS access portal に
> ログインした際のブラウザ（F12 → Network の `portal.sso.<region>.amazonaws.com`）
> で確認するか、管理者に確認してください。

各コマンドでは `--profile hvw` を付けるか、`$env:AWS_PROFILE = "hvw"`（PowerShell）
/ `export AWS_PROFILE=hvw`（bash）を設定します。環境変数は**ターミナルを開くたび**に
再設定が必要（そのウィンドウ内のみ有効）です。`aws configure sso` は再実行不要、
`aws sso login` はトークン失効時のみ実行します。

## 設定（context で上書き可能）

| context キー      | 既定値        | 説明 |
|-------------------|---------------|------|
| `instanceType`    | `t3.large`    | EC2 インスタンスタイプ |
| `volumeSize`      | `30`          | ルート EBS サイズ (GiB) |
| `allowedSshCidr`  | `0.0.0.0/0`   | SSH(22) を許可する CIDR。**自分のグローバル IP に絞る事を推奨**（下記参照） |
| `keyName`         | （未指定）    | 既存の EC2 キーペア名。未指定なら Session Manager で接続 |
| `sdkUrl`          | （未指定）    | HVW SDK の tar.gz ダウンロード URL。指定すると SDK を**自動インストール**（未指定なら手動 SCP）。環境変数 `HVW_SDK_URL` でも指定可 |

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

## SDK インストール方法：自動 or 手動

HVW SDK 本体（tar.gz、非公開・ライセンス取得者のみ）の設置には 2 通りあります。

### 方法 A：自動インストール（推奨・SCP 不要）

Developer Zone の署名付き S3 URL などを `HVW_SDK_URL` で渡すと、UserData が
ダウンロード〜展開〜配置〜`Config.js` 設定〜サーバ起動まで自動で行います。

環境変数 `HVW_SDK_URL`（または context `sdkUrl`）に URL をセットしてから
デプロイするだけです。**具体的なコマンドは下記「デプロイ手順」に一本化**して
います。デプロイ完了後、UserData が SDK を取得・設置するため**さらに 2〜5 分**
待ってから `http://<ElasticIP>/sample.html` を開きます。

> **注意**：署名付き URL は有効期限付き（通常数時間）かつ署名を含むため、
> **リポジトリにコミットしないでください**。デプロイ時のみ環境変数で渡します。
> URL は EC2 の UserData に埋め込まれるため、PoC / 検証用途を想定しています。
> この方法 A では「デプロイ後の手順（手動 / 方法 B）」のステップは不要です。

### 方法 B：手動インストール（`sdkUrl` を渡さない場合）

`HVW_SDK_URL` を指定せずにデプロイすると、インフラ（NGINX / リバースプロキシ
/ systemd）のみ構築されます。SDK は下記「デプロイ後の手順」に従い SCP で転送
して設置します。

## デプロイ手順

クローン直後から通しで実行する例（PowerShell）。方法 A（自動）と方法 B（手動）の
違いは、手順 4 で `HVW_SDK_URL` をセットするかどうかだけです。

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

# 4. 【方法 A のみ】SDK の署名付き URL をセット（& を含むためシングルクォート必須）
#    方法 B（手動 SCP）で進める場合はこの行を実行しない
$env:HVW_SDK_URL = 'https://.../HOOPS_Visualize_Web_2026.6.0_Linux_x86-64.tar.gz?X-Amz-...'

# 5. デプロイ（keyName / allowedSshCidr は上記「設定」で調べた自分の値に置換）
npx cdk deploy -c keyName=<キーペア名> -c allowedSshCidr=<自分のIP>/32 --require-approval never
```

bash の場合は 2〜4 を `export AWS_PROFILE=hvw` / `export HVW_SDK_URL='...'` に置換。

デプロイ完了後、出力（Outputs）に以下が表示されます。

- `ElasticIP` … 割り当てられた固定 IP
- `InstanceId` … Session Manager 接続に使用
- `SshCommand` … SSH 接続コマンド（keyName 指定時）
- `SampleUrl` … サンプル URL（SDK 設置後にアクセス可能）

## デプロイ後の手順（手動 / 方法 B の場合のみ）

> `HVW_SDK_URL` を指定して自動インストール（方法 A）した場合、この節は不要です。

### 1. サーバへ接続

キーペア指定時:

```bash
ssh -i <path-to-your-key>.pem ubuntu@<ElasticIP>
```

またはキーなし（Session Manager）:

```bash
aws ssm start-session --target <InstanceId>
```

### 2. HVW SDK 本体を転送・設置

ローカル PC から SCP で tar.gz を `/tmp` に転送します。

```bash
scp -i <key>.pem HOOPS_Visualize_Web_202x.x.x_Linux_xxx.tar.gz ubuntu@<ElasticIP>:/tmp/
```

サーバ側で展開し、SDK ツリーを `/opt/hvw` に、静的アセットのみ
`/var/www/html` に配置します（本プロジェクトの配置設計どおり）。

```bash
cd /tmp
tar -zxvf HOOPS_Visualize_Web_202x.x.x_Linux_xxx.tar.gz

# SDK ツリー丸ごとを /opt/hvw に置き、current シンボリックリンクを張る
sudo mkdir -p /opt/hvw
sudo cp -r HOOPS_Visualize_Web_202x.x.x /opt/hvw/
sudo ln -sfn /opt/hvw/HOOPS_Visualize_Web_202x.x.x /opt/hvw/current

# NGINX が配信する静的アセットだけを /var/www/html にコピー
cd /opt/hvw/current/web_viewer/
sudo cp -r demo-app /var/www/html/
sudo cp hoops-web-viewer.mjs engine.esm.wasm /var/www/html/
```

`Config.js` でストリーミングモデルの検索ディレクトリを設定します（`.scz` が
置かれている SDK ツリー内の絶対パスを指定）。

```bash
sudo vi /opt/hvw/current/server/node/Config.js
```

```js
    modelDirs: [
        "/opt/hvw/current/quick_start/converted_models/standard/sc_models",
    ],
```

> リバースプロキシ経由のため、`Config.js` の SSL 設定は不要です（WSS は NGINX で
> 終端され、WS として SC サーバへ届きます）。

### 3. HVW サーバを起動

UserData で `onboot.service` は enable 済みです。SDK 設置後は起動できます。

```bash
sudo systemctl start onboot.service
sudo systemctl status onboot.service
```

（再起動時は自動起動します。）

### 4. 動作確認（HTTP）

サンプル `sample.html` は、ページが HTTP なら `ws://`、HTTPS なら `wss://` で
自動接続します。まずは HTTP で確認できます。

```
http://<ElasticIP>/sample.html
```

microengine モデルが表示されれば成功です。この時点では SSL 証明書もドメインも
不要で、パス方式（`/wsproxy/11182`）で SC サーバに接続します。

> **demo-app（フル機能デモ）を使う場合**：現行の demo-app は URL パラメータで
> 設定します。ヘッダ方式のプロキシ経由でストリーミングするには `scPort` に
> 公開ポート（HTTP なら `80`、HTTPS なら `443`）を渡します。
> ```
> http://<ElasticIP>/demo-app/?viewer=csr&scPort=80&model=microengine
> ```
> SC サーバ不要のローカル SCS モードは `?viewer=scs&model=models/scs/<name>.scs`。

## （任意）HTTPS 化：ドメイン取得 + certbot

本番運用で暗号化したい場合は、ドメインを用意して Let's Encrypt 証明書を発行します。
IP アドレスには証明書を発行できないため、独自ドメインが必須です。

### A. ドメイン取得と DNS 設定

`ElasticIP` を指す A レコードを作成します（Route 53 など）。
`dig <YOUR_DOMAIN>` で Elastic IP が返ることを確認してください。

### B. certbot で SSL 証明書を発行

DNS が Elastic IP を指した後に実行します。

```bash
sudo certbot --nginx -d <YOUR_DOMAIN> -m <YOUR_EMAIL> --agree-tos
```

certbot が NGINX に 443 の server ブロックと HTTP→HTTPS リダイレクトを追加します。
本プロジェクトのリバースプロキシ設定・`.mjs` MIME 設定は保持されます。
`sample.html` は自動で `wss://` に切り替わります。

### C. 動作確認（HTTPS）

```
https://<YOUR_DOMAIN>/sample.html
```

## リバースプロキシの仕組み（参考）

`/etc/nginx/sites-available/default` に以下を設定しています。

- **ヘッダ方式**：`location /` で `Upgrade: websocket` の要求のみ
  `http://127.0.0.1:11182` へ中継し、それ以外は静的配信（`try_files`）。
  demo-app（`ws://host:<80|443>/?...`）はこれで動きます。
- **パス方式**：`/wsproxy/<port>` → `ws://127.0.0.1:<port>`（sample.html 用）
- `/httpproxy/<port>/<path>` → `http://127.0.0.1:<port>/<path>`
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
├── test/hvw-cdk.test.ts      # スタックの簡易テスト
└── README.md
```
