#!/bin/sh
# tammai-cc-status-line — a status line for Claude Code.
#
# Ported from the oh-my-posh default theme (path and git segments, palette
# below), plus what a shell prompt cannot know: the model and its effort
# level, context used, and the two subscription windows with their resets.
#
# Reads the status payload Claude Code sends on stdin. See the README for
# the full field list and how each one degrades when absent.
#
# If another tool already owns the statusLine hook to collect that payload
# and prints nothing itself, this script feeds it the payload on its own
# stdin first, discards its output and exit code, and then renders — so
# both survive. `orca_cmd` below is that hand-off; change the path to
# adapt it, or delete the block if nothing else wants the payload.
#
# PERFORMANCE: this runs on every turn, and on Windows every `$(...)` is a
# process spawn. Colour codes and glyphs are therefore built ONCE into
# plain variables and concatenated as strings, the whole line is emitted
# with a single printf, and git is asked exactly one question. Keep it
# that way — the first draft used per-segment helper functions and cost
# ~1.2s a render, almost all of it fork overhead.

tmp=$(mktemp "${TMPDIR:-/tmp}/claude-cc-status.XXXXXX") || exit 0
trap 'rm -f "$tmp"' EXIT INT TERM HUP

# Read our stdin exactly once; both the Orca reporter and the renderer
# below need it, and stdin can only be drained a single time.
cat >"$tmp"

# Hand Orca's reporter the payload on ITS stdin (it reads via more.com),
# never ours. Guard on the file existing so this still renders if Orca is
# uninstalled or the path moves, and never let its output or exit code
# touch our line.
orca_cmd="$HOME/.orca/agent-hooks/claude-statusline.cmd"
if [ "${STATUSLINE_SKIP_ORCA-}" != 1 ] && [ -f "$orca_cmd" ]; then
  "$orca_cmd" <"$tmp" >/dev/null 2>&1 || true
fi

# --- pull the rendered fields out of the payload (no jq here; python) ---
# One value per line in a fixed order, so a field the payload omits is an
# empty line rather than a shifted column. The percentages are the ones
# Claude Code pre-calculates; we never do token arithmetic ourselves.
#
# `python3` first, since plain `python` does not exist at all on macOS and most
# Linux distributions — but a name on PATH is not proof of an interpreter:
# Windows ships a `python3` shim in WindowsApps that only prints "Python was
# not found" and exits nonzero. Resolve each candidate and skip those, taking
# the first survivor. If it turns out to be broken anyway we fall through to
# the no-payload degrade below, which is cheaper than probing for it here —
# each `command -v` capture is a subshell, and this runs every turn.
py=""
for candidate in python3 python; do
  candidate_path=$(command -v "$candidate" 2>/dev/null) || continue
  case $candidate_path in
    *WindowsApps*) continue ;;
  esac
  py=$candidate
  break
done

payload_reader='
import hashlib, json, math, os, re, sys, tempfile, time


def money(v):
    return "$%.2f" % v


# USD per million tokens: input, output, 5-minute cache write, 1-hour cache
# write, cache read. Anthropic first-party rates as of 2026-10-06. Writes are
# 1.25x and 2x the input rate and reads 0.1x, except Opus 5.5 reads at 0.05x.
# Used only to ESTIMATE sessions that predate this script (see seed below);
# a model missing from the table counts as $0, so add a row for a new one.
PRICES = {
    "claude-opus-5-5": (4.0, 20.0, 5.0, 8.0, 0.20),
    "claude-opus-5": (5.0, 25.0, 6.25, 10.0, 0.50),
    "claude-opus-4-8": (5.0, 25.0, 6.25, 10.0, 0.50),
    "claude-opus-4-7": (5.0, 25.0, 6.25, 10.0, 0.50),
    "claude-opus-4-6": (5.0, 25.0, 6.25, 10.0, 0.50),
    "claude-sonnet-5-5": (2.0, 10.0, 2.50, 4.0, 0.20),
    "claude-sonnet-5": (2.0, 10.0, 2.50, 4.0, 0.20),
    "claude-sonnet-4-6": (3.0, 15.0, 3.75, 6.0, 0.30),
    "claude-haiku-4-5": (1.0, 5.0, 1.25, 2.0, 0.10),
}

