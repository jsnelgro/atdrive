#!/bin/bash
# Formats all Swift code in place (config: .swift-format).
set -euo pipefail
cd "$(dirname "$0")/.."
swift format --in-place --recursive Package.swift Sources Tests
