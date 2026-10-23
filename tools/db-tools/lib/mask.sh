#!/usr/bin/env bash
# mask.sh — filters from stdin to stdout. The rules live in mask.py: Python matches Unicode, unlike sed on
# macOS, which works on bytes.

mask_pii() {
    python3 -I "$DBTOOLS_DIR/lib/mask.py"
}

redact_secrets() {
    python3 -I "$DBTOOLS_DIR/lib/mask.py" --secrets-only
}
