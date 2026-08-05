#!/bin/bash
set -e

echo "=== Step 1: Enable Hermes Agent's API server ==="
# These use Hermes's own config-mutation commands instead of hand-editing
# YAML directly -- avoids the save/validation issues we hit earlier today.
API_KEY=$(openssl rand -hex 24)

hermes config set API_SERVER_ENABLED true
hermes config set API_SERVER_KEY "$API_KEY"

echo "Generated API_SERVER_KEY: $API_KEY"
echo "$API_KEY" > ~/.hermes-api-key.txt
chmod 600 ~/.hermes-api-key.txt
echo "(saved to ~/.hermes-api-key.txt for reference -- keep this private)"

echo "=== Step 2: Set up Hermes gateway as a persistent systemd service ==="
# Same pattern proven working today: real username, not the %i template bug.
HERMES_BIN=$(which hermes)

sudo tee /etc/systemd/system/hermes-gateway.service > /dev/null << EOF
[Unit]
Description=Hermes Agent API Gateway
After=network-online.target

[Service]
Type=simple
User=dano
ExecStart=${HERMES_BIN} gateway
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable hermes-gateway
sudo systemctl restart hermes-gateway

echo "=== Step 3: Verify the gateway is actually listening ==="
sleep 2
sudo systemctl status hermes-gateway --no-pager
ss -tlnp | grep 8642 || echo "WARNING: nothing listening on 8642 yet -- check 'journalctl -u hermes-gateway -f'"

echo "=== Step 4: Install Docker if not already present ==="
if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com | sh
    sudo usermod -aG docker "$USER"
    echo "Docker installed. You may need to log out/in for group membership to apply."
fi

echo "=== Step 5: Write docker-compose.yml for Open WebUI ==="
mkdir -p ~/openwebui
cat > ~/openwebui/docker-compose.yml << EOF
services:
  open-webui:
    image: ghcr.io/open-webui/open-webui:main
    ports:
      - "3000:8080"
    volumes:
      - open-webui:/app/backend/data
    environment:
      - OPENAI_API_BASE_URL=http://host.docker.internal:8642/v1
      - OPENAI_API_KEY=${API_KEY}
      - ENABLE_OLLAMA_API=false
    extra_hosts:
      - "host.docker.internal:host-gateway"
    restart: always

volumes:
  open-webui:
EOF

echo "=== Step 6: Launch Open WebUI ==="
cd ~/openwebui
sudo docker compose up -d

echo ""
echo "=== Done ==="
echo "Open http://<this-machine-IP>:3000 in a browser and create your admin account."
echo "The 'hermes-agent' model should appear in the model dropdown once logged in."
echo "API key (also saved to ~/.hermes-api-key.txt): $API_KEY"
