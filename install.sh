#!/bin/sh
# tammai-cc-status-line — installer.
#
#   sh install.sh                 install (or re-install) into ~/.claude
#   sh install.sh --dir DIR       install into another config directory
#   sh install.sh --codex         configure Codex CLI's native footer
#   sh install.sh --cursor        configure Cursor CLI's custom status line
#   sh install.sh --uninstall     remove the status line
#   sh install.sh --help
#
# Also works straight off the network, where it fetches the renderer itself:
#   curl -fsSL https://raw.githubusercontent.com/tammai/tammai-cc-status-line/main/install.sh | sh
#
# For Claude it writes statusline.sh and the statusLine key of settings.json.
# For Codex it writes only tui.status_line in config.toml. Other settings are
# preserved byte-for-byte where the target value can be changed surgically.

set -eu

VERSION=1.2.0
RAW_BASE=https://raw.githubusercontent.com/tammai/tammai-cc-status-line/main

self_dir=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd) || self_dir=.
target=${CLAUDE_CONFIG_DIR:-}
action=install
client=claude
want_codex=0
want_cursor=0
do_font=1
do_terminal_font=1

# The font the package manager is asked for, and the PostScript name Apple
# Terminal wants for it — which is not the name shown in a font menu.
NERD_CASK=font-meslo-lg-nerd-font
NERD_PS_NAME=MesloLGSNF-Regular

usage() {
  cat <<'USAGE'
tammai-cc-status-line — status lines for Claude Code, Codex CLI, and Cursor CLI

  path · git branch · model · effort · context used · 5h and 7d limits,
  each percentage with a small bar. Ported from the oh-my-posh default theme.

Usage:
  install.sh [--dir DIR]     install or re-install (idempotent)
  install.sh --codex         configure Codex CLI's native status line
  install.sh --cursor        configure Cursor CLI's custom status line
  install.sh --codex --cursor configure both CLI status lines
  install.sh --uninstall     remove statusline.sh and the statusLine setting
  install.sh --version
  install.sh --help

Options:
  --dir DIR            Claude Code config directory.
                       Default: $CLAUDE_CONFIG_DIR, else ~/.claude
  --codex              Target Codex CLI. Uses $CODEX_HOME/config.toml,
                       or ~/.codex/config.toml when CODEX_HOME is unset.
  --cursor             Configure ~/.cursor/cli-config.json (or CURSOR_CONFIG_DIR).
  --no-font            Do not check for or install a Nerd Font.
  --no-terminal-font   Do not repoint Apple Terminal's profile at one.

Claude Code needs python3 or python (parses its status payload) and a truecolor
terminal. Codex CLI uses its native footer and needs no renderer or font setup.
git is optional. The Claude separators and folder glyph need a Nerd Font; if
none is installed, the platform's package manager is asked to add one.
USAGE
}

while [ $# -gt 0 ]; do
  case $1 in
    --dir) [ $# -ge 2 ] || { echo "install.sh: --dir needs a path" >&2; exit 2; }
           target=$2; shift 2 ;;
    --dir=*) target=${1#--dir=}; shift ;;
    --codex) want_codex=1; shift ;;
    --cursor) want_cursor=1; shift ;;
    --uninstall) action=uninstall; shift ;;
    --no-font) do_font=0; shift ;;
    --no-terminal-font) do_terminal_font=0; shift ;;
    --version) echo "$VERSION"; exit 0 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "install.sh: unknown option '$1' (try --help)" >&2; exit 2 ;;
  esac
done

if { [ "$want_cursor" = 1 ] || [ "$want_codex" = 1 ]; } && [ -n "$target" ]; then
  echo "install.sh: --dir applies only to Claude Code" >&2
  exit 2
fi

# Resolve the default only now: --help and --version must work on a machine
# with no HOME, and under `set -u` a default of $HOME/.claude would have died
# reading it before the argument loop ever ran.
if [ "$want_cursor" = 0 ] && [ "$want_codex" = 0 ] && [ -z "$target" ]; then
  if [ -n "${HOME-}" ]; then
    target=$HOME/.claude
  else
    echo "install.sh: no --dir given, and neither \$CLAUDE_CONFIG_DIR nor \$HOME is set" >&2
    exit 2
  fi