# How long one render may spend scanning old transcripts before it yields and
# lets the next render carry on. Keeps a big project from stalling the line.
SEED_BUDGET = 2.5


def num(v):
    try:
        return float(v) if math.isfinite(float(v)) else 0.0
    except (TypeError, ValueError):
        return 0.0


def estimate(path):
    """Estimated USD for one transcript file, or None if it cannot be read."""
    seen = {}
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for n, line in enumerate(f):
                # Cheap test first: most lines carry no usage and are not parsed.
                if "\"usage\"" not in line:
                    continue
                try:
                    o = json.loads(line)
                except ValueError:
                    continue
                m = o.get("message") if isinstance(o, dict) else None
                u = m.get("usage") if isinstance(m, dict) else None
                if not isinstance(u, dict):
                    continue
                # A streamed reply is written more than once under one request
                # id; the last copy has the final counts, so keep only that.
                seen[o.get("requestId") or m.get("id") or n] = (m.get("model"), u)
    except OSError:
        return None

    total = 0.0
    for model, u in seen.values():
        name = re.sub(r"-\d{8}$", "", re.sub(r"\[.*\]$", "", str(model)))
        p = PRICES.get(name)
        if not p:
            continue
        made = u.get("cache_creation")
        if isinstance(made, dict):
            w5 = num(made.get("ephemeral_5m_input_tokens"))
            w1 = num(made.get("ephemeral_1h_input_tokens"))
        else:
            w5, w1 = num(u.get("cache_creation_input_tokens")), 0.0
        total += (
            num(u.get("input_tokens")) * p[0]
            + num(u.get("output_tokens")) * p[1]
            + w5 * p[2]
            + w1 * p[3]
            + num(u.get("cache_read_input_tokens")) * p[4]
        ) / 1e6
    return total


def write_record(root, name, base, last):
    """Write one session record atomically, so a reader never sees half of it."""
    fd, tmp = tempfile.mkstemp(dir=root)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump({"base": base, "last": last}, f)
    os.replace(tmp, os.path.join(root, name))


def seed(root, config_dir, proj, skip):
    """Estimate this project past sessions from its transcripts, once.

    Claude Code keeps every session as ~/.claude/projects/<dir>/<id>.jsonl, with
    token counts but no dollar figure, so the cost is priced from PRICES. Only
    sessions without a record yet are scanned (the live ones already have an
    exact one), newest first, and the marker file is written last: a scan cut
    short by SEED_BUDGET simply resumes on the next render.
    """
    marker = os.path.join(root, ".seeded")
    if os.path.exists(marker):
        return
    tdir = os.path.join(config_dir, "projects", re.sub(r"[^A-Za-z0-9]", "-", proj))
    try:
        files = [
            (os.path.getmtime(os.path.join(tdir, n)), n)
            for n in os.listdir(tdir)
            if n.endswith(".jsonl")
        ]
    except OSError:
        files = []
    deadline = time.time() + SEED_BUDGET
    for _, n in sorted(files, reverse=True):
        name = re.sub(r"[^A-Za-z0-9_-]", "", n[:-6])
        if not name or name == skip or os.path.exists(os.path.join(root, name)):
            continue
        if time.time() > deadline:
            return
        cost = estimate(os.path.join(tdir, n))
        if cost:
            write_record(root, name, 0.0, cost)
    with open(marker, "w", encoding="utf-8") as f:
        f.write("seeded\n")


