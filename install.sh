#!/usr/bin/env bash
#
# Install and start Vanika on macOS or Linux, then open it in your browser.
#
#   curl -fsSL https://raw.githubusercontent.com/<org>/VanikaAi/V2/install.sh | bash
#
# or, from a clone:
#
#   ./install.sh
#
# It detects the operating system and package manager, installs only what is
# missing, generates the secrets it needs, waits for every service to answer,
# and opens the browser. Re-running it is safe and is also how you update:
# nothing already correct is reinstalled, and .env.docker is never overwritten.
#
#   --repair        diagnose an existing install and fix what it can
#   --no-browser    do not open a browser (servers, CI)
#   --no-build      start from existing images instead of rebuilding
#   --yes           never prompt; assume yes (unattended)
#
set -euo pipefail

REPO_URL="${VANIKA_REPO:-https://github.com/adityapuppala1/VanikaAi.git}"
BRANCH="${VANIKA_BRANCH:-V2}"
APP_URL="http://localhost:8080"
GATEWAY_HEALTH="http://localhost:3001/v1/health"

REPAIR=0; OPEN_BROWSER=1; BUILD=1; ASSUME_YES=0
for arg in "$@"; do
  case "$arg" in
    --repair) REPAIR=1 ;;
    --no-browser) OPEN_BROWSER=0 ;;
    --no-build) BUILD=0 ;;
    --yes|-y) ASSUME_YES=1 ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

if [ -t 1 ]; then
  C_GRAY=$'\033[90m'; C_CYAN=$'\033[36m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_OFF=$'\033[0m'
else
  C_GRAY=""; C_CYAN=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_OFF=""
fi
say()  { printf '  %s%s%s\n' "$C_GRAY" "$*" "$C_OFF"; }
step() { printf '\n%s> %s%s\n' "$C_CYAN" "$*" "$C_OFF"; }
good() { printf '  %sok  %s%s\n' "$C_GREEN" "$*" "$C_OFF"; }
warn() { printf '  %s!   %s%s\n' "$C_YELLOW" "$*" "$C_OFF"; }
die()  { printf '\n%sx  %s%s\n' "$C_RED" "$*" "$C_OFF"; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

SUDO=""
if [ "$(id -u)" -ne 0 ] && have sudo; then SUDO="sudo"; fi

# ------------------------------------------------------------ detect ------
step "Checking this machine"

OS="unknown"; DISTRO=""; PKG=""
case "$(uname -s)" in
  Darwin) OS="macos"; PKG="brew" ;;
  Linux)
    OS="linux"
    if [ -r /etc/os-release ]; then . /etc/os-release; DISTRO="${ID:-linux}"; fi
    if   have apt-get; then PKG="apt"
    elif have dnf;     then PKG="dnf"
    elif have yum;     then PKG="yum"
    elif have pacman;  then PKG="pacman"
    elif have zypper;  then PKG="zypper"
    elif have apk;     then PKG="apk"
    fi
    ;;
  *) die "Unsupported system: $(uname -s). Windows users should run install.ps1." ;;
esac

ARCH="$(uname -m)"
say "$OS ${DISTRO:+($DISTRO) }on $ARCH, package manager: ${PKG:-none found}"

# Memory and disk, so a machine that cannot run this says so before installing.
if [ "$OS" = "macos" ]; then
  MEM_GB=$(( $(sysctl -n hw.memsize) / 1024 / 1024 / 1024 ))
else
  MEM_GB=$(( $(awk '/MemTotal/ {print $2}' /proc/meminfo) / 1024 / 1024 ))
fi
DISK_GB=$(df -Pk . | awk 'NR==2 {printf "%d", $4/1024/1024}')
say "${MEM_GB} GB RAM, ${DISK_GB} GB free here"
[ "$MEM_GB" -lt 8 ] && warn "8 GB or more is recommended; builds will be slow on ${MEM_GB} GB."
[ "$DISK_GB" -lt 20 ] && warn "Docker images need roughly 20 GB; ${DISK_GB} GB free."

# ------------------------------------------------------------ install ----
pkg_install() {
  local name="$1"
  case "$PKG" in
    brew)   brew install "$name" ;;
    apt)    $SUDO apt-get update -qq && $SUDO DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$name" ;;
    dnf)    $SUDO dnf install -y -q "$name" ;;
    yum)    $SUDO yum install -y -q "$name" ;;
    pacman) $SUDO pacman -Sy --noconfirm --quiet "$name" ;;
    zypper) $SUDO zypper --non-interactive --quiet install "$name" ;;
    apk)    $SUDO apk add --quiet "$name" ;;
    *) return 1 ;;
  esac
}

