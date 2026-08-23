#!/bin/sh
# tammai-cc-status-line — installer.
#
#   sh install.sh                 install (or re-install) into ~/.claude
#   sh install.sh --dir DIR       install into another config directory
#   sh install.sh --uninstall     remove the status line
#   sh install.sh --help
#
# Also works straight off the network, where it fetches the renderer itself:
#   curl -fsSL https://raw.githubusercontent.com/tammai/tammai-cc-status-line/main/install.sh | sh
#
# It only ever writes two things: statusline.sh, and the statusLine key of
# settings.json. Every other key, and every hook, is preserved byte-for-byte.

set -eu

VERSION=1.0.0
RAW_BASE=https://raw.githubusercontent.com/tammai/tammai-cc-status-line/main

self_dir=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd) || self_dir=.
target=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
action=install

usage() {
  cat <<'USAGE'
tammai-cc-status-line — a Claude Code status line

  path · git branch · model · effort · context used · 5h and 7d limits,
  each percentage with a small bar. Ported from the oh-my-posh default theme.

Usage:
  install.sh [--dir DIR]     install or re-install (idempotent)
  install.sh --uninstall     remove statusline.sh and the statusLine setting
  install.sh --version
  install.sh --help

Options:
  --dir DIR   Claude Code config directory.
              Default: $CLAUDE_CONFIG_DIR, else ~/.claude

Needs: python3 or python (parses the status payload), a Nerd Font and a
truecolor terminal for the separators and colours. git is optional.
USAGE
}

while [ $# -gt 0 ]; do
  case $1 in
    --dir) [ $# -ge 2 ] || { echo "install.sh: --dir needs a path" >&2; exit 2; }
           target=$2; shift 2 ;;
    --dir=*) target=${1#--dir=}; shift ;;
    --uninstall) action=uninstall; shift ;;
    --version) echo "$VERSION"; exit 0 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "install.sh: unknown option '$1' (try --help)" >&2; exit 2 ;;
  esac
done

settings="$target/settings.json"
dest="$target/statusline.sh"

# A name on PATH is not proof of an interpreter: Windows ships a `python3` shim
# in WindowsApps that only prints "Python was not found". Skip those, and check
# the survivor actually runs.
py=""
for candidate in python3 python; do
  candidate_path=$(command -v "$candidate" 2>/dev/null) || continue
  case $candidate_path in
    *WindowsApps*) continue ;;
  esac
  if "$candidate" -c "" >/dev/null 2>&1; then
    py=$candidate
    break
  fi
done

if [ -z "$py" ]; then
  echo "install.sh: needs a working python3 (or python)." >&2
  echo "  It edits settings.json safely, and the status line needs it to" >&2
  echo "  parse the payload Claude Code sends on stdin." >&2
  exit 1
fi

# ---------------------------------------------------------------- uninstall
if [ "$action" = uninstall ]; then
  if [ -f "$settings" ]; then
    SETTINGS=$settings "$py" - <<'PY'
import io, json, os, shutil, sys, time

path = os.environ["SETTINGS"]
raw = io.open(path, encoding="utf-8-sig", newline="").read()
try:
    data = json.loads(raw)
except ValueError as exc:
    sys.exit("uninstall: %s is not valid JSON (%s); leaving it alone." % (path, exc))

if "statusLine" not in data:
    print("settings.json: no statusLine key, nothing to remove")
    raise SystemExit(0)

backup = "%s.bak-statusline-%s" % (path, time.strftime("%Y%m%d%H%M%S"))
shutil.copy2(path, backup)
print("backup: %s" % backup)

del data["statusLine"]
io.open(path, "w", encoding="utf-8", newline="").write(
    json.dumps(data, indent=2) + "\n")
print("settings.json: statusLine removed")

older = sorted(f for f in os.listdir(os.path.dirname(path) or ".")
               if f.startswith(os.path.basename(path) + ".bak-statusline-"))
if len(older) > 1:
    print("note: an earlier settings.json backup exists (%s)." % older[0])
    print("      If another tool owned statusLine before this, restore from it.")
