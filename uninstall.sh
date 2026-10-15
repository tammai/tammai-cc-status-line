#!/bin/sh
# tammai-cc-status-line — uninstaller.
#
#   sh uninstall.sh                remove from Claude Code (~/.claude)
#   sh uninstall.sh --all          Claude Code, Codex CLI and Cursor CLI
#   sh uninstall.sh --dir DIR      a Claude config directory other than ~/.claude
#   sh uninstall.sh --codex        Codex CLI only
#   sh uninstall.sh --cursor       Cursor CLI only
#   sh uninstall.sh --font         also brew-uninstall the Nerd Font cask
#   sh uninstall.sh --help
#
# Also works straight off the network:
#   curl -fsSL https://raw.githubusercontent.com/tammai/tammai-cc-status-line/main/uninstall.sh | sh
#
# The removal itself is install.sh --uninstall, so there is one copy of that
# logic. Every config file touched is backed up first, a statusLine that
# something else owns is left alone, and the VS Code terminal font is reverted
# only where this installer wrote it. The font itself and Apple Terminal's font
# setting stay put unless --font asks otherwise.

set -eu

RAW_BASE=https://raw.githubusercontent.com/tammai/tammai-cc-status-line/main
NERD_CASK=font-meslo-lg-nerd-font

# Beside-the-script files are trusted only when this really is the script on
# disk. Piped from curl, $0 is the shell, and dirname of that is the current
# directory: whatever uninstall.sh sits there would be run, or its renderer copied.
case $0 in
  *uninstall.sh) self_dir=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd) || self_dir=/dev/null ;;
  *) self_dir=/dev/null ;;   # nothing can exist under it, so the fetch path runs
esac

want_claude=0 want_codex=0 want_cursor=0 want_font=0
dir=

usage() {
  if [ -f "$0" ]; then
    sed -n '3,12p' "$0" | sed 's/^# \{0,1\}//'
  else
    echo "usage: uninstall.sh [--all | --claude | --codex | --cursor] [--dir DIR] [--font]"
  fi
}

while [ $# -gt 0 ]; do
  case $1 in
    --all) want_claude=1 want_codex=1 want_cursor=1; shift ;;
    --claude) want_claude=1; shift ;;
    --codex) want_codex=1; shift ;;
    --cursor) want_cursor=1; shift ;;
    --font) want_font=1; shift ;;
    --dir) [ $# -ge 2 ] || { echo "uninstall.sh: --dir needs a path" >&2; exit 2; }
           dir=$2; want_claude=1; shift 2 ;;
    --dir=*) dir=${1#--dir=}; want_claude=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "uninstall.sh: unknown option '$1' (try --help)" >&2; exit 2 ;;
  esac
done

# No target named: Claude Code, as install.sh does.
if [ "$want_claude$want_codex$want_cursor" = 000 ]; then want_claude=1; fi

installer=$self_dir/install.sh
fetched=
if [ ! -f "$installer" ]; then
  installer=$(mktemp "${TMPDIR:-/tmp}/install.XXXXXX")
  fetched=$installer
  trap 'rm -f "$fetched"' EXIT INT TERM HUP
  echo "fetching install.sh from $RAW_BASE"
  if command -v curl >/dev/null 2>&1; then curl -fsSL "$RAW_BASE/install.sh" -o "$installer"
  elif command -v wget >/dev/null 2>&1; then wget -qO "$installer" "$RAW_BASE/install.sh"
  else echo "uninstall.sh: need curl or wget to fetch install.sh" >&2; exit 1
  fi
fi

rc=0
if [ "$want_claude" = 1 ]; then
  echo "== Claude Code"
  if [ -n "$dir" ]; then sh "$installer" --uninstall --dir "$dir" || rc=1
  else sh "$installer" --uninstall || rc=1
  fi
fi
if [ "$want_codex" = 1 ]; then
  echo "== Codex CLI"
  sh "$installer" --uninstall --codex || rc=1
fi
if [ "$want_cursor" = 1 ]; then
  echo "== Cursor CLI"
  sh "$installer" --uninstall --cursor || rc=1
fi

if [ "$want_font" = 1 ]; then
  echo "== Font"
  if [ "$(uname -s 2>/dev/null || :)" = Darwin ] && command -v brew >/dev/null 2>&1; then
    if brew list --cask "$NERD_CASK" >/dev/null 2>&1; then
      brew uninstall --cask "$NERD_CASK" || rc=1
    else
      echo "font: $NERD_CASK is not installed through brew, nothing to remove"
    fi
  else
    echo "font: only the Homebrew cask is removed automatically; delete any other Nerd Font by hand"
  fi
else
  echo
  echo "Kept: any Nerd Font and Apple Terminal's font setting (--font removes the brew cask)."
fi

exit "$rc"
