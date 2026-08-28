#!/usr/bin/env bash
set -Eeuo pipefail

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "Run this inside the Git repository."

STAGED_FILES=()

# macOS ships Bash 3.2. Use process substitution so the while-loop runs
# in the current shell and actually populates STAGED_FILES.
while IFS= read -r line; do
  [[ -n "$line" ]] && STAGED_FILES[${#STAGED_FILES[@]}]="$line"
done < <(git diff --cached --name-only --diff-filter=ACMR)

if [[ ${#STAGED_FILES[@]} -eq 0 ]]; then
  echo "No staged files. Run: git add ."
  exit 0
fi

echo "==> Staged files: ${#STAGED_FILES[@]}"
printf '  %s\n' "${STAGED_FILES[@]}"

fail=0

echo
echo "==> Checking forbidden paths / file types"

for f in "${STAGED_FILES[@]}"; do
  case "$f" in
    .env|*/.env|.env.*|*/.env.*)
      case "$f" in
        .env.example|*/.env.example|*.example) ;;
        *) echo "BLOCK: local environment file staged: $f"; fail=1 ;;
      esac
      ;;
  esac

  case "$f" in
    .state/*|*/.state/*|.cache/*|*/.cache/*)
      echo "BLOCK: generated runtime/cache content staged: $f"; fail=1 ;;
    RECOVERY-NOTES.md|*/RECOVERY-NOTES.md)
      echo "BLOCK: local recovery notes staged: $f"; fail=1 ;;
    diagnostics/*|*/diagnostics/*)
      echo "BLOCK: one-off troubleshooting artifact staged: $f"; fail=1 ;;
  esac

  case "${f##*.}" in
    key|pem|p12|pfx|jks|keystore|truststore|csr|crt|cer|der)
      echo "BLOCK: certificate/key material staged: $f"; fail=1 ;;
    jar|war|car|aar|zip|tgz)
      echo "BLOCK: generated/downloaded binary archive staged: $f"; fail=1 ;;
  esac

  if git cat-file -e ":$f" 2>/dev/null; then
    size="$(git cat-file -s ":$f" 2>/dev/null || echo 0)"
    case "$size" in
      ''|*[!0-9]*) size=0 ;;
    esac
    if [ "$size" -gt 5242880 ]; then
      echo "BLOCK: staged file is larger than 5 MiB ($size bytes): $f"
      fail=1
    fi
  fi
done

echo
echo "==> Scanning staged content for high-confidence secrets"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

for f in "${STAGED_FILES[@]}"; do
  if ! git show ":$f" >"$tmp" 2>/dev/null; then
    continue
  fi

  if grep -Eq -- '-----BEGIN ([A-Z0-9 ]+ )?PRIVATE KEY-----' "$tmp"; then
    echo "BLOCK: private key marker found in $f"
    fail=1
  fi

  if grep -Eq -- 'gh[pousr]_[A-Za-z0-9]{30,}' "$tmp"; then
    echo "BLOCK: GitHub token-like value found in $f"
    fail=1
  fi

  if grep -Eq -- '(AKIA|ASIA)[A-Z0-9]{16}' "$tmp"; then
    echo "BLOCK: AWS access-key-like value found in $f"
    fail=1
  fi

  if grep -Eq -- 'xox[baprs]-[A-Za-z0-9-]{20,}' "$tmp"; then
    echo "BLOCK: Slack token-like value found in $f"
    fail=1
  fi

  if grep -Eq -- 'sk-(proj-)?[A-Za-z0-9_-]{20,}' "$tmp"; then
    echo "BLOCK: sk-* API-key-like value found in $f"
    fail=1
  fi

  if grep -Eq -- 'eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}' "$tmp"; then
    echo "BLOCK: JWT-like token found in $f"
    fail=1
  fi

  # Generic high-risk assignments, but ignore documented/default demo values.
  if grep -Ein \
    '(client[_-]?secret|api[_-]?key|access[_-]?token|refresh[_-]?token|private[_-]?key)[[:space:]]*[:=][[:space:]]*["'\'']?[A-Za-z0-9+/=_-]{16,}' \
    "$tmp" >/dev/null 2>&1; then
    echo "WARN: credential-like assignment found in $f; inspect manually:"
    grep -Ein \
      '(client[_-]?secret|api[_-]?key|access[_-]?token|refresh[_-]?token|private[_-]?key)[[:space:]]*[:=]' \
      "$tmp" | head -10 || true
  fi
done

echo
echo "==> Git whitespace/conflict check"
if ! git diff --cached --check; then
  fail=1
fi

echo
echo "==> Intentional demo credentials"
echo "Known local demo defaults such as admin/admin, wso2/wso2 and wso2carbon"
echo "may appear in tracked example/config files. Treat them as demo-only."

if [ "$fail" -ne 0 ]; then
  echo
  echo "============================================================"
  echo "PRE-COMMIT AUDIT FAILED"
  echo "============================================================"
  exit 1
fi

echo
echo "============================================================"
echo "PRE-COMMIT AUDIT PASSED"
echo "============================================================"
echo
echo "Final manual review:"
echo "  git diff --cached --stat"
echo "  git diff --cached"
