#!/usr/bin/env bash
#
# COL724 Assignment 1 - one-click ns-3 setup for Linux
#
#   ./setup_ns3.sh
#
# Installs dependencies, downloads ns-3.48, builds only the modules this
# assignment needs, and verifies the build by running the provided baseline.
# Safe to re-run: it skips work that is already done.
#
# Override the install location with:   NS3_DIR=/path/to/ns-3.48 ./setup_ns3.sh

set -euo pipefail

NS3_VERSION="ns-3.48"
NS3_DIR="${NS3_DIR:-$HOME/ns-3.48}"
NS3_MODULES="core;network;internet;point-to-point;applications;flow-monitor"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG="$SCRIPT_DIR/setup-ns3.log"
TOTAL_STEPS=6
START_TIME=$SECONDS

# ---------------------------------------------------------------- formatting
if [ -t 1 ]; then
  B=$'\033[1m'; DIM=$'\033[2m'; R=$'\033[31m'; G=$'\033[32m'
  Y=$'\033[33m'; C=$'\033[36m'; N=$'\033[0m'
else
  B=''; DIM=''; R=''; G=''; Y=''; C=''; N=''
fi

step()  { echo; echo "${B}${C}==> [$1/$TOTAL_STEPS] $2${N}"; }
info()  { echo "    $*"; }
run()   { echo "${DIM}    \$ $*${N}"; "$@"; }
ok()    { echo "${G}    OK  $*${N}"; }
warn()  { echo "${Y}    !!  $*${N}"; }
die()   { echo; echo "${R}${B}FAILED: $*${N}"; echo "Full log: $LOG"; exit 1; }
elapsed() { local s=$((SECONDS-START_TIME)); printf '%dm%02ds' $((s/60)) $((s%60)); }

trap 'die "step failed at line $LINENO (see log). Nothing was left half-installed \
that a re-run will not fix - just run this script again."' ERR

# true if $1 >= $2
version_ge() {
  [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" = "$2" ]
}

# ---------------------------------------------------------------- preamble
echo "${B}COL724 Assignment 1 - ns-3 setup${N}"
echo "${DIM}Target:  $NS3_VERSION"
echo "Install: $NS3_DIR"
echo "Log:     $LOG${N}"
echo
echo "This takes roughly 5-15 minutes, mostly the build in step 5."
echo "Output is verbose on purpose - if you see text moving, it is working."

if [ "${EUID:-$(id -u)}" -eq 0 ]; then
  die "Do not run this script as root. Run it as your normal user; it will ask for sudo when needed."
fi

echo
echo "Dependency installation needs sudo. You may be asked for your password now."
sudo -v || die "sudo is required to install packages."
# keep the sudo timestamp alive while we work
( while true; do sudo -n true 2>/dev/null; sleep 50; done ) &
SUDO_KEEPALIVE=$!
trap 'kill $SUDO_KEEPALIVE 2>/dev/null || true' EXIT

exec > >(tee "$LOG") 2>&1

# ---------------------------------------------------------------- 1. detect
step 1 "Detecting your system"

OS_NAME="$( (. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME") || uname -s)"
info "Distribution : $OS_NAME"
info "Kernel       : $(uname -r)"
info "CPU cores    : $(nproc)"
info "Free disk    : $(df -h "$HOME" | awk 'NR==2{print $4}')"

if   command -v apt-get >/dev/null 2>&1; then PKG=apt
elif command -v dnf     >/dev/null 2>&1; then PKG=dnf
elif command -v pacman  >/dev/null 2>&1; then PKG=pacman
elif command -v zypper  >/dev/null 2>&1; then PKG=zypper
else
  die "No supported package manager found (apt, dnf, pacman, zypper).
    Install these manually, then re-run: a C++ compiler, python3, cmake >= 3.25, ninja, git, tcpdump"
fi
info "Package tool : $PKG"
ok "system detected"

# ---------------------------------------------------------------- 2. install
step 2 "Installing dependencies"
info "Needed: C++ compiler, python3, cmake, ninja, git, tcpdump"

case "$PKG" in
  apt)
    run sudo apt-get update -qq
    run sudo apt-get install -y build-essential python3 cmake ninja-build git tcpdump
    ;;
  dnf)
    run sudo dnf install -y gcc-c++ python3 cmake ninja-build git tcpdump
    ;;
  pacman)
    run sudo pacman -S --needed --noconfirm base-devel python cmake ninja git tcpdump
    ;;
  zypper)
    run sudo zypper --non-interactive install gcc-c++ python3 cmake ninja git tcpdump
    ;;
esac
ok "dependencies installed"

# ---------------------------------------------------------------- 3. verify
step 3 "Checking tool versions"

GXX_VER="$(g++ -dumpversion 2>/dev/null || echo 0)"
CMAKE_VER="$(cmake --version 2>/dev/null | head -n1 | awk '{print $3}' || echo 0)"
PY_VER="$(python3 -c 'import sys;print("%d.%d"%sys.version_info[:2])' 2>/dev/null || echo 0)"

