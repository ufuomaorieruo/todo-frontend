#!/bin/bash
# =============================================================================
# Frontend VM Provisioning Script — Next.js + PM2 + Nginx
# Run once as root (or with sudo) on a fresh GCP Ubuntu VM
# Usage: sudo bash provision-frontend.sh
#
# Uses your existing VM login user as the single app/deploy user.
# =============================================================================

set -euo pipefail

# Prevent apt/dpkg from hanging on interactive prompts (e.g. needrestart,
# google-cloud-cli postinst) during unattended provisioning
export DEBIAN_FRONTEND=noninteractive

# ---------- Config — edit these before running ----------
APP_USER="xahavi"   # <-- your VM login username
APP_DIR="/var/www/frontend"
REPO_URL="https://github.com/VictorOjedokun/todo-frontend.git"
REPO_BRANCH="master"
APP_PORT=3001
NGINX_SERVER_NAME="34.35.16.106"   # or VM public IP
BACKEND_API_URL="http://34.35.151.43"
NODE_VERSION="20"
# --------------------------------------------------------

echo "==> [1/7] System update"

# google-cloud-cli's postinst script is known to hang indefinitely on GCP
# images during unattended apt runs (no TTY, tries to configure shell
# completions / phone home). It's not needed for this deployment.
# Purge it, hold it (blocks reinstall even if pulled in as a dependency),
# and disable the Google Cloud apt repo so it can't come back at all.
echo "==> Disabling Google Cloud apt repo to prevent google-cloud-cli reinstall"
if [ -f /etc/apt/sources.list.d/google-cloud-sdk.list ]; then
  mv /etc/apt/sources.list.d/google-cloud-sdk.list /etc/apt/sources.list.d/google-cloud-sdk.list.disabled
fi
find /etc/apt/sources.list.d/ -iname "*google*" -exec sh -c 'mv "$1" "$1.disabled"' _ {} \; 2>/dev/null || true

if dpkg -l | grep -q google-cloud-cli; then
  echo "==> Removing google-cloud-cli (known to hang apt postinst on GCP images)"
  apt-get remove --purge -y google-cloud-cli google-cloud-cli-anthoscli 2>/dev/null || true
fi
# Hold unconditionally so apt refuses to reinstall it even as a dependency
apt-mark hold google-cloud-cli google-cloud-cli-anthoscli 2>/dev/null || true

apt-get update -y
apt-get -o Dpkg::Options::="--force-confold" upgrade -y \
  --no-install-recommends \
  -o APT::Get::Always-Include-Phased-Updates=false
apt-get install -y git curl build-essential nginx ufw

echo "==> [2/7] Install Node.js $NODE_VERSION via NodeSource"
curl -fsSL https://deb.nodesource.com/setup_${NODE_VERSION}.x | bash -
apt-get install -y nodejs
node -v && npm -v

echo "==> [3/7] Install PM2 globally"
npm install -g pm2

echo "==> [4/7] Ensure app user exists (it already does — this is your VM login user)"
if ! id "$APP_USER" &>/dev/null; then
  useradd -m -s /bin/bash "$APP_USER"
fi

echo "$APP_USER ALL=(ALL) NOPASSWD: /usr/bin/pm2, /usr/bin/npm" > /etc/sudoers.d/app-deploy
chmod 0440 /etc/sudoers.d/app-deploy

echo "==> [5/7] Clone repo, install deps, and build"
mkdir -p "$APP_DIR"
chown "$APP_USER":"$APP_USER" "$APP_DIR"

sudo -u "$APP_USER" git clone --branch "$REPO_BRANCH" "$REPO_URL" "$APP_DIR"
cd "$APP_DIR"

# Write .env.production with backend URL
cat > "$APP_DIR/.env.production" <<EOF
NEXT_PUBLIC_API_URL=$BACKEND_API_URL
EOF
chown "$APP_USER":"$APP_USER" "$APP_DIR/.env.production"

sudo -u "$APP_USER" npm ci
sudo -u "$APP_USER" npm run build

echo "==> [6/7] Configure PM2 and start app"
cat > "$APP_DIR/ecosystem.config.js" <<EOF
module.exports = {
  apps: [{
    name: 'frontend',
    script: 'node_modules/.bin/next',
    args: 'start',
    cwd: '$APP_DIR',
    instances: 1,
    autorestart: true,
    watch: false,
    env: {
      NODE_ENV: 'production',
      PORT: $APP_PORT,
    }
  }]
};
EOF

chown "$APP_USER":"$APP_USER" "$APP_DIR/ecosystem.config.js"
sudo -u "$APP_USER" pm2 start "$APP_DIR/ecosystem.config.js"
sudo -u "$APP_USER" pm2 save

env PATH=$PATH:/usr/bin pm2 startup systemd -u "$APP_USER" --hp /home/"$APP_USER"
systemctl enable pm2-"$APP_USER"

echo "==> [7/7] Configure Nginx reverse proxy"
cat > /etc/nginx/sites-available/frontend <<EOF
server {
    listen 80;
    server_name $NGINX_SERVER_NAME;

    # Serve Next.js app
    location / {
        proxy_pass http://127.0.0.1:$APP_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_cache_bypass \$http_upgrade;
    }

    # Cache static Next.js assets aggressively
    location /_next/static/ {
        proxy_pass http://127.0.0.1:$APP_PORT;
        proxy_cache_valid 200 1y;
        add_header Cache-Control "public, max-age=31536000, immutable";
    }
}
EOF

ln -sf /etc/nginx/sites-available/frontend /etc/nginx/sites-enabled/frontend
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx

echo "==> Configuring UFW firewall"
ufw allow OpenSSH
ufw allow 'Nginx HTTP'
ufw --force enable

echo ""
echo "✅ Frontend VM provisioned successfully!"
echo "   App running on: http://$NGINX_SERVER_NAME"
echo "   PM2 status: pm2 list"
echo ""
echo "📌 Next steps:"
echo "   1. Add the GitHub Actions deploy public key to /home/$APP_USER/.ssh/authorized_keys"
echo "      (it likely already has one from VM creation — you can add a second line)"
echo "   2. Verify NEXT_PUBLIC_API_URL in $APP_DIR/.env.production"