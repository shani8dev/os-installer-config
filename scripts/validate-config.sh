#!/usr/bin/env bash
set -euo pipefail

# validate-config.sh — Validate os-installer configuration files.
#
# Validates YAML/JSON configuration for the os-installer framework:
#   - Checks /etc/shani/os-installer/config for required fields
#   - Validates that all referenced scripts exist and are executable
#   - Checks for syntax errors in configuration files
#
# Usage: validate-config.sh [CONFIG_DIR]
#   CONFIG_DIR  Path to config directory (default: /etc/shani/os-installer/config)
#
# Exit codes:
#   0   Configuration is valid
#   1   Configuration errors found
#   2   Configuration directory not found

CONFIG_DIR="${1:-/etc/shani/os-installer/config}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

ERRORS=0
WARNINGS=0
declare -a ERROR_MESSAGES=()
declare -a WARNING_MESSAGES=()

echo "=== OS Installer Config Validation ==="
echo "Config directory: ${CONFIG_DIR}"
echo "Script directory: ${SCRIPT_DIR}"
echo ""

# --- Check config directory exists ---
if [[ ! -d "$CONFIG_DIR" ]]; then
    echo "ERROR: Config directory not found: ${CONFIG_DIR}" >&2
    echo "HINT: Create it or set CONFIG_DIR to the correct path." >&2
    exit 2
fi

# --- Check required config files exist ---
echo "--- Checking required config files ---"
# os-installer reads config.yaml (the framework's YAML format). config.json
# was an artifact of an earlier validator draft — the repo ships YAML only.
REQUIRED_FILES=("config.yaml")
found_config=false

for config_file in "${REQUIRED_FILES[@]}"; do
    if [[ -f "${CONFIG_DIR}/${config_file}" ]]; then
        echo "  Found: ${config_file}"
        found_config=true
    fi
done

if [[ "$found_config" == "false" ]]; then
    echo "ERROR: No config file found (expected config.yaml)" >&2
    ERROR_MESSAGES+=("No config file found in ${CONFIG_DIR}")
    ERRORS=$((ERRORS + 1))
fi

# --- Validate YAML config ---
YAML_CONFIG=""
if [[ -f "${CONFIG_DIR}/config.yaml" ]]; then
    YAML_CONFIG="${CONFIG_DIR}/config.yaml"
elif [[ -f "${REPO_DIR}/config.yaml" ]]; then
    YAML_CONFIG="${REPO_DIR}/config.yaml"
fi

if [[ -n "$YAML_CONFIG" ]]; then
    echo ""
    echo "--- Validating YAML syntax: ${YAML_CONFIG} ---"

    # Use python3 with yaml.SafeLoader for syntax validation
    if command -v python3 &>/dev/null; then
        YAML_ERRORS="$(python3 -c "
import yaml
import sys
try:
    with open('${YAML_CONFIG}', 'r') as f:
        data = yaml.safe_load(f)
    if data is None:
        print('ERROR: YAML file is empty')
        sys.exit(1)
    elif not isinstance(data, dict):
        print('ERROR: YAML root must be a mapping (dict), got ' + type(data).__name__)
        sys.exit(1)
except yaml.YAMLError as e:
    print(f'ERROR: YAML syntax error: {e}')
    sys.exit(1)
except FileNotFoundError:
    print('ERROR: File not found')
    sys.exit(1)
" 2>&1)" || true

        if [[ -n "$YAML_ERRORS" ]]; then
            echo "$YAML_ERRORS" >&2
            ERROR_MESSAGES+=("YAML syntax error in ${YAML_CONFIG}")
            ERRORS=$((ERRORS + 1))
        else
            echo "  YAML syntax: OK"
        fi
    else
        echo "  WARNING: python3 not available, skipping YAML syntax check" >&2
        WARNING_MESSAGES+=("python3 not available for YAML validation")
        WARNINGS=$((WARNINGS + 1))
    fi
fi

# --- Validate JSON config ---
JSON_CONFIG=""
if [[ -f "${CONFIG_DIR}/config.json" ]]; then
    JSON_CONFIG="${CONFIG_DIR}/config.json"
