# ollama-hermes-quickstart
A repo for quick start setup of the Ollama AI model and Hermes AI agent harness.

This setup assumes both `ollama` and `hermes` are running on the same machine and installs them all together.

## Overrides
You can override the defaults before running the script by setting some environment variables:
```
export OLLAMA_MODEL="qwen3.5:9b"
export CONTEXT_LENGTH="65536"
export DASHBOARD_HOST="0.0.0.0"
export DASHBOARD_PORT="9119"
export DASHBOARD_USERNAME="admin"

./install_ollama_hermes_dashboard.sh
```

## Unattended setup
The key to the unattended setup is setting the dashboard password before running the script.
```
read -s -p "Dashboard password: " HERMES_DASHBOARD_PASSWORD
echo
export HERMES_DASHBOARD_PASSWORD

./install_ollama_hermes_dashboard.sh

unset HERMES_DASHBOARD_PASSWORD
```

## Redeployment
To rebuild the Hermes Python environment completely:
```
RECREATE_HERMES_VENV=1 ./install_ollama_hermes_dashboard.sh
```

To avoid updating an existing Ollama installation:
```
UPDATE_OLLAMA=0 ./install_ollama_hermes_dashboard.sh
```
