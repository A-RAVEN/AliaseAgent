#!/usr/bin/env bash
set -euo pipefail

echo "========================================================"
echo "  SearXNG Setup — AliasAgent"
echo "========================================================"
echo ""

# Check prerequisites
echo "[1/5] Checking prerequisites..."

if ! command -v python3 &>/dev/null; then
    echo "ERROR: Python 3.7+ is required but not found in PATH."
    echo "Install Python from https://www.python.org/downloads/"
    exit 1
fi

python3 -c "import sys; sys.exit(0 if sys.version_info >= (3,7) else 1)" || {
    echo "ERROR: Python 3.7+ is required. Detected version is older."
    exit 1
}
echo "  Python OK"

if ! command -v git &>/dev/null; then
    echo "ERROR: git is required but not found in PATH."
    exit 1
fi
echo "  git OK"

# Clone SearXNG
echo ""
echo "[2/5] Cloning SearXNG (depth=1)..."
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SEARXNG_DIR="$SCRIPT_DIR/../tools/searxng"

if [ -d "$SEARXNG_DIR" ]; then
    echo "  SearXNG directory already exists, skipping clone"
else
    git clone --depth 1 https://github.com/searxng/searxng.git "$SEARXNG_DIR" || {
        echo "ERROR: Failed to clone SearXNG."
        echo "Try setting proxy: git config --global http.proxy http://127.0.0.1:7890"
        exit 1
    }
    echo "  Clone complete"
fi

# Create virtual environment
echo ""
echo "[3/5] Setting up Python virtual environment..."

cd "$SEARXNG_DIR"

if [ ! -d "venv" ]; then
    python3 -m venv venv || {
        echo "ERROR: Failed to create virtual environment."
        exit 1
    }
fi

source venv/bin/activate

# Install prerequisites
echo ""
echo "[4/5] Installing dependencies..."

pip install pyyaml msgspec typing-extensions pybind11 tomli tzdata || {
    echo "WARNING: Some pip packages may have failed."
    echo "Try: pip install --proxy http://127.0.0.1:7890 <package>"
}

pip install -e . || {
    echo "WARNING: pip install -e . failed."
    echo "Try: pip install --proxy http://127.0.0.1:7890 -e ."
}

# Generate settings.yml
echo ""
echo "[5/5] Generating settings.yml..."

python3 -c "
import yaml, secrets, os
settings = {
    'use_default_settings': True,
    'server': {
        'port': 8888,
        'bind_address': '127.0.0.1',
        'secret_key': secrets.token_hex(32),
    },
    'search': {
        'formats': ['html', 'json'],
    },
    'engines': [
        {
            'name': 'bing',
            'engine': 'bing',
            'base_url': 'https://cn.bing.com',
            'disabled': False,
        },
    ],
    'valkey': {
        'url': False,
    },
}
os.makedirs(os.path.dirname('$SEARXNG_DIR/searx/settings.yml'), exist_ok=True)
with open('$SEARXNG_DIR/searx/settings.yml', 'w') as f:
    yaml.dump(settings, f, default_flow_style=False)
print('  settings.yml generated')
"

echo ""
echo "========================================================"
echo "  SearXNG setup complete!"
echo ""
echo "  Start SearXNG:"
echo "    cd tools/searxng"
echo "    source venv/bin/activate"
echo "    python -m searx.webapp"
echo ""
echo "  Then access: http://localhost:8888"
echo "  Search JSON API: http://localhost:8888/search?q=test&format=json"
echo ""
echo "  Stop: Ctrl+C"
echo "  Update: cd tools/searxng && git pull"
echo "========================================================"
