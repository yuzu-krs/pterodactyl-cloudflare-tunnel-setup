# Pterodactyl Panel 構築手順（panel.cloudru.jp）

この手順書は、Cloudflare管理のドメイン `cloudru.jp` のサブドメイン `panel.cloudru.jp` で Pterodactyl Panel を公開するためのセットアップガイドです。OS は Ubuntu 22.04 LTS を前提としています（Windows サーバー上への Panel 直接導入は非推奨／未対応のため、Linux サーバーをご用意ください）。

---

## 概要

- 目的: Pterodactyl Panel を `https://panel.cloudru.jp` に Cloudflare Tunnel で公開
- DNS/SSL: Cloudflare Tunnel による CNAME。SSL は Cloudflare 終端（Let's Encrypt 不要）
- Web: Nginx（ローカル受け：127.0.0.1:80） + PHP-FPM + MariaDB + Redis
- 推奨構成: Ubuntu 22.04 LTS の VM（ローカル／NAT環境でも可）、Wings（ゲームノード）は別サーバーで運用

---

## 前提条件

- Cloudflare 上で `cloudru.jp` を管理していること
- Panel 実行サーバー（Ubuntu 22.04 LTS のVM、ローカル／NAT環境でも可）
  - 推奨: 2 vCPU / 4GB RAM / 40GB SSD 以上
- サーバーへ SSH（root または sudo）接続可能
- メール送信に使う SMTP アカウント（任意／推奨）
- Cloudflare Tunnel でドメイン `panel.cloudru.jp` を公開

---

## Cloudflare DNS 設定（Tunnel公開）

1. Cloudflare ダッシュボード → `cloudru.jp` → DNS
2. DNS レコードの作成
   - **A レコードは不要です**（グローバルIPは使いません）
   - `cloudflared tunnel route dns panel-cloudru panel.cloudru.jp` の実行で CNAME が自動作成されます
   - 手動で設定する場合: `panel.cloudru.jp` を `<トンネルUUID>.cfargotunnel.com` に CNAME

3. Cloudflare → SSL/TLS 設定
   - モード: `Full`
   - `WebSockets` を有効（デフォルト有効）
   - 注: SSL は Cloudflare 側で終端されるため、Let's Encrypt の設定は不要です

---

## Cloudflare Tunnel の利点

本手順では Cloudflare Tunnel を使用するため、以下の利点があります。

- **グローバルIP不要**: ローカルやNAT環境のVMでも公開可能
- **ポート開放不要**: サーバーから Cloudflare へのアウトバウンド接続のみ
- **SSL自動**: Cloudflare 側でSSL終端されるため、Let's Encrypt の設定不要

**Wings（ゲームノード）について**

- パブリックなゲーム運用には、グローバルIPと必要ポート開放が必須（UDP を含む）
- Cloudflare Tunnel はゲームの任意ポートや UDP をプロキシできません
- Wings の公開運用はグローバルIPを持つ VPS/専用サーバー上で行ってください

---

## Cloudflare Tunnel セットアップ

Cloudflare Tunnel（cloudflared）で `panel.cloudru.jp` を公開します。

### 手順（Ubuntu 例）

1. Cloudflare Zero Trust を有効化（無料枠で可）
2. サーバーに cloudflared を導入

```bash
# 最新版の cloudflared をダウンロード
wget https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
sudo dpkg -i cloudflared-linux-amd64.deb

# インストール確認
cloudflared --version
# ↑ バージョン情報が表示されればOK
```

3. 認証・トンネル作成・DNS ルート設定

```bash
# Cloudflare にログイン（ブラウザが開きます）
cloudflared tunnel login
# ↑ブラウザで Cloudflare にログインし、ドメイン（cloudru.jp）を選択
# 成功すると ~/.cloudflared/cert.pem が作成されます

# トンネルを作成
cloudflared tunnel create panel-cloudru
# ↑ 成功すると以下のような出力が表示されます:
# Created tunnel panel-cloudru with id 515d3a99-e74c-4312-a85c-feab39c95128
# このUUID（515d3a99-...）を次のステップで使用します

# 資格情報ファイルの場所を確認
ls -la ~/.cloudflared/*.json
# ↑ /root/.cloudflared/515d3a99-e74c-4312-a85c-feab39c95128.json のようなファイルが作成されています

# DNS ルートを作成（panel.cloudru.jp をトンネルに紐付け）
cloudflared tunnel route dns panel-cloudru panel.cloudru.jp
# ↑ Cloudflare DNS に自動的に CNAME レコードが追加されます
# panel.cloudru.jp → 515d3a99-e74c-4312-a85c-feab39c95128.cfargotunnel.com

# DNS レコード作成を確認
# Cloudflare ダッシュボード → cloudru.jp → DNS → Records
# panel.cloudru.jp の CNAME が作成されていればOK
```

4. 設定ファイル作成（`/etc/cloudflared/config.yml`）

```bash
sudo tee /etc/cloudflared/config.yml <<'YAML'
tunnel: panel-cloudru
# 上行のトンネル名に対応する資格情報JSONのパスを指定（login/create後に作成されます）
credentials-file: /root/.cloudflared/<トンネルUUID>.json
ingress:
    - hostname: panel.cloudru.jp
        service: http://127.0.0.1:80
    - service: http_status:404
YAML
```

5. Nginx はローカル受けにする（例：`listen 127.0.0.1:80;`）
   - 本 README の Nginx サイト設定内の `listen 80;` を `listen 127.0.0.1:80;` に変更
6. cloudflared を常駐化

```bash
# サービスとしてインストール
sudo cloudflared service install
# ↑ systemd サービスが作成されます

# サービスを有効化して起動
sudo systemctl enable --now cloudflared

# サービスの状態を確認
sudo systemctl status cloudflared
# ↑ "active (running)" と表示され、
# "Registered tunnel connection" というログが表示されればOK

# トンネル接続を確認
sudo journalctl -u cloudflared -n 50
# ↑ "Registered tunnel connection" が複数表示されていれば正常に動作中
```

以後、`panel.cloudru.jp` へのアクセスは Cloudflare 経由でサーバー内の `127.0.0.1:80` にルーティングされます。Let’s Encrypt は不要（Cloudflare 側で終端）。`Full (strict)` を使う場合は Origin 証明書の構成で 443 をローカル終端にして `service: https://127.0.0.1:443` とする運用も可能です。

---

## サーバー初期設定（Ubuntu 22.04）

```bash
# システム更新
sudo apt update && sudo apt upgrade -y

# Webサーバー、データベース、キャッシュサーバー
sudo apt install -y nginx mariadb-server redis-server

# PHP 8.2 と必要な拡張モジュール（PPA 経由）
sudo apt install -y software-properties-common  # PPAリポジトリ追加用ツール
sudo add-apt-repository ppa:ondrej/php -y       # 最新PHP用のPPA
sudo apt update

# PHP 8.2 本体と必須拡張を一括インストール
# 注意: php8.2-fpm は必須です（Nginx連携に使用）
sudo apt install -y \
  php8.2 \              # PHP 8.2 本体
  php8.2-fpm \          # ★必須★ FastCGI Process Manager（Nginx連携用）
  php8.2-cli \          # コマンドライン版PHP
  php8.2-common \       # 共通ファイル
  php8.2-mysql \        # ★必須★ MySQL/MariaDB接続（pdo_mysql含む）
  php8.2-mbstring \     # ★必須★ マルチバイト文字列処理（日本語対応）
  php8.2-xml \          # ★必須★ XML処理（dom, simplexml含む）
  php8.2-bcmath \       # ★必須★ 高精度数値演算
  php8.2-curl \         # HTTP通信
  php8.2-gd \           # 画像処理
  php8.2-zip \          # ZIP圧縮/解凍
  php8.2-intl \         # 国際化サポート
  php8.2-opcache \      # パフォーマンス向上
  php8.2-readline       # 対話式コマンド入力

# PHP-FPM が正常にインストールされたか確認
sudo systemctl status php8.2-fpm
# ↑ "active (running)" と表示されればOK

# PHPバージョン確認（CLI）
php -v
# ↑ "PHP 8.2.x" と表示されることを確認

# インストールされた拡張モジュールの確認
php -m | grep -E 'pdo_mysql|mbstring|bcmath|dom|simplexml|xml'
# ↑ これらがすべて表示されればOK

# 依存関係管理とバージョン管理
sudo apt install -y composer git curl unzip
# composer: PHP依存関係管理ツール（依存パッケージのインストールに使用）
# git: バージョン管理システム（Pterodactylのダウンロードに使用）
# curl: HTTP通信ツール
# unzip: ZIP解凍ツール
```

