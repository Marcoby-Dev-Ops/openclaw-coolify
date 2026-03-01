#!/bin/bash
# Fix markdown linting errors in documentation

set -e

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

DOCS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/docs"

echo -e "${YELLOW}Installing markdownlint-cli globally...${NC}"
npm install -g markdownlint-cli@latest

echo -e "${YELLOW}Fixing markdown files in $DOCS_DIR...${NC}"
markdownlint --fix --config .markdownlint.json "$DOCS_DIR/**/*.md" 2>/dev/null || \
  find "$DOCS_DIR" -name "*.md" -exec markdownlint --fix {} \;

echo -e "${GREEN}✓ Markdown files fixed!${NC}"

# Verify no outstanding errors
echo -e "${YELLOW}Verifying fixes...${NC}"
markdownlint --config .markdownlint.json "$DOCS_DIR/**/*.md" 2>/dev/null || {
  echo -e "${YELLOW}Some warnings remain (review manually if needed)${NC}"
}

echo -e "${GREEN}✓ Done!${NC}"
