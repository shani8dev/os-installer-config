#!/usr/bin/env bash
set -euo pipefail

CONFIG_DIR="/etc/shani/os-installer"
SCRIPT_DIR="/home/shrinivaskumbhar/Documents/shani/os-installer-config/scripts"

ERRORS=0

echo "=== OS Installer Config Validation ==="

# Check config directory exists
if [[ ! -d "$CONFIG_DIR" ]]; then
    echo "ERROR: Config directory not found: $CONFIG_DIR" >&2
    ERRORS=$((ERRORS + 1))
fi

# Check required config files
for config_file in config.yaml configure.sh install.sh prepare.sh; do
    if [[ ! -f "$CONFIG_DIR/$config_file" ]]; then
        echo "WARNING: Missing config file: $CONFIG_DIR/$config_file"
    fi
done

# Validate scripts exist and are executable
for script in configure.sh install.sh prepare.sh; do
    if [[ -f "$SCRIPT_DIR/$script" ]]; then
        if [[ ! -x "$SCRIPT_DIR/$script" ]]; then
            echo "ERROR: Script not executable: $SCRIPT_DIR/$script" >&2
            ERRORS=$((ERRORS + 1))
        fi
    fi
done

# Check for required fields in config.yaml if it exists
if [[ -f "$CONFIG_DIR/config.yaml" ]]; then
    if ! grep -q "version" "$CONFIG_DIR/config.yaml" 2>/dev/null; then
        echo "WARNING: config.yaml missing 'version' field"
    fi
    if ! grep -q "base" "$CONFIG_DIR/config.yaml" 2>/dev/null; then
        echo "WARNING: config.yaml missing 'base' field"
    fi
fi

if [[ $ERRORS -eq 0 ]]; then
    echo "Config validation passed"
    exit 0
else
    echo "Config validation failed with $ERRORS error(s)" >&2
    exit 1
fi