---

## MariaDB 初期設定とデータベース作成

```bash
# MariaDB のセキュア化（root パスワード設定）
sudo mysql_secure_installation
# 対話形式で以下を設定:
# - root パスワード設定: Y → 強力なパスワードを入力
# - 匿名ユーザー削除: Y
# - rootのリモートログイン禁止: Y
# - testデータベースの削除: Y
# - 権限テーブルの再読み込み: Y

# DB とユーザー作成（パスワードは必ず変更してください）
# 注意: パスワードに特殊文字（#, $, !, @ など）が含まれる場合は要注意
sudo mysql -u root -p <<'SQL'
CREATE DATABASE pterodactyl;
CREATE USER 'ptero'@'localhost' IDENTIFIED BY '#ehLqrZECk2w2GL$5iLV';
GRANT ALL PRIVILEGES ON pterodactyl.* TO 'ptero'@'localhost';
FLUSH PRIVILEGES;
SQL

# データベースとユーザーが正しく作成されたか確認
sudo mysql -u root -p -e "SHOW DATABASES LIKE 'pterodactyl';"
sudo mysql -u root -p -e "SELECT User, Host FROM mysql.user WHERE User='ptero';"
# ↑ pterodactyl データベースと ptero@localhost ユーザーが表示されればOK

# 作成したユーザーで接続テスト
mysql -u ptero -p pterodactyl -e "SELECT 1;"
# ↑ パスワード入力後、"1" が表示されれば接続成功
```

---

## Pterodactyl Panel の取得と配置

```bash
# パネル用ディレクトリ作成
sudo mkdir -p /var/www/pterodactyl
sudo chown -R $USER:$USER /var/www/pterodactyl
cd /var/www/pterodactyl

# 最新の安定版を取得（公式リリースページから自動取得）
curl -L https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz | tar -xz

# 依存パッケージのインストール
# 注意: PHP 8.4がインストールされている場合、composer がそちらを使用する可能性があります
# その場合、必要な拡張が不足してエラーになるため、以下を確認してください
php -v  # 使用される PHP バージョンを確認

# Composer で依存パッケージをインストール
# --no-dev: 開発用パッケージをインストールしない（本番環境用）
# --optimize-autoloader: autoload を最適化（パフォーマンス向上）
composer install --no-dev --optimize-autoloader

# エラーが出た場合のトラブルシューティング:
#
# エラー例: "ext-pdo_mysql * is missing from your system"
# → PHP拡張が不足しています。以下を実行:
# sudo apt install -y php8.2-mysql php8.2-xml php8.2-bcmath php8.2-mbstring
# sudo systemctl restart php8.2-fpm
# その後、再度 composer install を実行
#
# エラー例: "Call to undefined function Illuminate\Support\mb_split()"
# → mbstring 拡張がありません:
# sudo apt install -y php8.2-mbstring
# sudo systemctl restart php8.2-fpm

# composer install が成功したか確認
ls -la vendor/  # vendor ディレクトリが作成されていればOK
php artisan --version  # Pterodactyl のバージョンが表示されればOK

# .env ファイルの作成
cp .env.example .env
```

---

## .env の主な設定

`.env` ファイルを編集して、以下を設定します。

```bash
# エディタで .env を開く
nano /var/www/pterodactyl/.env
```

設定内容（重要な箇所を抜粋）:

```env
APP_NAME="Pterodactyl Panel"
APP_URL=https://panel.cloudru.jp
APP_ENV=production
APP_DEBUG=false
APP_TIMEZONE=Asia/Tokyo

# データベース接続設定
DB_CONNECTION=mysql
DB_HOST=127.0.0.1
DB_PORT=3306
DB_DATABASE=pterodactyl
DB_USERNAME=ptero
# ★重要★ パスワードに特殊文字（#, $, !, @など）が含まれる場合は
# ダブルクォーテーションで囲んでください
# 例: DB_PASSWORD="#ehLqrZECk2w2GL$5iLV"
DB_PASSWORD="#ehLqrZECk2w2GL$5iLV"

# Redis（キャッシュ・セッション・キュー用）
REDIS_HOST=127.0.0.1
REDIS_PASSWORD=null
REDIS_PORT=6379
CACHE_STORE=redis
SESSION_DRIVER=redis
QUEUE_CONNECTION=redis

# メール送信設定（任意：通知やパスワードリセットに使用）
# 未設定の場合、メール送信機能は無効になります
MAIL_MAILER=smtp
MAIL_HOST=smtp.example.com
MAIL_PORT=587
MAIL_USERNAME=ユーザー名
MAIL_PASSWORD=パスワード
MAIL_ENCRYPTION=tls
MAIL_FROM_ADDRESS=panel@cloudru.jp
MAIL_FROM_NAME="Pterodactyl"
```

**重要な注意点:**

1. **DB_PASSWORD の引用符**
   - パスワードに `#`, `$`, `!`, `@`, スペースなどの特殊文字が含まれる場合は、必ずダブルクォーテーションで囲んでください
   - 悪い例: `DB_PASSWORD=#ehLqrZECk2w2GL$5iLV` ← # がコメントとして扱われる
   - 良い例: `DB_PASSWORD="#ehLqrZECk2w2GL$5iLV"` ← 正しく解釈される

2. **APP_URL の設定**
   - Cloudflare Tunnel を使用する場合は `https://panel.cloudru.jp` を設定
   - 末尾にスラッシュ `/` は不要です

3. **APP_DEBUG**
   - 本番環境では必ず `false` に設定（セキュリティ上重要）
   - デバッグ情報の漏洩を防ぎます

---

## パネルの初期化

```bash
cd /var/www/pterodactyl

# 1. アプリケーションキーの生成
php artisan key:generate --force
# ↑ "Application key set successfully." と表示されればOK
# .env ファイルに APP_KEY が自動生成されます

# 2. データベースのマイグレーションと初期データ投入
php artisan migrate --seed --force
# ↑ テーブル作成と初期データが投入されます
# エラーが出た場合のトラブルシューティング:
#
# エラー例: "Access denied for user 'ptero'@'localhost' (using password: NO)"
# → .env の DB_PASSWORD が正しく読み込まれていません
# 対処法:
# 1. パスワードをダブルクォーテーションで囲む
#    sed -i 's/^DB_PASSWORD=.*$/DB_PASSWORD="#ehLqrZECk2w2GL$5iLV"/' .env
# 2. 設定キャッシュをクリア
#    php artisan config:clear
# 3. 再度マイグレーション実行
#    php artisan migrate --seed --force

# データベースにテーブルが作成されたか確認
mysql -u ptero -p"#ehLqrZECk2w2GL\$5iLV" pterodactyl -e "SHOW TABLES;"
# ↑ 多数のテーブル（users, servers, nodes など）が表示されればOK

# 3. ストレージディレクトリへのシンボリックリンク作成
php artisan storage:link
# ↑ "The [public/storage] link has been connected to [storage/app/public]." と表示されればOK

# 4. ファイルパーミッションの設定
# 所有者を www-data（Webサーバーユーザー）に変更
sudo chown -R www-data:www-data /var/www/pterodactyl

# ファイルは 644（rw-r--r--）、ディレクトリは 755（rwxr-xr-x）に設定
sudo find /var/www/pterodactyl -type f -exec chmod 644 {} \;
sudo find /var/www/pterodactyl -type d -exec chmod 755 {} \;

# storage と bootstrap/cache には書き込み権限が必要
sudo chmod -R 775 /var/www/pterodactyl/storage /var/www/pterodactyl/bootstrap/cache

# パーミッション確認
ls -la /var/www/pterodactyl/ | head -20
# ↑ 所有者が www-data:www-data になっていればOK
```

