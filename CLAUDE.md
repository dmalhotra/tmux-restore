# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A single bash script, `tmux-session`, that snapshots tmux sessions into `~/.tmux-sessions/<host>/<id>/` and lists, attaches and resurrects them, with a full-screen picker as the default UI on a terminal. No build step; the only dependencies are `bash` and `tmux`. `tests/run.sh` is the only other code. The earlier `tmux-save`/`tmux-restore` pair (still in git history) was replaced by this script, and its flat snapshot files are ignored.

## Commands

```bash
bash -n tmux-session tests/run.sh   # syntax check; there is no linter in the repo
tests/run.sh                        # end-to-end suite on a private tmux server and temp snapshot dir
```

The suite builds sessions on `tmux -L tmux-session-test-$$` with a throwaway `HOME`, saves, kills the server, resurrects and compares, and drives the picker inside a tmux pane with `send-keys`/`capture-pane`. It never touches real sessions or config. Its timing assumptions are short sleeps after tmux actions; a failure that mentions a missing window or pane usually means a fixture was built on a server started by the tool rather than by the suite. To poke at the tool by hand with the same isolation:

```bash
export TMUX_SESSION_SOCKET=dev TMUX_SESSION_DIR=/tmp/ts-dev; unset TMUX
tmux -L dev -f /dev/null new-session -d -s x; ./tmux-session save -v; ./tmux-session list
```

## Hard constraints

- **bash 3.2 compatible** (macOS `/bin/bash`): no associative arrays, `mapfile`, `${var,,}`, `|&`. Regexes live in variables because 3.2 mishandles quoted regex literals. Empty arrays expand as `${a[@]+"${a[@]}"}` because `set -u` on old bash rejects a bare `"${a[@]}"`.
- **Snapshot format is `format=1`**; field order is documented in the script header. Old snapshots must keep resurrecting, so add fields at the end or bump the version and read both.
- **Save never deletes.** Only `rm` and the menu's `d` remove a snapshot. A fresh post-reboot tmux must never wipe the snapshots the user is about to resurrect.
- **`@tmux-session-id` is the identity contract.** Live sessions carry `<host>/<id>` there; the snapshot directory is `$DEST_DIR/<tag>`. The id is `YYYYMMDD-HHMMSS-<tmux session number>` in local time.

## Architecture

**Identity.** `ensure_tag` adopts any untagged live session by building an id from `session_created` and the numeric session id, then writes the tag into tmux. `resurrect_snapshot` writes the original tag onto the rebuilt session as its final step, and `cmd_save` carries `created` over from an existing `meta`, so the listing date never changes across resurrections.

**Entries.** `build_entries` merges live sessions with snapshot directories into one sorted TSV (`created tag state sid windows panes attached saved name`) with state `active`, `unsaved` (live, never saved) or `inactive` (snapshot only). `list`, the menu, `resolve_target`, `attach` and `rm` all consume that table. `resolve_target` matches tag, id, label, name, then unique prefix, and takes a preferred state (`live` for attach, `inactive` for resurrect and rm) to break ties between an old and a new session with the same name.

**Save.** Takes a `mkdir` lock, snapshots `ps` once, and skips a session when `session_activity < saved` and its name and window count are unchanged. Each snapshot is written to a staging dir inside `DEST_DIR` and swapped in with `mv` (old dir moved aside, then removed), so a crash leaves the previous snapshot intact. Scrollback uses `capture-pane -epJ`; `-J` joins soft-wrapped lines, which is what stops narrow windows from corrupting history. Relaunch commands come from a breadth-first walk of the pane's process tree (`descendants`, awk over the single `ps` snapshot), pre-filtered on `comm` and confirmed on argv[0]; on Linux argv is read exactly from `/proc/PID/cmdline` and `%q`-quoted.

**Resurrect.** Builds windows and panes with tmux's own `-c` for the cwd and a pane command, instead of typing into a shell. The pane command is `tmux-session _replay DIR W P`: it `cat`s the history, `eval`s the saved command under job control, then `exec`s the login shell (honouring `default-shell` and `default-command`). Panes are split off the last pane so indices come out in saved order, then `select-layout` applies the saved layout string; window size goes to `new-session -x/-y` so layouts with many panes fit. Everything after `new-session -P` targets the session id (`$N`).

**Picker.** `cmd_tui` draws straight to the terminal: `tput` for capabilities (smcup/rmcup, civis/cnorm, colours, reverse video) and CSI sequences for cursor positioning, one `printf` per frame to avoid flicker. `tui_refresh` renders rows once from `build_entries`; `tui_draw` only pads and colours them, and caches the preview per selection. Keys come from `read -rsn1` with a 5-second timeout that doubles as auto-refresh. Actions that need the real screen (attach, resurrect output, `new`) call `tui_leave`, run, then `tui_enter`; `cleanup` calls `tui_leave` so a `die` anywhere restores the terminal. `cmd_menu` is the plain fallback when stdin is not a terminal or `TERM` is dumb.

## Gotchas learned the hard way

- `set-option -t =name` fails with "no such session" even though `has-session`, `list-windows` and `select-layout` accept `=name`. Use the session id from `new-session -P -F '#{session_id}'` for every target after creation.
- TAB is IFS whitespace, so `read` collapses consecutive tabs and an empty field shifts every later one. Fields that can be empty use a `-` placeholder (cwd, sid, and the tag via `#{?@opt,#{@opt},-}`), and free-text fields (window name, cwd) are always last on their line.
- `#{automatic-rename}` expands to `1`/`0`, not `on`/`off`.
- Do not set `umask 077` globally: `new` and `resurrect` may start the tmux server, which would inherit it for every future pane. It is set inside `cmd_save` only; elsewhere privacy comes from `chmod 700` on the directories.
- In `_replay`, a stopped foreground job makes bash abandon every enclosing loop, and `fg` fails outright when its output is redirected. `resume_job` therefore recurses instead of looping and leaves `fg`'s output alone.
- In a detached session tmux's default window is 80x24 and the fifth vertical split fails with "no space for new pane"; that is why window sizes are saved and passed to `new-session`.
- `resize-window` switches the window to `window-size manual`, which stops it following the client; never use it in resurrect.
- `#{window_layout}` strings embed pane ids and a checksum over them, so a faithfully rebuilt window has a different string. Tests compare shapes with those stripped (`shape` in `tests/run.sh`).
- A server started by the tool reads the user's `~/.tmux.conf`; the suite isolates `HOME` so `base-index` and friends cannot shift window numbers under the fixtures.
- bash 3.2 `read -t` takes whole seconds only, and on timeout the exit status is not distinguishable from EOF; `tui_key` uses `$SECONDS` to tell an instant failure (stdin gone) from a timeout.
- Row-presence checks against a picker screenshot must look at entry rows only: the status line repeats the label of whatever was just deleted or renamed.
