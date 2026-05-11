#!/bin/bash
set -e
echo "[AI Rules] Syncing livemask-docs submodule..."
git submodule update --init --recursive
echo "[AI Rules] Done. Latest rules from docs/ai-rules/v3.7/ are now active."