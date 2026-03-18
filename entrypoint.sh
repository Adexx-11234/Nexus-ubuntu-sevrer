#!/usr/bin/env bash
# ============================================================
#  entrypoint.sh
#  Starts: SSH server | QEMU/KVM | Tailscale | sshx
# ============================================================
set -e

RED='\033[0;31m'
GRN='\033[0;32m'
YEL='\033[1;33m'
BLU='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${GRN}[+]${NC} $*"; }
warn() { echo -e "${YEL}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*"; }
head() { echo -e "\n${BLU}══════════════════════════════════════════${NC}"; \
         echo -e "${BLU}  $*${NC}"; \
         echo -e "${BLU}══════════════════════════════════════════${NC}"; }

# ─── Validate required env vars ───────────────────────────────
: "${SSH_PASSWORD:?SSH_PASSWORD must be set in .env}"
: "${TAILSCALE_AUTHKEY:?TAILSCALE_AUTHKEY must be set in .env}"

# ─── 1. Set root SSH password ─────────────────────────────────
head "SSH Server"
echo "root:${SSH_PASSWORD}" | chpasswd
log "Root password configured."

# Re-generate host keys if missing
ssh-keygen -A 2>/dev/null || true

service ssh start && log "OpenSSH started." || warn "SSH may already be running."

# ─── 2. Force QEMU / KVM setup (aggressive multi-method) ─────
head "QEMU / KVM — Forced Setup"

kvm_active=false

# ── Method 1: Already present ─────────────────────────────────
if [ -e /dev/kvm ] && [ -r /dev/kvm ]; then
    log "Method 1: /dev/kvm already present and readable."
    kvm_active=true
fi

# ── Method 2: Load kernel modules then check again ─────────────
if [ "$kvm_active" = false ]; then
    warn "Method 2: /dev/kvm missing – loading kernel modules…"
    modprobe kvm          2>/dev/null && log "  ✓ kvm base module loaded"       || warn "  ✗ kvm base module failed"
    modprobe kvm_intel nested=1 2>/dev/null && log "  ✓ kvm_intel (nested=1) loaded" || warn "  ✗ kvm_intel not available (may be AMD host)"
    modprobe kvm_amd   nested=1 2>/dev/null && log "  ✓ kvm_amd (nested=1) loaded"   || warn "  ✗ kvm_amd not available (may be Intel host)"
    # Also try loading vhost modules for better networking performance
    modprobe vhost      2>/dev/null || true
    modprobe vhost_net  2>/dev/null || true
    sleep 1
    if [ -e /dev/kvm ]; then
        log "  /dev/kvm appeared after loading modules!"
        kvm_active=true
    fi
fi

# ── Method 3: mknod using /proc/misc dynamic minor number ──────
# /proc/misc lists the actual minor number the kernel registered for kvm
if [ "$kvm_active" = false ]; then
    warn "Method 3: Creating /dev/kvm node via mknod + /proc/misc…"
    KVM_MINOR=$(grep -w 'kvm' /proc/misc 2>/dev/null | awk '{print $1}')
    if [ -n "$KVM_MINOR" ]; then
        log "  Found KVM in /proc/misc with minor number: ${KVM_MINOR}"
        mknod /dev/kvm c 10 "${KVM_MINOR}" 2>/dev/null && \
            chmod 666 /dev/kvm && \
            log "  ✓ /dev/kvm created via mknod (minor=${KVM_MINOR})" || \
            warn "  ✗ mknod failed (need --privileged)"
        if [ -e /dev/kvm ]; then
            # Quick test: dd from /dev/kvm to confirm it actually works
            if dd if=/dev/kvm count=0 2>/dev/null; then
                log "  ✓ /dev/kvm is readable and functional!"
                kvm_active=true
            else
                warn "  ✗ /dev/kvm exists but is not accessible (kernel module not loaded on host)"
                rm -f /dev/kvm
            fi
        fi
    else
        warn "  kvm not found in /proc/misc — host kernel has no KVM module loaded at all."
    fi
fi

# ── Method 4: mknod with hardcoded fallback minor (232) ────────
if [ "$kvm_active" = false ]; then
    warn "Method 4: Trying mknod with hardcoded minor 232 (common default)…"
    mknod /dev/kvm c 10 232 2>/dev/null && chmod 666 /dev/kvm || true
    if [ -e /dev/kvm ]; then
        if dd if=/dev/kvm count=0 2>/dev/null; then
            log "  ✓ /dev/kvm functional with minor=232!"
            kvm_active=true
        else
            warn "  ✗ /dev/kvm node created but not functional – removing stub."
            rm -f /dev/kvm
        fi
    fi
fi

# ── Final KVM status report ────────────────────────────────────
echo ""
if [ "$kvm_active" = true ]; then
    chmod 666 /dev/kvm 2>/dev/null || true
    NESTED_INTEL=$(cat /sys/module/kvm_intel/parameters/nested 2>/dev/null || echo "N/A")
    NESTED_AMD=$(cat /sys/module/kvm_amd/parameters/nested   2>/dev/null || echo "N/A")
    echo -e "  ${GRN}╔══════════════════════════════════════════════╗${NC}"
    echo -e "  ${GRN}║  ✅ KVM IS ACTIVE — Hardware acceleration ON ║${NC}"
    echo -e "  ${GRN}║  Nested virt Intel: ${NESTED_INTEL}  AMD: ${NESTED_AMD}          ║${NC}"
    echo -e "  ${GRN}╚══════════════════════════════════════════════╝${NC}"