need() {
  local cmd="$1" pkgname="${2:-$1}" friendly="${3:-$1}"
  if have "$cmd"; then good "$friendly is already installed"; return 0; fi
  if [ -z "$PKG" ]; then warn "$friendly is missing and no package manager was found."; return 1; fi
  say "Installing $friendly ..."
  if pkg_install "$pkgname" >/dev/null 2>&1 && have "$cmd"; then good "$friendly installed"; return 0; fi
  warn "Could not install $friendly automatically."
  return 1
}

step "Dependencies"
if [ "$OS" = "macos" ] && ! have brew; then
  warn "Homebrew is not installed; it is the simplest way to get the rest."
  say  'Install it with: /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
fi
need git git Git || die "Git is required."
need curl curl curl || true

# ------------------------------------------------------------ docker -----
step "Docker"
if ! have docker; then
  case "$OS" in
    macos)
      warn "Docker Desktop is not installed."
      if have brew; then
        say "Installing Docker Desktop ..."
        brew install --cask docker || die "Install Docker Desktop from https://docs.docker.com/desktop/install/mac-install/"
        warn "Start Docker Desktop once to finish its setup, then re-run this script."
        exit 0
      fi
      die "Install Docker Desktop from https://docs.docker.com/desktop/install/mac-install/ and re-run."
      ;;
    linux)
      say "Installing Docker Engine from the official convenience script ..."
      if [ "$ASSUME_YES" -ne 1 ]; then
        printf '  This runs get.docker.com as root. Continue? [y/N] '
        read -r reply </dev/tty || reply=""
        case "$reply" in [yY]*) ;; *) die "Install Docker yourself, then re-run." ;; esac
      fi
      curl -fsSL https://get.docker.com | $SUDO sh || die "Docker installation failed."
      $SUDO usermod -aG docker "$(id -un)" 2>/dev/null || true
      $SUDO systemctl enable --now docker 2>/dev/null || true
      warn "You were added to the 'docker' group. Log out and back in if the next step is denied."
      ;;
  esac
fi
have docker || die "Docker is still not available."

# The daemon may still be starting, especially just after installation.
deadline=$(( $(date +%s) + 180 ))
until docker info >/dev/null 2>&1; do
  [ "$(date +%s)" -ge "$deadline" ] && die "The Docker daemon did not come up. Start Docker and re-run."
  say "Waiting for the Docker daemon ..."
  sleep 5
done
good "Docker $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo running)"

docker compose version >/dev/null 2>&1 || die "The Docker Compose plugin is missing. Install docker-compose-plugin and re-run."

# ------------------------------------------------------------ source ----
step "Source"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
if [ ! -f "$ROOT/docker-compose.yml" ]; then
  ROOT="$PWD/VanikaAi"
  if [ -d "$ROOT/.git" ]; then
    say "Updating the existing clone ..."
    git -C "$ROOT" fetch --quiet origin "$BRANCH"
    git -C "$ROOT" checkout --quiet "$BRANCH"
    git -C "$ROOT" pull --quiet --ff-only origin "$BRANCH"
  else
    say "Cloning into $ROOT ..."
    git clone --quiet --branch "$BRANCH" "$REPO_URL" "$ROOT"
  fi
fi
cd "$ROOT"
good "Using $ROOT"

# ------------------------------------------------------------ secrets ---
step "Configuration"
if [ -f .env.docker ]; then
  good ".env.docker already exists and was left untouched"
else
  [ -f .env.docker.example ] || die "No .env.docker.example to work from."
  gen() { head -c 32 /dev/urandom | base64 | tr '+/' '-_' | tr -d '='; }
  while IFS= read -r line; do
    case "$line" in
      INTERNAL_API_KEY=*)          printf 'INTERNAL_API_KEY=%s\n' "$(gen)" ;;
      PROVIDER_ENCRYPTION_KEY=*)   printf 'PROVIDER_ENCRYPTION_KEY=%s\n' "$(gen)" ;;
      APP_DB_PASSWORD=*)           printf 'APP_DB_PASSWORD=%s\n' "$(gen)" ;;
      *) printf '%s\n' "$line" ;;
    esac
  done < .env.docker.example > .env.docker
  # Anything the example does not carry yet is appended, so an older template
  # still produces a complete configuration.
  for key in INTERNAL_API_KEY PROVIDER_ENCRYPTION_KEY APP_DB_PASSWORD; do
    grep -q "^${key}=" .env.docker || printf '%s=%s