def spend(d):
    """Session and project cost as ($1.23, $14.80), either "" when unknown.

    The payload carries only the running total of this session, so the
    project figure is built here: every render stores the latest total in a
    file of its own under a folder for the project, and the project is the
    sum of those files. One file per session means two sessions never rewrite
    the same file. Sessions from before this was installed are estimated once
    from their transcripts by seed.
    (No apostrophes in this block: it lives inside a single-quoted string.)
    """
    try:
        total = float((d.get("cost") or {}).get("total_cost_usd"))
    except (TypeError, ValueError):
        return "", ""
    if not math.isfinite(total) or total < 0:
        return "", ""

    sid = re.sub(r"[^A-Za-z0-9_-]", "", str(d.get("session_id") or ""))
    ws = d.get("workspace") or {}
    proj = ws.get("project_dir") or ws.get("current_dir") or d.get("cwd") or ""
    if not sid or not proj:
        return money(total), ""

    proj = str(proj).replace("\\", "/").rstrip("/")
    config_dir = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")
    root = os.path.join(
        config_dir,
        "statusline-cost",
        hashlib.sha1(proj.encode("utf-8")).hexdigest()[:16],
    )
    path = os.path.join(root, sid)
    try:
        os.makedirs(root, exist_ok=True)
        try:
            seed(root, config_dir, proj, sid)
        except Exception:
            pass
        base = 0.0
        try:
            with open(path, encoding="utf-8") as f:
                old = json.load(f)
            base, last = float(old["base"]), float(old["last"])
            # A total below the stored one means the counter restarted (a
            # resumed session), so what was spent before is kept as a base.
            if total < last:
                base += last
        except Exception:
            pass
        write_record(root, sid, base, total)

        project = 0.0
        for name in os.listdir(root):
            try:
                with open(os.path.join(root, name), encoding="utf-8") as f:
                    rec = json.load(f)
                project += float(rec["base"]) + float(rec["last"])
            except Exception:
                continue
        return money(total), money(project)
    except Exception:
        return money(total), ""


def pct(v):
    try:
        return str(int(round(float(v))))
    except (TypeError, ValueError):
        return ""


def until(epoch):
    """Time left until a reset, as a compact 43m / 2h14m / 4d3h."""
    try:
        secs = int(float(epoch) - time.time())
    except (TypeError, ValueError):
        return ""
    if secs <= 0:
        return "now"
    mins = secs // 60
    if mins < 60:
        return "%dm" % mins
    hours, mins = divmod(mins, 60)
    if hours < 24:
        return "%dh%02dm" % (hours, mins)
    days, hours = divmod(hours, 24)
    return "%dd%dh" % (days, hours)


try:
    with open(sys.argv[1], encoding="utf-8") as f:
        d = json.load(f)
except Exception:
    d = {}

ctx = d.get("context_window") or {}
limits = d.get("rate_limits") or {}
five = limits.get("five_hour") or {}
seven = limits.get("seven_day") or {}
session_cost, project_cost = spend(d)

values = [
    (d.get("workspace") or {}).get("current_dir") or d.get("cwd") or "",
    (d.get("model") or {}).get("display_name") or "",
    # Absent entirely on models without reasoning effort, so never assume one.
    (d.get("effort") or {}).get("level") or "",
    pct(ctx.get("used_percentage")),
    pct(five.get("used_percentage")),
    until(five.get("resets_at")),
    pct(seven.get("used_percentage")),
    until(seven.get("resets_at")),
    session_cost,
    project_cost,
]

# Write bytes, not print(): on Windows text mode turns every newline into
# CRLF, and the trailing CR rides into the shell variables — enough to make
# an integer comparison fail and an absent field look non-empty.
sys.stdout.buffer.write(("\n".join(values) + "\n").encode("utf-8"))
'

fields=""
[ -n "$py" ] && fields=$("$py" -c "$payload_reader" "$tmp" 2>/dev/null)

# A here-doc, not IFS splitting: it keeps empty values as empty lines and
# leaves spaces inside a path or model name alone.
{
  read -r cwd
  read -r model
  read -r effort
  read -r ctx_used
  read -r five_pct
  read -r five_reset
  read -r seven_pct
  read -r seven_reset
  read -r session_cost
  read -r project_cost
} <<EOF
$fields
EOF

