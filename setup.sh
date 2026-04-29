#!/usr/bin/env bash
#
# GCP Free Tier Guard — interactive setup
#
# Provisions a free-tier-eligible VM and an automated kill-switch that stops it
# when billing exceeds a configured threshold.

set -euo pipefail

# ---------- helpers ----------
bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
info()  { printf '  \033[36m→\033[0m %s\n' "$*"; }
ok()    { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn()  { printf '  \033[33m!\033[0m %s\n' "$*" >&2; }
die()   { printf '  \033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }

ask() {
  # ask "prompt" "default" -> echoes user input or default
  local prompt="$1" default="${2:-}" reply
  if [[ -n "$default" ]]; then
    read -rp "  $prompt [$default]: " reply
    echo "${reply:-$default}"
  else
    read -rp "  $prompt: " reply
    echo "$reply"
  fi
}

require_cmd() { command -v "$1" >/dev/null 2>&1 || die "$1 is required but not installed"; }

# ---------- preflight ----------
bold "GCP Free Tier Guard — setup"
echo
require_cmd gcloud

# Detect or set project
CURRENT_PROJECT="$(gcloud config get-value project 2>/dev/null || true)"
PROJECT_ID="$(ask 'Project ID' "$CURRENT_PROJECT")"
[[ -n "$PROJECT_ID" ]] || die "Project ID is required"
gcloud config set project "$PROJECT_ID" >/dev/null

PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"
ok "Project: $PROJECT_ID (number: $PROJECT_NUMBER)"

# Detect or pick billing account
mapfile -t BILLING_ACCOUNTS < <(gcloud billing accounts list --filter='OPEN=true' --format='value(ACCOUNT_ID)')
if [[ ${#BILLING_ACCOUNTS[@]} -eq 0 ]]; then
  die "No open billing accounts found. Enable billing on your project first."
elif [[ ${#BILLING_ACCOUNTS[@]} -eq 1 ]]; then
  BILLING_ACCOUNT="${BILLING_ACCOUNTS[0]}"
  ok "Billing account: $BILLING_ACCOUNT (auto-detected)"
else
  echo "  Available billing accounts:"
  for a in "${BILLING_ACCOUNTS[@]}"; do echo "    - $a"; done
  BILLING_ACCOUNT="$(ask 'Billing account ID' "${BILLING_ACCOUNTS[0]}")"
fi

CURRENCY="$(gcloud billing accounts describe "$BILLING_ACCOUNT" --format='value(currencyCode)')"
ok "Currency: $CURRENCY"

# ---------- gather config ----------
echo
bold "Configuration"
VM_NAME="$(ask 'VM name' 'free-tier-vm')"
ZONE="$(ask 'Zone (must be us-west1-*, us-central1-*, or us-east1-* for free tier)' 'us-east1-b')"
REGION="${ZONE%-*}"
SSH_USER="$(ask 'Linux username for SSH' "${USER:-admin}")"

echo
echo "  Paste your SSH public key (single line, e.g. 'ssh-ed25519 AAAA... comment'):"
read -r SSH_PUBKEY
[[ "$SSH_PUBKEY" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-) ]] || die "That doesn't look like a valid SSH public key"

BUDGET_AMOUNT="$(ask "Budget amount (in $CURRENCY)" '1')"
BUDGET_NAME="$(ask 'Budget display name' 'free-tier-guard')"
TOPIC_NAME="$(ask 'Pub/Sub topic name' 'billing-alerts')"
FUNCTION_NAME="$(ask 'Cloud Function name' 'stop-vm-on-billing-alert')"
SA_NAME="$(ask 'Service account name (for VM stopper)' 'vm-stopper')"

# ---------- IP strategy ----------
echo
bold "External IP strategy"
cat <<'EOF'
  An e2-micro's external IP changes after every reboot by default.
  Choose how you'd like to handle this:

    1) ephemeral  — accept that the IP changes (simplest, fully free)
    2) duckdns    — use DuckDNS for a stable hostname (free, requires a token)
    3) static     — reserve a static IP (free while VM runs; ~$0.01/hr while stopped)
    4) static-auto — reserve a static IP, auto-release when kill-switch fires
                     (fully free, but you'll need to re-attach manually on restart)
EOF
echo
IP_STRATEGY="$(ask 'Choice [1/2/3/4]' '1')"
case "$IP_STRATEGY" in
  1) IP_STRATEGY=ephemeral ;;
  2) IP_STRATEGY=duckdns ;;
  3) IP_STRATEGY=static ;;
  4) IP_STRATEGY=static-auto ;;
  ephemeral|duckdns|static|static-auto) ;;
  *) die "Invalid choice: $IP_STRATEGY" ;;
esac

