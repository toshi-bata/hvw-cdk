# hvw-cdk — HOOPS Visualize Web + リバースプロキシ を AWS CDK で構築

TechSoft3D フォーラム記事
[HOOPS Visualize Web HTTPS server with reverse proxy](https://forum.techsoft3d.com/t/hoops-visualize-web-https-server-with-reverse-proxy/1682)
（および前提記事 [How to setup HTTPS server with AWS](https://forum.techsoft3d.com/t/how-to-setup-https-server-with-aws/1680)）
の構成を、AWS CDK (TypeScript) で自動化するプロジェクトです。

NGINX のリバースプロキシで WSS→WS を中継することで、Stream Cache サーバの
`11182` ポートをインターネットに公開せずに HTTPS 配信できます。

## CDK が作成するもの

- 最小構成の VPC（パブリックサブネット 1つ、NAT なし）
- セキュリティグループ：**22 / 80 / 443 のみ**（`11182` は非公開）
- Ubuntu Server 24.04 LTS の EC2 インスタンス
  - UserData で NGINX・certbot を導入
  - リバースプロキシ設定（`/wsproxy/<port>`, `/httpproxy/<port>/<path>`）
  - `.mjs` の MIME タイプ追加
  - 最小サンプル `sample.html` 配置
  - 起動時に HVW サーバを立ち上げる systemd サービス `onboot.service`
- Elastic IP（インスタンスに関連付け。ドメインの A レコード先に使用）
- Session Manager 接続用の IAM ロール（SSH 鍵なしでも接続可）

> **手動で行う手順**：ドメイン取得、HVW SDK 本体（tar.gz）の転送・設置、
> certbot による SSL 証明書発行。理由は下記「デプロイ後の手順」を参照。

## 前提

- Node.js / npm（確認済み: v22）
- AWS CDK v2（`npx cdk` で利用）
- AWS 認証情報（`aws configure` 済みのプロファイル、または環境変数）
- HOOPS Visualize Web の Linux 版 SDK（`.tar.gz`。ライセンス取得者のみ）

## 設定（context で上書き可能）

| context キー      | 既定値        | 説明 |
|-------------------|---------------|------|
| `instanceType`    | `t3.large`    | EC2 インスタンスタイプ |
| `volumeSize`      | `30`          | ルート EBS サイズ (GiB) |
| `allowedSshCidr`  | `0.0.0.0/0`   | SSH(22) を許可する CIDR。**自分の IP に絞る事を推奨** |
| `keyName`         | （未指定）    | 既存の EC2 キーペア名。未指定なら Session Manager で接続 |

例:

```bash
npx cdk deploy \
  -c keyName=my-keypair \
  -c allowedSshCidr=203.0.113.10/32 \
  -c instanceType=g4dn.xlarge
```

> **GPU について**：サーバサイドレンダリング（SSR）を使う場合は GPU 付き
> インスタンス（例 `g4dn.xlarge`）が必要です。サンプルの `csr`（クライアント
> サイドレンダリング）だけなら `t3.large` 程度で動作します。

## デプロイ手順

```bash
cd hvw-cdk
npm install                 # 初回のみ
npx cdk bootstrap           # アカウント/リージョン初回のみ
npx cdk deploy
```

デプロイ完了後、出力（Outputs）に以下が表示されます。

- `ElasticIP` … 割り当てられた固定 IP
- `InstanceId` … Session Manager 接続に使用
- `SshCommand` … SSH 接続コマンド（keyName 指定時）
- `SampleUrl` … サンプル URL（SDK 設置後にアクセス可能）

## デプロイ後の手順（手動）

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

サーバ側で展開し、`/var/www` 以下へ配置します（記事の構成どおり）。

```bash
cd /tmp
tar -zxvf HOOPS_Visualize_Web_202x.x.x_Linux_xxx.tar.gz
cd HOOPS_Visualize_Web_202x.x.x/

sudo cp -r 3rd_party/ server/ /var/www/
sudo cp -r quick_start/converted_models/standard/sc_models/ /var/www/
cd web_viewer/
sudo cp -r demo-app hoops-web-viewer.mjs engine.esm.wasm /var/www/html/
```

`Config.js` でモデル検索ディレクトリを設定します。

```bash
sudo vi /var/www/server/node/Config.js
```

```js
    modelDirs: [
        "./sc_models",
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
不要で、リバースプロキシ経由（`/wsproxy/11182`）で SC サーバに接続します。

> `demo-app` を使う場合は `Router.js` の `wsUriRoot` の `:` を `/wsproxy/` に
> 変更してから以下を開きます。
> ```bash
> sudo vi /var/www/html/demo-app/app/Router.js
> # 例）http://<ElasticIP>/demo-app/index.html?viewer=csr&model=arboleda&wsPort=11182
> ```

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

`/etc/nginx/sites-available/default` に以下のロケーションを設定しています。

- `/wsproxy/<port>` → `ws://127.0.0.1:<port>`（WebSocket, Upgrade ヘッダ付き）
- `/httpproxy/<port>/<path>` → `http://127.0.0.1:<port>/<path>`
- `client_max_body_size 200M;`

クライアントは
`ws://<host>/wsproxy/11182`（HTTPS 時は `wss://`）
へ接続し、NGINX が `ws://127.0.0.1:11182` へ中継します。

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
├── test/hvw-cdk.test.ts      # スタックの簡易テスト
└── README.md
```
