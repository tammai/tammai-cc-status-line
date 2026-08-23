# tammai-cc-status-line

A status line for [Claude Code](https://claude.com/claude-code), ported from the
oh-my-posh **default** theme so the terminal and the agent look like one tool.

```
 playnook   main    Opus 5 (1M context) high | ctx █░░░░ 22% | 5h ███░░ 65% 2h13m | 7d ████░ 88% 3d23h
```

Path and git branch come from the theme. The rest is what a shell prompt has no
way to know: the model and its effort level, how much of the context window is
gone, and both Claude subscription windows with the time until each resets. Every
percentage gets a five-cell bar, so three numbers can be compared without
reading digits.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/tammai/tammai-cc-status-line/main/install.sh | sh
```

Or clone and run it:

```sh
git clone https://github.com/tammai/tammai-cc-status-line
cd tammai-cc-status-line
sh install.sh
```

```
install.sh [--dir DIR]     install or re-install (idempotent)
install.sh --uninstall     remove statusline.sh and the statusLine setting
install.sh --version
install.sh --help
```

It writes exactly two things — `statusline.sh`, and the `statusLine` key of
`settings.json` — backs that file up with a timestamp first, and does a surgical
one-line replace so every other key and hook survives byte-for-byte. Run it
again any time; it reports "already points here" and changes nothing.

`--dir` (or `$CLAUDE_CONFIG_DIR`) installs into a config directory other than
`~/.claude`.

`--uninstall` deletes `statusline.sh` and drops the `statusLine` key. It backs
the file up first, but unlike install it rewrites the JSON, so formatting is
normalised even though every other key survives. If another tool owned
`statusLine` before you installed this, restore its command from the backup the
installer made at the time.

## What it shows

| segment | source | colour |
| --- | --- | --- |
| folder | `workspace.current_dir` | white on orange `#F07623` |
| git | one `git status --porcelain -b` call | black on green `#59C9A5`; **yellow** with `✎N` when dirty; `detached` when off-branch |
| model | `model.display_name` | bold blue `#4B95E9` |
| effort | `effort.level` | grey `#9090A1`, subordinate to the model name |
| `ctx` | `context_window.used_percentage` | bar + value, see below |
| `5h` / `7d` | `rate_limits.*.used_percentage` + `resets_at` | bar + value, reset time in grey |

One scale for all three gauges, in a single `set_pct_colour` function:

| used | colour |
| --- | --- |
| 0–50% | green `#59C9A5` |
| 51–79% | orange `#F07623` |
| ≥ 80% | red `#D81E5B` |

The bar is five cells of `█` / `░` — one cell per 20 points, rounded to nearest,
so 0% is empty, 50% shows three, and 100% is full. Filled cells take the value's
colour and the remainder stays grey. `BAR_CELLS` changes the width.

A dim `|` divides the three gauges from each other, and their labels are bold,
so the eye lands on a label before it reads a number. The git block needs no
divider — its powerline cap already closes it.

The theme's session (username) segment is deliberately dropped: on a single-user
machine it spends width to say nothing.

## Degrading

Nothing here is load-bearing, and nothing is invented when a field is missing:

| situation | result |
| --- | --- |
| before the first response (`context_window` null) | no gauges |
| not a subscriber (`rate_limits` absent) | no limit segments |
| a window with no `resets_at` | percentage only, no reset text |
| a model without reasoning effort | no effort text |
| not in a git repo | no git segment |
| no python at all | folder and branch from `$PWD`; model and gauges omitted |

Never a stack trace, and never a number that isn't real.

## Requirements

- **`python3` or `python`** — parses the status payload. On Windows, note that a
  `python3` on PATH may be the Microsoft Store shim, which is not an interpreter
  at all; candidates resolving inside `WindowsApps` are skipped for that reason.
- **A Nerd Font**, for the powerline separators (`U+E0B0`, `U+E0B6`, `U+E0B4`)
  and the folder glyph (`U+EA83`). The bar and `✎` are plain Unicode. An
  older *Powerline-patched* font is not enough — see below.
- **A truecolor terminal** — colours are 24-bit `38;2;R;G;B`.
- **git** is optional; no repo simply means no git segment.

POSIX `sh` only. Works on Windows (Git Bash), macOS and Linux; Windows-style
paths in the payload are converted.

### Getting the font right

Boxes or `?` where the separators and folder should be mean the terminal font
has no glyph there. The usual cause is a font from the older **Powerline**
project rather than a **Nerd Font**: those cover `U+E0B0`–`U+E0B3` only, so
the arrow renders and the two diamond caps (`U+E0B6`, `U+E0B4`) and the folder
(`U+EA83`, a Codicon) do not. Having a directory full of `... for Powerline.ttf`
is not the same as having a Nerd Font installed.

Any Nerd Font v3 carries all four. Meslo is a good default — it derives from
Menlo, so on macOS it changes nothing but the glyph coverage:

```sh
brew install --cask font-meslo-lg-nerd-font          # macOS
```

Then point the terminal at it. In Apple Terminal the profile font is set per
profile, and it wants the **PostScript** name, which is not the menu name:
`MesloLGSNF-Regular`, not `MesloLGSNerdFont-Regular`. A name it does not
recognise is accepted in silence and leaves the setting empty, so read it back:

```sh
osascript -e 'tell application "Terminal" to set font name of settings set "Basic" to "MesloLGSNF-Regular"'
osascript -e 'tell application "Terminal" to get font name of settings set "Basic"'
```

Open windows keep their own copy of the profile, so the change shows up in the
next new window. To check a font before setting it, `fc-list` on Linux, or the
Font Book inspector on macOS.

## If something already owns the statusLine slot

Some tools install their own `statusLine` command — an agent harness, for
instance, may use that hook to collect the payload and print nothing. Two things
make that survivable:

- The installer prints a warning and keeps the previous command in its backup.
- If `~/.orca/agent-hooks/claude-statusline.cmd` exists, `statusline.sh` feeds it
  the payload on its own stdin first, discards its output and exit code, and then
  renders. So that tool keeps working alongside this line. On a machine without
  it, the guard skips it silently.

To adapt that to a different tool, change `orca_cmd` near the top of
`statusline.sh`.

## Performance

It runs on every turn, so the script is deliberately fork-light: colour codes
and glyphs are built **once** into plain variables and concatenated as strings,
the whole line is emitted with a single `printf`, and git is asked exactly one
question. About half a second per render on Windows — one python start, one git,
and (where present) one `cmd.exe` for the other tool's hook. Faster on
macOS/Linux, where process spawns are cheap and `python3` resolves first try.

An earlier draft used per-segment helper functions inside command substitutions
and cost ~1.2s: on Windows every `$(...)` is a process spawn. That is the thing
to watch when editing — prefer shell parameter expansion over calling out.

## Licence

MIT