---

## 管理ユーザー作成

```bash
cd /var/www/pterodactyl

# 管理者ユーザーを作成
php artisan p:user:make

# 対話形式で以下を入力:
# Is this user an administrator? (yes/no) [no]:
# → yes と入力
#
# Email Address:
# → yuzuto.poi@gmail.com（お好きなメールアドレス）
#
# Username:
# → yuzu（お好きなユーザー名）
#
# First Name:
# → Yuzu（名前）
#
# Last Name:
# → Admin（姓）
#
# Password:
# → YuzuAdmin123（大文字・数字を含む8文字以上）
#
# パスワード要件:
# - 8文字以上
# - 大文字を最低1文字含む
# - 数字を最低1文字含む

# ユーザーが作成されたか確認
mysql -u ptero -p"#ehLqrZECk2w2GL\$5iLV" pterodactyl -e "SELECT id, username, email, root_admin FROM users;"
# ↑ 作成したユーザーが表示され、root_admin が 1 になっていればOK
```

### 既存ユーザーのパスワードをリセットする方法

既にユーザーが存在していてパスワードを忘れた場合:

**方法1: ユーザーを削除して再作成**

```bash
# ユーザーを削除
php artisan p:user:delete --user=1
# ↑ ユーザーIDを指定（mysql で確認した id を使用）

# 削除確認で "1" を入力、次に "yes" を入力

# 削除後、再度作成
php artisan p:user:make
```

**方法2: Tinker でパスワードを直接更新**

```bash
# Laravel Tinker を起動
php artisan tinker

# Tinker 内で以下を実行（>>> プロンプトで入力）:
$user = \Pterodactyl\Models\User::where('email', 'yuzuto.poi@gmail.com')->first();
$user->password = bcrypt('NewPassword123');
$user->save();
exit

# ↑ NewPassword123 の部分を新しいパスワードに変更してください
```

**方法3: MySQL で直接更新（非推奨だが緊急時に有効）**

```bash
# パスワードハッシュを生成
php -r "echo password_hash('NewPassword123', PASSWORD_BCRYPT) . PHP_EOL;"
# ↑ 生成されたハッシュ値をコピー

# MySQL でパスワードを更新
mysql -u ptero -p"#ehLqrZECk2w2GL\$5iLV" pterodactyl -e "UPDATE users SET password='生成したハッシュ値' WHERE email='yuzuto.poi@gmail.com';"
```

---

## Nginx 構成（`panel.cloudru.jp`）

```bash
# Nginx サイト設定ファイルを作成
# 注意: Cloudflare Tunnel を使用するため、listen 127.0.0.1:80 でローカルのみリッスン
sudo tee /etc/nginx/sites-available/pterodactyl <<'NGINX'
server {
    # Cloudflare Tunnel 経由のため、ローカルのみリッスン
    listen 127.0.0.1:80;
    server_name panel.cloudru.jp;
    root /var/www/pterodactyl/public;

    index index.php;

    # アクセスログとエラーログ
    access_log /var/log/nginx/pterodactyl-access.log;
    error_log /var/log/nginx/pterodactyl-error.log;

    # ルートディレクトリの設定
    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    # PHP-FPM の設定
    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        # PHP 8.2-FPM のソケットパス
        fastcgi_pass unix:/var/run/php/php8.2-fpm.sock;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        include fastcgi_params;
    }

    # 静的ファイルのキャッシュ設定
    location ~* \.(jpg|jpeg|png|gif|ico|css|js|svg|woff|woff2|ttf|eot)$ {
        expires 30d;
        access_log off;
        add_header Cache-Control "public, immutable";
    }

    # .htaccess などの隠しファイルへのアクセス拒否
    location ~ /\.ht {
        deny all;
    }
}
NGINX

# サイトを有効化
sudo ln -s /etc/nginx/sites-available/pterodactyl /etc/nginx/sites-enabled/pterodactyl

# デフォルトサイトを無効化（任意）
sudo rm -f /etc/nginx/sites-enabled/default

# Nginx 設定のテスト
sudo nginx -t
# ↑ "syntax is ok" と "test is successful" が表示されればOK

# PHP-FPM が起動しているか確認
sudo systemctl status php8.2-fpm
# ↑ "active (running)" と表示されればOK

# Nginx を再起動
sudo systemctl reload nginx

# Nginx のステータス確認
sudo systemctl status nginx

# ローカルでリッスンしているか確認
sudo ss -ltnp | grep ':80'
# ↑ "127.0.0.1:80" で nginx がリッスンしていればOK
```

---

## キューとスケジューラの常駐化

### Systemd サービス（Queue Worker）

```bash
sudo tee /etc/systemd/system/pteroq.service <<'UNIT'
[Unit]
Description=Pterodactyl Queue Worker
After=redis-server.service

[Service]
User=www-data
Group=www-data
WorkingDirectory=/var/www/pterodactyl
ExecStart=/usr/bin/php /var/www/pterodactyl/artisan queue:work --sleep=3 --tries=3 --timeout=90
Restart=always
StartLimitInterval=0

[Install]
WantedBy=multi-user.target
UNIT

sudo systemctl daemon-reload
sudo systemctl enable --now pteroq
```

### Cron（Scheduler）

```bash
sudo -u www-data crontab -l | { cat; echo "* * * * * php /var/www/pterodactyl/artisan schedule:run >> /dev/null 2>&1"; } | sudo -u www-data crontab -
```

---

## Cloudflare 推奨設定

- SSL/TLS: `Full`（Origin Cert を使うなら `Full (strict)`）
- Speed: `HTTP/2` と `HTTP/3` を有効
- Network: `WebSockets` 有効（デフォルト）
- Page Rules/Rules: 不要なキャッシュを避け、動的ページでの過度なキャッシュはしない

---

## 動作確認

セットアップが完了したら、以下の手順で動作確認を行います。

### 1. サービスの状態確認

```bash
# すべてのサービスが正常に動作しているか確認
sudo systemctl status cloudflared nginx php8.2-fpm mariadb redis-server pteroq

# 個別に確認する場合:
sudo systemctl status cloudflared   # Cloudflare Tunnel
sudo systemctl status nginx          # Webサーバー
sudo systemctl status php8.2-fpm     # PHP FastCGI Process Manager
sudo systemctl status mariadb        # データベース
sudo systemctl status redis-server   # キャッシュ/キュー
sudo systemctl status pteroq         # Queue Worker

# すべて "active (running)" と表示されればOK
```

### 2. ネットワーク接続確認

```bash
# Nginx がローカルでリッスンしているか確認
sudo ss -ltnp | grep ':80'
# ↑ "127.0.0.1:80" でnginxがリッスンしていればOK

# MariaDB がローカルでリッスンしているか確認
sudo ss -ltnp | grep ':3306'
# ↑ "127.0.0.1:3306" または ":::3306" が表示されればOK

# Redis がローカルでリッスンしているか確認
sudo ss -ltnp | grep ':6379'
# ↑ "127.0.0.1:6379" が表示されればOK
```

