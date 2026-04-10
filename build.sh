#!/bin/bash
set -e

ROOT="$(cd "$(dirname "$0")" && pwd)"

echo "Building TypeScript edition..."
(cd "$ROOT/typescript" && mdbook build)

echo "Building Python edition..."
(cd "$ROOT/python" && mdbook build)

echo "Building Rust edition..."
(cd "$ROOT/rust" && mdbook build)

echo "Building Go edition..."
(cd "$ROOT/go" && mdbook build)

echo "Building Java edition..."
(cd "$ROOT/java" && mdbook build)

# Copy landing page to docs root
cp "$ROOT/index.html" "$ROOT/docs/index.html"

echo "Done! Output in docs/"
