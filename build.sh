#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
xcodegen generate
xcodebuild -scheme HogHunter -configuration Release -derivedDataPath build
echo "Built: $(pwd)/build/Build/Products/Release/HogHunter.app"
echo "To sign and install to ~/Applications instead, use scripts/install.sh."