### 3. ログの確認

```bash
# Cloudflare Tunnel のログ
sudo journalctl -u cloudflared -n 50
# ↑ "Registered tunnel connection" が複数行表示されていればOK

# Nginx のエラーログ
sudo tail -n 50 /var/log/nginx/error.log
# ↑ エラーがないか確認

# Pterodactyl のログ
sudo tail -n 100 /var/www/pterodactyl/storage/logs/laravel-*.log
# ↑ ERROR レベルのログがないか確認

# pteroq のログ
sudo journalctl -u pteroq -n 50
# ↑ ジョブが正常に処理されているか確認
```

### 4. ブラウザでアクセス

1. ブラウザで **https://panel.cloudru.jp** にアクセス
2. Pterodactyl のログイン画面が表示されることを確認
3. 作成した管理者ユーザーでログイン:
   - **ユーザー名またはメール**: `yuzu` または `yuzuto.poi@gmail.com`
   - **パスワード**: 作成時に設定したパスワード

4. ログイン成功後、以下を確認:
   - ダッシュボードが表示される
   - 左側のメニューが正常に表示される
   - 右上にユーザー名が表示される

### 5. 管理画面の確認

ログイン後、以下の管理機能が正常に動作するか確認:

```
1. /admin にアクセス → 管理画面が表示される
2. Settings → メール設定などが保存できる
3. Locations → 新しいLocationを作成できる
4. Nodes → ノード一覧が表示される（まだノードは未作成）
5. Servers → サーバー一覧が表示される（まだサーバーは未作成）
```

### チェックリスト（Tunnel公開時）

すべて☑になっていれば正常にセットアップ完了です:

- [ ] `cloudflared` サービスが `active (running)`
- [ ] `nginx` サービスが `active (running)`
- [ ] `php8.2-fpm` サービスが `active (running)`
- [ ] `mariadb` サービスが `active (running)`
- [ ] `redis-server` サービスが `active (running)`
- [ ] `pteroq` サービスが `active (running)`
- [ ] Cloudflare DNS に `panel.cloudru.jp` の CNAME レコードが存在
- [ ] Nginx が `127.0.0.1:80` でリッスン中
- [ ] `.env` の `APP_URL` が `https://panel.cloudru.jp`
- [ ] `.env` の `DB_PASSWORD` が引用符で囲まれている（特殊文字含む場合）
- [ ] https://panel.cloudru.jp でログイン画面が表示される
- [ ] 管理者ユーザーでログインできる
- [ ] /admin にアクセスできる
- [ ] Laravelログにエラーがない

### トラブル発生時の確認コマンド

問題が発生した場合、以下のコマンドを順に実行して情報を収集してください:

```bash
# サービスの状態確認
sudo systemctl status cloudflared nginx php8.2-fpm mariadb redis-server pteroq

# ログの確認
sudo journalctl -u cloudflared -n 50
sudo tail -n 100 /var/log/nginx/error.log
sudo tail -n 100 /var/www/pterodactyl/storage/logs/laravel-*.log

# ネットワーク確認
sudo ss -ltnp | grep -E ':80|:3306|:6379'

# ファイルパーミッション確認
ls -la /var/www/pterodactyl/
ls -la /var/www/pterodactyl/storage/

# PHP拡張確認
php -m | grep -E 'pdo_mysql|mbstring|bcmath|dom|simplexml|xml'

# データベース接続テスト
php artisan migrate:status
```

---

## Wings（ゲームノード）の導入（任意）

**重要:** Wingsは実際にゲームサーバーを動かすコンポーネントです。Panelとは別のサーバーで運用することを強く推奨します。

### 前提条件

- **グローバルIPアドレス必須**: ゲームサーバーにプレイヤーが接続するため
- **ポート開放必須**:
  - Wings API: 8080/TCP
  - SFTP: 2022/TCP
  - ゲームポート: ゲームごとに異なる（例: Minecraft 25565/TCP, Rust 28015-28016/TCP+UDP）
- **推奨スペック**: 4 vCPU / 8GB RAM / 100GB SSD 以上
- **Cloudflare Tunnelは使用不可**: UDP通信や任意ポートをプロキシできないため

### セットアップ手順概要

#### 1. Docker のインストール

```bash
# Docker の公式インストールスクリプトを使用
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh

# Docker サービスを有効化
sudo systemctl enable --now docker

# Docker が動作しているか確認
sudo docker run hello-world
# ↑ "Hello from Docker!" と表示されればOK
```

#### 2. Wings のインストール

```bash
# Wings バイナリをダウンロード
sudo mkdir -p /etc/pterodactyl
curl -L -o /usr/local/bin/wings "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_amd64"

# 実行権限を付与
sudo chmod u+x /usr/local/bin/wings

# バージョン確認
wings --version
# ↑ バージョン情報が表示されればOK
```

#### 3. Panel 側でノードを作成

1. Panel の管理画面にログイン: https://panel.cloudru.jp/admin
2. **Locations** → **Create New**
   - Short Code: `tokyo`（任意）
   - Description: `Tokyo Datacenter`（任意）
   - 作成
3. **Nodes** → **Create New**
   - Name: `Node-1`（任意）
   - Description: ノードの説明（任意）
   - Location: 先ほど作成したLocation（tokyo）を選択
   - **FQDN**: WingsサーバーのドメインまたはグローバルIP（例: `node1.cloudru.jp` または `203.0.113.10`）
   - **Communicate Over SSL**: WingsでSSLを設定する場合はチェック（推奨）
   - **Behind Proxy**: 通常はチェックしない
   - **Daemon Port**: `8080`（デフォルト）
   - **Daemon SFTP Port**: `2022`（デフォルト）
   - Memory: 利用可能なメモリ量（MB単位、例: 8192）
   - Memory Over-Allocate: オーバーアロケーション率（%、例: 0）
   - Disk Space: 利用可能なディスク容量（MB単位、例: 102400）
   - Disk Over-Allocate: オーバーアロケーション率（%、例: 0）
   - **Daemon Server File Directory**: `/var/lib/pterodactyl/volumes`（デフォルト）
   - 作成

4. 作成したノードの **Configuration** タブを開く
5. `config.yml` の内容をコピー

#### 4. Wings の設定

```bash
# Panel からコピーした config.yml を配置
sudo nano /etc/pterodactyl/config.yml
# ↑ コピーした内容を貼り付けて保存

# config.yml の内容例:
# debug: false
# uuid: ノードのUUID
# token_id: トークンID
# token: トークン
# api:
#   host: 0.0.0.0
#   port: 8080
#   ssl:
#     enabled: false
#     cert: ""
#     key: ""
# system:
#   data: /var/lib/pterodactyl/volumes
#   sftp:
#     bind_port: 2022
# remote: https://panel.cloudru.jp

# 設定ファイルの権限を設定
sudo chmod 600 /etc/pterodactyl/config.yml
```

#### 5. Wings の起動テスト

```bash
# Wings を手動で起動してテスト
sudo wings --config /etc/pterodactyl/config.yml --debug

# ↑ 以下のようなログが表示されればOK:
# [INFO] Wings v1.x.x
# [INFO] Using configuration file: /etc/pterodactyl/config.yml
# [INFO] Checking for new releases
# [INFO] Starting server manager
# [INFO] Configuring internal webserver
# [INFO] Listening on 0.0.0.0:8080

# Ctrl+C で停止
```

#### 6. Wings の常駐化