fi

# Create the directory up front for an install, then canonicalise: the
# dispatcher should record a clean absolute path, not whatever relative or
# dot-laden form happened to be typed on the command line.
if [ "$want_cursor" = 0 ] && [ "$want_codex" = 0 ] && [ "$action" = install ]; then
  # A path that exists but is not a directory would otherwise surface as a
  # bare mkdir error with no hint of which option caused it.
  if [ -e "$target" ] && [ ! -d "$target" ]; then
    echo "install.sh: $target exists and is not a directory" >&2
    exit 2
  fi
  mkdir -p "$target" || { echo "install.sh: cannot create $target" >&2; exit 1; }
fi
if [ "$want_cursor" = 0 ] && [ "$want_codex" = 0 ] && [ -d "$target" ]; then
  target=$(CDPATH= cd -- "$target" && pwd)
fi

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

# Cursor CLI supports the same command-backed status line pattern and streams
# its session payload to stdin. Reuse the renderer, installing it under the
# Cursor config directory and managing only the statusLine key.
if [ "$want_cursor" = 1 ]; then
  if [ -n "${CURSOR_CONFIG_DIR-}" ]; then
    cursor_config_dir=$CURSOR_CONFIG_DIR
  elif [ -n "${XDG_CONFIG_HOME-}" ] && [ "$(uname -s 2>/dev/null || :)" = Linux ]; then
    cursor_config_dir=$XDG_CONFIG_HOME/cursor
  elif [ -n "${HOME-}" ]; then
    cursor_config_dir=$HOME/.cursor
  else
    echo "install.sh: set CURSOR_CONFIG_DIR or HOME" >&2
    exit 2
  fi
  cursor_settings=$cursor_config_dir/cli-config.json
  cursor_renderer=$cursor_config_dir/statusline.sh
  cursor_command=$cursor_config_dir/cursor-statusline.sh
  if [ "$action" = install ]; then
    mkdir -p "$cursor_config_dir"
    if [ -f "$self_dir/statusline.sh" ]; then
      cp "$self_dir/statusline.sh" "$cursor_renderer"
    else
      echo "fetching statusline.sh from $RAW_BASE"
      if command -v curl >/dev/null 2>&1; then curl -fsSL "$RAW_BASE/statusline.sh" -o "$cursor_renderer"
      elif command -v wget >/dev/null 2>&1; then wget -qO "$cursor_renderer" "$RAW_BASE/statusline.sh"
      else echo "install.sh: need curl or wget to fetch statusline.sh" >&2; exit 1
      fi
    fi
    chmod +x "$cursor_renderer"
    cat >"$cursor_command" <<'SH'
#!/bin/sh
STATUSLINE_SKIP_ORCA=1
STATUSLINE_MODEL_FALLBACK='Cursor Agent'
export STATUSLINE_SKIP_ORCA STATUSLINE_MODEL_FALLBACK
exec sh "$1"
SH
    chmod +x "$cursor_command"
  fi
  CURSOR_SETTINGS=$cursor_settings CURSOR_RENDERER=$cursor_renderer CURSOR_COMMAND=$cursor_command CURSOR_ACTION=$action "$py" - <<'PY'
import io, json, os, shutil, time

path = os.environ["CURSOR_SETTINGS"]
renderer = os.environ["CURSOR_RENDERER"]
command = os.environ["CURSOR_COMMAND"]
action = os.environ["CURSOR_ACTION"]
try:
    raw = io.open(path, encoding="utf-8").read()
    data = json.loads(raw)
except FileNotFoundError:
    raw, data = "", {}
except ValueError as exc:
    raise SystemExit("install.sh: %s is not valid JSON (%s)" % (path, exc))

