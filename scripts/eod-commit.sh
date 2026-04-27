#!/usr/bin/env bash
# =============================================================================
# eod-commit.sh — End-of-Day Git Snapshot
# SRE Master Demo · ~/sre
#
# Usage:
#   bash scripts/eod-commit.sh                  # auto-generates commit message
#   bash scripts/eod-commit.sh "custom message" # override commit message
#   bash scripts/eod-commit.sh --dry-run        # see what would be committed
#
# Place this file at: ~/sre/k8s/scripts/eod-commit.sh
# =============================================================================

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BRANCH_DEFAULT="main"
REMOTE_DEFAULT="origin"
TIMESTAMP="$(date '+%Y-%m-%d %H:%M')"
DATE_SHORT="$(date '+%Y-%m-%d')"

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}▶${RESET}  $*"; }
success() { echo -e "${GREEN}✔${RESET}  $*"; }
warn()    { echo -e "${YELLOW}⚠${RESET}  $*"; }
error()   { echo -e "${RED}✖${RESET}  $*" >&2; }
header()  { echo -e "\n${BOLD}$*${RESET}"; }

# ── Parse Args ────────────────────────────────────────────────────────────────
DRY_RUN=false
CUSTOM_MSG=""

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    *)         CUSTOM_MSG="$arg" ;;
  esac
done

# ── Navigate to repo root ─────────────────────────────────────────────────────
cd "$REPO_ROOT"
header "📁 SRE Holy Grail — End-of-Day Commit"
info "Repo root: $REPO_ROOT"
info "Timestamp: $TIMESTAMP"

# ── Dry-run check ─────────────────────────────────────────────────────────────
if $DRY_RUN; then
  warn "DRY RUN — nothing will be committed or pushed"
fi

# ── Sanity checks ─────────────────────────────────────────────────────────────
if ! git rev-parse --is-inside-work-tree &>/dev/null; then
  error "Not a git repo: $REPO_ROOT"
  exit 1
fi

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
REMOTE="$(git remote | head -1 || echo '')"

info "Branch: $BRANCH"
[[ -n "$REMOTE" ]] && info "Remote: $REMOTE" || warn "No remote configured — will skip push"

# ── Detect changed areas for smart commit message ─────────────────────────────
header "🔍 Scanning changes..."

CHANGED_FILES="$(git status --porcelain)"

if [[ -z "$CHANGED_FILES" ]]; then
  success "Nothing to commit — repo is clean."
  exit 0
fi

# Summarise which areas changed
AREAS=()
echo "$CHANGED_FILES" | grep -q "k8s/observability"  && AREAS+=("observability")
echo "$CHANGED_FILES" | grep -q "k8s/boutique"        && AREAS+=("boutique")
echo "$CHANGED_FILES" | grep -q "k8s/scripts"         && AREAS+=("scripts")
echo "$CHANGED_FILES" | grep -q "k8s/cluster"         && AREAS+=("cluster")
echo "$CHANGED_FILES" | grep -q "helm/"               && AREAS+=("helm")
echo "$CHANGED_FILES" | grep -q "infra/"              && AREAS+=("infra")
echo "$CHANGED_FILES" | grep -q "gitops/"             && AREAS+=("gitops")
echo "$CHANGED_FILES" | grep -q "load-testing/"       && AREAS+=("load-testing")
echo "$CHANGED_FILES" | grep -q "platform/"           && AREAS+=("platform")
echo "$CHANGED_FILES" | grep -q "docs/"               && AREAS+=("docs")
echo "$CHANGED_FILES" | grep -q "aiops/"              && AREAS+=("aiops")

AREA_STR="$(IFS=', '; echo "${AREAS[*]:-misc}")"

# Count files
ADDED="$(echo "$CHANGED_FILES"   | grep -c '^A\|^??' || true)"
MODIFIED="$(echo "$CHANGED_FILES" | grep -c '^M'       || true)"
DELETED="$(echo "$CHANGED_FILES"  | grep -c '^D'       || true)"

info "Changed areas : $AREA_STR"
info "Files — added: $ADDED  modified: $MODIFIED  deleted: $DELETED"

# ── Build commit message ───────────────────────────────────────────────────────
if [[ -n "$CUSTOM_MSG" ]]; then
  COMMIT_MSG="$CUSTOM_MSG"
else
  COMMIT_MSG="snapshot: eod $DATE_SHORT [$AREA_STR]

Changes
- Areas touched : $AREA_STR
- Added         : $ADDED file(s)
- Modified      : $MODIFIED file(s)
- Deleted       : $DELETED file(s)

Files
$(git status --short | head -40)"
fi

# ── Show diff summary ──────────────────────────────────────────────────────────
header "📋 Staged diff preview (top 60 lines):"
git status --short | head -60

echo ""
echo -e "${BOLD}Commit message:${RESET}"
echo "──────────────────────────────────────────"
echo "$COMMIT_MSG"
echo "──────────────────────────────────────────"

# ── Confirm (skip in non-interactive / dry-run) ───────────────────────────────
if ! $DRY_RUN && [[ -t 0 ]]; then
  echo ""
  read -rp "$(echo -e "${YELLOW}Proceed with commit + push? [Y/n]:${RESET} ")" CONFIRM
  CONFIRM="${CONFIRM:-Y}"
  if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    warn "Aborted by user."
    exit 0
  fi
fi

# ── Commit ─────────────────────────────────────────────────────────────────────
if ! $DRY_RUN; then
  header "📦 Committing..."
  git add -A
  git commit -m "$COMMIT_MSG"
  success "Committed: $(git rev-parse --short HEAD)"

  # ── Push ──────────────────────────────────────────────────────────────────────
  if [[ -n "$REMOTE" ]]; then
    header "🚀 Pushing to $REMOTE/$BRANCH..."
    if git push "$REMOTE" "$BRANCH" 2>&1; then
      success "Pushed to $REMOTE/$BRANCH"
    else
      warn "Push failed — check remote access. Commit is safe locally."
    fi
  else
    warn "No remote — skipping push. Add one with: git remote add origin <url>"
  fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────
header "✅ Done"
echo -e "  ${CYAN}Branch${RESET}  : $BRANCH"
[[ -n "$REMOTE" ]] && echo -e "  ${CYAN}Remote${RESET}  : $REMOTE"
echo -e "  ${CYAN}Areas${RESET}   : $AREA_STR"
$DRY_RUN && warn "Dry-run complete — no changes were made."