```bash
# systemd サービスファイルを作成
sudo tee /etc/systemd/system/wings.service <<'UNIT'
[Unit]
Description=Pterodactyl Wings Daemon
After=docker.service
Requires=docker.service
PartOf=docker.service

[Service]
User=root
WorkingDirectory=/etc/pterodactyl
LimitNOFILE=4096
PIDFile=/var/run/wings/daemon.pid
ExecStart=/usr/local/bin/wings
Restart=on-failure
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s

[Install]
WantedBy=multi-user.target
UNIT

# systemd をリロード
sudo systemctl daemon-reload

# Wings を有効化して起動
sudo systemctl enable --now wings

# 状態確認
sudo systemctl status wings
# ↑ "active (running)" と表示されればOK
```

#### 7. ファイアウォール設定

```bash
# UFW を使用する場合の例
sudo ufw allow 8080/tcp   # Wings API
sudo ufw allow 2022/tcp   # SFTP
sudo ufw allow 25565/tcp  # Minecraft（例）
# ゲームごとに必要なポートを開放してください
```

#### 8. Panel での確認

1. Panel の管理画面 → **Nodes** → 作成したノード
2. ハートビートアイコンが緑色（オンライン）になっていることを確認
3. システム情報（CPU、メモリ、ディスク）が表示されていればOK

### SSL設定（推奨）

WingsとPanel間の通信をSSLで暗号化する場合:

```bash
# Let's Encrypt を使用（例: node1.cloudru.jp）
sudo apt install -y certbot
sudo certbot certonly --standalone -d node1.cloudru.jp

# 証明書が /etc/letsencrypt/live/node1.cloudru.jp/ に生成されます

# config.yml を編集
sudo nano /etc/pterodactyl/config.yml
```

config.yml の ssl セクションを以下のように変更:

```yaml
api:
  host: 0.0.0.0
  port: 8080
  ssl:
    enabled: true
    cert: /etc/letsencrypt/live/node1.cloudru.jp/fullchain.pem
    key: /etc/letsencrypt/live/node1.cloudru.jp/privkey.pem
```

```bash
# Wings を再起動
sudo systemctl restart wings

# Panel 側のノード設定で "Communicate Over SSL" をチェック
# FQDN を https://node1.cloudru.jp に変更
```

### サーバー作成

Wingsのセットアップが完了したら、Panel からゲームサーバーを作成できます:

1. Panel 管理画面 → **Servers** → **Create New**
2. 必要事項を入力:
   - Server Name: サーバー名
   - Server Owner: サーバーの所有者（ユーザー）
   - Node: 先ほど作成したノードを選択
   - Default Allocation: IPアドレスとポートを選択
   - Memory/Disk/CPU: リソース割り当て
   - Nest: ゲームの種類（例: Minecraft）
   - Egg: ゲームのバージョン（例: Paper）
3. 作成
4. サーバー管理画面でサーバーの起動/停止/再起動が可能になります

---

## セキュリティの要点

セキュリティは継続的な取り組みです。以下の項目を定期的に確認してください。

### 1. システムとパッケージの更新

```bash
# 定期的にシステムを更新（週1回推奨）
sudo apt update && sudo apt upgrade -y

# Pterodactyl Panel の更新確認
cd /var/www/pterodactyl
php artisan p:upgrade

# Wings の更新確認
curl -L -o /usr/local/bin/wings "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_amd64"
sudo chmod u+x /usr/local/bin/wings
sudo systemctl restart wings
```

### 2. 環境変数とパスワードの管理

```bash
# .env ファイルの権限を制限
sudo chmod 600 /var/www/pterodactyl/.env
sudo chown www-data:www-data /var/www/pterodactyl/.env

# APP_DEBUG を本番環境では必ず false に
# APP_ENV を必ず production に
grep -E "APP_DEBUG|APP_ENV" /var/www/pterodactyl/.env

# データベースパスワードは強力なものを使用
# 40文字以上、大小英数字+記号を含む推奨
```

### 3. ファイアウォールの設定

```bash
# UFW（Uncomplicated Firewall）のインストールと設定
sudo apt install -y ufw

# デフォルトポリシー（すべて拒否、送信は許可）
sudo ufw default deny incoming
sudo ufw default allow outgoing

# SSH を許可（重要！ロックアウト防止）
sudo ufw allow ssh

# Panel サーバーの場合（Cloudflare Tunnel使用時）:
# - 80/443は開放不要（Tunnelがアウトバウンド接続するため）
# - SSH のみ開放

# Wings サーバーの場合:
sudo ufw allow 8080/tcp   # Wings API
sudo ufw allow 2022/tcp   # SFTP
# + ゲームポート（例: 25565/tcp）

# UFW を有効化
sudo ufw enable

# 設定確認
sudo ufw status verbose
```

### 4. Fail2Ban の導入（SSH攻撃対策）

```bash
# Fail2Ban のインストール
sudo apt install -y fail2ban

# 設定ファイルのコピー
sudo cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local

# SSH 保護を有効化
sudo tee /etc/fail2ban/jail.d/sshd.conf <<'EOF'
[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 5
bantime = 3600
EOF

# Fail2Ban を起動
sudo systemctl enable --now fail2ban

# 状態確認
sudo fail2ban-client status sshd
```

### 5. SSH のセキュリティ強化

```bash
# SSH 設定を編集
sudo nano /etc/ssh/sshd_config

# 以下を確認・設定:
# PermitRootLogin no                 # root ログインを無効化（推奨）
# PasswordAuthentication no          # パスワード認証を無効化（鍵認証のみ）
# PubkeyAuthentication yes           # 公開鍵認証を有効化
# Port 22                            # デフォルトポートを変更（任意）

# 設定を反映
sudo systemctl restart sshd
```

### 6. Cloudflare のセキュリティ機能

Cloudflare ダッシュボードで以下を設定:

1. **Security → WAF**: Web Application Firewall ルールを有効化
2. **Security → DDoS**: DDoS 保護が自動で有効
3. **Security → Bot Fight Mode**: ボット攻撃対策を有効化
4. **Security → Rate Limiting**: レート制限ルールを設定（例: /login へのアクセスを制限）
5. **SSL/TLS**: モードを `Full` または `Full (strict)` に設定

#### Rate Limiting 設定例:

- Path: `https://panel.cloudru.jp/auth/login`
- Requests: 5 requests
- Period: 60 seconds
- Action: Block

### 7. データベースのセキュリティ

```bash
# MariaDB の外部アクセス無効化（127.0.0.1のみ）
sudo nano /etc/mysql/mariadb.conf.d/50-server.cnf

# 以下を確認:
# bind-address = 127.0.0.1

# MariaDB を再起動
sudo systemctl restart mariadb

# root ユーザーのリモートアクセスを無効化
sudo mysql -u root -p -e "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');"
sudo mysql -u root -p -e "FLUSH PRIVILEGES;"

# 不要なデータベースユーザーの削除
sudo mysql -u root -p -e "SELECT User, Host FROM mysql.user;"
# ↑ 不要なユーザーがいれば DROP USER で削除
```

### 8. 定期的なバックアップ

```bash
# バックアップスクリプトの作成
sudo tee /usr/local/bin/pterodactyl-backup.sh <<'SCRIPT'
#!/bin/bash
BACKUP_DIR="/backup/pterodactyl"
DATE=$(date +%Y%m%d_%H%M%S)

# ディレクトリ作成
mkdir -p $BACKUP_DIR

# データベースバックアップ
mysqldump -u ptero -p'#ehLqrZECk2w2GL$5iLV' pterodactyl | gzip > $BACKUP_DIR/pterodactyl_db_$DATE.sql.gz

# アプリケーションバックアップ
tar -czf $BACKUP_DIR/pterodactyl_app_$DATE.tar.gz /var/www/pterodactyl

# 30日以上古いバックアップを削除
find $BACKUP_DIR -type f -mtime +30 -delete

echo "Backup completed: $DATE"
SCRIPT

# 実行権限を付与
sudo chmod +x /usr/local/bin/pterodactyl-backup.sh

# cron で毎日実行
sudo crontab -e
# 以下を追加:
# 0 3 * * * /usr/local/bin/pterodactyl-backup.sh >> /var/log/pterodactyl-backup.log 2>&1
```