managed = {"type": "command", "command": 'sh "' + command.replace('"', '\\"') + '" "' + renderer.replace('"', '\\"') + '"', "padding": 0}
current = data.get("statusLine")
if action == "uninstall":
    if current != managed:
        print("cli-config.json: managed Cursor statusLine not found, nothing removed")
        raise SystemExit(0)
    del data["statusLine"]
elif current == managed:
    print("cli-config.json: Cursor status line already points here, left as-is")
    raise SystemExit(0)
else:
    data["statusLine"] = managed

if raw:
    backup = "%s.bak-statusline-%s" % (path, time.strftime("%Y%m%d%H%M%S"))
    shutil.copy2(path, backup)
    print("backup: %s" % backup)
io.open(path, "w", encoding="utf-8").write(json.dumps(data, indent=2) + "\n")
print("cli-config.json: Cursor statusLine %s" % ("removed" if action == "uninstall" else "set"))
PY
  if [ "$action" = uninstall ]; then
    [ ! -f "$cursor_command" ] || rm -f "$cursor_command"
    [ ! -f "$cursor_renderer" ] || rm -f "$cursor_renderer"
    echo "Restart Cursor CLI for the change to take effect."
  else
    echo "Done. Restart Cursor CLI to load the custom status line."
  fi
  if [ "$want_codex" = 0 ]; then exit 0; fi
fi

# Codex owns its status line natively: unlike Claude Code it does not invoke
# an external command or supply a JSON payload. Keep this renderer-free path
# separate and edit only tui.status_line in its TOML config.
if [ "$want_codex" = 1 ]; then
  if [ -n "${CODEX_HOME-}" ]; then
    codex_home=$CODEX_HOME
  elif [ -n "${HOME-}" ]; then
    codex_home=$HOME/.codex
  else
    echo "install.sh: neither \$CODEX_HOME nor \$HOME is set" >&2
    exit 2
  fi
  codex_settings=$codex_home/config.toml
  if [ "$action" = install ]; then
    mkdir -p "$codex_home" || { echo "install.sh: cannot create $codex_home" >&2; exit 1; }
  fi

  CODEX_SETTINGS=$codex_settings CODEX_ACTION=$action "$py" - <<'PY'
import io, os, re, shutil, time

path = os.environ["CODEX_SETTINGS"]
action = os.environ["CODEX_ACTION"]
value = '["model-with-reasoning", "current-dir", "git-branch", "context-remaining", "five-hour-limit", "weekly-limit"]'

try:
    raw = io.open(path, encoding="utf-8").read()
except FileNotFoundError:
    raw = ""

def table_end(text, start):
    hit = re.search(r"(?m)^\s*\[[^\[][^\]]*\]\s*$", text[start:])
    return start + hit.start() if hit else len(text)

def value_range(text, start, end, pattern):
    hit = re.search(pattern, text[start:end], re.M)
    if not hit:
        return None
    a, b = start + hit.start(), start + hit.end()
    # Also replace a multiline array value as one unit.
    while text[a:b].count("[") > text[a:b].count("]") and b < len(text):
        nl = text.find("\n", b)
        b = len(text) if nl == -1 else nl + 1
    return a, b

table = re.search(r"(?m)^\s*\[tui\]\s*$", raw)
if table:
    start, end = table.end(), table_end(raw, table.end())
    found = value_range(raw, start, end, r"^[ \t]*status_line\s*=.*(?:\n|$)")
    line = "status_line = " + value + "\n"
elif raw:
    found = value_range(raw, 0, len(raw), r"^[ \t]*tui\.status_line\s*=.*(?:\n|$)")
    line = "tui.status_line = " + value + "\n"
else:
    found = None
    line = "[tui]\nstatus_line = " + value + "\n"

if action == "uninstall":
    if not found:
        print("config.toml: no Codex status line managed here, nothing to remove")
        raise SystemExit(0)
    backup = "%s.bak-statusline-%s" % (path, time.strftime("%Y%m%d%H%M%S"))
    shutil.copy2(path, backup)
    a, b = found
    io.open(path, "w", encoding="utf-8", newline="").write(raw[:a] + raw[b:])
    print("backup: %s" % backup)
    print("config.toml: Codex tui.status_line removed")
    raise SystemExit(0)

