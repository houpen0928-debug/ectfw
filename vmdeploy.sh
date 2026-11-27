#!/bin/bash
# VM 端部署（幂等）：解包 → .env/证书 → compose up（容器自动 migrate）→ 红线自检
# 2026-11-27 批次①：改从 ~/ectfw 中转 repo 读 tar；新增 C.15 唯读红线自检
# 在 VM 上执行：bash ~/ectfw/vmdeploy.sh
set -e
TAR="$HOME/ectfw/ect-tw-main.tar.gz"
[ -f "$TAR" ] || { echo "MISSING $TAR"; exit 1; }
rm -rf ~/appnew && mkdir -p ~/appnew
tar xzf "$TAR" -C ~/appnew
cd ~/appnew

echo "=== 1. env & certs (migrate from ~/app if present, else generate) ==="
if [ -f ~/app/.env ]; then
  cp ~/app/.env .env
  mkdir -p deploy/certs
  cp ~/app/deploy/certs/origin.pem ~/app/deploy/certs/origin.key deploy/certs/ 2>/dev/null || true
  echo "migrated existing .env & certs"
else
  cp .env.example .env
  sed -i "s/^ECT_NODE_ENV=.*/ECT_NODE_ENV=production/" .env
  sed -i "s/^ECT_SESSION_SECRET=.*/ECT_SESSION_SECRET=$(openssl rand -hex 32)/" .env
  sed -i "s/^ECT_ADMIN_TOKEN=.*/ECT_ADMIN_TOKEN=$(openssl rand -hex 24)/" .env
  sed -i "s/^ECT_PG_PASSWORD=.*/ECT_PG_PASSWORD=$(openssl rand -hex 16)/" .env
  sed -i "s/^ECT_EDGE_PORT=.*/ECT_EDGE_PORT=80/" .env
  sed -i "s/^ECT_TLS_PORT=.*/ECT_TLS_PORT=443/" .env
  sed -i "s/^NGINX_CONF=.*/NGINX_CONF=ssl/" .env
  sed -i "s/^# ECT_DYNAMIC_CODE_SECRET=.*/ECT_DYNAMIC_CODE_SECRET=$(openssl rand -hex 24)/" .env
  grep -q "^ECT_DYNAMIC_CODE_SECRET=" .env || echo "ECT_DYNAMIC_CODE_SECRET=$(openssl rand -hex 24)" >> .env
  openssl req -x509 -nodes -newkey rsa:2048 -days 365 \
    -keyout deploy/certs/origin.key -out deploy/certs/origin.pem \
    -subj "/CN=api.twect.com.tw" 2>/dev/null
  echo "generated fresh .env & self-signed cert"
fi

echo "=== 1b. 批次②階段1：冪等寫入 LINE 非敏感設定（secret 不進 public repo） ==="
set_env() {
  key="$1"; val="$2"
  if grep -q "^${key}=" .env; then
    sed -i "s|^${key}=.*|${key}=${val}|" .env
  else
    echo "${key}=${val}" >> .env
  fi
}
set_env LINE_CHANNEL_ID 2012825728
set_env ECT_LIFF_ID 2012825728-EXJZKzCC
set_env LINE_REDIRECT_URI https://api.twect.com.tw/api/auth/line/callback
set_env ECT_LIFF_ORIGIN https://www.twect.com.tw
set_env ECT_LINE_LANDING_URL https://www.twect.com.tw/liff/
set_env ECT_SESSION_TTL_MS 604800000
set_env ECT_ALLOW_DEV_HEADER 0
# 🔴 LINE_CHANNEL_SECRET 唯一來源：VM 本機 ~/.ect-line-secret（不進版控、不進中轉 repo）
# 未帶入時保持空白 → /api/auth/line/* 503 fail-closed；帶入後由 set_env 冪等寫入。
if [ -f "$HOME/.ect-line-secret" ]; then
  SEC=$(tr -d '\r\n' < "$HOME/.ect-line-secret")
  if [ -n "$SEC" ]; then set_env LINE_CHANNEL_SECRET "$SEC"; echo "line secret injected from VM-local file"; fi
else
  grep -q '^LINE_CHANNEL_SECRET=' .env || echo 'LINE_CHANNEL_SECRET=' >> .env
  echo "line secret NOT set -> /api/auth/line/* stays 503 (fail-closed)"
fi

echo "=== 2. replace ~/app with ~/appnew (keep compose project dir stable) ==="
rm -rf ~/appold
mv ~/app ~/appold 2>/dev/null || true
mv ~/appnew ~/app
cd ~/app

echo "=== 3. compose up (container auto-runs db/migrate.js before server) ==="
# docker 權限 fallback：GCP VM 用戶預設不在 docker 群 → permission denied 時退回 sudo
if docker ps >/dev/null 2>&1; then
  DOCKER="docker"
else
  DOCKER="sudo docker"
  echo "docker permission denied -> fallback to sudo docker"
fi
$DOCKER compose up -d --build

echo "=== 4. wait and verify ==="
sleep 25
$DOCKER compose ps
echo "--- read-only health via local 443 ---"
curl -sk --max-time 10 https://127.0.0.1/health || echo "health FAIL"
echo
curl -sk --max-time 10 https://127.0.0.1/health/db || echo "health/db FAIL"
echo
echo "--- C.15/C.21 red-line self-check: write/admin endpoints MUST be 404 ---"
echo "transfer create: $(curl -sk -o /dev/null -w '%{http_code}' -X POST --max-time 10 https://127.0.0.1/api/transfer/create)"
echo "admin static:    $(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 https://127.0.0.1/admin)"
echo "verify static:   $(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 https://127.0.0.1/verify)"
echo "public esg:      $(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 https://127.0.0.1/api/public/esg)"
echo "--- C.21 階段1 白名單自檢 ---"
echo "auth start:      $(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 https://127.0.0.1/api/auth/line/start)   (302=secret 已帶入／503=fail-closed)"
echo "auth me no-cookie: $(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 https://127.0.0.1/api/auth/me)   (須 401)"
echo "VM_DEPLOY_DONE"
