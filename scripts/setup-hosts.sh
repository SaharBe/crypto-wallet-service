#!/usr/bin/env bash
# Adds /etc/hosts entries for the Ingress hostnames defined under
# k8s/apps/ingress/ (argocd.local, grafana.local, vault.local, wallet.local),
# pointing them at 127.0.0.1. That's the address that resolves once
# `make ingress-forward` (or a manual
# `kubectl port-forward svc/ingress-nginx-controller -n ingress-nginx`) is
# running — this repo targets a real EKS cluster with no local node IP to
# point at instead. Idempotent: safe to re-run, only ever adds missing
# entries inside a clearly marked block, never touches anything else in the
# file.
#
# Invoked by `make setup-hosts` and, best-effort, at the end of
# bootstrap.sh's Step 11.
set -euo pipefail

HOSTS_FILE="${HOSTS_FILE:-/etc/hosts}"
TARGET_IP="${TARGET_IP:-127.0.0.1}"
MARKER_START="# >>> crypto-wallet-service local ingress hosts >>>"
MARKER_END="# <<< crypto-wallet-service local ingress hosts <<<"
DOMAINS=(argocd.local grafana.local vault.local wallet.local)

missing=()
for domain in "${DOMAINS[@]}"; do
  if ! grep -qE "^[^#]*\b${domain}\b" "$HOSTS_FILE"; then
    missing+=("$domain")
  fi
done

if [ "${#missing[@]}" -eq 0 ]; then
  echo "✅ All local ingress hostnames already present in $HOSTS_FILE."
  exit 0
fi

echo "🔧 Adding ${#missing[@]} missing host entr$([ "${#missing[@]}" -eq 1 ] && echo y || echo ies) to $HOSTS_FILE: ${missing[*]}"

block="$(
  echo "$MARKER_START"
  for domain in "${missing[@]}"; do
    echo "$TARGET_IP $domain"
  done
  echo "$MARKER_END"
)"

if [ -w "$HOSTS_FILE" ]; then
  printf '\n%s\n' "$block" >> "$HOSTS_FILE"
else
  echo "🔑 $HOSTS_FILE isn't writable — requesting sudo..."
  printf '\n%s\n' "$block" | sudo tee -a "$HOSTS_FILE" > /dev/null
fi

echo "✅ Done. Verify with: grep -A ${#DOMAINS[@]} '$MARKER_START' $HOSTS_FILE"