DUCKDNS_DOMAIN=""
DUCKDNS_TOKEN=""
STATIC_IP_NAME=""
if [[ "$IP_STRATEGY" == "duckdns" ]]; then
  echo
  echo "  DuckDNS setup: register at https://www.duckdns.org/ (sign in with Google/GitHub)"
  echo "  then create a subdomain and copy your account token."
  DUCKDNS_DOMAIN="$(ask 'DuckDNS subdomain (the part before .duckdns.org)')"
  [[ -n "$DUCKDNS_DOMAIN" ]] || die "DuckDNS subdomain required"
  DUCKDNS_TOKEN="$(ask 'DuckDNS token')"
  [[ -n "$DUCKDNS_TOKEN" ]] || die "DuckDNS token required"
elif [[ "$IP_STRATEGY" == "static" || "$IP_STRATEGY" == "static-auto" ]]; then
  STATIC_IP_NAME="$(ask 'Name for the reserved static IP' "${VM_NAME}-ip")"
fi

SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
FUNCTION_REGION="$REGION"

echo
bold "Review"
cat <<EOF
  Project:          $PROJECT_ID
  Billing account:  $BILLING_ACCOUNT ($CURRENCY)
  VM:               $VM_NAME in $ZONE
  SSH user:         $SSH_USER
  Budget:           $BUDGET_AMOUNT $CURRENCY ($BUDGET_NAME)
  Pub/Sub topic:    $TOPIC_NAME
  Function:         $FUNCTION_NAME (region: $FUNCTION_REGION)
  Service account:  $SA_EMAIL
  IP strategy:      $IP_STRATEGY${DUCKDNS_DOMAIN:+ (${DUCKDNS_DOMAIN}.duckdns.org)}${STATIC_IP_NAME:+ (reserve as ${STATIC_IP_NAME})}
EOF
echo
read -rp "  Proceed? [y/N] " confirm
[[ "$confirm" =~ ^[Yy]$ ]] || die "Aborted"

# ---------- enable APIs ----------
echo
bold "Enabling APIs"
APIS=(
  compute.googleapis.com
  billingbudgets.googleapis.com
  pubsub.googleapis.com
  cloudfunctions.googleapis.com
  run.googleapis.com
  cloudbuild.googleapis.com
  eventarc.googleapis.com
  iam.googleapis.com
  artifactregistry.googleapis.com
)
gcloud services enable "${APIS[@]}" --project="$PROJECT_ID"
ok "APIs enabled"

# ---------- reserve static IP if requested ----------
STATIC_IP_ADDRESS=""
if [[ "$IP_STRATEGY" == "static" || "$IP_STRATEGY" == "static-auto" ]]; then
  echo
  bold "Reserving static external IP"
  if gcloud compute addresses describe "$STATIC_IP_NAME" --region="$REGION" --project="$PROJECT_ID" >/dev/null 2>&1; then
    warn "Address $STATIC_IP_NAME already exists — reusing"
  else
    gcloud compute addresses create "$STATIC_IP_NAME" \
      --project="$PROJECT_ID" \
      --region="$REGION"
    ok "Static IP reserved"
  fi
  STATIC_IP_ADDRESS="$(gcloud compute addresses describe "$STATIC_IP_NAME" \
    --region="$REGION" --project="$PROJECT_ID" --format='value(address)')"
  ok "Static IP: $STATIC_IP_ADDRESS"
fi

# ---------- prepare DuckDNS startup script if requested ----------
STARTUP_SCRIPT_FLAG=()
if [[ "$IP_STRATEGY" == "duckdns" ]]; then
  STARTUP_TMP="$(mktemp)"
  cat > "$STARTUP_TMP" <<EOF
#!/bin/bash
# DuckDNS auto-update — installs a cron job that publishes the VM's
# current public IP to ${DUCKDNS_DOMAIN}.duckdns.org every 5 minutes.
set -e
mkdir -p /opt/duckdns
cat > /opt/duckdns/duck.sh <<'INNER'
#!/bin/bash
echo url="https://www.duckdns.org/update?domains=${DUCKDNS_DOMAIN}&token=${DUCKDNS_TOKEN}&ip=" | curl -sS -k -o /var/log/duckdns.log -K -
INNER
chmod 700 /opt/duckdns/duck.sh
/opt/duckdns/duck.sh || true
( crontab -l 2>/dev/null | grep -v duckdns; echo "*/5 * * * * /opt/duckdns/duck.sh >/dev/null 2>&1" ) | crontab -
EOF
  STARTUP_SCRIPT_FLAG=(--metadata-from-file "startup-script=$STARTUP_TMP")
  trap 'rm -f "$STARTUP_TMP" "${TMPKEY:-}"' EXIT
fi

# ---------- create VM ----------
echo
bold "Creating VM"
if gcloud compute instances describe "$VM_NAME" --zone="$ZONE" --project="$PROJECT_ID" >/dev/null 2>&1; then
  warn "VM $VM_NAME already exists in $ZONE — skipping creation"
