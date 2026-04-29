#!/usr/bin/env bash
# GCP Free Tier Guard — teardown
# Removes everything setup.sh created. Prompts for the same identifiers.

set -euo pipefail

ask() { local p="$1" d="${2:-}" r; read -rp "  $p${d:+ [$d]}: " r; echo "${r:-$d}"; }
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn(){ printf '  \033[33m!\033[0m %s\n' "$*" >&2; }

PROJECT_ID="$(ask 'Project ID' "$(gcloud config get-value project 2>/dev/null || true)")"
gcloud config set project "$PROJECT_ID" >/dev/null

mapfile -t BAS < <(gcloud billing accounts list --filter='OPEN=true' --format='value(ACCOUNT_ID)')
BILLING_ACCOUNT="$(ask 'Billing account ID' "${BAS[0]:-}")"

VM_NAME="$(ask 'VM name' 'free-tier-vm')"
ZONE="$(ask 'Zone' 'us-east1-b')"
REGION="${ZONE%-*}"
TOPIC_NAME="$(ask 'Pub/Sub topic' 'billing-alerts')"
FUNCTION_NAME="$(ask 'Function name' 'stop-vm-on-billing-alert')"
SA_NAME="$(ask 'Service account name' 'vm-stopper')"
BUDGET_NAME="$(ask 'Budget display name' 'free-tier-guard')"
STATIC_IP_NAME="$(ask 'Static IP name (blank if none)' '')"

SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

read -rp "  This will DELETE the resources above. Continue? [y/N] " c
[[ "$c" =~ ^[Yy]$ ]] || { warn "Aborted"; exit 0; }

gcloud functions delete "$FUNCTION_NAME" --region="$REGION" --project="$PROJECT_ID" --quiet 2>/dev/null && ok "Function deleted" || warn "Function not found"
gcloud pubsub topics delete "$TOPIC_NAME" --project="$PROJECT_ID" --quiet 2>/dev/null && ok "Topic deleted" || warn "Topic not found"
gcloud compute instances delete "$VM_NAME" --zone="$ZONE" --project="$PROJECT_ID" --quiet 2>/dev/null && ok "VM deleted" || warn "VM not found"

if [[ -n "$STATIC_IP_NAME" ]]; then
  gcloud compute addresses delete "$STATIC_IP_NAME" --region="$REGION" --project="$PROJECT_ID" --quiet 2>/dev/null && ok "Static IP released" || warn "Static IP not found"
fi

BUDGET_ID="$(gcloud billing budgets list --billing-account="$BILLING_ACCOUNT" \
  --filter="displayName=$BUDGET_NAME" --format='value(name)' | head -n1 || true)"
if [[ -n "$BUDGET_ID" ]]; then
  gcloud billing budgets delete "${BUDGET_ID##*/}" --billing-account="$BILLING_ACCOUNT" --quiet
  ok "Budget deleted"
else
  warn "Budget not found"
fi

gcloud iam service-accounts delete "$SA_EMAIL" --project="$PROJECT_ID" --quiet 2>/dev/null && ok "Service account deleted" || warn "Service account not found"

echo
ok "Teardown complete."
