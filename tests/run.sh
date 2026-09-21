#!/bin/bash
# End-to-end tests for tmux-session on an isolated tmux server and snapshot directory.
# Usage: tests/run.sh          (exit status 0 when every check passes)
set -u
cd "$(dirname "$0")/.." || exit 1
REPO="$PWD"

export TMUX_SESSION_SOCKET="tmux-session-test-$$"
export TMUX_SESSION_DIR="$(mktemp -d "${TMPDIR:-/tmp}/tmux-session-test.XXXXXX")"
export TMUX_SESSION_CMDS='sleep|vim|vi|nvim|emacs'     # `sleep` stands in for an editor
export TMUX_SESSION_LOCK_WAIT=2
export HOME="$TMUX_SESSION_DIR/home"; mkdir -p "$HOME"  # no ~/.tmux.conf, no shell rc noise
unset TMUX                                              # behave as if outside tmux
T=./tmux-session
TM() { command tmux -L "$TMUX_SESSION_SOCKET" -f /dev/null "$@"; }
HOST="$(hostname -s)"
WORK="$TMUX_SESSION_DIR/work dir"; mkdir -p "$WORK"     # a cwd with a space
LONG="$(printf 'word%03d ' $(seq 1 40))"                # 320 chars, wider than a narrow window
stamp()  { date -d "@$1" "+$2" 2>/dev/null || date -r "$1" "+$2"; }
tag_of() { TM show-option -qv -t "$1" @tmux-session-id; }        # live session -> host/id
snapdirs() { ls "$TMUX_SESSION_DIR/$HOST" 2>/dev/null | wc -l | tr -d ' '; }
shape() {   # layout string -> same without checksum and pane ids (those differ between servers)
    printf '%s\n' "$1" | sed -E 's/^[0-9a-f]{4},//; s/(,[0-9]+,[0-9]+),[0-9]+([],]|$)/\1\2/g'
}
descendant_comms() {   # PID -> comm of every descendant process
    ps -eo pid=,ppid=,comm= | awk -v root="$1" '
        { kids[$2] = kids[$2] " " $1; comm[$1] = $3 }
        END { n = 0; q[n++] = root
              for (i = 0; i < n; i++) { c = split(kids[q[i]], k, " ")
                  for (j = 1; j <= c; j++) { q[n++] = k[j]; print comm[k[j]] } } }'
}