# With no interpreter there is no payload, so fall back to where we were
# invoked: a folder and branch beat an empty status line, and the model and
# gauges simply stay absent rather than being guessed at.
[ -n "$cwd" ] || cwd=$PWD

# --- folder + git, from the payload's cwd (never our own) ---
case $cwd in
  *\\*) cwd_unix=$(printf '%s' "$cwd" | tr '\\' '/') ;;
  *) cwd_unix=$cwd ;;
esac

folder=${cwd_unix%/}
folder=${folder##*/}
[ -n "$folder" ] || folder=$cwd_unix

# One git call for both facts: `-b` puts "## branch...upstream" on the
# first line and one line per changed path after it.
branch=""
dirty_count=0
if [ -n "$cwd_unix" ]; then
  status_out=$(git -C "$cwd_unix" --no-optional-locks status --porcelain -b 2>/dev/null)
  if [ -n "$status_out" ]; then
    while IFS= read -r status_line; do
      case $status_line in
        '## '*)
          branch=${status_line#'## '}
          branch=${branch%%...*}
          # Detached HEAD reads as "HEAD (no branch)"; show it as such.
          case $branch in
            'HEAD (no branch)') branch='detached' ;;
          esac
          ;;
        ?*) dirty_count=$((dirty_count + 1)) ;;
      esac
    done <<INNER
$status_out
INNER
  fi
fi

# --- oh-my-posh default theme palette, prebuilt as strings ---
esc=$(printf '\033')
r="${esc}[0m"
b="${esc}[1m"

fg_black="${esc}[38;2;38;43;68m"
fg_yellow="${esc}[38;2;243;174;53m"
fg_orange="${esc}[38;2;240;118;35m"
fg_green="${esc}[38;2;89;201;165m"
fg_white="${esc}[38;2;224;222;244m"
fg_blue="${esc}[38;2;75;149;233m"
fg_red="${esc}[38;2;216;30;91m"
# Not from the oh-my-posh theme, which carries no neutral: a muted slate for
# text that should recede rather than read — reset times, effort level.
fg_grey="${esc}[38;2;144;144;161m"

bg_yellow="${esc}[48;2;243;174;53m"
bg_orange="${esc}[48;2;240;118;35m"
bg_green="${esc}[48;2;89;201;165m"

# U+E0B6 leading diamond, U+E0B0 separator, U+E0B4 trailing diamond,
# U+EA83 folder, U+270E pencil, U+2588 full block, U+2591 light shade. One
# printf, split on spaces — building these separately would be a fork apiece.
glyphs=$(printf '\356\202\266 \356\202\260 \356\202\264 \356\252\203 \342\234\216 \342\226\210 \342\226\221')
# shellcheck disable=SC2086
set -- $glyphs
lead=$1 arrow=$2 trail=$3 folder_icon=$4 dirty_icon=$5 bar_on_cell=$6 bar_off_cell=$7

# Section divider: dim, so it groups without competing with the values.
sep="${fg_grey}|${r}"

# --- compose ---
# The theme opened with a session (username) segment; dropped here, because
# a single-user machine gains nothing from being told whose it is. The path
# segment therefore carries the leading diamond now.
line="${fg_orange}${lead}${r}"
line="${line}${fg_white}${bg_orange} ${folder_icon} ${folder} ${r}"

if [ -n "$branch" ]; then
  # The theme flips this segment's background to yellow on a dirty tree
  # (background_templates in its git segment); the pencil count rides along.
  if [ "$dirty_count" -gt 0 ]; then
    git_edge=$fg_yellow git_bg=$bg_yellow
    git_text=" ${branch} ${dirty_icon}${dirty_count} "
  else
    git_edge=$fg_green git_bg=$bg_green
    git_text=" ${branch} "
  fi
  line="${line}${fg_orange}${git_bg}${arrow}${r}"
  line="${line}${fg_black}${git_bg}${git_text}${r}"
  line="${line}${git_edge}${trail}${r}"
