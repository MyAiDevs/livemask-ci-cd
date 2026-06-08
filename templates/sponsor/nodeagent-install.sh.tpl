#!/bin/bash
# Reference template for sponsor NodeAgent install bundles.
# Source of truth for rendering: livemask-backend/internal/node/install_bundle.go
# Sponsors receive a personalized copy via GET /api/v1/me/sponsor/install-bundle
#
# Placeholders (replaced by Backend):
#   {{OWNER_AMBASSADOR_ID}}  — sponsor user UUID
#   {{BACKEND_URL}}          — public API base URL
#   {{NODEAGENT_IMAGE}}      — container image
#   {{AGENT_VERSION}}        — release label
#   {{DATA_DIR}}             — persistent volume host path
#   {{DISTRIBUTION_ID}}      — per-download trace id
#   {{GENERATED_AT}}         — RFC3339 timestamp
#
# Must NOT include node_id or node_secret.