### 9. ログの監視

```bash
# 定期的にログを確認
sudo tail -n 100 /var/www/pterodactyl/storage/logs/laravel-*.log | grep -i error
sudo tail -n 100 /var/log/nginx/error.log
sudo journalctl -u cloudflared -n 100 | grep -i error
sudo journalctl -u pteroq -n 100 | grep -i error

# ログローテーションの設定
sudo tee /etc/logrotate.d/pterodactyl <<'EOF'
/var/www/pterodactyl/storage/logs/*.log {
    daily
    rotate 14
    compress
    delaycompress
    notifempty
    create 0640 www-data www-data
    sharedscripts
}
EOF
```

### 10. セキュリティチェックリスト

定期的に以下を確認してください:

- [ ] システムとパッケージが最新版
- [ ] `APP_DEBUG=false` と `APP_ENV=production`
- [ ] データベースパスワードが強力
- [ ] ファイアウォールが有効で適切なポートのみ開放
- [ ] SSH がパスワード認証無効（鍵認証のみ）
- [ ] Fail2Ban が有効
- [ ] MariaDB が外部アクセス無効
- [ ] Cloudflare WAF とレート制限が有効
- [ ] バックアップが定期的に実行されている
- [ ] ログに異常なアクセスやエラーがない
- [ ] 不要なユーザーアカウントが削除されている
- [ ] ファイルパーミッションが適切（644/755）

---

## バックアップ

定期的なバックアップは非常に重要です。以下の項目をバックアップしてください。

### 1. バックアップ対象

```bash
# 1. Pterodactyl アプリケーションファイル
/var/www/pterodactyl                    # アプリケーション全体
/var/www/pterodactyl/.env               # 環境変数（特に重要）
/var/www/pterodactyl/storage            # ログ、キャッシュ、アップロードファイル

# 2. データベース
# pterodactyl データベース全体

# 3. 設定ファイル
/etc/nginx/sites-available/pterodactyl  # Nginx 設定
/etc/systemd/system/pteroq.service      # Queue Worker サービス
/etc/cloudflared/config.yml             # Cloudflare Tunnel 設定
/root/.cloudflared/*.json               # Cloudflare Tunnel 資格情報

# 4. SSL証明書（使用している場合）
/etc/letsencrypt/                       # Let's Encrypt 証明書

# 5. Wings（別サーバーの場合）
/etc/pterodactyl/config.yml             # Wings 設定
/var/lib/pterodactyl/volumes            # ゲームサーバーデータ
```

### 2. 手動バックアップ

```bash
# バックアップディレクトリを作成
sudo mkdir -p /backup/pterodactyl
DATE=$(date +%Y%m%d_%H%M%S)

# 1. データベースのバックアップ
sudo mysqldump -u ptero -p"#ehLqrZECk2w2GL\$5iLV" pterodactyl | gzip > /backup/pterodactyl/pterodactyl_db_$DATE.sql.gz

# 2. アプリケーションファイルのバックアップ
sudo tar -czf /backup/pterodactyl/pterodactyl_app_$DATE.tar.gz \
  /var/www/pterodactyl \
  --exclude='/var/www/pterodactyl/storage/logs/*.log' \
  --exclude='/var/www/pterodactyl/storage/framework/cache/*' \
  --exclude='/var/www/pterodactyl/storage/framework/sessions/*'

# 3. 設定ファイルのバックアップ
sudo tar -czf /backup/pterodactyl/pterodactyl_config_$DATE.tar.gz \
  /etc/nginx/sites-available/pterodactyl \
  /etc/systemd/system/pteroq.service \
  /etc/cloudflared/config.yml \
  /root/.cloudflared/

# バックアップサイズを確認
du -sh /backup/pterodactyl/*
```

### 3. 自動バックアップスクリプト

```bash
# 自動バックアップスクリプトを作成
sudo tee /usr/local/bin/pterodactyl-backup.sh <<'SCRIPT'
#!/bin/bash
# Pterodactyl Panel バックアップスクリプト

set -e  # エラーで停止

# 設定
BACKUP_DIR="/backup/pterodactyl"
DATE=$(date +%Y%m%d_%H%M%S)
KEEP_DAYS=30
LOG_FILE="/var/log/pterodactyl-backup.log"

# ログ関数
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a $LOG_FILE
}

# バックアップディレクトリ作成
mkdir -p $BACKUP_DIR

log "=== Pterodactyl Panel Backup Start ==="

# 1. データベースバックアップ
log "Backing up database..."
mysqldump -u ptero -p'#ehLqrZECk2w2GL$5iLV' pterodactyl | gzip > $BACKUP_DIR/pterodactyl_db_$DATE.sql.gz
log "Database backup completed: pterodactyl_db_$DATE.sql.gz"

# 2. アプリケーションバックアップ
log "Backing up application files..."
tar -czf $BACKUP_DIR/pterodactyl_app_$DATE.tar.gz \
  /var/www/pterodactyl \
  --exclude='/var/www/pterodactyl/storage/logs/*.log' \
  --exclude='/var/www/pterodactyl/storage/framework/cache/*' \
  --exclude='/var/www/pterodactyl/storage/framework/sessions/*' \
  2>> $LOG_FILE
log "Application backup completed: pterodactyl_app_$DATE.tar.gz"

# 3. 設定ファイルバックアップ
log "Backing up configuration files..."
tar -czf $BACKUP_DIR/pterodactyl_config_$DATE.tar.gz \
  /etc/nginx/sites-available/pterodactyl \
  /etc/systemd/system/pteroq.service \
  /etc/cloudflared/config.yml \
  /root/.cloudflared/ \
  2>> $LOG_FILE
log "Configuration backup completed: pterodactyl_config_$DATE.tar.gz"

# 4. 古いバックアップを削除
log "Removing old backups (older than $KEEP_DAYS days)..."
find $BACKUP_DIR -type f -mtime +$KEEP_DAYS -delete
log "Old backups removed"

# バックアップサイズを報告
BACKUP_SIZE=$(du -sh $BACKUP_DIR | cut -f1)
log "Total backup size: $BACKUP_SIZE"
log "=== Pterodactyl Panel Backup Completed Successfully ==="
SCRIPT

# 実行権限を付与
sudo chmod +x /usr/local/bin/pterodactyl-backup.sh

# テスト実行
sudo /usr/local/bin/pterodactyl-backup.sh
```

### 4. cron で自動実行

```bash
# root の crontab を編集
sudo crontab -e

# 以下を追加（毎日午前3時に実行）
0 3 * * * /usr/local/bin/pterodactyl-backup.sh

# cron ジョブを確認
sudo crontab -l
```

### 5. リストア（復元）手順

バックアップから復元する場合:

```bash
# 復元する日付を指定
RESTORE_DATE="20260208_030000"  # バックアップファイルの日付

# 1. データベースを復元
gunzip < /backup/pterodactyl/pterodactyl_db_$RESTORE_DATE.sql.gz | mysql -u ptero -p'#ehLqrZECk2w2GL$5iLV' pterodactyl

# 2. アプリケーションファイルを復元
cd /
sudo tar -xzf /backup/pterodactyl/pterodactyl_app_$RESTORE_DATE.tar.gz

# 3. 設定ファイルを復元
cd /
sudo tar -xzf /backup/pterodactyl/pterodactyl_config_$RESTORE_DATE.tar.gz

# 4. パーミッションを修正
sudo chown -R www-data:www-data /var/www/pterodactyl
sudo chmod -R 755 /var/www/pterodactyl
sudo chmod -R 775 /var/www/pterodactyl/storage /var/www/pterodactyl/bootstrap/cache

# 5. サービスを再起動
sudo systemctl daemon-reload
sudo systemctl restart php8.2-fpm nginx pteroq cloudflared

# 6. キャッシュをクリア
cd /var/www/pterodactyl
php artisan config:clear
php artisan cache:clear
php artisan view:clear
```

### 6. オフサイトバックアップ（推奨）

バックアップを別の場所にも保存することを強く推奨します:

```bash
# rsync で別サーバーにバックアップ
rsync -avz --delete /backup/pterodactyl/ user@backup-server:/path/to/backup/

# または、オブジェクトストレージ（AWS S3, Wasabi など）に送信
# aws s3 sync /backup/pterodactyl/ s3://your-bucket/pterodactyl-backup/

# rclone を使用する場合
# rclone sync /backup/pterodactyl/ remote:pterodactyl-backup/
```

### 7. バックアップの検証

定期的にバックアップが正しく作成されているか確認してください:

```bash
# 最新のバックアップファイルを確認
ls -lh /backup/pterodactyl/ | tail -10

# バックアップログを確認
tail -n 50 /var/log/pterodactyl-backup.log

# データベースバックアップの整合性チェック（解凍できるか確認）
gunzip -t /backup/pterodactyl/pterodactyl_db_*.sql.gz

# tar アーカイブの整合性チェック
tar -tzf /backup/pterodactyl/pterodactyl_app_*.tar.gz > /dev/null
```

---

## よくあるトラブル

### 1. Nginx 502 Bad Gateway

**症状:** ブラウザで https://panel.cloudru.jp にアクセスすると "502 Bad Gateway" エラー

**原因と対処法:**

```bash
# PHP-FPM がインストールされていない・起動していない
sudo systemctl status php8.2-fpm

# 起動していない場合:
sudo apt install -y php8.2-fpm
sudo systemctl enable --now php8.2-fpm
sudo systemctl reload nginx

# ソケットファイルの確認
ls -la /var/run/php/php8.2-fpm.sock
# ↑ ファイルが存在しない場合、PHP-FPM が起動していません

# Nginx エラーログを確認
sudo tail -n 50 /var/log/nginx/error.log
# ↑ "connect() to unix:/var/run/php/php8.2-fpm.sock failed" というエラーがあれば
# PHP-FPM の問題です
```

### 2. 500 Internal Server Error

**症状:** Pterodactylパネルにアクセスすると "Oops! An Error Occurred" / "500 Internal Server Error"

**原因と対処法:**

```bash
# Laravel ログを確認（最も重要）
sudo tail -n 100 /var/www/pterodactyl/storage/logs/laravel-*.log

# よくあるエラー1: "Call to undefined function Illuminate\Support\mb_split()"
# → mbstring 拡張がインストールされていない
sudo apt install -y php8.2-mbstring
sudo systemctl restart php8.2-fpm

# よくあるエラー2: "Class 'DOMDocument' not found"
# → XML/DOM 拡張がインストールされていない
sudo apt install -y php8.2-xml
sudo systemctl restart php8.2-fpm

# よくあるエラー3: ファイルパーミッションエラー
sudo chown -R www-data:www-data /var/www/pterodactyl
sudo chmod -R 775 /var/www/pterodactyl/storage /var/www/pterodactyl/bootstrap/cache

# キャッシュをクリア
cd /var/www/pterodactyl
php artisan config:clear
php artisan cache:clear
php artisan view:clear
```

### 3. Database Connection Error

**症状:** "SQLSTATE[HY000] [1045] Access denied for user 'ptero'@'localhost' (using password: NO)"

**原因:** .envファイルのDB_PASSWORDが正しく読み込まれていない

**対処法:**

```bash
# .env のDB_PASSWORDを確認
grep "DB_PASSWORD" /var/www/pterodactyl/.env

# パスワードに特殊文字（#, $, !, @など）が含まれる場合は引用符で囲む
# 悪い例: DB_PASSWORD=#ehLqrZECk2w2GL$5iLV
# 良い例: DB_PASSWORD="#ehLqrZECk2w2GL$5iLV"

# 自動修正（パスワードを実際の値に置き換えてください）
sed -i 's/^DB_PASSWORD=.*$/DB_PASSWORD="#ehLqrZECk2w2GL$5iLV"/' /var/www/pterodactyl/.env

# 設定キャッシュをクリア
php artisan config:clear

# データベース接続テスト
php artisan migrate:status
# ↑ マイグレーション一覧が表示されれば接続成功
```

### 4. Composer Install エラー

**症状:** `composer install` 実行時に拡張モジュールエラー

```
Could not save Pterodactyl\Models\User[]:
failed to validate data: ext-pdo_mysql * is missing from your system
```

**原因:** PHP拡張がインストールされていない、または異なるPHPバージョンが使用されている

**対処法:**

```bash
# 使用されているPHPバージョンを確認
php -v
# ↑ PHP 8.4 が表示される場合、PHP 8.2 用の拡張が使われていない可能性

# PHP 8.4 用の拡張をインストール（composer が PHP 8.4 を使用している場合）
sudo apt install -y php8.4-mysql php8.4-xml php8.4-bcmath php8.4-mbstring

# または、PHP 8.2 用の拡張をインストール
sudo apt install -y php8.2-mysql php8.2-xml php8.2-bcmath php8.2-mbstring

# PHP-FPM を再起動
sudo systemctl restart php8.2-fpm

# 再度 composer install を実行
cd /var/www/pterodactyl
composer install --no-dev --optimize-autoloader

# インストールされた拡張を確認
php -m | grep -E 'pdo_mysql|mbstring|bcmath|dom|simplexml'
```

### 5. Cloudflare Tunnel 502 Error

**症状:** Cloudflare の "502 Bad Gateway" エラー

**原因と対処法:**

```bash
# cloudflared サービスの状態確認
sudo systemctl status cloudflared
# ↑ "active (running)" でない場合、起動していません

# トンネル接続を確認
sudo journalctl -u cloudflared -n 100
# ↑ "Registered tunnel connection" が表示されているか確認

# config.yml の確認
cat /etc/cloudflared/config.yml
# ↑ インデントが正しいか、credentials-file のパスが正しいか確認

# Nginx がローカルでリッスンしているか確認
sudo ss -ltnp | grep ':80'
# ↑ "127.0.0.1:80" が表示されない場合、Nginx の設定を確認

# Nginx の設定を確認
sudo nginx -t
sudo systemctl status nginx

# cloudflared を再起動
sudo systemctl restart cloudflared
```

### 6. YAML Syntax Error（config.yml）

**症状:** `cloudflared tunnel ingress validate` でエラー

**エラー例:**

```
yaml: line 6: mapping values are not allowed in this context
```

**対処法:**

正しいインデント（スペース）を使用してください:

```yaml
# 正しい例
tunnel: panel-cloudru
credentials-file: /root/.cloudflared/515d3a99-e74c-4312-a85c-feab39c95128.json
ingress:
  - hostname: panel.cloudru.jp
    service: http://127.0.0.1:80
  - service: http_status:404
```

注意点:

- `- hostname:` は 2 スペースのインデント
- `service:` は 4 スペース追加（合計 6 スペース）
- タブ文字は使用しない（スペースのみ）

### 7. ユーザー作成エラー

**症状:** `php artisan p:user:make` でユーザー作成できない