else
  line="${line}${fg_orange}${trail}${r}"
fi

# model: blue bold and plain, mirroring the theme's right prompt. The effort
# level rides alongside it in grey — a property of the model, not a fact of
# its own, so it stays subordinate to the name.
line="${line}  ${fg_blue}${b}${model:-${STATUSLINE_MODEL_FALLBACK:-Claude Code}}${r}"
[ -n "$effort" ] && line="${line} ${fg_grey}${effort}${r}"

# --- session gauges: context left, then the two subscription windows ---
# The label stays neutral and the number carries the colour, so the line
# reads as calm until something actually needs attention. A field the
# payload omits renders nothing: context_window is null before the first
# response, and rate_limits is absent entirely for non-subscribers.
#
# Nothing but digits reaches a numeric test, so a shape change upstream
# costs a segment rather than spraying errors into the line.
# All three are stated as USED, so high is the bad end throughout, and one
# scale covers them all: calm to 50, orange past it, red from 80. A plain
# function, not a subshell — see the performance note at the top.
pct_colour=$fg_green
set_pct_colour() {
  if [ "$1" -ge 80 ]; then
    pct_colour=$fg_red
  elif [ "$1" -gt 50 ]; then
    pct_colour=$fg_orange
  else
    pct_colour=$fg_green
  fi
}

# A five-cell bar sits left of every percentage, so the three gauges can be
# compared at a glance without reading digits. Filled cells take the value's
# colour, the remainder stays grey. Five cells means one cell per 20 points,
# rounded to nearest — 0% is an empty bar, 100% a full one.
BAR_CELLS=5

add_gauge() { # $1 label, $2 percentage (digits only), $3 reset text or ""
  set_pct_colour "$2"

  filled=$(( ($2 * BAR_CELLS + 50) / 100 ))
  [ "$filled" -lt 0 ] && filled=0
  [ "$filled" -gt "$BAR_CELLS" ] && filled=$BAR_CELLS

  # Built by concatenation rather than a repeat command: five iterations of
  # shell builtins cost nothing, where any `$(...)` here would cost a fork.
  bar_on='' bar_off='' cell=0
  while [ "$cell" -lt "$BAR_CELLS" ]; do
    if [ "$cell" -lt "$filled" ]; then
      bar_on="${bar_on}${bar_on_cell}"
    else
      bar_off="${bar_off}${bar_off_cell}"
    fi
    cell=$((cell + 1))
  done

  line="${line} ${sep} ${fg_white}${b}$1${r} ${pct_colour}${bar_on}${fg_grey}${bar_off}${r}"
  line="${line} ${pct_colour}${b}$2%${r}"
  # The reset time trails the number, dim, so the number reads first.
  [ -n "$3" ] && line="${line} ${fg_grey}$3${r}"
}

case ${ctx_used:-x} in
  '' | *[!0-9]*) ;;
  *) add_gauge ctx "$ctx_used" '' ;;
esac

# A window with no resets_at simply shows no reset text.
for window in "5h:$five_pct:$five_reset" "7d:$seven_pct:$seven_reset"; do
  label=${window%%:*}
  rest=${window#*:}
  value=${rest%%:*}
  reset=${rest#*:}
  case ${value:-x} in
    '' | *[!0-9]*) continue ;;
  esac
  add_gauge "$label" "$value" "$reset"
done

# --- spend: this session, then the whole project ---
# Money has no scale to be judged against, so it takes no colour. Shown as
# session/project with no label (the dollar signs say what it is): the
# session figure bold white, the slash grey, the project figure plain white.
if [ -n "$session_cost" ]; then
  line="${line} ${sep} ${fg_white}${b}${session_cost}${r}"
  [ -n "$project_cost" ] && line="${line}${fg_grey}/${r}${fg_white}${project_cost}${r}"
fi

printf '%s' "$line"