else
  # Build network-interface arg with optional static IP
  NETWORK_IFACE="network-tier=PREMIUM,stack-type=IPV4_ONLY,subnet=default"
  if [[ -n "$STATIC_IP_ADDRESS" ]]; then
    NETWORK_IFACE="${NETWORK_IFACE},address=${STATIC_IP_ADDRESS}"
  fi

  gcloud compute instances create "$VM_NAME" \
    --project="$PROJECT_ID" \
    --zone="$ZONE" \
    --machine-type=e2-micro \
    --provisioning-model=STANDARD \
    --maintenance-policy=MIGRATE \
    --restart-on-failure \
    --network-interface="$NETWORK_IFACE" \
    --no-service-account \
    --no-scopes \
    --create-disk=auto-delete=yes,boot=yes,image=projects/debian-cloud/global/images/family/debian-13,mode=rw,size=30,type=pd-standard \
    --shielded-secure-boot \
    --shielded-vtpm \
    --shielded-integrity-monitoring \
    --reservation-affinity=none \
    "${STARTUP_SCRIPT_FLAG[@]}"
  ok "VM created"
fi

# ---------- inject SSH key ----------
info "Injecting SSH key for user '$SSH_USER'"
TMPKEY="$(mktemp)"
trap 'rm -f "$TMPKEY"' EXIT
printf '%s:%s\n' "$SSH_USER" "$SSH_PUBKEY" > "$TMPKEY"
gcloud compute instances add-metadata "$VM_NAME" \
  --project="$PROJECT_ID" \
  --zone="$ZONE" \
  --metadata-from-file ssh-keys="$TMPKEY" >/dev/null
ok "SSH key added"

# ---------- pub/sub topic ----------
echo
bold "Creating Pub/Sub topic"
if gcloud pubsub topics describe "$TOPIC_NAME" --project="$PROJECT_ID" >/dev/null 2>&1; then
  warn "Topic $TOPIC_NAME already exists — skipping"
else
  gcloud pubsub topics create "$TOPIC_NAME" --project="$PROJECT_ID"
  ok "Topic created"
fi

# ---------- budget ----------
echo
bold "Creating billing budget"
EXISTING_BUDGET="$(gcloud billing budgets list \
  --billing-account="$BILLING_ACCOUNT" \
  --filter="displayName=$BUDGET_NAME" \
  --format='value(name)' | head -n1 || true)"

if [[ -n "$EXISTING_BUDGET" ]]; then
  warn "Budget '$BUDGET_NAME' already exists — updating to use topic"
  gcloud billing budgets update "${EXISTING_BUDGET##*/}" \
    --billing-account="$BILLING_ACCOUNT" \
    --notifications-rule-pubsub-topic="projects/$PROJECT_ID/topics/$TOPIC_NAME" >/dev/null
else
  gcloud billing budgets create \
    --billing-account="$BILLING_ACCOUNT" \
    --display-name="$BUDGET_NAME" \
    --budget-amount="${BUDGET_AMOUNT}${CURRENCY}" \
    --threshold-rule=percent=0.01,basis=current-spend \
    --threshold-rule=percent=0.5,basis=current-spend \
    --threshold-rule=percent=1.0,basis=current-spend \
    --notifications-rule-pubsub-topic="projects/$PROJECT_ID/topics/$TOPIC_NAME" >/dev/null
  ok "Budget created"
fi

# ---------- service account ----------
echo
bold "Creating service account"
if gcloud iam service-accounts describe "$SA_EMAIL" --project="$PROJECT_ID" >/dev/null 2>&1; then
  warn "Service account $SA_EMAIL already exists — skipping creation"
else
  gcloud iam service-accounts create "$SA_NAME" \
    --display-name="VM Stopper" \
    --project="$PROJECT_ID" >/dev/null
  ok "Service account created"
fi

info "Granting compute.instanceAdmin.v1 to $SA_NAME"
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$SA_EMAIL" \
  --role="roles/compute.instanceAdmin.v1" \
  --condition=None >/dev/null

if [[ "$IP_STRATEGY" == "static-auto" ]]; then
  info "Granting compute.networkAdmin to $SA_NAME (for IP release)"
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:$SA_EMAIL" \
    --role="roles/compute.networkAdmin" \
    --condition=None >/dev/null
fi

# Cloud Build needs to act-as the SA when deploying gen2 functions
CLOUDBUILD_SA="service-${PROJECT_NUMBER}@gcp-sa-cloudbuild.iam.gserviceaccount.com"
info "Granting Cloud Build act-as on $SA_NAME"
gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" \
  --member="serviceAccount:$CLOUDBUILD_SA" \
  --role="roles/iam.serviceAccountUser" \
  --project="$PROJECT_ID" >/dev/null
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$CLOUDBUILD_SA" \
  --role="roles/cloudbuild.builds.builder" \
  --condition=None >/dev/null