```
The email has already been taken.
The username has already been taken.
```

**対処法:**

```bash
# 既存のユーザーを確認
mysql -u ptero -p pterodactyl -e "SELECT id, username, email, root_admin FROM users;"

# 既存ユーザーのパスワードをリセット
php artisan tinker
# Tinker 内で:
$user = \Pterodactyl\Models\User::find(1);
$user->password = bcrypt('NewPassword123');
$user->save();
exit

# または、既存ユーザーを削除
php artisan p:user:delete --user=1
# その後、新規作成
php artisan p:user:make
```

### 8. Queue Worker が動作しない

**症状:** サーバーの起動/停止操作が実行されない

**対処法:**

```bash
# pteroq サービスの状態確認
sudo systemctl status pteroq

# ログを確認
sudo journalctl -u pteroq -n 100

# サービスを再起動
sudo systemctl restart pteroq

# Redis が起動しているか確認
sudo systemctl status redis-server

# キューにジョブが残っているか確認
redis-cli
> LLEN queues:high
> LLEN queues:standard
> exit
```

### 9. 403 Forbidden エラー

**症状:** 特定のページで "403 Forbidden" エラー

**対処法:**

```bash
# ファイルパーミッションを確認
ls -la /var/www/pterodactyl/

# 修正
sudo chown -R www-data:www-data /var/www/pterodactyl
sudo chmod -R 755 /var/www/pterodactyl
sudo chmod -R 775 /var/www/pterodactyl/storage /var/www/pterodactyl/bootstrap/cache

# Nginx の設定を確認
sudo nginx -t
```

### 10. デバッグモードの有効化

問題の詳細を確認する場合、一時的にデバッグモードを有効にできます:

```bash
# .env を編集
nano /var/www/pterodactyl/.env

# 以下を変更:
APP_DEBUG=true

# キャッシュをクリア
php artisan config:clear

# ブラウザでエラーを再現 → 詳細なエラー情報が表示されます

# ★重要★ 問題解決後は必ず false に戻してください（セキュリティリスク）
APP_DEBUG=false
php artisan config:clear
```

---

## 補足

### プラットフォームサポート

- **推奨OS**: Ubuntu 22.04 LTS（本手順書のベース）
- **対応OS**: Ubuntu 20.04+, Debian 11+, CentOS Stream 9+, Rocky Linux 9+
- **非対応**: Windows Server（直接インストール不可）
  - Windows で運用する場合は WSL2 または VMware/Hyper-V で Linux VM を使用してください

### Cloudflare Tunnel の制限事項

**できること:**

- HTTP/HTTPS通信（Panel の Web アクセス）
- WebSocket（Panel の一部機能で使用）

**できないこと:**

- 任意のTCP/UDPポート（ゲームサーバー用ポート）
- ICMP（Ping）
- 双方向UDP通信

**結論:**

- **Panel**: Cloudflare Tunnel で公開可能
- **Wings（ゲームノード）**: グローバルIP + ポート開放が必須

### パフォーマンスチューニング

本番環境で多数のサーバーを運用する場合のチューニング:

#### 1. PHP-FPM の最適化

```bash
# PHP-FPM プール設定を編集
sudo nano /etc/php/8.2/fpm/pool.d/www.conf

# 以下を最適化（サーバースペックに応じて調整）:
pm = dynamic
pm.max_children = 50
pm.start_servers = 5
pm.min_spare_servers = 5
pm.max_spare_servers = 35
pm.max_requests = 500

# PHP-FPM を再起動
sudo systemctl restart php8.2-fpm
```

#### 2. Redis の最適化

```bash
# Redis 設定を編集
sudo nano /etc/redis/redis.conf

# メモリ上限を設定（例: 1GB）
maxmemory 1gb
maxmemory-policy allkeys-lru

# Redis を再起動
sudo systemctl restart redis-server
```

#### 3. MariaDB の最適化

```bash
# MariaDB 設定を編集
sudo nano /etc/mysql/mariadb.conf.d/50-server.cnf

# [mysqld] セクションに追加:
innodb_buffer_pool_size = 2G        # サーバーメモリの50-70%
innodb_log_file_size = 512M
max_connections = 200
query_cache_size = 0                # クエリキャッシュは無効推奨
query_cache_type = 0

# MariaDB を再起動
sudo systemctl restart mariadb
```

### アップグレード手順

Pterodactyl Panel を新しいバージョンにアップグレードする場合:

```bash
# バックアップを取得
sudo /usr/local/bin/pterodactyl-backup.sh

# メンテナンスモードを有効化
cd /var/www/pterodactyl
php artisan down

# 最新版をダウンロード
curl -L https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz | tar -xz

# 依存パッケージを更新
composer install --no-dev --optimize-autoloader

# データベースをマイグレーション
php artisan migrate --seed --force

# キャッシュとビューをクリア
php artisan config:clear
php artisan cache:clear
php artisan view:clear

# メンテナンスモードを解除
php artisan up

# Queue Worker を再起動
sudo systemctl restart pteroq
```

### よく使うコマンド一覧

```bash
# サービスの再起動
sudo systemctl restart nginx
sudo systemctl restart php8.2-fpm
sudo systemctl restart mariadb
sudo systemctl restart redis-server
sudo systemctl restart pteroq
sudo systemctl restart cloudflared

# ログの確認
sudo tail -f /var/log/nginx/error.log
sudo tail -f /var/www/pterodactyl/storage/logs/laravel-*.log
sudo journalctl -u pteroq -f
sudo journalctl -u cloudflared -f

# キャッシュクリア
cd /var/www/pterodactyl
php artisan config:clear
php artisan cache:clear
php artisan view:clear
php artisan route:clear

# ユーザー管理
php artisan p:user:make                          # 新規ユーザー作成
php artisan p:user:delete --user=1               # ユーザー削除
php artisan p:user:disable2fa --email=user@example.com  # 2FA無効化

# データベース管理
php artisan migrate:status                       # マイグレーション状態
php artisan db:seed --force                      # シーダー実行
mysql -u ptero -p pterodactyl                    # データベース接続

# パーミッション修正
sudo chown -R www-data:www-data /var/www/pterodactyl
sudo chmod -R 755 /var/www/pterodactyl
sudo chmod -R 775 /var/www/pterodactyl/storage /var/www/pterodactyl/bootstrap/cache
```

### 公式リソース

- **公式ドキュメント**: https://pterodactyl.io/project/introduction.html
- **GitHub リポジトリ**:
  - Panel: https://github.com/pterodactyl/panel
  - Wings: https://github.com/pterodactyl/wings
- **コミュニティ Discord**: https://discord.gg/pterodactyl
- **GitHub Discussions**: https://github.com/pterodactyl/panel/discussions

### サポートとトラブルシューティング

問題が発生した場合:

1. **本README のトラブルシューティングセクションを確認**
2. **ログファイルを確認**（Laravel, Nginx, systemd）
3. **公式ドキュメントを参照**
4. **GitHub Discussions で検索**（既知の問題かどうか）
5. **Discord コミュニティで質問**（英語推奨）

質問する際は以下の情報を含めてください:

- OS とバージョン（`lsb_release -a`）
- PHP バージョン（`php -v`）
- Pterodactyl バージョン（`php artisan --version`）
- エラーメッセージ全文
- 関連するログファイルの内容

### ライセンスと著作権

- Pterodactyl Panel は MIT ライセンスで提供されています
- 商用利用可能、無料
- 本手順書は学習・構築目的で作成されたものです

---

**最終更新**: 2026年2月8日  
**バージョン**: v2.0（詳細版）  
**対象OS**: Ubuntu 22.04 LTS  
**Pterodactyl**: v1.11+
# pterodactyl-cloudflare-tunnel-setup
