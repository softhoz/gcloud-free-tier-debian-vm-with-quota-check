# GCP Free Tier Guard

One-shot setup script that creates a **GCP Always Free** VM and wires up an automated kill-switch that stops it the moment your billing exceeds a configurable threshold — so a misconfigured workload or surprise charge can never bleed your wallet.

## Architecture

```
Spend > threshold  →  Billing Budget  →  Pub/Sub topic  →  Cloud Function  →  VM stops
```

Every component sits inside its own free tier (Pub/Sub: 10 GB/mo, Cloud Functions: 2M invocations/mo, Budgets: always free), so the safety net itself costs nothing.

## What the script provisions

- An `e2-micro` VM in a free-tier-eligible US region with a 30 GB standard persistent disk (Debian 13), Shielded VM enabled, no service account attached
- Your SSH public key injected into instance metadata
- A Pub/Sub topic for billing alerts
- A Cloud Billing Budget with three threshold rules (1%, 50%, 100% of the configured amount)
- A dedicated service account with the minimum permissions needed to stop the VM
- A Cloud Function (Python 3.11, gen2) subscribed to the Pub/Sub topic
- All required IAM bindings for the gen2 function trigger (Eventarc + Pub/Sub invokers)
- All required APIs enabled (compute, billingbudgets, pubsub, cloudfunctions, run, cloudbuild, eventarc, iam)

## Prerequisites

- A Google Cloud account with billing enabled
- An existing GCP project (the script will use whichever project is currently active in `gcloud`)
- `gcloud` CLI installed and authenticated, OR run the script directly from [Cloud Shell](https://console.cloud.google.com/cloudshell)
- Project Owner or equivalent IAM role on the target project
- An SSH public key (the script will prompt for it)

## Quick start

```bash
git clone https://github.com/<your-user>/gcp-free-tier-guard.git
cd gcp-free-tier-guard
chmod +x setup.sh
./setup.sh
```

The script is fully interactive and will prompt for everything it needs:

| Prompt | Default | Notes |
|---|---|---|
| Project ID | current `gcloud` config | Press Enter to accept |
| Billing account | auto-detected (if only one) | Otherwise pick from list |
| VM name | `free-tier-vm` | |
| Zone | `us-east1-b` | Must be in `us-west1`, `us-central1`, or `us-east1` for free tier eligibility |
| Linux username for SSH | `$USER` | Used as the metadata key for your public key |
| SSH public key | — | Paste the full line (`ssh-ed25519 …` or `ssh-rsa …`) |
| Budget amount | `1` | In your billing account's native currency |
| Budget display name | `free-tier-guard` | |
| **External IP strategy** | `1` (ephemeral) | See table below |

Everything else (project number, currency code, service-account principals) is detected automatically.

## External IP strategy

By default, an `e2-micro`'s external IP changes after every reboot — including the reboots that happen when the kill-switch fires. The script offers four ways to handle this:

| Choice | Cost | Behavior | Best for |
|---|---|---|---|
| **1. ephemeral** | Free | IP changes on every restart | Throwaway / experimentation |
| **2. duckdns** | Free | Stable hostname (`yours.duckdns.org`) updated by VM cron | Long-running personal projects |
| **3. static** | Free while VM runs, ~$0.01/hr while stopped | IP never changes | Production-ish, accept small cost during outages |
| **4. static-auto** | Free always | IP is reserved on setup, attached to VM, **released by the kill-switch when it fires** | Strict zero-cost discipline |

For **duckdns**, you'll need to register a free account at [duckdns.org](https://www.duckdns.org/) (signs in with Google/GitHub), create a subdomain, and copy your token. The script bakes a 5-minute cron job into the VM's startup script that pushes the current IP to DuckDNS.

For **static-auto**, the Cloud Function additionally releases the reserved IP after stopping the VM, so you never pay for an idle address. When you want to bring the VM back up, the script's final summary prints the exact commands to re-reserve and re-attach the IP.

## What you get when it's done

- The VM running and reachable over SSH at `ssh <username>@<external-ip>`
- A summary printed to the terminal with the external IP, function name, and a one-line test command
- A working end-to-end pipeline you can verify by publishing a fake message to the topic:
  ```bash
  gcloud pubsub topics publish billing-alerts \
    --message='{"costAmount":999,"budgetAmount":1}'
  ```
  Within ~20 seconds the VM should transition to `TERMINATED`.

## Free tier eligibility notes

Google's [Always Free](https://cloud.google.com/free/docs/free-cloud-features#compute) tier covers, at the time of writing:

- 1 `e2-micro` instance per month, in `us-west1`, `us-central1`, or `us-east1`
- 30 GB of standard persistent disk
- 1 GB of egress from North America to all regions (excluding China and Australia)

The script provisions exactly these specs. Running anything larger, in another region, or for a second instance will incur charges — at which point the kill-switch fires.

## Restarting the VM

After a billing-triggered shutdown (or any other shutdown), bring the VM back with:

```bash
gcloud compute instances start <vm-name> --zone=<zone>
```

Note: stopping the VM does not stop disk billing. The 30 GB free disk allowance still covers it, but if you've gone over the threshold, address the root cause before restarting.

## Cleanup

To tear down everything the script created:

```bash
./teardown.sh
```

This deletes the VM, the Cloud Function, the Pub/Sub topic, the budget, and the service account. It does not disable the APIs (they're harmless when idle and re-enabling takes a few minutes).

## Limitations & caveats

- **Billing data lag.** GCP's billing pipeline updates every few hours, not in real time. The kill-switch fires within minutes of the budget *report* updating, but actual spend may have grown a bit further by then. This is a property of the platform, not the script.
- **Budget alerts are advisory.** The Pub/Sub message fires once per threshold crossing. Stopping the VM doesn't reset the budget; if you restart the VM and exceed the threshold again in the same billing cycle, no new alert fires for that threshold. Bumping the budget amount or waiting for the next month resets it.
- **Region.** The free-tier zones change occasionally. Verify against [Google's current free tier page](https://cloud.google.com/free/docs/free-cloud-features#compute) before deploying.
- **Single VM.** This script protects one named VM. To protect multiple instances, extend the function to iterate over a list, or to stop *all* instances in the project.

## File layout

```
.
├── README.md
├── setup.sh           # the main installer
├── teardown.sh        # removes everything setup.sh created
└── function/
    ├── main.py        # Cloud Function source
    └── requirements.txt
```

## License

MIT
