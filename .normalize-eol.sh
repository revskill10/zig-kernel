#!/bin/bash
# Normalize worktree to LF for tracked text files, re-stage, show real diff.
cd "$(dirname "$0")"
for f in $(git diff --name-only HEAD | grep -E '\.(zig|md|yml|sh|ld|zon|gitignore|attributes)$|\.gitignore$|\.gitattributes$'); do
  [ -f "$f" ] || continue
  # strip CR only when followed by LF
  sed -i 's/\r$//' "$f"
done
git add -A --renormalize 2>/dev/null || git add -A
echo "=== real diff after normalization ==="
git diff --cached --stat | tail -8
