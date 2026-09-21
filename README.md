# tmux-session

One command to save, list, attach and resurrect tmux sessions.

```
tmux-session   host: laptop   3 session(s)
  date        time   name    state     size
  2026-09-12--09:41--0       inactive  2w/3p    saved 2026-09-19 22:10
  2026-09-18--14:02--paper   active    1w/2p    attached
> 2026-09-20--08:15--1       active    3w/4p    not yet saved
------------------------------------------------------------------------
  0: bash  (2 panes)  /home/me/src/solver
  1: vim   (1 panes)  /home/me/src/solver/notes
  active pane:
  | $ make test
  | 42 passed

  Up/Down move   Enter attach/resurrect   n new   r rename   d delete   s save   a all hosts   q quit
```

Running `tmux-session` on a terminal opens a full-screen picker. Sessions are listed
as `YYYY-MM-DD--HH:MM--NAME`, where the date and time are when the session was first
created, so sessions you never named (`0`, `1`, ...) stay easy to tell apart. The
lower pane previews the selected session: its windows, their working directories and
the last lines of its active pane. Press Enter on a running session to attach, or on a
dead one to rebuild it from its last snapshot and attach.

A snapshot records, per pane, the window layout, working directory, scrollback
(colours kept, long lines unwrapped) and the editor that was running, which is
relaunched when the session is resurrected.

## Install

```bash
cp tmux-session ~/bin/ && chmod +x ~/bin/tmux-session
```

Needs `bash` 3.2 or newer and `tmux` 3.x (developed against 3.5a). Linux and macOS.

## Saving periodically

```
* * * * * $HOME/bin/tmux-session -s
```

A save skips sessions with no activity since the last one, so running it every
minute is cheap. Saves never delete anything: when a session is gone its snapshot
simply lists as inactive until you remove it with `rm`. Sessions started with plain
`tmux` are picked up automatically by the next save or listing.

Event-driven saves work too, through tmux hooks:

```
set-hook -g client-detached 'run-shell -b "tmux-session -s"'
```

## Commands

| Command | What it does |
|---|---|
| `tmux-session` | Full-screen picker on a terminal; plain `list` otherwise |
| `tmux-session menu` | The same picker as a plain numbered prompt (for dumb terminals) |
| `tmux-session list [-a]` | List sessions for this host (`-a`: every host sharing the snapshot dir) |
| `tmux-session new [NAME]` | Create a session and attach to it |
| `tmux-session attach [TARGET]` | Attach to a running session (switches when already inside tmux) |
| `tmux-session resurrect TARGET [-n NAME] [-d]` | Rebuild an inactive session, then attach (`-d`: do not attach) |
| `tmux-session save`, `-s` | Snapshot every running session (`-f` ignores the activity check) |
| `tmux-session rm TARGET` | Delete an inactive session's snapshot |

`TARGET` is an id such as `20260920-133153-3`, a label such as
`2026-09-20--13:31--paper`, a session name, or a unique prefix of an id or label.
When an old and a new session share a name, `attach` prefers the running one and
`resurrect`/`rm` prefer the snapshot.

If a session's name is already taken when you resurrect it, the copy is created as
`NAME-2`, `NAME-3`, and so on.

### Picker keys

| Key | Action |
|---|---|
| `Up`/`Down`, `j`/`k`, `PgUp`/`PgDn`, `g`/`G` | Move the cursor (it starts on the newest session) |
| `Enter` | Attach to a running session, or resurrect a dead one and attach |
| `n` | Create a new session, optionally named, and attach |
| `r` | Rename the selected session (running or not) |
| `d` | Delete the selected snapshot; only for sessions that are not running |
| `s` | Save every running session now |
| `a` | Toggle sessions from other hosts sharing the snapshot directory |
| `R`, `Ctrl-L` | Refresh (the list also refreshes itself every few seconds) |
| `q`, `Esc` | Quit |

When you detach from a session you attached through the picker, the picker comes back.
Inside tmux, attaching switches the current client instead and the picker exits.

## How sessions keep their identity

Every session carries a tag, `<host>/<id>`, in the tmux user option
`@tmux-session-id`. The id is built from the session's creation time and tmux's
session number. A session created by `tmux-session new` gets the tag immediately;
one created by plain `tmux` gets it the first time a save or listing sees it, dated
from tmux's own record of when it was created. A resurrected session receives the
original tag, so later saves update the same snapshot and the date in the listing
never changes.

## What is restored

- windows with their indices, names, sizes and layouts; `automatic-rename` stays on
  for windows that tmux was naming itself
- the active window, the active pane of each window, and zoom
- each pane's working directory
- each pane's scrollback, replayed into the new pane so it can be scrolled again
- the editor running in a pane (`vim`, `vi`, `nvim`, `emacs` by default) with its
  original arguments; set `TMUX_SESSION_CMDS` to widen the list, for example
  `vim|nvim|less|htop`

Shell history, other running programs, remote logins and unsaved editor buffers are
not restored. `Ctrl-Z` inside a relaunched editor resumes it rather than dropping to
a shell; use the editor's own shell escape instead.

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `TMUX_SESSION_DIR` | `~/.tmux-sessions` | Where snapshots live |
| `TMUX_SESSION_HISTORY` | `100000` | Scrollback lines saved per pane (bounded by tmux's `history-limit`) |
| `TMUX_SESSION_CMDS` | `vim\|vi\|nvim\|emacs` | Programs relaunched on resurrect, as regex alternatives matched against the command name |
| `TMUX_SESSION_SOCKET` | unset | Talk to `tmux -L <name>` instead of the default server |

## Snapshot layout

```
~/.tmux-sessions/<host>/<id>/
  meta       key=value: format id host name created saved windows panes
  windows    TAB: index active zoomed width height automatic-rename layout name
  panes      TAB: window pane active cwd
  W.P.hist   scrollback of window W, pane P
  W.P.cmd    command relaunched in that pane
```

Snapshots are private to the user (mode 0700). Several machines can share the
directory, for instance through a synced home: each writes under its own host name
and `list -a` shows them all.

## Notes

- tmux's default `history-limit` is 2000 lines and a narrow window uses them up
  quickly. Raise it in `.tmux.conf` for deeper snapshots. Lines that a narrow window
  wrapped are joined back into one line when saved.
- On Linux the relaunched editor gets its exact original arguments. On macOS they
  come from `ps`, which loses the quoting of arguments that contain spaces.
- Migrating from the earlier `tmux-save`/`tmux-restore` scripts: their files in
  `~/.tmux-sessions` are ignored. Run the old `tmux-restore` once (it is in the git
  history), then `tmux-session save`, then delete the old files.

## Tests

```bash
tests/run.sh
```

Runs end to end against a private tmux server (`tmux -L`), a temporary snapshot
directory and a throwaway `HOME`, so it never touches your own sessions or config.
It covers save, resurrect (layouts, zoom, index gaps, six stacked panes, a real `vim`
round trip including `Ctrl-Z`), target resolution, locking, snapshots from other hosts,
and it drives the full-screen picker itself inside a tmux pane.

## License

MIT
