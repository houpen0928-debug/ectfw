#!/bin/bash
# VM 端部署（幂等）：解包 → 迁移/生成 .env 与证书 → compose up → health check
set -e
rm -rf ~/appnew && mkdir -p ~/appnew
tar xzf /tmp/app.tar.gz -C ~/appnew
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
    -subj "/CN=twect.com.tw" 2>/dev/null
  echo "generated fresh .env & self-signed cert"
fi

echo "=== 2. replace ~/app with ~/appnew (keep compose project dir stable) ==="
rm -rf ~/appold
mv ~/app ~/appold 2>/dev/null || true
mv ~/appnew ~/app
cd ~/app

echo "=== 3. compose up ==="
docker compose up -d --build

echo "=== 4. wait and verify ==="
sleep 20
docker compose ps
echo "--- health via local 443 ---"
curl -sk https://127.0.0.1/health || echo "443 health FAIL"
echo
echo "VM_DEPLOY_DONE"
