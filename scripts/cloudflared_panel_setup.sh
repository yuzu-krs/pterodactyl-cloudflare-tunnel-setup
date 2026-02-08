#!/usr/bin/env bash
set -euo pipefail

# Cloudflare Tunnel で panel.cloudru.jp をローカルVM上の Nginx(127.0.0.1:80)へルーティングするセットアップ
# 実行対象: Ubuntu 22.04 LTS（VM内）
# 事前に Cloudflare ログイン可能なブラウザがあること（login時に認証用URLが表示されます）

TUNNEL_NAME="panel-cloudru"
HOSTNAME="panel.cloudru.jp"
LOCAL_SERVICE="http://127.0.0.1:80"
CRED_DIR="/root/.cloudflared"

# cloudflared のインストール
if ! command -v cloudflared >/dev/null 2>&1; then
  echo "Installing cloudflared..."
  curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb -o /tmp/cloudflared.deb
  sudo dpkg -i /tmp/cloudflared.deb || sudo apt install -y /tmp/cloudflared.deb || true
fi

# Cloudflare 認証（ブラウザで認証が必要です）
cloudflared tunnel login

# トンネル作成（既存ならスキップ可）
if ! cloudflared tunnel list | awk '{print $2}' | grep -Fxq "$TUNNEL_NAME"; then
  echo "Creating tunnel: $TUNNEL_NAME"
  cloudflared tunnel create "$TUNNEL_NAME"
else
  echo "Tunnel $TUNNEL_NAME already exists."
fi

# トンネルUUID取得
UUID=$(cloudflared tunnel list | awk -v name="$TUNNEL_NAME" '$0 ~ name {print $1}' | head -n1)
if [[ -z "$UUID" ]]; then
  echo "Failed to get tunnel UUID for $TUNNEL_NAME" >&2
  exit 1
fi

# 設定ファイル作成
sudo tee /etc/cloudflared/config.yml >/dev/null <<EOF
tunnel: $TUNNEL_NAME
credentials-file: $CRED_DIR/$UUID.json
ingress:
  - hostname: $HOSTNAME
    service: $LOCAL_SERVICE
  - service: http_status:404
EOF

# DNS を tunnel にルーティング
cloudflared tunnel route dns "$TUNNEL_NAME" "$HOSTNAME"

# サービス常駐化
sudo cloudflared service install
sudo systemctl enable --now cloudflared

# 状態表示
systemctl status cloudflared --no-pager || true

cat <<INFO
\nCloudflare Tunnel setup complete.\n- Hostname: $HOSTNAME\n- Local service: $LOCAL_SERVICE\n\n次の対応を忘れずに:\n1) Nginx サイト設定を 127.0.0.1:80 受けに変更\n2) Panel が /var/www/pterodactyl/public を正しく公開しているか確認\n3) ブラウザで https://$HOSTNAME にアクセスして動作確認\nINFO