else
    echo -e "  ${YEL}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "  ${YEL}║  ⚠  KVM NOT AVAILABLE — Using QEMU TCG (software mode) ║${NC}"
    echo -e "  ${YEL}║                                                          ║${NC}"
    echo -e "  ${YEL}║  To get real KVM, your HOST machine must:                ║${NC}"
    echo -e "  ${YEL}║   1. Have an Intel/AMD CPU with VT-x / AMD-V             ║${NC}"
    echo -e "  ${YEL}║   2. Have KVM enabled in BIOS/UEFI                       ║${NC}"
    echo -e "  ${YEL}║   3. Run: modprobe kvm_intel nested=1  (on the HOST)     ║${NC}"
    echo -e "  ${YEL}║   4. Pass --device /dev/kvm to this container            ║${NC}"
    echo -e "  ${YEL}║                                                          ║${NC}"
    echo -e "  ${YEL}║  QEMU still works — just slower for nested VMs.          ║${NC}"
    echo -e "  ${YEL}╚══════════════════════════════════════════════════════════╝${NC}"
fi
echo ""

# Enable ignore_msrs for better KVM guest compat
echo 1 > /sys/module/kvm/parameters/ignore_msrs 2>/dev/null || true

# Start libvirtd daemon
if command -v libvirtd &>/dev/null; then
    libvirtd --daemon 2>/dev/null && log "libvirtd started." || warn "libvirtd already running or unavailable."
    sleep 1
fi

# ─── 3. Tailscale ────────────────────────────────────────────
head "Tailscale"

# Tailscale requires /dev/tun and iptables – enable if possible
mkdir -p /dev/net
[ -e /dev/net/tun ] || (mknod /dev/net/tun c 10 200 && chmod 666 /dev/net/tun) 2>/dev/null || warn "Could not create /dev/net/tun (may already exist)."

# Start the tailscale daemon in the background
tailscaled --state=/var/lib/tailscale/tailscaled.state \
           --socket=/var/run/tailscale/tailscaled.sock \
           --tun=userspace-networking \
           2>/tmp/tailscaled.log &

TAILSCALED_PID=$!
log "tailscaled started (PID ${TAILSCALED_PID})."
sleep 3

mkdir -p /var/run/tailscale

# Authenticate / bring up the interface
if tailscale up \
      --authkey="${TAILSCALE_AUTHKEY}" \
      --hostname="ubuntu-server-docker" \
      --accept-routes \
      --accept-dns \
      2>/tmp/tailscale-up.log; then
    log "Tailscale connected!"
    TS_IP=$(tailscale ip -4 2>/dev/null || echo "pending…")
    log "Tailscale IPv4: ${TS_IP}"
    echo ""
    echo -e "  ${GRN}╔══════════════════════════════════════════════╗${NC}"
    echo -e "  ${GRN}║  SSH via Tailscale:                          ║${NC}"
    echo -e "  ${GRN}║  ssh root@${TS_IP}                    ║${NC}"
    echo -e "  ${GRN}╚══════════════════════════════════════════════╝${NC}"
else
    warn "Tailscale up failed – check /tmp/tailscale-up.log"
    cat /tmp/tailscale-up.log || true
fi

# ─── 4. sshx – web terminal link ─────────────────────────────
head "sshx (Web Terminal)"

log "Installing sshx…"
curl -sSf https://sshx.io/get | sh 2>/dev/null || warn "sshx download failed."

if command -v sshx &>/dev/null; then
    log "Launching sshx and printing link…"
    echo ""
    # Run sshx in background; its output (the URL) is tee'd to both stdout and a log file
    sshx 2>&1 | tee /tmp/sshx.log &
    sleep 5   # give it time to print the URL
    echo ""
    SSHX_URL=$(grep -oP 'https://sshx\.io/s/\S+' /tmp/sshx.log 2>/dev/null | head -1 || echo "see /tmp/sshx.log")
    echo -e "  ${YEL}╔══════════════════════════════════════════════╗${NC}"
    echo -e "  ${YEL}║  sshx WEB TERMINAL LINK:                     ║${NC}"
    echo -e "  ${YEL}║  ${SSHX_URL}  ║${NC}"
    echo -e "  ${YEL}╚══════════════════════════════════════════════╝${NC}"
    echo ""
else
    warn "sshx binary not found after install."
fi

# ─── 5. Summary ───────────────────────────────────────────────
head "Container Ready"
log "All services started. Container is live."
log "──────────────────────────────────────────"
log "  SSH password : ${SSH_PASSWORD}"
log "  SSH port     : 22 (mapped to host via docker-compose)"
log "  Tailscale IP : $(tailscale ip -4 2>/dev/null || echo 'check Tailscale admin')"
log "  sshx link    : ${SSHX_URL:-see /tmp/sshx.log}"
log "──────────────────────────────────────────"

# ─── 6. Keep container alive ─────────────────────────────────
exec tail -f /dev/null