info "g++     $GXX_VER   (need >= 11.1)"
info "cmake   $CMAKE_VER   (need >= 3.25)"
info "python3 $PY_VER   (need >= 3.10)"

version_ge "$GXX_VER" "11.1" || die "g++ $GXX_VER is too old. ns-3.48 needs 11.1 or newer."
version_ge "$PY_VER"  "3.10" || die "python3 $PY_VER is too old. ns-3.48 needs 3.10 or newer."

if ! version_ge "$CMAKE_VER" "3.25"; then
  warn "cmake $CMAKE_VER is too old (Ubuntu 22.04 ships 3.22). Installing a newer one via pip."
  if ! pip install --user --quiet cmake 2>/dev/null; then
    run pip install --user --quiet --break-system-packages cmake
  fi
  export PATH="$HOME/.local/bin:$PATH"
  CMAKE_VER="$(cmake --version | head -n1 | awk '{print $3}')"
  version_ge "$CMAKE_VER" "3.25" || die "Could not obtain cmake >= 3.25. Install it manually and re-run."
  ok "cmake upgraded to $CMAKE_VER"
  warn "Add this line to your ~/.bashrc so cmake stays available in new terminals:"
  echo "        export PATH=\"\$HOME/.local/bin:\$PATH\""
fi
ok "all version requirements satisfied"

# ---------------------------------------------------------------- 4. download
step 4 "Downloading ns-3.48"

if [ -x "$NS3_DIR/ns3" ]; then
  info "Found an existing ns-3 at $NS3_DIR - skipping download."
  ok "already downloaded"
else
  [ -e "$NS3_DIR" ] && die "$NS3_DIR exists but does not look like ns-3. Move or delete it, then re-run."
  info "About 250 MB. Progress percentages appear below."
  run git clone --depth 1 --branch "$NS3_VERSION" --progress \
      https://gitlab.com/nsnam/ns-3-dev.git "$NS3_DIR"
  ok "downloaded to $NS3_DIR"
fi

cd "$NS3_DIR"

# ---------------------------------------------------------------- 5. build
step 5 "Configuring and building  ${DIM}(the long step - $(elapsed) elapsed so far)${N}"
info "Building only: $NS3_MODULES"
info "A full ns-3 build is 20-30 minutes; this is typically 3-8 minutes."
info "Do NOT use --build-profile=optimized - it silently disables NS_LOG output."
echo

run ./ns3 configure --enable-modules="$NS3_MODULES" --disable-examples --disable-tests

echo
info "Compiling with $(nproc) cores. The [n/m] counters below are your progress bar."
echo
run ./ns3 build
ok "build complete"

# ---------------------------------------------------------------- 6. verify
step 6 "Verifying with the provided baseline"

BASELINE=""
for cand in "$SCRIPT_DIR/bgp.cc" "$PWD/bgp.cc" "$SCRIPT_DIR/../bgp.cc"; do
  [ -f "$cand" ] && { BASELINE="$cand"; break; }
done

if [ -z "$BASELINE" ]; then
  warn "bgp.cc not found next to this script - skipping the verification run."
  warn "Copy bgp.cc into $NS3_DIR/scratch/ and run:  ./ns3 run scratch/bgp"
else
  info "Using baseline: $BASELINE"
  run cp "$BASELINE" "$NS3_DIR/scratch/"
  rm -f "$NS3_DIR/bgp-lite-results.xml"
  echo
  run ./ns3 run scratch/bgp
  echo
  [ -f "$NS3_DIR/bgp-lite-results.xml" ] \
    || die "The baseline ran but did not produce bgp-lite-results.xml. Something is wrong with the build."
  ok "baseline ran and produced bgp-lite-results.xml"
fi

# ---------------------------------------------------------------- done
echo
echo "${G}${B}================ SETUP COMPLETE (took $(elapsed)) ================${N}"
echo
echo "${B}ns-3 is installed at:${N} $NS3_DIR"
echo
echo "${B}To work on the assignment:${N}"
echo "  1. Put your scripts in   $NS3_DIR/scratch/"
echo "  2. Run them from         $NS3_DIR"
echo
echo "     cd $NS3_DIR"
echo "     ./ns3 run scratch/bgp_partB"
echo
echo "     # with command-line arguments, quote the whole thing:"
echo "     ./ns3 run \"scratch/bgp_partB --fastDirect=1\""
echo
echo "${B}Things that catch people out:${N}"
echo "  - Output files (.pcap, .xml) land in $NS3_DIR, NOT in scratch/"
echo "  - Interface 0 is always the loopback; interface 1 is the first link"
echo "  - Always run ./ns3 from $NS3_DIR, never from inside scratch/"
echo
echo "${DIM}A full log of this setup was saved to $LOG${N}"
