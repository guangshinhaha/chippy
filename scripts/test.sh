#!/bin/bash
# Build every target, then run the whole test suite. Exits non-zero on any failure. CI and people run the same thing.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build
swift test
