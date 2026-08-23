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
install.sh [--dir DIR]          install or re-install (idempotent)
install.sh --no-font            skip the font check and install
install.sh --no-terminal-font   leave Apple Terminal's profile font alone
install.sh --uninstall          remove statusline.sh and the statusLine setting
install.sh --version
install.sh --help
```

It writes `statusline.sh` and the `statusLine` key of `settings.json` — backing
that file up with a timestamp first, and doing a surgical one-line replace so
every other key and hook survives byte-for-byte. Run it again any time; it
reports "already points here" and changes nothing.

First, though, it looks at the fonts, because the line is illegible in the wrong
one and a fresh machine is the likeliest place to hit that. Two things follow,
and only on a machine that has no font with the glyphs: the package manager is
asked for a Nerd Font, and on Apple Terminal the profile is pointed at it.
`--no-font` and `--no-terminal-font` opt out of each. Neither is reached when a
font already covers the glyphs, so re-running stays a no-op.

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

`install.sh` handles this, and only steps in when it has to. What it is looking
for is narrow: the two diamond caps (`U+E0B6`, `U+E0B4`) and the folder
(`U+EA83`, a Codicon).

Filenames cannot answer that question, which is why the check reads each
installed font's `cmap` instead. A machine can hold a complete set of
`... for Powerline.ttf` and still be missing three of the four glyphs, because
that project stopped at `U+E0B3` — the arrow lands and the rest do not. The
scan costs about 50ms across a few hundred fonts.

If nothing qualifies, `brew install --cask font-meslo-lg-nerd-font` runs on
macOS. Meslo derives from Menlo, so it changes nothing but the glyph coverage.
Elsewhere the installer prints what to run rather than asking a piped-from-curl
script for a root password:

```sh
sudo pacman -S ttf-meslo-nerd            # Arch
```

or unpack a [release](https://github.com/ryanoasis/nerd-fonts/releases) into
`~/.local/share/fonts` and run `fc-cache -f`. Either way the install continues,
and the line renders without its separators until a font is there.

A font on disk is only half of it: the terminal has to be pointed at it, and
that is per profile. Apple Terminal is handled — it wants the **PostScript**
name rather than the one in the font menu (`MesloLGSNF-Regular`, not
`MesloLGSNerdFont-Regular`) and accepts a name it does not know in silence,
leaving the setting empty, so the installer reads it back before believing it.
The profile is left alone if the font it already names has the glyphs; that
check is why an unrelated Nerd Font is never overwritten. Open windows keep
their own copy of a profile, so the change appears in the next new window.

Other terminals set this themselves — in iTerm2, VS Code
(`terminal.integrated.fontFamily`), Ghostty (`font-family`) and the rest, point
the font at a Nerd Font and the glyphs appear.

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