elif [[ -f "${REPO_DIR}/config.json" ]]; then
    JSON_CONFIG="${REPO_DIR}/config.json"
fi

if [[ -n "$JSON_CONFIG" ]]; then
    echo ""
    echo "--- Validating JSON syntax: ${JSON_CONFIG} ---"

    if command -v jq &>/dev/null; then
        if ! jq empty "$JSON_CONFIG" 2>/dev/null; then
            echo "  ERROR: Invalid JSON in ${JSON_CONFIG}" >&2
            ERROR_MESSAGES+=("Invalid JSON in ${JSON_CONFIG}")
            ERRORS=$((ERRORS + 1))
        else
            echo "  JSON syntax: OK"
        fi
    else
        echo "  WARNING: jq not available, skipping JSON syntax check" >&2
        WARNING_MESSAGES+=("jq not available for JSON validation")
        WARNINGS=$((WARNINGS + 1))
    fi
fi

# --- Check required fields in config.yaml ---
if [[ -n "$YAML_CONFIG" ]]; then
    echo ""
    echo "--- Checking required fields ---"

    if command -v python3 &>/dev/null; then
        REQUIRED_FIELDS=(
            "distribution_name"
            "scripts.install"
            "scripts.configure"
        )

        for field in "${REQUIRED_FIELDS[@]}"; do
            FIELD_RESULT="$(python3 -c "
import yaml
import sys
with open('${YAML_CONFIG}', 'r') as f:
    data = yaml.safe_load(f)

# Navigate nested fields using dot notation
keys = '${field}'.split('.')
current = data
found = True
for key in keys:
    if isinstance(current, dict) and key in current:
        current = current[key]
    else:
        found = False
        break

if found and current is not None and current != '':
    print('OK')
else:
    print('MISSING')
" 2>&1)" || true

            if [[ "$FIELD_RESULT" == "OK" ]]; then
                echo "  ✓ ${field}"
            else
                echo "  ✗ ${field} — REQUIRED field missing or empty" >&2
                ERROR_MESSAGES+=("Required field '${field}' is missing or empty")
                ERRORS=$((ERRORS + 1))
            fi
        done
    else
        echo "  WARNING: python3 not available, skipping required field checks" >&2
        WARNING_MESSAGES+=("python3 not available for required field checks")
        WARNINGS=$((WARNINGS + 1))
    fi
fi

# --- Warn on unknown top-level keys (typo / stale-section detection) ---
if [[ -n "$YAML_CONFIG" ]]; then
    echo ""
    echo "--- Checking for unknown top-level keys ---"

    if command -v python3 &>/dev/null; then
        UNKNOWN_KEYS="$(python3 -c "
import yaml
with open('${YAML_CONFIG}', 'r') as f:
    data = yaml.safe_load(f) or {}
known = {'distribution_name', 'scripts', 'internet', 'fixed_language',
         'welcome_page', 'disk', 'disk_encryption', 'user',
         'skip_region', 'skip_user', 'failure_help_url', 'commands'}
unknown = [k for k in data if k not in known]
print('\n'.join(unknown))
" 2>/dev/null)" || true

        if [[ -n "$UNKNOWN_KEYS" ]]; then
            while IFS= read -r key; do
                [[ -n "$key" ]] || continue
                echo "  ⚠ unknown top-level key: ${key}" >&2
                WARNING_MESSAGES+=("Unknown top-level key '${key}' in ${YAML_CONFIG}")
                WARNINGS=$((WARNINGS + 1))
            done <<< "$UNKNOWN_KEYS"
        else
            echo "  All top-level keys recognized"
        fi
    else
        echo "  WARNING: python3 not available, skipping unknown-key check" >&2
        WARNING_MESSAGES+=("python3 not available for unknown-key check")
        WARNINGS=$((WARNINGS + 1))
    fi
fi

# --- Validate referenced scripts exist and are executable ---
echo ""
echo "--- Checking referenced scripts ---"

# Scripts referenced in config.yaml's scripts section
SCRIPTS_TO_CHECK=("prepare" "install" "configure")