if found:
    a, b = found
    if raw[a:b] == line:
        print("config.toml: Codex status line already points here, left as-is")
        raise SystemExit(0)
    new = raw[:a] + line + raw[b:]
elif table:
    new = raw[:table.end()] + "\n" + line + raw[table.end():]
elif raw:
    new = raw.rstrip() + "\n\n[tui]\n" + "status_line = " + value + "\n"
else:
    new = line

if raw:
    backup = "%s.bak-statusline-%s" % (path, time.strftime("%Y%m%d%H%M%S"))
    shutil.copy2(path, backup)
    print("backup: %s" % backup)
io.open(path, "w", encoding="utf-8", newline="").write(new)
print("config.toml: Codex tui.status_line set")
PY

  echo
  echo "Done. Restart Codex CLI, or use /statusline to adjust the native footer interactively."
  exit 0
fi

# ---------------------------------------------------------------- uninstall
if [ "$action" = uninstall ]; then
  if [ -f "$settings" ]; then
    # `|| :` so an unparseable settings.json still lets the renderer below be
    # removed; the reason is already printed by the block itself.
    SETTINGS=$settings "$py" - <<'PY' || :
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

# --------------------------------------------------------------------- font
# The two diamond caps and the folder glyph are Nerd Font territory, and a
# filename cannot tell you whether they are present: a machine can hold a
# complete set of "... for Powerline.ttf" and still miss three of the four,
# because that project stopped at U+E0B3. So ask each installed font's cmap
# directly — and ask the same question of the font the terminal is actually
# set to, since a profile pointing at Menlo renders boxes however many Nerd
# Fonts are installed.
#
# Nothing is bundled and nothing is downloaded: if a font is needed, the
# platform's package manager is asked for one.
fontq() {
  "$py" - "$@" <<'PY'
import os, struct, sys

NEEDED = (0xE0B6, 0xE0B4, 0xEA83)   # U+E0B0 is not diagnostic; Powerline has it


def _read(path, tag):
    try:
        f = open(path, "rb")
    except OSError:
        return None
    with f:
        head = f.read(12)
        if len(head) < 12 or head[:4] == b"ttcf":   # collections: not worth it
            return None
        n = struct.unpack(">H", head[4:6])[0]
        raw = f.read(n * 16)
        if len(raw) < n * 16:
            return None
        for i in range(n):
            r = raw[i*16:(i+1)*16]
            if r[:4] == tag:
                off, ln = struct.unpack(">II", r[8:16])
                f.seek(off)
                return f.read(ln)
    return None


def covers(path):
    d = _read(path, b"cmap")
    if not d or len(d) < 4:
        return False
    best = None
    for i in range(struct.unpack(">H", d[2:4])[0]):
        rec = d[4+i*8:12+i*8]
        if len(rec) < 8:
            break
        pid, eid, so = struct.unpack(">HHI", rec)
        if ((pid == 3 and eid in (1, 10)) or pid == 0) and so + 2 <= len(d):
            fmt = struct.unpack(">H", d[so:so+2])[0]
            if fmt == 12:
                best = (12, so)
                break
            if fmt == 4 and best is None:
                best = (4, so)
    if not best:
        return False
    fmt, so = best
    rs = []
    if fmt == 12:
        if so + 16 > len(d):
            return False
        for g in range(struct.unpack(">I", d[so+12:so+16])[0]):
            r = so + 16 + g*12
            if r + 12 > len(d):
                break
            a, b, _ = struct.unpack(">III", d[r:r+12])
            rs.append((a, b))
    else:
        if so + 8 > len(d):
            return False
        segx2 = struct.unpack(">H", d[so+6:so+8])[0]
        endo, starto = so + 14, so + 16 + segx2   # endCode, pad, startCode
        for i in range(segx2 // 2):
            if starto + i*2 + 2 > len(d):
                break
            b = struct.unpack(">H", d[endo+i*2:endo+i*2+2])[0]
            a = struct.unpack(">H", d[starto+i*2:starto+i*2+2])[0]
            rs.append((a, b))
    return all(any(a <= cp <= b for a, b in rs) for cp in NEEDED)


def psname(path):
    d = _read(path, b"name")
    if not d or len(d) < 6:
        return None
    _, count, so = struct.unpack(">HHH", d[:6])
    for i in range(count):
        r = 6 + i*12
        if r + 12 > len(d):
            break
        pid, _, _, nid, ln, off = struct.unpack(">HHHHHH", d[r:r+12])
        if nid != 6:                             # 6 = PostScript name
            continue
        raw = d[so+off:so+off+ln]
        try:
            return raw.decode("utf-16-be") if pid == 3 else raw.decode("latin1")
        except (UnicodeDecodeError, ValueError):
            continue
    return None


def installed():
    home = os.path.expanduser("~")
    dirs = [os.path.join(home, "Library/Fonts"), "/Library/Fonts",
            os.path.join(home, ".local/share/fonts"),
            os.path.join(home, ".fonts"),
            "/usr/local/share/fonts", "/usr/share/fonts"]
    for env, tail in (("LOCALAPPDATA", "Microsoft/Windows/Fonts"),
                      ("WINDIR", "Fonts")):
        v = os.environ.get(env)
        if v:
            dirs.append(os.path.join(v.replace("\\", "/"), tail))
    out = []
    for d in dirs:
        if not os.path.isdir(d):
            continue
        for root, _, files in os.walk(d):
            for fn in files:
                if fn.lower().endswith((".ttf", ".otf")):
                    out.append(os.path.join(root, fn))
    # A name claiming to be a Nerd Font is the likeliest hit, so look there
    # first. The cmap, never the name, gives the answer.
    out.sort(key=lambda q: 0 if "nerd" in os.path.basename(q).lower() else 1)
    return out


mode = sys.argv[1] if len(sys.argv) > 1 else "scan"

if mode == "scan":                    # any font at all with the glyphs?
    for q in installed():
        if covers(q):
            print(os.path.basename(q))
            sys.exit(0)
    sys.exit(1)

if mode == "ps":                      # does the font with this PostScript name?
    want = (sys.argv[2] if len(sys.argv) > 2 else "").strip().lower()
    if not want:
        sys.exit(2)
    for q in installed():
        n = psname(q)
        if n and n.strip().lower() == want:
            sys.exit(0 if covers(q) else 1)
    sys.exit(1)

sys.exit(2)
PY
}

# Git Bash and MSYS report MINGW64_NT-… and MSYS_NT-…, Cygwin CYGWIN_NT-…;
# all three are Windows for our purposes. `uname` is assumed by little else
# here, so a missing one degrades to "other" rather than killing the script.
os_kind() {
  case $(uname -s 2>/dev/null || echo unknown) in
    Darwin) echo darwin ;;
    Linux) echo linux ;;
    MINGW* | MSYS* | CYGWIN* | Windows_NT) echo windows ;;
    *) echo other ;;
  esac
}