' "$key" "$(gen)" >> .env.docker
  done
  grep -q '^PUBLIC_APP_URL=' .env.docker || printf 'PUBLIC_APP_URL=%s
' "$APP_URL" >> .env.docker
  chmod 600 .env.docker
  good "Created .env.docker with freshly generated secrets"
  warn "Add your Supabase URL and keys to .env.docker before signing in."
fi

# ------------------------------------------------------------ repair ---
if [ "$REPAIR" -eq 1 ]; then
  step "Repairing"
  say "Reclaiming build cache ..."
  docker builder prune -af 2>/dev/null | tail -1 || true
  say "Restarting anything unhealthy ..."
  docker compose ps --format '{{.Service}} {{.Status}}' 2>/dev/null | while read -r svc status; do
    case "$status" in Up*) ;; *) say "restarting $svc"; docker compose restart "$svc" >/dev/null 2>&1 || true ;; esac
  done
fi

# ------------------------------------------------------------ one only --
# Refuse to stand up a second copy. See scripts/preflight.sh for what this
# checks and why each check exists.
step "Making sure only one Vanika runs"
if [ -f "$ROOT/scripts/preflight.sh" ]; then
  # shellcheck source=scripts/preflight.sh
  . "$ROOT/scripts/preflight.sh"
  preflight_all
  good "no conflicting stack or port"
else
  warn "scripts/preflight.sh is missing; skipping the duplicate check"
fi

# ------------------------------------------------------------ start ----
step "Starting Vanika"
[ "$BUILD" -eq 1 ] && say "The first run builds images and takes several minutes."
if [ "$BUILD" -eq 1 ]; then
  docker compose up -d --build || die "The stack did not start. Run 'docker compose logs' to see why."
else
  docker compose up -d || die "The stack did not start."
fi

# ------------------------------------------------------------ wait ----
step "Waiting for the services"
deadline=$(( $(date +%s) + 300 ))
ready=0
while [ "$(date +%s)" -lt "$deadline" ]; do
  if curl -fsS -o /dev/null --max-time 5 "$GATEWAY_HEALTH" 2>/dev/null &&
     curl -fsS -o /dev/null --max-time 5 "$APP_URL" 2>/dev/null; then
    ready=1; break
  fi
  say "not ready yet ..."
  sleep 5
done

if [ "$ready" -ne 1 ]; then
  # A container that is Up but unreachable from the host almost always means
  # stale port forwarding, which is what a `wsl --shutdown` leaves behind on
  # Windows: Docker still reports the ports as published and the service answers
  # inside the network, but nothing forwards from the host. Recreating the
  # containers re-establishes it, so try that once before giving up.
  if docker compose ps --format '{{.Status}}' 2>/dev/null | grep -q '^Up'; then
    warn "Services are running but not answering; re-establishing port publishing ..."
    docker compose up -d --force-recreate >/dev/null 2>&1 || true
    sleep 20
    deadline=$(( $(date +%s) + 120 ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
      if curl -fsS -o /dev/null --max-time 5 "$GATEWAY_HEALTH" 2>/dev/null &&
         curl -fsS -o /dev/null --max-time 5 "$APP_URL" 2>/dev/null; then
        ready=1; good "recovered after re-publishing the ports"; break
      fi
      sleep 5
    done
  fi
fi

if [ "$ready" -ne 1 ]; then
  warn "The services did not answer in time."
  say  "docker compose ps        - what is running"
  say  "docker compose logs -f   - why something is not"
  say  "./install.sh --repair    - try to fix it automatically"
  exit 1
fi
good "Gateway and web app are answering"

# ------------------------------------------------------------ done ---
printf '\n  %sVanika is running.%s\n' "$C_GREEN" "$C_OFF"
printf '  %s\n\n' "$APP_URL"
say "docker compose logs -f   follow the logs"
say "docker compose down      stop everything"
say "./install.sh --repair    diagnose and fix"

if [ "$OPEN_BROWSER" -eq 1 ]; then
  if   have open;      then open "$APP_URL" >/dev/null 2>&1 || true
  elif have xdg-open;  then xdg-open "$APP_URL" >/dev/null 2>&1 || true
  else say "Open $APP_URL in your browser."
  fi
fi