for script_name in "${SCRIPTS_TO_CHECK[@]}"; do
    # Check in multiple possible locations
    script_path=""
    for candidate in \
        "${CONFIG_DIR}/scripts/${script_name}.sh" \
        "${CONFIG_DIR}/${script_name}.sh" \
        "${REPO_DIR}/scripts/${script_name}.sh" \
        "${SCRIPT_DIR}/${script_name}.sh"; do
        if [[ -f "$candidate" ]]; then
            script_path="$candidate"
            break
        fi
    done

    if [[ -z "$script_path" ]]; then
        echo "  ✗ ${script_name}.sh — NOT FOUND" >&2
        ERROR_MESSAGES+=("Script ${script_name}.sh not found in any expected location")
        ERRORS=$((ERRORS + 1))
    elif [[ ! -x "$script_path" ]]; then
        echo "  ✗ ${script_name}.sh — NOT EXECUTABLE (${script_path})" >&2
        ERROR_MESSAGES+=("Script ${script_name}.sh is not executable: ${script_path}")
        ERRORS=$((ERRORS + 1))
    else
        echo "  ✓ ${script_name}.sh — ${script_path}"
    fi
done

# --- Check for syntax errors in shell scripts ---
echo ""
echo "--- Checking shell script syntax ---"

for script_file in "${SCRIPT_DIR}"/*.sh; do
    [[ -f "$script_file" ]] || continue
    script_basename="$(basename "$script_file")"

    if ! bash -n "$script_file" 2>/dev/null; then
        echo "  ✗ ${script_basename} — SYNTAX ERROR" >&2
        ERROR_MESSAGES+=("Syntax error in ${script_basename}")
        ERRORS=$((ERRORS + 1))
    else
        echo "  ✓ ${script_basename} — syntax OK"
    fi
done

# --- Check for syntax errors in YAML/JSON ---
if [[ -n "$YAML_CONFIG" ]]; then
    echo ""
    echo "--- Checking YAML config for semantic errors ---"

    if command -v python3 &>/dev/null; then
        # Check that scripts referenced in YAML actually point to valid files
        SCRIPT_REFS="$(python3 -c "
import yaml
with open('${YAML_CONFIG}', 'r') as f:
    data = yaml.safe_load(f)
scripts = data.get('scripts', {}) if isinstance(data, dict) else {}
for key, path in scripts.items():
    if isinstance(path, str):
        print(f'{key}={path}')
" 2>/dev/null)" || true

        if [[ -n "$SCRIPT_REFS" ]]; then
            while IFS='=' read -r key path; do
                # Resolve relative paths against config directory
                if [[ "$path" != /* ]]; then
                    resolved="$(dirname "$YAML_CONFIG")/${path}"
                else
                    resolved="$path"
                fi

                if [[ ! -f "$resolved" ]]; then
                    echo "  ⚠ ${key}: referenced script not found: ${resolved}" >&2
                    WARNING_MESSAGES+=("Script ${key} references non-existent file: ${resolved}")
                    WARNINGS=$((WARNINGS + 1))
                elif [[ ! -x "$resolved" ]]; then
                    echo "  ⚠ ${key}: referenced script not executable: ${resolved}" >&2
                    WARNING_MESSAGES+=("Script ${key} references non-executable file: ${resolved}")
                    WARNINGS=$((WARNINGS + 1))
                else
                    echo "  ✓ ${key}: ${resolved}"
                fi
            done <<< "$SCRIPT_REFS"
        fi
    fi
fi

# --- Summary ---
echo ""
echo "=== Validation Summary ==="

if [[ ${#ERROR_MESSAGES[@]} -gt 0 ]]; then
    echo "ERRORS (${ERRORS}):"
    for msg in "${ERROR_MESSAGES[@]}"; do
        echo "  ✗ ${msg}"
    done
fi

if [[ ${#WARNING_MESSAGES[@]} -gt 0 ]]; then
    echo "WARNINGS (${WARNINGS}):"
    for msg in "${WARNING_MESSAGES[@]}"; do
        echo "  ⚠ ${msg}"
    done
fi

echo ""
if [[ $ERRORS -eq 0 ]]; then
    echo "Result: PASS"
    exit 0
else
    echo "Result: FAIL (${ERRORS} error(s), ${WARNINGS} warning(s))"
    exit 1
fi