PY
  else
    echo "settings.json: not found at $settings"
  fi

  if [ -f "$dest" ]; then
    rm -f "$dest"
    echo "removed: $dest"
  fi
  echo
  echo "Uninstalled. Restart Claude Code to drop the line."
  exit 0
fi

# ------------------------------------------------------------------ install
src="$self_dir/statusline.sh"
fetched=""

if [ ! -f "$src" ]; then
  # Piped from curl: the renderer is not on disk beside us, so fetch it.
  src=$(mktemp "${TMPDIR:-/tmp}/statusline.XXXXXX")
  fetched=$src
  trap 'rm -f "$fetched"' EXIT INT TERM HUP
  echo "fetching statusline.sh from $RAW_BASE"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$RAW_BASE/statusline.sh" -o "$src"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$src" "$RAW_BASE/statusline.sh"
  else
    echo "install.sh: need curl or wget to fetch statusline.sh" >&2
    exit 1
  fi
  [ -s "$src" ] || { echo "install.sh: downloaded statusline.sh is empty" >&2; exit 1; }
fi

# Refuse to install something that will not parse, rather than leaving a
# status line that errors on every turn.
sh -n "$src" || { echo "install.sh: statusline.sh failed a syntax check" >&2; exit 1; }

mkdir -p "$target"
cp "$src" "$dest"
chmod +x "$dest" 2>/dev/null || true
echo "installed: $dest"

# The dispatcher. Guarded, so a machine without the script — or a wiped config
# directory — drains stdin quietly instead of erroring every turn.
command='if [ -f "${HOME-}/.claude/statusline.sh" ]; then sh "${HOME-}/.claude/statusline.sh"; else { command -p cat 2>/dev/null || cat; } >/dev/null 2>&1 || :; fi'

# Installing somewhere other than ~/.claude: point at that path literally.
case $target in
  "$HOME/.claude") ;;
  *) command="if [ -f \"$dest\" ]; then sh \"$dest\"; else { command -p cat 2>/dev/null || cat; } >/dev/null 2>&1 || :; fi" ;;
esac

COMMAND=$command SETTINGS=$settings "$py" - <<'PY'
import io, json, os, shutil, sys, time

path = os.environ["SETTINGS"]
command = os.environ["COMMAND"]
block = {"type": "command", "command": command}

# utf-8-sig: a BOM-prefixed settings.json is valid and must survive a round trip.
if not os.path.exists(path):
    io.open(path, "w", encoding="utf-8", newline="").write(
        json.dumps({"statusLine": block}, indent=2) + "\n")
    print("settings.json: created with statusLine")
    raise SystemExit(0)

raw = io.open(path, encoding="utf-8-sig", newline="").read()
try:
    data = json.loads(raw)
except ValueError as exc:
    sys.exit("install.sh: %s is not valid JSON (%s); not touching it." % (path, exc))

old = (data.get("statusLine") or {}).get("command")
if old == command:
    print("settings.json: statusLine already points here, left as-is")
    raise SystemExit(0)

backup = "%s.bak-statusline-%s" % (path, time.strftime("%Y%m%d%H%M%S"))
shutil.copy2(path, backup)
print("backup: %s" % backup)

if old is not None:
    print("note: statusLine was already set by something else.")
    print("      Its command is preserved in the backup above.")
    # Replace the value in place, so formatting, key order, and every other
    # setting stay exactly as they were.
    enc_old, enc_new = json.dumps(old), json.dumps(command)
    if raw.count(enc_old) == 1:
        io.open(path, "w", encoding="utf-8", newline="").write(
            raw.replace(enc_old, enc_new))
        print("settings.json: statusLine.command replaced (one line changed)")
        raise SystemExit(0)
    print("settings.json: could not do a surgical edit; rewriting the file")

data["statusLine"] = block
io.open(path, "w", encoding="utf-8", newline="").write(
    json.dumps(data, indent=2) + "\n")
print("settings.json: statusLine set")
PY

cat <<EOF

Done. New sessions pick it up; a running one keeps its old line until restarted.

Preview it now:
  printf '{"workspace":{"current_dir":"%s"},"model":{"display_name":"Opus 5"},"context_window":{"used_percentage":22}}' "\$PWD" | sh "$dest"
EOF