ok "IAM bindings applied"

# ---------- deploy function ----------
echo
bold "Deploying Cloud Function (this takes a few minutes)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FUNCTION_DIR="$SCRIPT_DIR/function"
[[ -d "$FUNCTION_DIR" ]] || die "Function directory not found at $FUNCTION_DIR"

# Wait briefly for IAM to propagate before first deploy
sleep 15

FUNCTION_ENV="PROJECT_ID=$PROJECT_ID,ZONE=$ZONE,VM_NAME=$VM_NAME,IP_STRATEGY=$IP_STRATEGY,REGION=$REGION"
if [[ "$IP_STRATEGY" == "static-auto" ]]; then
  FUNCTION_ENV="${FUNCTION_ENV},STATIC_IP_NAME=$STATIC_IP_NAME"
fi

gcloud functions deploy "$FUNCTION_NAME" \
  --project="$PROJECT_ID" \
  --region="$FUNCTION_REGION" \
  --runtime=python311 \
  --trigger-topic="$TOPIC_NAME" \
  --entry-point=stop_vm \
  --service-account="$SA_EMAIL" \
  --set-env-vars="$FUNCTION_ENV" \
  --memory=256MB \
  --source="$FUNCTION_DIR" \
  --gen2 >/dev/null
ok "Function deployed"

# ---------- gen2 invoker bindings ----------
info "Granting Pub/Sub & Eventarc invoker on Cloud Run service"
PUBSUB_SA="service-${PROJECT_NUMBER}@gcp-sa-pubsub.iam.gserviceaccount.com"
EVENTARC_SA="service-${PROJECT_NUMBER}@gcp-sa-eventarc.iam.gserviceaccount.com"

for member in "$PUBSUB_SA" "$EVENTARC_SA" "$SA_EMAIL"; do
  gcloud run services add-iam-policy-binding "$FUNCTION_NAME" \
    --region="$FUNCTION_REGION" \
    --project="$PROJECT_ID" \
    --member="serviceAccount:$member" \
    --role="roles/run.invoker" >/dev/null
done
ok "Invoker bindings applied"

# ---------- summary ----------
EXTERNAL_IP="$(gcloud compute instances describe "$VM_NAME" \
  --zone="$ZONE" --project="$PROJECT_ID" \
  --format='value(networkInterfaces[0].accessConfigs[0].natIP)')"

case "$IP_STRATEGY" in
  ephemeral)
    SSH_HOST="$EXTERNAL_IP"
    IP_NOTE="Ephemeral IP (will change on reboot): $EXTERNAL_IP" ;;
  duckdns)
    SSH_HOST="${DUCKDNS_DOMAIN}.duckdns.org"
    IP_NOTE="Stable hostname: ${DUCKDNS_DOMAIN}.duckdns.org → ${EXTERNAL_IP} (updated every 5 min by VM)" ;;
  static)
    SSH_HOST="$EXTERNAL_IP"
    IP_NOTE="Static IP (free while VM runs, ~\$0.01/hr while stopped): $EXTERNAL_IP" ;;
  static-auto)
    SSH_HOST="$EXTERNAL_IP"
    IP_NOTE="Static IP (auto-released on shutdown): $EXTERNAL_IP — re-attach after restart, see notes" ;;
esac

echo
bold "Done!"
cat <<EOF

  VM:               $VM_NAME
  $IP_NOTE
  SSH:              ssh $SSH_USER@$SSH_HOST
  Budget:           $BUDGET_AMOUNT $CURRENCY → topic '$TOPIC_NAME' → function '$FUNCTION_NAME'

  Test the pipeline (this will stop your VM):
    gcloud pubsub topics publish $TOPIC_NAME \\
      --project=$PROJECT_ID \\
      --message='{"costAmount":999,"budgetAmount":1}'

  Restart the VM:
    gcloud compute instances start $VM_NAME --zone=$ZONE --project=$PROJECT_ID

EOF

if [[ "$IP_STRATEGY" == "static-auto" ]]; then
  cat <<EOF
  After a kill-switch firing, the static IP is released to stay fully free.
  To re-attach it on next start:

    gcloud compute instances delete-access-config $VM_NAME --zone=$ZONE \\
      --access-config-name="External NAT"
    gcloud compute addresses create $STATIC_IP_NAME --region=$REGION 2>/dev/null || true
    IP=\$(gcloud compute addresses describe $STATIC_IP_NAME --region=$REGION --format='value(address)')
    gcloud compute instances add-access-config $VM_NAME --zone=$ZONE \\
      --access-config-name="External NAT" --address=\$IP

EOF
fi
