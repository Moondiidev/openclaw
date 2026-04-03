#!/usr/bin/env bash
set -euo pipefail

on_error() {
  echo "A2UI bundling failed. Re-run with: pnpm canvas:a2ui:bundle" >&2
  echo "If this persists, verify pnpm deps and try again." >&2
}
trap on_error ERR

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HASH_FILE="$ROOT_DIR/src/canvas-host/a2ui/.bundle.hash"
OUTPUT_FILE="$ROOT_DIR/src/canvas-host/a2ui/a2ui.bundle.js"
A2UI_RENDERER_DIR="$ROOT_DIR/vendor/a2ui/renderers/lit"
A2UI_APP_DIR="$ROOT_DIR/apps/shared/OpenClawKit/Tools/CanvasA2UI"

# Docker builds exclude vendor/apps via .dockerignore.
# In that environment we can keep a prebuilt bundle only if it exists.
if [[ ! -d "$A2UI_RENDERER_DIR" || ! -d "$A2UI_APP_DIR" ]]; then
  if [[ -f "$OUTPUT_FILE" ]]; then
    echo "A2UI sources missing; keeping prebuilt bundle."
    exit 0
  fi
  echo "A2UI sources missing and no prebuilt bundle found at: $OUTPUT_FILE" >&2
  exit 1
fi

INPUT_PATHS=(
  "$ROOT_DIR/package.json"
  "$ROOT_DIR/pnpm-lock.yaml"
  "$A2UI_RENDERER_DIR"
  "$A2UI_APP_DIR"
)

resolve_node_cmd() {
  local pnpm_path
  local pnpm_dir
  if command -v node >/dev/null 2>&1; then
    NODE_CMD=(node)
    return
  fi
  if command -v node.exe >/dev/null 2>&1; then
    NODE_CMD=(node.exe)
    return
  fi
  if command -v pnpm >/dev/null 2>&1; then
    pnpm_path="$(command -v pnpm)"
    pnpm_dir="$(dirname "$pnpm_path")"
    if [[ -f "$pnpm_dir/node.exe" ]]; then
      NODE_CMD=("$pnpm_dir/node.exe")
      return
    fi
    if [[ -f "$pnpm_dir/node" ]]; then
      NODE_CMD=("$pnpm_dir/node")
      return
    fi
  fi
  if command -v pnpm >/dev/null 2>&1; then
    NODE_CMD=(pnpm -s exec node)
    return
  fi
  echo "Missing Node.js runtime in PATH (node/node.exe) and pnpm fallback unavailable." >&2
  exit 1
}

USE_CYGPATH_FOR_NODE=0

to_node_path() {
  local value="$1"
  if [[ "$USE_CYGPATH_FOR_NODE" == "1" ]]; then
    cygpath -w "$value"
    return
  fi
  if [[ "$value" =~ ^/mnt/host/([A-Za-z])/(.*)$ ]]; then
    local drive="${BASH_REMATCH[1]}"
    local rest="${BASH_REMATCH[2]}"
    rest="${rest//\//\\}"
    printf '%s' "${drive^}:\\${rest}"
    return
  fi
  if [[ "$value" =~ ^/([A-Za-z])/(.*)$ ]]; then
    local drive="${BASH_REMATCH[1]}"
    local rest="${BASH_REMATCH[2]}"
    rest="${rest//\//\\}"
    printf '%s' "${drive^}:\\${rest}"
    return
  fi
  printf '%s' "$value"
}

resolve_node_cmd

ensure_node_on_path() {
  local primary="${NODE_CMD[0]}"
  if [[ "$primary" != */* && "$primary" != *\\* ]]; then
    return
  fi
  local node_dir
  node_dir="$(dirname "$primary")"
  case ":$PATH:" in
  *":$node_dir:"*)
    ;;
  *)
    PATH="$node_dir:$PATH"
    export PATH
    ;;
  esac
}

ensure_node_on_path

# WSL (and some cross-env shells) put Windows `pnpm` on PATH; that shim runs `exec node`,
# but Linux PATH often has no `node` even when `node.exe` works. Prefer driving pnpm via
# the same Node we already resolved (`NODE_CMD`).
resolve_pnpm_cli() {
  PNPM_CLI=""
  PNPM_KIND=""
  if [[ "${NODE_CMD[0]:-}" == "pnpm" ]]; then
    return
  fi
  local f
  shopt -s nullglob
  for f in "$ROOT_DIR/node_modules/.pnpm"/pnpm@*/node_modules/pnpm/bin/pnpm.cjs; do
    if [[ -f "$f" ]]; then
      PNPM_CLI="$f"
      PNPM_KIND="pnpm"
      break
    fi
  done
  shopt -u nullglob
  if [[ -n "$PNPM_CLI" ]]; then
    return
  fi
  if [[ -f "$ROOT_DIR/node_modules/pnpm/bin/pnpm.cjs" ]]; then
    PNPM_CLI="$ROOT_DIR/node_modules/pnpm/bin/pnpm.cjs"
    PNPM_KIND="pnpm"
    return
  fi
  local probe
  probe="$(
    "${NODE_CMD[@]}" -e '
const fs = require("node:fs");
const p = require("node:path");
const base = p.dirname(process.execPath);
const tries = [
  [p.join(base, "node_modules", "pnpm", "bin", "pnpm.cjs"), "pnpm"],
  [p.join(base, "node_modules", "corepack", "dist", "corepack.js"), "corepack"],
  [p.join(base, "node_modules", "corepack", "dist", "corepack.cjs"), "corepack"],
];
for (const [filePath, kind] of tries) {
  if (fs.existsSync(filePath)) {
    process.stdout.write(kind + "\n" + filePath);
    process.exit(0);
  }
}
' 2>/dev/null | tr -d '\r'
  )"
  if [[ -n "$probe" ]]; then
    PNPM_KIND="${probe%%$'\n'*}"
    PNPM_CLI="${probe#*$'\n'}"
  fi
}

pnpm_cli_is_runnable() {
  [[ -f "$1" ]] && return 0
  # Node may print a Windows path (e.g. from process.execPath); WSL bash -f often fails on those.
  [[ "$1" =~ ^[A-Za-z]:[\\/] ]] && return 0
  return 1
}

run_pnpm() {
  if [[ -n "${PNPM_CLI:-}" ]] && pnpm_cli_is_runnable "$PNPM_CLI"; then
    local script_path="$PNPM_CLI"
    if [[ "${NODE_CMD[0]}" == *.exe ]]; then
      script_path="$(to_node_path "$PNPM_CLI")"
    fi
    if [[ "${PNPM_KIND:-}" == "corepack" ]]; then
      "${NODE_CMD[@]}" "$script_path" pnpm "$@"
    else
      "${NODE_CMD[@]}" "$script_path" "$@"
    fi
    return
  fi
  if command -v pnpm >/dev/null 2>&1; then
    command pnpm "$@"
    return
  fi
  echo "pnpm not found (no pnpm.cjs next to Node, no project copy, and no pnpm on PATH)." >&2
  exit 1
}

resolve_pnpm_cli

if command -v cygpath >/dev/null 2>&1; then
  case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN*)
    USE_CYGPATH_FOR_NODE=1
    ;;
  esac