font_hint() {
  cat >&2 <<EOF
font: install a Nerd Font, then re-run this script.
  macOS     brew install --cask $NERD_CASK
  Windows   scoop bucket add nerd-fonts && scoop install Meslo-NF
            (or winget, or right-click the .ttf files and Install)
  Linux     your distribution's Meslo Nerd Font package (Arch: ttf-meslo-nerd),
            or unpack a release into ~/.local/share/fonts and run fc-cache -f
  any       https://github.com/ryanoasis/nerd-fonts/releases
EOF
}

# Only the case that needs no sudo is automated. Asking a piped-from-curl
# script for a root password is a worse bargain than printing one line.
font_auto_install() {
  case $(os_kind) in
    darwin)
      command -v brew >/dev/null 2>&1 || return 2
      echo "font: brew install --cask $NERD_CASK"
      brew install --cask "$NERD_CASK" || return 1
      return 0 ;;
    # Windows and Linux both want either a root password or a bucket added to
    # someone's package manager. Neither is a decision a piped-from-curl
    # script should be making, so those print instead.
    *) return 2 ;;
  esac
}

# Apple Terminal keeps the font per profile and wants the PostScript name, not
# the one in the font menu — and it accepts a name it does not recognise in
# silence, leaving the setting empty. So read it back and check.
apple_terminal_font() {
  [ "$(os_kind)" = darwin ] || return 2
  [ "${TERM_PROGRAM-}" = Apple_Terminal ] || return 2
  command -v osascript >/dev/null 2>&1 || return 2

  profile=$(osascript -e 'tell application "Terminal" to get name of default settings' 2>/dev/null) || return 2
  [ -n "$profile" ] || return 2

  current=$(osascript -e "tell application \"Terminal\" to get font name of settings set \"$profile\"" 2>/dev/null) || current=
  if [ -n "$current" ] && fontq ps "$current"; then
    echo "font: Apple Terminal profile '$profile' already uses $current"
    return 0
  fi

  fontq ps "$NERD_PS_NAME" || return 2   # nothing safe to point it at

  osascript -e "tell application \"Terminal\" to set font name of settings set \"$profile\" to \"$NERD_PS_NAME\"" >/dev/null 2>&1 || return 1
  check=$(osascript -e "tell application \"Terminal\" to get font name of settings set \"$profile\"" 2>/dev/null) || check=
  [ "$check" = "$NERD_PS_NAME" ] || return 1

  echo "font: Apple Terminal profile '$profile' now uses $NERD_PS_NAME (was ${current:-unset})"
  echo "      open windows keep their own copy of the profile; a new window shows it"
  return 0
}