pass=0; fail=0
ok()    { pass=$((pass + 1)); echo "ok   - $1"; }
bad()   { fail=$((fail + 1)); echo "FAIL - $1"; [ $# -gt 1 ] && printf '       %s\n' "${@:2}"; }
eq()    { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got:  [$2]" "want: [$3]"; fi; }
has()   { if printf '%s\n' "$2" | grep -Fq -- "$3"; then ok "$1"; else bad "$1" "output lacks: [$3]" "$2"; fi; }
lacks() { if printf '%s\n' "$2" | grep -Fq -- "$3"; then bad "$1" "output has: [$3]"; else ok "$1"; fi; }
section() { echo; echo "## $1"; }
cleanup() { TM kill-server 2>/dev/null; rm -rf "$TMUX_SESSION_DIR" /tmp/ts-test-$$.txt; }
trap cleanup EXIT

# =============================================================== 1. save
section "save"
TM new-session -d -s alpha -n "log viewer" -x 120 -y 30 -c "$WORK"
TM send-keys -t alpha:0.0 "echo $LONG" Enter
TM split-window -d -t alpha:0.0 -c "$WORK" 'sleep 1000'
TM split-window -d -h -t alpha:0.1 -c "$HOME"
TM new-window -d -t alpha:1 -n second -c "$HOME"
TM new-window -d -t alpha:2 -c "$HOME"                      # unnamed: automatic-rename stays on
TM select-window -t alpha:0; TM select-pane -t alpha:0.2
sleep 0.5
TM resize-window -t alpha:0 -x 40 -y 30                     # narrow: the long line now wraps
UNNAMED="$(TM new-session -d -P -F '#{session_name}')"      # like typing plain `tmux`
sleep 1                                                     # let shell prompts appear (activity)
LAYOUT0="$(TM display-message -p -t alpha:0 '#{window_layout}')"

out="$($T save -v 2>&1)"; rc=$?
eq   "save exits 0" "$rc" 0
has  "save reports alpha"   "$out" "--alpha"
has  "save reports unnamed" "$out" "--$UNNAMED"
eq   "one snapshot per session" "$(snapdirs)" 2
TAG="$(tag_of alpha)"; DIR="$TMUX_SESSION_DIR/$TAG"; ID="${TAG#*/}"
has  "alpha tagged with host/id" "$TAG" "$HOST/"
eq   "meta format"  "$(grep '^format=' "$DIR/meta")"  "format=1"
eq   "meta name"    "$(grep '^name=' "$DIR/meta")"    "name=alpha"
eq   "meta windows" "$(grep '^windows=' "$DIR/meta")" "windows=3"
eq   "meta panes"   "$(grep '^panes=' "$DIR/meta")"   "panes=5"
eq   "long line saved unwrapped" "$(grep -Fxc -- "${LONG% }" "$DIR/0.0.hist")" 1
eq   "editor-like command recorded" "$(cat "$DIR/0.1.cmd")" "sleep 1000"
eq   "plain shell pane has no command file" "$([ -f "$DIR/0.2.cmd" ] && echo yes || echo no)" no
eq   "cwd with space recorded" "$(awk -F'\t' '$1==0 && $2==0 {print $4}' "$DIR/panes")" "$WORK"
eq   "window name with space recorded" "$(awk -F'\t' '$1==0 {print $8}' "$DIR/windows")" "log viewer"
eq   "automatic-rename recorded off/off/on" "$(awk -F'\t' '{printf "%s ", $6}' "$DIR/windows")" "0 0 1 "
eq   "active window/pane recorded" "$(awk -F'\t' '$2==1{print $1}' "$DIR/windows")/$(awk -F'\t' '$1==0 && $3==1{print $2}' "$DIR/panes")" "0/2"
eq   "snapshot dir is private" "$(stat -c %a "$DIR" 2>/dev/null || stat -f %Lp "$DIR")" 700
CREATED="$(grep '^created=' "$DIR/meta" | cut -d= -f2)"

out="$($T list 2>&1)"
has  "list shows alpha active" "$out" "active"
eq   "list shows both sessions" "$(printf '%s\n' "$out" | grep -c ')')" 2
has  "list label has date--time--name" "$out" "$(stamp "$CREATED" '%Y-%m-%d--%H:%M')--alpha"
out="$($T save -v 2>&1)"
eq   "second save skips unchanged sessions" "$(printf '%s\n' "$out" | grep -c '^unchanged')" 2
out="$($T save -v -f 2>&1)"
eq   "-f saves everything again" "$(printf '%s\n' "$out" | grep -c '^saved')" 2
out="$(TMUX_SESSION_CMDS=vim $T save -f 2>&1)"
eq   "default command list ignores sleep" "$([ -f "$DIR/0.1.cmd" ] && echo yes || echo no)" no
$T save -f >/dev/null 2>&1
eq   "command file back with the wider list" "$([ -f "$DIR/0.1.cmd" ] && echo yes || echo no)" yes

TM send-keys -t alpha:1.0 'seq 1 100' Enter; sleep 0.5
TMUX_SESSION_HISTORY=3 $T save -f >/dev/null 2>&1
n="$(wc -l < "$DIR/1.0.hist" | tr -d ' ')"
eq   "history depth is honoured" "$([ "$n" -ge 20 ] && [ "$n" -le 40 ] && echo ok || echo "$n lines")" ok
$T save -f >/dev/null 2>&1

TM rename-session -t alpha alpha-renamed
out="$($T save -v 2>&1)"
has  "rename triggers a save" "$out" "saved      "
eq   "meta follows the rename" "$(grep '^name=' "$DIR/meta")" "name=alpha-renamed"
eq   "id unchanged by rename" "$(snapdirs)" 2
TM rename-session -t alpha-renamed alpha; $T save >/dev/null 2>&1

# =============================================================== 2. resurrect
section "resurrect"
TM kill-server; sleep 0.3
out="$($T list 2>&1)"
eq   "after kill both inactive" "$(printf '%s\n' "$out" | grep -c inactive)" 2
eq   "list shows saved time"    "$(printf '%s\n' "$out" | grep -c 'saved 20')" 2

out="$($T resurrect "$ID" -d 2>&1)"; rc=$?
eq   "resurrect exits 0" "$rc" 0
sleep 1
eq   "session alpha exists" "$(TM has-session -t =alpha 2>&1 && echo yes)" yes
eq   "window names restored" "$(TM list-windows -t alpha -F '#{window_index}=#{window_name}' | grep -v '^2=' | tr '\n' ' ')" "0=log viewer 1=second "
eq   "pane count restored" "$(TM list-panes -t alpha:0 | wc -l | tr -d ' ')" 3
eq   "layout restored exactly" "$(shape "$(TM display-message -p -t alpha:0 '#{window_layout}')")" "$(shape "$LAYOUT0")"
eq   "active window restored" "$(TM display-message -p -t alpha '#{window_index}')" 0
eq   "active pane restored" "$(TM display-message -p -t alpha:0 '#{pane_index}')" 2
eq   "cwd restored" "$(TM display-message -p -t alpha:0.0 '#{pane_current_path}')" "$WORK"
eq   "command relaunched" "$(descendant_comms "$(TM display-message -p -t alpha:0.1 '#{pane_pid}')" | grep -c '^sleep$')" 1
eq   "automatic-rename kept off on named window" "$(TM show-options -wv -t alpha:0 automatic-rename)" off
eq   "automatic-rename inherited on unnamed window" "$(TM show-options -wv -t alpha:2 automatic-rename)" ""
eq   "scrollback replayed and still one line" "$(TM capture-pane -pJ -S - -t alpha:0.0 | grep -Fxc -- "${LONG% }")" 1
eq   "tag carried over" "$(tag_of alpha)" "$TAG"
TM new-session -d -s umref; sleep 0.5                    # a shell tmux itself started, for reference
TM send-keys -t umref 'umask > "'"$TMUX_SESSION_DIR"'/umask-ref.txt"' Enter
TM send-keys -t alpha:0.2 'umask > "'"$TMUX_SESSION_DIR"'/umask.txt"' Enter; sleep 0.7
eq   "umask in replayed shell matches a tmux-started shell" "$(cat "$TMUX_SESSION_DIR/umask.txt")" "$(cat "$TMUX_SESSION_DIR/umask-ref.txt")"
TM kill-session -t umref
out="$($T save -v 2>&1)"
eq   "save after resurrect updates same snapshot" "$(snapdirs)" 2
eq   "created date preserved" "$(grep '^created=' "$DIR/meta" | cut -d= -f2)" "$CREATED"
out="$($T resurrect alpha -d 2>&1)"; rc=$?
has  "resurrecting a running session just says so" "$out" "already running"
eq   "…and exits 0" "$rc" 0

# =============================================================== 3. layouts and edge cases
section "layouts and edge cases"
TM new-session -d -s six -x 200 -y 60
for i in 1 2 3 4 5; do TM split-window -d -t six:0; TM select-layout -t six:0 even-vertical; done
TM new-session -d -s zoom -x 120 -y 40; TM split-window -d -t zoom:0; TM resize-pane -Z -t zoom:0.0
TM new-session -d -s gaps
TM new-window -d -t gaps:1; TM new-window -d -t gaps:2; TM new-window -d -t gaps:3
TM kill-window -t gaps:1; TM kill-window -t gaps:2
TM new-session -d -s 'a/b'
mkdir -p "$TMUX_SESSION_DIR/gone"; TM new-session -d -s gone -c "$TMUX_SESSION_DIR/gone"
TM new-session -d -s nohist
TM new-session -d -s bad
sleep 1
SIXLAYOUT="$(TM display-message -p -t six:0 '#{window_layout}')"
$T save >/dev/null 2>&1
eq   "zoom recorded" "$(awk -F'\t' '{print $3}' "$TMUX_SESSION_DIR/$(tag_of zoom)/windows")" 1
eq   "slash in a session name is fine" "$(grep '^name=' "$TMUX_SESSION_DIR/$(tag_of 'a/b')/meta")" "name=a/b"
NOHIST="$(tag_of nohist)"; BAD="$(tag_of bad)"; GONE="$(tag_of gone)"
TM kill-server; sleep 0.3
rm -f "$TMUX_SESSION_DIR/$NOHIST/0.0.hist"
rm -f "$TMUX_SESSION_DIR/$BAD/windows"
rm -rf "$TMUX_SESSION_DIR/gone"

$T resurrect six -d >/dev/null 2>&1; sleep 0.5
eq   "six stacked panes restored" "$(TM list-panes -t six:0 | wc -l | tr -d ' ')" 6
eq   "six-pane layout exact" "$(shape "$(TM display-message -p -t six:0 '#{window_layout}')")" "$(shape "$SIXLAYOUT")"
$T resurrect zoom -d >/dev/null 2>&1; sleep 0.3
eq   "zoom restored" "$(TM display-message -p -t zoom:0 '#{window_zoomed_flag}')" 1
$T resurrect gaps -d >/dev/null 2>&1; sleep 0.3
eq   "window index gaps restored" "$(TM list-windows -t gaps -F '#{window_index}' | tr '\n' ' ')" "0 3 "
$T resurrect a/b -d >/dev/null 2>&1; sleep 0.3
eq   "slash-named session resurrected" "$(TM has-session -t '=a/b' 2>&1 && echo yes)" yes
$T resurrect "${GONE#*/}" -d >/dev/null 2>&1; sleep 0.5
eq   "missing cwd falls back to HOME" "$(TM display-message -p -t gone:0.0 '#{pane_current_path}')" "$HOME"
$T resurrect "${NOHIST#*/}" -d >/dev/null 2>&1; sleep 1
eq   "missing history still yields a shell" "$(TM display-message -p -t nohist:0.0 '#{pane_current_command}')" "bash"
out="$($T resurrect "${BAD#*/}" -d 2>&1)"; rc=$?
eq   "incomplete snapshot is refused" "$rc" 1
has  "…with a reason" "$out" "incomplete"
out="$($T resurrect "$ID" -n fresh -d 2>&1)"; rc=$?
eq   "resurrect -n exits 0" "$rc" 0
eq   "resurrect -n uses the new name" "$(TM has-session -t =fresh 2>&1 && echo yes)" yes
eq   "resurrect -n keeps the tag" "$(tag_of fresh)" "$TAG"
$T save >/dev/null 2>&1
eq   "renamed copy updates the same snapshot" "$(grep '^name=' "$DIR/meta")" "name=fresh"

if command -v vim >/dev/null 2>&1; then
    TM new-session -d -s ed -x 100 -y 30 -c /tmp "vim /tmp/ts-test-$$.txt"; sleep 1
    $T save >/dev/null 2>&1
    EDTAG="$(tag_of ed)"
    has  "vim command line recorded" "$(cat "$TMUX_SESSION_DIR/$EDTAG/0.0.cmd")" "vim /tmp/ts-test-$$.txt"
    TM kill-session -t ed; sleep 0.3
    $T resurrect "${EDTAG#*/}" -d >/dev/null 2>&1; sleep 1.5
    eq   "vim relaunched in the foreground" "$(TM display-message -p -t ed:0.0 '#{pane_current_command}')" vim
    TM send-keys -t ed:0.0 C-z; sleep 1
    eq   "Ctrl-Z resumes vim instead of freezing" "$(TM display-message -p -t ed:0.0 '#{pane_current_command}')" vim
    TM send-keys -t ed:0.0 Escape ':q!' Enter; sleep 1.2
    eq   "quitting vim drops into a shell" "$(TM display-message -p -t ed:0.0 '#{pane_current_command}')" bash
    TM kill-session -t ed
else
    echo "skip - vim not installed; editor round trip not exercised"
fi

# =============================================================== 4. names, targets, guards
section "names, targets and guards"
sleep 1
TM new-session -d -s beta; sleep 0.3
$T save >/dev/null 2>&1
BTAG="$(tag_of beta)"
TM kill-session -t beta; sleep 1
TM new-session -d -s beta                               # a new, different "beta"
out="$($T resurrect "${BTAG#*/}" -d 2>&1)"
has  "collision renames" "$out" "resurrecting as 'beta-2'"
eq   "beta-2 exists" "$(TM has-session -t =beta-2 2>&1 && echo yes)" yes
out="$($T rm "${BTAG#*/}" 2>&1)"; rc=$?
eq   "rm refuses running session" "$rc" 1
TM kill-session -t beta-2; sleep 0.3
out="$($T rm "${BTAG#*/}" 2>&1)"; rc=$?
eq   "rm deletes inactive snapshot" "$rc" 0
eq   "snapshot dir gone" "$([ -d "$TMUX_SESSION_DIR/$BTAG" ] && echo present || echo gone)" gone
out="$($T rm 2>&1)"; rc=$?;              eq "rm without target fails" "$rc" 1
out="$($T resurrect nonexistent 2>&1)"; rc=$?; eq "unknown target fails" "$rc" 1
out="$($T resurrect 2026 -d 2>&1)"; rc=$?
eq   "ambiguous prefix fails" "$rc" 1
has  "…and lists the candidates" "$out" "ambiguous"
out="$($T attach fresh 2>&1)"
has  "attach off-tty prints hint" "$out" "attach-session"
out="$($T attach 2>&1)"; rc=$?
eq   "attach with several live sessions asks which" "$rc" 1
out="$($T new gamma 2>&1)"; rc=$?
eq   "new creates a session" "$(TM has-session -t =gamma 2>&1 && echo yes)" yes
has  "new tags it at birth" "$(tag_of gamma)" "$HOST/"
out="$($T new gamma 2>&1)"; rc=$?
eq   "new with a taken name fails" "$rc" 1
out="$($T bogus 2>&1)"; rc=$?;           eq "unknown command fails" "$rc" 1
has  "help prints usage" "$($T help)" "Usage:"
out="$(printf 'q\n' | $T menu 2>&1)"; rc=$?
eq   "menu quits on q" "$rc" 0
has  "menu lists sessions" "$out" "--fresh"
out="$(printf 'q\n' | $T tui 2>&1)"; rc=$?
eq   "tui off-tty falls back to the menu" "$rc" 0
has  "…and still lists sessions" "$out" "--fresh"

# =============================================================== 5. locking and pruning safety
section "locking and pruning safety"
mkdir -p "$TMUX_SESSION_DIR/.lock"; echo $$ > "$TMUX_SESSION_DIR/.lock/pid"     # held by a live process
out="$($T save -v 2>&1)"; rc=$?
eq   "save gives up on a held lock" "$rc" 0
has  "…and says so" "$out" "holds the lock"
rm -rf "$TMUX_SESSION_DIR/.lock"
mkdir -p "$TMUX_SESSION_DIR/.lock"; echo 4194000 > "$TMUX_SESSION_DIR/.lock/pid"  # dead owner
out="$($T save -v 2>&1)"; rc=$?
eq   "stale lock is reclaimed" "$rc" 0
lacks "…without complaint" "$out" "holds the lock"
before="$(snapdirs)"
TM set -g exit-empty off
for s in $(TM list-sessions -F '#{session_name}'); do TM kill-session -t "=$s"; done
sleep 0.3
eq   "server alive with zero sessions" "$(TM list-sessions 2>&1 | wc -l | tr -d ' ')" 0
$T save >/dev/null 2>&1
eq   "save with zero sessions deletes nothing" "$(snapdirs)" "$before"
TM kill-server 2>/dev/null; sleep 0.3
out="$($T save 2>&1)"; rc=$?
eq   "save with no server exits 0 quietly" "$rc/$out" "0/"

# =============================================================== 6. other hosts
section "other hosts"
OTHER="$TMUX_SESSION_DIR/otherhost/20200101-000000-1"; mkdir -p "$OTHER"
printf 'format=1\nid=20200101-000000-1\nhost=otherhost\nname=remote\ncreated=946684800\nsaved=946684800\nwindows=1\npanes=1\n' > "$OTHER/meta"
printf '0\t1\t0\t80\t24\t1\tbogus\tremote-win\n' > "$OTHER/windows"
printf '0\t0\t1\t-\n' > "$OTHER/panes"
printf 'hello from otherhost\n' > "$OTHER/0.0.hist"
lacks "list hides other hosts" "$($T list 2>&1)" "[otherhost]"
has   "list -a shows them"     "$($T list -a 2>&1)" "[otherhost]"
out="$($T resurrect remote -d 2>&1)"; rc=$?
eq   "foreign snapshot resurrects (bad layout falls back)" "$rc" 0
sleep 0.5
eq   "foreign tag kept" "$(tag_of remote)" "otherhost/20200101-000000-1"
has  "foreign history replayed" "$(TM capture-pane -p -S - -t remote:0.0)" "hello from otherhost"
before="$(snapdirs)"; $T save >/dev/null 2>&1
eq   "saving it writes under its own host" "$(snapdirs)" "$before"
TM kill-server; sleep 0.3

# =============================================================== 7. full-screen picker
section "full-screen picker"
rm -rf "$TMUX_SESSION_DIR/$HOST"
TM new-session -d -s old1; sleep 0.5; $T save >/dev/null 2>&1; TM kill-server; sleep 1
TM new-session -d -s old2; sleep 0.5; $T save >/dev/null 2>&1; OLD2="$(tag_of old2)"; TM kill-server; sleep 1
TM new-session -d -s live1 -x 120 -y 40; sleep 0.5; $T save >/dev/null 2>&1
# the picker runs in a second window of live1 (not its own session), addressed by pane id
TUIPANE="$(TM new-window -P -F '#{pane_id}' -t live1 -c "$REPO" 'env -u TMUX ./tmux-session tui; echo "TUI-EXIT=$?"; sleep 30')"
sleep 1.5
scr() { TM capture-pane -p -t "$TUIPANE"; }
selected() { scr | grep '^> ' | head -n 1; }
rows() { scr | grep -E '^[> ] [0-9]{4}-[0-9]{2}-[0-9]{2}--'; }   # entry rows only, not the status line
key() { TM send-keys -t "$TUIPANE" "$@"; sleep 0.7; }
S="$(scr)"
has  "tui header"  "$S" "tmux-session   host: $HOST   3 session(s)"
has  "tui footer"  "$S" "q quit"
has  "tui shows every entry" "$S" "--old1"
has  "tui starts on the newest session" "$(selected)" "--live1"
has  "tui preview lists windows" "$S" "(1 panes)"
key k;      has "k moves up"     "$(selected)" "--old2"
key Up;     has "Up moves up"    "$(selected)" "--old1"
key Up;     has "Up stops at top" "$(selected)" "--old1"
key G;      has "G jumps to end" "$(selected)" "--live1"
key g;      has "g jumps home"   "$(selected)" "--old1"
key Down;   has "Down moves down" "$(selected)" "--old2"
key r;      has "rename prompt"  "$(scr)" "Rename 'old2' to:"
key -l renamed; key Enter
has  "renamed inactive entry" "$(selected)" "--renamed"
eq   "rename rewrote meta" "$(grep '^name=' "$TMUX_SESSION_DIR/$OLD2/meta")" "name=renamed"
has  "rename feedback" "$(scr)" "renamed to 'renamed'"
key G; key r; key -l live-renamed; key Enter
eq   "rename of a live session renames in tmux" "$(TM has-session -t =live-renamed 2>&1 && echo yes)" yes
key d;      has "deleting a live session is refused" "$(scr)" "is running"
key g; key d
has  "delete asks for confirmation" "$(scr)" "Delete "
key n;      has "n declines deletion" "$(rows)" "--old1"
key d; key y
lacks "y deletes the snapshot" "$(rows)" "--old1"
has  "delete feedback" "$(scr)" "deleted "
eq   "snapshot really gone" "$(snapdirs)" 2
key s;      S="$(scr)"
if printf '%s\n' "$S" | grep -Eq 'saved, [0-9]+ unchanged'; then ok "s saves and reports"; else bad "s saves and reports" "$S"; fi
key a;      S="$(scr)"
has  "a toggles all hosts" "$S" "[all hosts]"
has  "…and shows the foreign entry" "$S" "[otherhost]"
key a;      lacks "a toggles back" "$(scr)" "[all hosts]"
key q; sleep 0.5
has  "q exits with status 0" "$(scr)" "TUI-EXIT=0"
TM kill-server 2>/dev/null

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