fi

NODE_ROOT_DIR="$(to_node_path "$ROOT_DIR")"
NODE_INPUT_PATHS=()
for input_path in "${INPUT_PATHS[@]}"; do
  NODE_INPUT_PATHS+=("$(to_node_path "$input_path")")
done

NODE_ROLLDOWN_CONFIG_PATH="$(to_node_path "$A2UI_APP_DIR/rolldown.config.mjs")"
NODE_ROLLDOWN_CLI_PATH="$(to_node_path "$ROOT_DIR/node_modules/.pnpm/node_modules/rolldown/bin/cli.mjs")"
NODE_ROLLDOWN_LEGACY_CLI_PATH="$(to_node_path "$ROOT_DIR/node_modules/.pnpm/rolldown@1.0.0-rc.9/node_modules/rolldown/bin/cli.mjs")"

compute_hash() {
  ROOT_DIR="$NODE_ROOT_DIR" "${NODE_CMD[@]}" --input-type=module --eval '
import { createHash } from "node:crypto";
import { promises as fs } from "node:fs";
import path from "node:path";

const rootDir = process.env.ROOT_DIR ?? process.cwd();
const inputs = process.argv.slice(1);
const files = [];

async function walk(entryPath) {
  const st = await fs.stat(entryPath);
  if (st.isDirectory()) {
    const entries = await fs.readdir(entryPath);
    for (const entry of entries) {
      await walk(path.join(entryPath, entry));
    }
    return;
  }
  files.push(entryPath);
}

for (const input of inputs) {
  await walk(input);
}

function normalize(p) {
  return p.split(path.sep).join("/");
}

files.sort((a, b) => normalize(a).localeCompare(normalize(b)));

const hash = createHash("sha256");
for (const filePath of files) {
  const rel = normalize(path.relative(rootDir, filePath));
  hash.update(rel);
  hash.update("\0");
  hash.update(await fs.readFile(filePath));
  hash.update("\0");
}

process.stdout.write(hash.digest("hex"));
' "${NODE_INPUT_PATHS[@]}"
}

current_hash="$(compute_hash)"
if [[ -f "$HASH_FILE" ]]; then
  previous_hash="$(cat "$HASH_FILE")"
  if [[ "$previous_hash" == "$current_hash" && -f "$OUTPUT_FILE" ]]; then
    echo "A2UI bundle up to date; skipping."
    exit 0
  fi
fi

TSC_PROJECT_PATH="$A2UI_RENDERER_DIR/tsconfig.json"
if [[ "${NODE_CMD[0]}" == *.exe ]]; then
  TSC_PROJECT_PATH="$(to_node_path "$TSC_PROJECT_PATH")"
fi
run_pnpm -s exec tsc -p "$TSC_PROJECT_PATH"
if command -v rolldown >/dev/null 2>&1 && rolldown --version >/dev/null 2>&1; then
  rolldown -c "$A2UI_APP_DIR/rolldown.config.mjs"
elif [[ -f "$ROOT_DIR/node_modules/.pnpm/node_modules/rolldown/bin/cli.mjs" ]]; then
  "${NODE_CMD[@]}" "$NODE_ROLLDOWN_CLI_PATH" -c "$NODE_ROLLDOWN_CONFIG_PATH"
elif [[ -f "$ROOT_DIR/node_modules/.pnpm/rolldown@1.0.0-rc.9/node_modules/rolldown/bin/cli.mjs" ]]; then
  "${NODE_CMD[@]}" "$NODE_ROLLDOWN_LEGACY_CLI_PATH" -c "$NODE_ROLLDOWN_CONFIG_PATH"
else
  ROLLDOWN_CONFIG_PATH="$A2UI_APP_DIR/rolldown.config.mjs"
  if [[ "${NODE_CMD[0]}" == *.exe ]]; then
    ROLLDOWN_CONFIG_PATH="$(to_node_path "$ROLLDOWN_CONFIG_PATH")"
  fi
  run_pnpm -s dlx rolldown -c "$ROLLDOWN_CONFIG_PATH"
fi

echo "$current_hash" > "$HASH_FILE"
