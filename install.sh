#!/usr/bin/env bash
# Roundtable installer.
#
#   curl -fsSL https://raw.githubusercontent.com/ZmagoD/roundtable/main/install.sh | bash
#
# Re-run it any time to update to the latest release. It installs into your
# home directory and never asks for sudo.
#
#   ROUNDTABLE_PREFIX    where the app lives   (default ~/.local/share/roundtable)
#   ROUNDTABLE_BIN_DIR   where the command goes (default ~/.local/bin)
#   ROUNDTABLE_REF       branch or tag to install (default main)
#   ROUNDTABLE_REPO      clone URL, for forks
set -euo pipefail

REPO="${ROUNDTABLE_REPO:-https://github.com/ZmagoD/roundtable.git}"
REF="${ROUNDTABLE_REF:-main}"
PREFIX="${ROUNDTABLE_PREFIX:-${XDG_DATA_HOME:-$HOME/.local/share}/roundtable}"
BIN_DIR="${ROUNDTABLE_BIN_DIR:-$HOME/.local/bin}"
MIN_ELIXIR="1.17.0"
PURGE=0
ACTION="install"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m==>\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m==>\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
Usage: install.sh [--uninstall [--purge]] [--ref <branch-or-tag>] [--prefix <dir>]

  (no arguments)  install, or update an existing install
  --uninstall     remove the roundtable command and the installed code,
                  keeping your rooms and messages
  --purge         with --uninstall, also delete your rooms and messages
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --uninstall) ACTION="uninstall"; shift ;;
    --purge)     PURGE=1; shift ;;
    --ref)       REF="${2:?--ref needs a value}"; shift 2 ;;
    --prefix)    PREFIX="${2:?--prefix needs a value}"; shift 2 ;;
    -h|--help)   usage; exit 0 ;;
    *)           usage; die "Unknown option: $1" ;;
  esac
done

STATE_DIR="$PREFIX/.local"

# Compares versions without assuming a particular numbering depth.
version_at_least() {
  [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" == "$2" ]]
}

stop_service() {
  if [[ -x "$PREFIX/bin/roundtable" ]]; then
    "$PREFIX/bin/roundtable" stop >/dev/null 2>&1 || true
  fi
}

if [[ "$ACTION" == "uninstall" ]]; then
  say "Stopping the service"
  stop_service
  rm -f "$BIN_DIR/roundtable"

  if [[ $PURGE -eq 1 ]]; then
    rm -rf "$PREFIX"
    say "Removed $PREFIX, rooms and messages included."
  elif [[ -d "$PREFIX" ]]; then
    find "$PREFIX" -mindepth 1 -maxdepth 1 ! -name '.local' -exec rm -rf {} +
    say "Removed the command and the code."
    say "Your rooms and messages are still in $STATE_DIR"
    say "Delete them with: rm -rf \"$PREFIX\""
  fi
  exit 0
fi

# --- preflight ---------------------------------------------------------------

[[ "$(uname -s)" == "Linux" ]] || die "Roundtable currently supports Linux only."

missing=()
for tool in git elixir mix erl python3; do
  command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done

if [[ ${#missing[@]} -gt 0 ]]; then
  warn "Missing: ${missing[*]}"
  cat >&2 <<'DEPS'

Roundtable needs Elixir (with Erlang/OTP), Git and Python 3. Install them with
your package manager, for example:

  Arch      sudo pacman -S elixir git python
  Debian    sudo apt install elixir erlang git python3
  Fedora    sudo dnf install elixir erlang git python3

or with a version manager such as mise (https://mise.jdx.dev):

  mise use -g erlang elixir

DEPS
  die "Install the missing tools and run this again."
fi

ELIXIR_VERSION="$(elixir --version | sed -n 's/^Elixir \([0-9.]*\).*/\1/p' | head -n1)"
[[ -n "$ELIXIR_VERSION" ]] || die "Could not read the Elixir version from 'elixir --version'."
version_at_least "$ELIXIR_VERSION" "$MIN_ELIXIR" ||
  die "Elixir $MIN_ELIXIR or newer is required; found $ELIXIR_VERSION."

say "Elixir $ELIXIR_VERSION, $(erl -noshell -eval 'io:format("Erlang/OTP ~s",[erlang:system_info(otp_release)]), halt().')"

# --- fetch -------------------------------------------------------------------

if [[ -d "$PREFIX/.git" ]]; then
  say "Updating $PREFIX"
  stop_service
  git -C "$PREFIX" fetch --quiet origin "$REF"
  git -C "$PREFIX" checkout --quiet "$REF"
  # A local build leaves the tree clean, so a fast-forward is always safe here.
  git -C "$PREFIX" merge --quiet --ff-only "origin/$REF" 2>/dev/null ||
    warn "Could not fast-forward $REF; staying on the current commit."
elif [[ -e "$PREFIX" ]]; then
  # `--uninstall` without `--purge` leaves the state directory behind. Install
  # around it rather than making the user move their own messages out of the way.
  if [[ -n "$(find "$PREFIX" -mindepth 1 -maxdepth 1 ! -name '.local' -print -quit)" ]]; then
    die "$PREFIX exists and is not a Roundtable checkout. Move it aside first."
  fi

  say "Reinstalling into $PREFIX, keeping the rooms already there"
  scratch="$(mktemp -d "${PREFIX}.XXXXXX")"
  git clone --quiet --branch "$REF" "$REPO" "$scratch/app"
  mv "$scratch/app/.git" "$PREFIX/.git"
  git -C "$PREFIX" checkout --quiet -- .
  rm -rf "$scratch"
else
  say "Cloning into $PREFIX"
  mkdir -p "$(dirname "$PREFIX")"
  git clone --quiet --branch "$REF" "$REPO" "$PREFIX"
fi

# --- build -------------------------------------------------------------------

say "Installing Hex and rebar"
mix local.hex --force --if-missing >/dev/null 2>&1
mix local.rebar --force --if-missing >/dev/null 2>&1

say "Building the release (this takes a minute)"
build_log="$(mktemp)"
trap 'rm -f "$build_log"' EXIT

if ! "$PREFIX/bin/roundtable" setup >"$build_log" 2>&1; then
  tail -n 40 "$build_log" >&2
  die "Build failed. Full log: $build_log"
fi

# --- link --------------------------------------------------------------------

mkdir -p "$BIN_DIR"
ln -sf "$PREFIX/bin/roundtable" "$BIN_DIR/roundtable"
say "Linked $BIN_DIR/roundtable"

echo
bold "Roundtable is installed."
echo
echo "  roundtable start     start the service"
echo "  roundtable tui       open the terminal client"
echo "  roundtable status    check on it, and print the browser URL"
echo "  roundtable stop      stop it"
echo
echo "Your rooms and messages live in $STATE_DIR"
echo "Log in to each agent CLI (codex, claude, opencode) in a terminal first;"
echo "Roundtable uses their existing credentials and stores no API keys."

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    echo
    warn "$BIN_DIR is not on your PATH. Add it:"
    echo "    echo 'export PATH=\"$BIN_DIR:\$PATH\"' >> ~/.bashrc && exec bash"
    ;;
esac