# Windows Terminal keeps the face in its own settings.json, and the old
# console keeps it in the registry per-executable. Neither is safe to edit
# from here, so say where it is and let the reader do it.
windows_terminal_hint() {
  cat <<EOF
font: point the terminal at it, or the glyphs stay boxes:
      Windows Terminal — Settings, Defaults, Appearance, Font face
      (or "font": { "face": "MesloLGS Nerd Font" } in its settings.json)
      Git Bash console — right-click the title bar, Options, Text
EOF
}

if [ "$do_font" = 1 ]; then
  font_was_missing=0
  if found=$(fontq scan); then
    echo "font: $found already covers the glyphs"
  else
    font_was_missing=1
    echo "font: nothing installed carries U+E0B6, U+E0B4 and U+EA83"
    rc=0
    font_auto_install || rc=$?
    if [ "$rc" = 0 ]; then
      if found=$(fontq scan); then
        echo "font: installed, satisfied by $found"
      else
        echo "font: the install reported success but the glyphs are still absent" >&2
      fi
    else
      [ "$rc" = 2 ] || echo "font: install failed" >&2
      font_hint
    fi
  fi

  # A font on disk is only half of it; the terminal has to name it. macOS can
  # be done here. Windows cannot, so it is described — and only when the font
  # was missing, since an established setup does not need telling twice.
  if [ "$do_terminal_font" = 1 ]; then
    case $(os_kind) in
      darwin) apple_terminal_font || : ;;
      windows) [ "$font_was_missing" = 0 ] || windows_terminal_hint ;;
    esac
  fi
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

# Running from inside the config directory makes src and dest the same file,
# and cp would fail there — aborting before settings.json is ever touched.
src_dir=$(CDPATH= cd -- "$(dirname -- "$src")" && pwd)
if [ "$src_dir/$(basename -- "$src")" = "$dest" ]; then
  echo "installed: $dest (already in place)"
else
  cp "$src" "$dest"
  echo "installed: $dest"
fi
chmod +x "$dest" 2>/dev/null || true

# The dispatcher. Guarded, so a machine without the script — or a wiped config
# directory — drains stdin quietly instead of erroring every turn.
command='if [ -f "${HOME-}/.claude/statusline.sh" ]; then sh "${HOME-}/.claude/statusline.sh"; else { command -p cat 2>/dev/null || cat; } >/dev/null 2>&1 || :; fi'

# Installing somewhere other than ~/.claude: point at that path literally.
case $target in
  "${HOME-}/.claude") ;;
  *) command="if [ -f \"$dest\" ]; then sh \"$dest\"; else { command -p cat 2>/dev/null || cat; } >/dev/null 2>&1 || :; fi" ;;
esac

COMMAND=$command SETTINGS=$settings "$py" - <<'PY'
import io, json, os, shutil, sys, time

path = os.environ["SETTINGS"]
command = os.environ["COMMAND"]
block = {"type": "command", "command": command}


def indent_step(text):
    """The indent this file uses for a top-level key, so an insert matches it."""
    for ln in text.splitlines()[1:]:
        bare = ln.lstrip(" \t")
        if bare.startswith('"'):
            return ln[:len(ln) - len(bare)] or "  "
    return "  "


def insert_key(text, blk):
    """Add statusLine to a JSON object textually, leaving all else untouched.

    Returns None if the text is not a shape worth hand-editing. The caller
    verifies the result parses to the intended object before writing it.
    """
    close = text.rfind("}")
    if close == -1:
        return None
    head, tail = text[:close].rstrip(), text[close:]
    if not head.endswith("{") and not head.endswith(","):
        head += ","                        # the object already had keys
    nl = "\r\n" if "\r\n" in text else "\n"
    step = indent_step(text)
    lines = []
    for ln in json.dumps({"statusLine": blk}, indent=2).split("\n")[1:-1]:
        bare = ln.lstrip(" ")              # re-indent from dumps' 2-space step
        lines.append(step * ((len(ln) - len(bare)) // 2) + bare)
    return head + nl + nl.join(lines) + nl + tail


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

# statusLine is normally {"type": ..., "command": ...}, but a hand-edited
# file can hold a bare string or a list there, and .get() on those raises.
# Only a dict has a command to compare or to swap surgically; any other shape
# is "owned by something else, contents unknown" and takes the rewrite path.
existing = data.get("statusLine")
old = existing.get("command") if isinstance(existing, dict) else None
if old == command:
    print("settings.json: statusLine already points here, left as-is")
    raise SystemExit(0)

backup = "%s.bak-statusline-%s" % (path, time.strftime("%Y%m%d%H%M%S"))
shutil.copy2(path, backup)
print("backup: %s" % backup)

if existing is not None:
    print("note: statusLine was already set by something else.")
    print("      Its command is preserved in the backup above.")

if old is not None:
    # Replace the value in place, so formatting, key order, and every other
    # setting stay exactly as they were.
    enc_old, enc_new = json.dumps(old), json.dumps(command)
    if raw.count(enc_old) == 1:
        io.open(path, "w", encoding="utf-8", newline="").write(
            raw.replace(enc_old, enc_new))
        print("settings.json: statusLine.command replaced (one line changed)")
        raise SystemExit(0)
    print("settings.json: could not do a surgical edit; rewriting the file")
elif "statusLine" not in data:
    # No key at all: the only case an insert is right for. A key holding some
    # other shape goes through the rewrite below instead, or we would end up
    # with two statusLine keys. Serialising `data` would reformat every other
    # key in the file, so add ours as text and leave the rest byte-for-byte,
    # writing it only if it re-parses to exactly the object we intended.
    patched = insert_key(raw, block)
    want = dict(data)
    want["statusLine"] = block
    good = False
    if patched is not None:
        try:
            good = json.loads(patched) == want
        except ValueError:
            good = False
    if good:
        io.open(path, "w", encoding="utf-8", newline="").write(patched)
        print("settings.json: statusLine added (one key inserted)")
        raise SystemExit(0)
    print("settings.json: could not insert surgically; rewriting the file")

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
