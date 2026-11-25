#!/usr/bin/env bash
# Waterbox release regression tests. These tests never boot, stop, reset, or enter
# a real box; privileged/runtime paths are checked as generated code or with mocks.
set -euo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
WB=$(realpath "$HERE/../waterbox")
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

count=0
pass=0
skip=0
fail() { printf 'not ok - %s\n' "$*" >&2; exit 1; }
ok() { count=$((count + 1)); pass=$((pass + 1)); printf 'ok %d - %s\n' "$count" "$*"; }
skip_test() { count=$((count + 1)); skip=$((skip + 1)); printf 'ok %d - %s # SKIP\n' "$count" "$*"; }
assert_eq() {
    local expected=$1 actual=$2 label=$3
    [[ "$actual" == "$expected" ]] || fail "$label (expected '$expected', got '$actual')"
}
assert_has() {
    local haystack=$1 needle=$2 label=$3
    [[ "$haystack" == *"$needle"* ]] || fail "$label (missing '$needle')"
}
extract() {
    local start=$1 end=$2 output=$3
    awk -v start="$start" -v end="$end" '
        $0 ~ start { copying=1; next }
        copying && $0 ~ end { exit }
        copying { print }
    ' "$WB" > "$output"
    [[ -s "$output" ]] || fail "could not extract $start ... $end"
}

printf 'TAP version 13\n'

# The outer script and every generated program must parse in its target shell.
bash -n "$WB"
ok "outer Bash syntax"

extract "cat <<'HELPER'" '^HELPER$' "$TMP/helper.bash"
bash -n "$TMP/helper.bash"
ok "generated privileged helper Bash syntax"
awk '/^_valid_env_id\(\)/ { c=1 } c && /^# --- end env identity/ { exit } c { print }' "$WB" > "$TMP/env.bash"
[[ -s "$TMP/env.bash" ]] || fail "could not extract env identity block"

extract "cat <<'FIRE'" '^FIRE$' "$TMP/fire.sh"
sh -n "$TMP/fire.sh"
ok "generated in-box scheduler helper syntax"

extract '^_statusline_body' '^SL$' "$TMP/statusline.sh"
sh -n "$TMP/statusline.sh"
ok "generated statusline POSIX shell syntax"

extract "<<'RESUMEPY'" '^RESUMEPY$' "$TMP/waterbox-resume"
python3 -m py_compile "$TMP/waterbox-resume"
ok "generated session-restore helper Python syntax"

extract "<<'WBRC'" '^WBRC$' "$TMP/waterbox-rc"
bash -n "$TMP/waterbox-rc"
ok "generated waterbox-rc Bash syntax"

extract "wb_tee .*[.]zshrc.*<<'EOF'" '^EOF$' "$TMP/zshrc"
if command -v zsh >/dev/null 2>&1; then
    zsh -n "$TMP/zshrc"
    ok "generated zshrc syntax"
else
    skip_test "generated zshrc syntax (zsh unavailable)"
fi
# Agent temp files must not accumulate on the RAM-backed /tmp. The exported path and
# the tmpfiles rule that creates and age-cleans it have to name the same directory.
assert_has "$(cat "$TMP/zshrc")" 'export CLAUDE_CODE_TMPDIR=/var/tmp/claude' \
    "zshrc moves Claude Code temp files off /tmp"
assert_has "$(grep -F 'd /var/tmp/claude ' "$WB")" \
    '"d /var/tmp/claude 0700 $USER_NAME $USER_NAME 7d"' \
    "tmpfiles rule creates and age-cleans the Claude Code temp dir"
assert_has "$(cat "$TMP/zshrc")" 'known_marketplaces.json' \
    "zshrc self-heals pre-1.9 marketplace installLocation paths"
assert_has "$(cat "$TMP/zshrc")" 'cmd=(claude --resume "$id")' "zshrc reopens a restored Claude chat"
assert_has "$(cat "$TMP/zshrc")" 'cmd=(codex resume "$id")' "zshrc reopens a restored Codex chat"
assert_has "$(cat "$TMP/zshrc")" 'unset WB_RESUME_AGENT WB_RESUME_ID WB_RESUME_DIR WB_RESUME_BUSY WB_RESUME_RUN' \
    "zshrc consumes the restore variables so later shells do not reopen the chat"

extract "cat <<'AGENTENV_HEAD'" '^AGENTENV_HEAD$' "$TMP/agent-head.zsh"
extract "cat <<'AGENTENV'" '^AGENTENV$' "$TMP/agent-body.zsh"
{
    printf '%s\n' "$(cat "$TMP/agent-head.zsh")"
    printf '%s\n' "AGENT_ENV_REGISTRY=('claude|Claude Code|claude|CLAUDE_CONFIG_DIR|settings.json|.claude|projects')"
    printf '%s\n' "$(cat "$TMP/agent-body.zsh")"
} > "$TMP/agent-env.zsh"
if command -v zsh >/dev/null 2>&1; then
    zsh -n "$TMP/agent-env.zsh"
    ok "generated agent-env zsh syntax"
else
    skip_test "generated agent-env zsh syntax (zsh unavailable)"
fi

extract "cat <<'COMPLETION'" '^COMPLETION$' "$TMP/completion.zsh"
if command -v zsh >/dev/null 2>&1; then
    zsh -n "$TMP/completion.zsh"
    ok "generated zsh completion syntax"
else
    skip_test "generated zsh completion syntax (zsh unavailable)"
fi

awk -v dir="$TMP" '
    /<<'\''PY'\''/ { n++; copying=1; next }
    copying && /^PY$/ { copying=0; next }
    copying { print > (dir "/embedded-" n ".py") }
' "$WB"
py_count=0
for py in "$TMP"/embedded-*.py; do
    [[ -e "$py" ]] || continue
    python3 -m py_compile "$py"
    py_count=$((py_count + 1))
done
assert_eq 4 "$py_count" "embedded Python block count"
ok "all embedded safe-read and mount-helper Python programs compile"

extract "wb_tee .*[.]tmux[.]conf.*<<'EOF'" '^EOF$' "$TMP/tmux.conf"
if command -v tmux >/dev/null 2>&1; then
    tmux_socket="waterbox-test-$$"
    tmux -L "$tmux_socket" -f "$TMP/tmux.conf" new-session -d
    assert_eq on "$(tmux -L "$tmux_socket" show -gv mouse)" "tmux mouse setting"
    assert_eq external "$(tmux -L "$tmux_socket" show -sv set-clipboard)" "tmux clipboard setting"
    tmux -L "$tmux_socket" kill-server
    ok "generated tmux config loads with scrolling and safe clipboard mode"
else
    skip_test "generated tmux config load (tmux unavailable)"
fi

# Read-only CLI commands and errors must not create ~/.waterbox as a side effect.
cli_home="$TMP/cli-home"
mkdir -p "$cli_home"
version=$(HOME="$cli_home" "$WB" --version)
assert_has "$version" "waterbox v" "version output"
[[ ! -e "$cli_home/.waterbox" ]] || fail "version created user state"
HOME="$cli_home" "$WB" --help >/dev/null
[[ ! -e "$cli_home/.waterbox" ]] || fail "help created user state"
set +e
unknown=$(HOME="$cli_home" "$WB" definitely-not-a-command 2>&1)
unknown_rc=$?
set -e
[[ "$unknown_rc" -ne 0 ]] || fail "unknown command succeeded"
assert_has "$unknown" "Unknown command" "unknown command diagnostic"
[[ ! -e "$cli_home/.waterbox" ]] || fail "unknown command created user state"
ok "read-only CLI inspection has no configuration side effects"

# Run the real parser/dispatcher with all effects stubbed. This tests option scope,
# arity, conflicts, and preservation of option-like literal values.
awk '/^# --- Argument parsing/{copying=1} copying{print}' "$WB" > "$TMP/parser.bash"
run_parser() {
    CONFIG_DIR="$TMP/parser-cfg" bash -c '
        set -e
        WATERBOX_GUI=0 WATERBOX_X11=0 WATERBOX_NO_GPU=0 WATERBOX_HERE=0
        WATERBOX_UNSAFE_HOST_ROOT=0 WATERBOX_VERSION=test
        _ensure_user_config() { echo INIT; }
        _valid_env_name() { case "$1" in ""|-*|*[!A-Za-z0-9._-]*) return 1 ;; esac; }
        _resolve_env() { echo "RESOLVE:${CLI_ENV_NAME:-}"; }
        _helper_current() { return 0; }
        env_cmd() { printf "CALL:env"; printf " <%s>" "$@"; echo; }
        status_all() { echo CALL:status-all; }
        help_env() { echo CALL:help-env; }
        log_error() { echo "ERR:$1"; exit 64; }
        show_help() { echo CALL:help; }
        help_start() { echo CALL:help-start; }
        help_share() { echo CALL:help-share; }
        help_wake() { echo CALL:help-wake; }
        help_schedule() { echo CALL:help-schedule; }
        start_sandbox() { printf "CALL:start:<%s>:gui=%s:here=%s\n" "${1:-}" "$WATERBOX_GUI" "$WATERBOX_HERE"; }
        stop_sandbox() { echo CALL:stop; }
        restart_sandbox() { echo CALL:restart; }
        status_sandbox() { echo CALL:status; }
        reset_sandbox() { echo CALL:reset; }
        ensure_host_privs() { echo CALL:setup; }
        refresh_config() { echo CALL:refresh; }
        emit_completion() { printf "CALL:completion:<%s>\n" "${1:-}"; }
        run_priv() { printf "CALL:helper"; printf " <%s>" "$@"; echo; }
        list_sessions_quiet() { echo CALL:sessions; }
        share_manager() { echo CALL:share-manager; }
        manage_share() { printf "CALL:share:<%s>:<%s>\n" "$1" "${2:-}"; }
        list_shares() { echo CALL:share-list; }
        wake_manager() { echo CALL:wake-manager; }
        manage_wake_claude() { printf "CALL:wake"; printf " <%s>" "$@"; echo; }
        wake_add() { printf "CALL:wake-add:<%s>\n" "$1"; }
        schedule_manager() { echo CALL:schedule-manager; }
        manage_schedule() { printf "CALL:schedule"; printf " <%s>" "$@"; echo; }
        sched_add() { printf "CALL:sched-add:<%s>\n" "$1"; }
        help_autostart() { echo CALL:help-autostart; }
        manage_autostart() { printf "CALL:autostart:<%s>\n" "${1:-}"; }
        self_update() { echo CALL:update; }
        parser_file=$1
        shift
        source "$parser_file"
    ' parser "$TMP/parser.bash" "$@"
}
parser_fails() {
    local out rc
    set +e
    out=$(run_parser "$@" 2>&1); rc=$?
    set -e
    [[ "$rc" -eq 64 ]] || fail "parser unexpectedly accepted: $* ($out)"
}
assert_has "$(run_parser start alpha)" "CALL:start:<alpha>" "named start dispatch"
assert_has "$(run_parser --gui start alpha)" "gui=1" "global flag before command"
assert_has "$(run_parser schedule-command sess 12:00 -- --gui daily)" \
    "<--gui> <daily>" "literal option-like scheduled command"
assert_has "$(run_parser schedule-command sess 12:00 "")" \
    "CALL:schedule <add> <sess> <12:00> <>" "empty Enter-only command, default mode"
assert_has "$(run_parser schedule-command sess 12:00 "" daily)" \
    "CALL:schedule <add> <sess> <12:00> <> <daily>" "mode is the optional last argument"
assert_has "$(run_parser share add "/tmp/a b")" \
    "CALL:share:<add>:</tmp/a b>" "share path containing spaces"
assert_has "$(run_parser autostart)" "CALL:autostart:<>" "bare autostart shows status"
assert_has "$(run_parser autostart on)" "CALL:autostart:<on>" "autostart on dispatch"
assert_has "$(run_parser autostart off)" "CALL:autostart:<off>" "autostart off dispatch"
assert_has "$(run_parser autostart --help)" "CALL:help-autostart" "autostart help"
parser_fails autostart onn
parser_fails autostart on extra
parser_fails autostart on --gui
parser_fails stop unexpected
parser_fails reset unexpected
parser_fails start alpha beta
parser_fails start --here named
parser_fails status --unsafe-host-root
parser_fails share list unexpected
parser_fails wake-claude list 12:00 daily unexpected
parser_fails schedule-command sess 12:00 once pwd
parser_fails schedule-command sess 12:00 pwd typo
parser_fails schedule-command sess 12:00 pwd daily extra
assert_has "$(run_parser schedule-command list 12:00 pwd)" \
    "CALL:schedule <add> <list> <12:00> <pwd>" "session named list"
assert_has "$(run_parser schedule-command del)" "CALL:sched-add:<del>" "session named del"
assert_has "$(run_parser wake-claude del 12:00)" \
    "CALL:wake <add> <del> <12:00>" "profile named del"
assert_has "$(run_parser wake-claude del wake-7)" \
    "CALL:wake <del> <wake-7>" "wake deletion dispatch"
assert_has "$(run_parser env)" "CALL:env" "bare env opens the menu"
assert_has "$(run_parser env list)" "CALL:env <list>" "env list"
assert_has "$(run_parser env create gaming)" "CALL:env <create> <gaming>" "env create"
assert_has "$(run_parser env rename a b)" "CALL:env <rename> <a> <b>" "env rename"
assert_has "$(run_parser env delete gaming)" "CALL:env <delete> <gaming>" "env delete"
assert_has "$(run_parser env --help)" "CALL:help-env" "env help"
assert_has "$(run_parser --env gaming stop)" "RESOLVE:gaming" "--env before the command"
assert_has "$(run_parser stop --env=gaming)" "RESOLVE:gaming" "--env= after the command"
assert_has "$(run_parser stop)" "RESOLVE:" "per-box commands always resolve an environment"
assert_has "$(run_parser status)" "CALL:status-all" "bare status summarizes every environment"
assert_has "$(run_parser status --env gaming)" "RESOLVE:gaming" "status --env shows one"
assert_has "$(run_parser start --env gaming alpha)" "CALL:start:<alpha>" "start keeps the session with --env"
assert_has "$(run_parser schedule-command --env g sess 12:00 pwd)" "RESOLVE:g" "schedule-command takes --env"
parser_fails env create
parser_fails env rename a
parser_fails env delete a b
parser_fails env bogus
parser_fails env list --gui
parser_fails env --env x list
parser_fails --env gaming update
parser_fails stop --env
parser_fails stop --env=
parser_fails stop --env -bad
ok "CLI parser rejects ignored/ambiguous arguments and preserves literals after --"

# Account/profile names are embedded in helper argument vectors and systemd unit
# metadata. Leading option-like names must be rejected at creation and host/helper
# scheduling boundaries.
awk '
    /^_agent_env_valid_new_name\(\)/ { copying=1 }
    copying { print }
    copying && /^}/ { exit }
' "$WB" > "$TMP/profile-name.zsh"
if command -v zsh >/dev/null 2>&1; then
    zsh -c 'source "$1"; _agent_env_valid_new_name personal &&
            ! _agent_env_valid_new_name --user &&
            ! _agent_env_valid_new_name .hidden &&
            ! _agent_env_valid_new_name "bad/name"' zsh "$TMP/profile-name.zsh"
    ok "agent-env rejects hidden, option-like, and path-like new account names"
else
    skip_test "agent-env account-name validation (zsh unavailable)"
fi
assert_has "$(grep -m1 '^_valid_profile()' "$TMP/helper.bash")" "|-*|" \
    "privileged helper leading-hyphen profile validation"
ok "privileged wake profile validation rejects option-like names"

# A symlink anywhere in a managed path must be rejected. The root itself must also
# stay literal: allowing the NOPASSWD helper's caller to redirect it would turn
# fixed privileged writes into arbitrary host-root writes. Relocation uses a bind
# mount at ~/.waterbox, which preserves the literal path.
awk '
    /^_in_jail\(\)/ { copying=1 }
    copying && /^_guard_jail_path\(\)/ { exit }
    copying { print }
' "$WB" > "$TMP/in-jail.bash"
real_root="$TMP/real-root"
outside="$TMP/outside"
mkdir -p "$real_root/safe" "$outside"
ln -s "$real_root" "$TMP/root-link"
ln -s "$outside" "$real_root/escape"
# shellcheck disable=SC1090
source "$TMP/in-jail.bash"
JAIL_ROOT="$real_root"
_in_jail "$JAIL_ROOT/safe/file" || fail "ordinary path inside root was rejected"
if _in_jail "$JAIL_ROOT/escape/file"; then
    fail "parent symlink escape was accepted"
fi
JAIL_ROOT="$TMP/root-link"
if _in_jail "$JAIL_ROOT/safe/file"; then
    fail "redirectable root symlink was accepted"
fi
ok "host-root path guard rejects parent escapes and a redirectable root symlink"

# Host inspection of guest-controlled markers must reject FIFOs, symlinks, and
# oversized files without blocking.
awk '
    /^_in_jail\(\)/ { copying=1 }
    copying && /^wb_tee\(\)/ { exit }
    copying { print }
' "$WB" > "$TMP/safe-reader.bash"
reader_root="$TMP/reader-root"
mkdir -p "$reader_root/etc"
printf 'current\n' > "$reader_root/etc/marker"
mkfifo "$reader_root/etc/fifo"
ln -s "$outside" "$reader_root/etc/redirect"
printf '123456789\n' > "$reader_root/etc/large"
timeout 2 bash -c '
    JAIL_ROOT=$1
    source "$2"
    [[ "$(_read_jail_regular "$JAIL_ROOT/etc/marker" 64)" == current ]]
    ! _read_jail_regular "$JAIL_ROOT/etc/fifo" 64 >/dev/null 2>&1
    ! _read_jail_regular "$JAIL_ROOT/etc/redirect/file" 64 >/dev/null 2>&1
    ! _read_jail_regular "$JAIL_ROOT/etc/large" 4 >/dev/null 2>&1
' reader "$reader_root" "$TMP/safe-reader.bash" \
    || fail "bounded rootfs reader accepted unsafe input or blocked"
ok "bounded rootfs reader rejects FIFO, symlink-parent, and oversized input"

# The update path must replace atomically with the exact downloaded bytes and keep
# executable permissions; malformed downloads must not touch the installed file.
awk '
    /^_version_gt\(\)/ { copying=1 }
    copying && /^attach_session\(\)/ { exit }
    copying { print }
' "$WB" > "$TMP/update-functions.bash"
awk '/^_refresh_completion_cache\(\)/,/^}/' "$WB" >> "$TMP/update-functions.bash"
old="$TMP/update-target"
remote="$TMP/update-remote"
cache="$TMP/update-cache"
printf '#!/usr/bin/env bash\nWATERBOX_VERSION="1.0"\necho old\n' > "$old"
mkdir -p "$TMP/update-cfg"; echo stale > "$TMP/update-cfg/completion.zsh"
printf '#!/usr/bin/env bash\nWATERBOX_VERSION="9.9"\necho new\n' > "$remote"
chmod 0751 "$old"
(
    # shellcheck disable=SC1090
    source "$TMP/update-functions.bash"
    WATERBOX_VERSION=1.0
    UPDATE_URL="file://$remote"
    PROJECT_URL=https://example.invalid/project
    UPDATE_CHECK_FILE="$cache"
    SELF_PATH="$old"
    CONFIG_DIR="$TMP/update-cfg"
    log_info() { :; }
    log_success() { :; }
    log_warn() { :; }
    log_error() { printf '%s\n' "$1" >&2; exit 1; }
    self_update
)
cmp -s "$old" "$remote" || fail "self-update did not install exact remote bytes"
assert_eq new "$(cat "$TMP/update-cfg/completion.zsh")" "self-update refreshes the cached completion from the new script"
assert_eq 751 "$(stat -c %a "$old")" "updated script mode"
before=$(cksum "$old")
printf '<html>not a script</html>\n' > "$remote"
set +e
(
    # shellcheck disable=SC1090
    source "$TMP/update-functions.bash"
    WATERBOX_VERSION=9.9
    UPDATE_URL="file://$remote"
    PROJECT_URL=https://example.invalid/project
    UPDATE_CHECK_FILE="$cache"
    SELF_PATH="$old"
    CONFIG_DIR="$TMP/update-cfg"
    log_info() { :; }
    log_success() { :; }
    log_warn() { :; }
    log_error() { exit 1; }
    self_update
) >/dev/null 2>&1
bad_update_rc=$?
set -e
[[ "$bad_update_rc" -ne 0 ]] || fail "malformed update was accepted"
assert_eq "$before" "$(cksum "$old")" "malformed update preservation"
ok "self-update is exact, atomic, mode-preserving, and rejects non-scripts"

# GUI forwarding is protocol-based: a live Wayland socket is accepted, and plain
# Wayland mode must not accidentally add an X11/Xwayland bind.
awk '
    /^build_gui_bind_args\(\)/ { copying=1 }
    copying && /^container_tmux\(\)/ { exit }
    copying { print }
' "$WB" > "$TMP/gui-function.bash"
mkdir -p "$TMP/runtime"
wayland_socket="$TMP/runtime/wayland-7"
python3 -c 'import socket,sys,time
s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(1); time.sleep(20)' \
    "$wayland_socket" &
socket_pid=$!
for _ in {1..50}; do [[ -S "$wayland_socket" ]] && break; sleep 0.02; done
[[ -S "$wayland_socket" ]] || fail "could not create Wayland test socket"
(
    # shellcheck disable=SC1090
    source "$TMP/gui-function.bash"
    GUI_ENV_FILE="$TMP/gui-env"
    GUI_BINDS_FILE="$TMP/gui-binds"
    CONFIG_DIR="$TMP/gui-config"
    HOST_RUNTIME_DIR="$TMP/runtime"
    WATERBOX_GUI=1
    WATERBOX_X11=0
    WAYLAND_DISPLAY="$wayland_socket"
    XDG_RUNTIME_DIR="$TMP/no-runtime-prefix"
    DISPLAY=:0
    RUN_USER=test
    HOME="$TMP/gui-home"
    mkdir -p "$CONFIG_DIR" "$HOME"
    build_gui_bind_args
    grep -Fq "$wayland_socket:/tmp/.waterbox-wayland" "$GUI_BINDS_FILE"
    ! grep -Fq '/tmp/.X11-unix/' "$GUI_BINDS_FILE"
    grep -Fq 'export GDK_BACKEND="wayland"' "$GUI_ENV_FILE"
)
kill "$socket_pid" 2>/dev/null || true
wait "$socket_pid" 2>/dev/null || true
ok "plain Wayland GUI forwarding does not expose X11"

# An explicit GUI request with no usable display must fail before boot instead of
# reporting success and leaving applications with dead display variables.
(
    # shellcheck disable=SC1090
    source "$TMP/gui-function.bash"
    GUI_ENV_FILE="$TMP/no-display-env"
    GUI_BINDS_FILE="$TMP/no-display-binds"
    CONFIG_DIR="$TMP/no-display-config"
    HOST_RUNTIME_DIR="$TMP/no-display-runtime"
    WATERBOX_GUI=1
    WATERBOX_X11=0
    WAYLAND_DISPLAY=wayland-0
    XDG_RUNTIME_DIR="$HOST_RUNTIME_DIR"
    DISPLAY=
    RUN_USER=test
    HOME="$TMP/no-display-home"
    mkdir -p "$CONFIG_DIR" "$HOME"
    log_warn() { :; }
    ! build_gui_bind_args
) || fail "an explicit GUI request without a display socket succeeded"
ok "explicit GUI forwarding fails fast when no display socket is usable"

# The privileged helper must derive GUI exports only from validated fixed targets.
# It must not copy a mutable caller-owned file as root, and the accepted sockets
# are limited to canonical display locations rather than arbitrary capabilities.
awk '
    /^write_gui_env\(\)/ { copying=1 }
    copying && /^clear_gui_env\(\)/ { exit }
    copying { print }
' "$TMP/helper.bash" > "$TMP/helper-gui-env.bash"
(
    # shellcheck disable=SC1090
    source "$TMP/helper-gui-env.bash"
    JAIL_ROOT="$TMP/gui-root"
    mkdir -p "$JAIL_ROOT/etc/waterbox"
    _in_jail() { return 0; }
    GUI_TARGETS=(/tmp/.waterbox-wayland)
    write_gui_env
    grep -Fq 'export WAYLAND_DISPLAY="/tmp/.waterbox-wayland"' \
        "$JAIL_ROOT/etc/waterbox/gui-env"
    GUI_TARGETS=()
    ! write_gui_env 2>/dev/null
) || fail "helper GUI environment was not derived safely"
assert_eq 0 "$(grep -c 'WB_CFG/gui_env' "$TMP/helper.bash" || true)" \
    "privileged mutable GUI environment reads"
assert_has "$(grep -A35 '^collect_gui_mounts()' "$TMP/helper.bash")" \
    '"/run/user/$wb_uid/$src_base"' "canonical Wayland runtime restriction"
assert_has "$(grep -A35 '^collect_gui_mounts()' "$TMP/helper.bash")" \
    '[ ! -L "$src" ]' "GUI source symlink rejection"
ok "privileged GUI forwarding derives trusted exports and rejects arbitrary sockets/files"

# DNS generation keeps glibc's three-server ceiling useful: at most one host
# resolver followed by the two known fallbacks, with short failover.
awk '
    /^_container_nameservers\(\)/ { copying=1 }
    copying && /^}/ { print; exit }
    copying { print }
' "$WB" > "$TMP/dns-function.bash"
(
    # shellcheck disable=SC1090
    source "$TMP/dns-function.bash"
    HOST_IP=10.20.30.1
    DNS_SERVERS=(1.1.1.1 8.8.8.8)
    _container_nameservers
) > "$TMP/resolv.generated"
assert_eq 1 "$(grep -c '^nameserver 1[.]1[.]1[.]1$' "$TMP/resolv.generated")" "Cloudflare fallback count"
assert_eq 1 "$(grep -c '^nameserver 8[.]8[.]8[.]8$' "$TMP/resolv.generated")" "Google fallback count"
[[ "$(grep -c '^nameserver ' "$TMP/resolv.generated")" -le 3 ]] || fail "too many DNS servers"
assert_has "$(tail -n1 "$TMP/resolv.generated")" "timeout:1 attempts:2" "DNS failover options"
ok "DNS output preserves room for both public fallbacks"

# Status reports the main live limits and headroom without depending on a real
# systemd unit in the test environment.
awk '
    /^human_bytes\(\)/ { copying=1 }
    copying && /^# Attach a host path/ { exit }
    copying { print }
' "$TMP/helper.bash" > "$TMP/resource-status.bash"
(
    # shellcheck disable=SC1090
    source "$TMP/resource-status.bash"
    _valid_id() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
    unit_property() {
        case "$1" in
            MemoryCurrent) echo 4294967296 ;;
            MemoryHigh) echo 8589934592 ;;
            MemoryMax) echo 12884901888 ;;
            TasksCurrent) echo 64 ;;
            TasksMax) echo 2048 ;;
            CPUWeight) echo 50 ;;
            CPUQuotaPerSecUSec) echo infinity ;;
        esac
    }
    slice_property() { unit_property "$@"; }
    resource_status 0
) > "$TMP/status.out"
assert_has "$(cat "$TMP/status.out")" "4.0 GiB / 12.0 GiB max" "status RAM use/max"
assert_has "$(cat "$TMP/status.out")" "8.0 GiB remaining" "status RAM remaining"
assert_has "$(cat "$TMP/status.out")" "no hard cap" "status CPU policy"
assert_has "$(cat "$TMP/status.out")" "64 / 2048" "status task use/max"
ok "resource status shows RAM, CPU, task use, limits, and remaining headroom"

# net_up must report any critical firewall/sysctl failure. A false success here
# makes start claim that a box with no working forwarding is usable.
awk '
    /^net_up\(\)/ { copying=1 }
    copying && /^net_down\(\)/ { exit }
    copying { print }
' "$TMP/helper.bash" > "$TMP/net-up.bash"
(
    # shellcheck disable=SC1090
    source "$TMP/net-up.bash"
    VE_IFACE=ve-test HOST_IP=10.20.30.1 NET_CIDR=24
    ALLOW_CONTAINER_TO_HOST_PORTS=true
    ip() { return 0; }
    sysctl() { return 0; }
    iptables() { return 0; }
    net_up
    sysctl() { return 1; }
    ! net_up
    # The inter-environment DROP is inserted last, so it sits above every ACCEPT.
    sysctl() { return 0; }
    iptables() { printf '%s\n' "$*" >> "$TMP/ipt.log"; [[ "$1" != -C && "$1" != -D ]]; }
    : > "$TMP/ipt.log"; net_up
    [[ "$(grep -- '^-I ' "$TMP/ipt.log" | tail -n1)" == '-I FORWARD 1 -i ve-waterbox+ -o ve-waterbox+ -j DROP' ]]
) || fail "net_up swallowed a critical setup failure, or environments can reach each other"
assert_eq 0 "$(grep -c 'net_up || true' "$TMP/helper.bash" || true)" "ignored net_up call count"
ok "network setup failures propagate instead of reporting a broken boot as successful"

# Host wake installation is transactional: a timer that systemd cannot enable is
# removed rather than being listed as if it would fire.
awk '
    /^_write_host_wake\(\)/ { copying=1 }
    copying && /^_reschedule_on_limit\(\)/ { exit }
    copying { print }
' "$TMP/helper.bash" > "$TMP/host-wake.bash"
(
    # shellcheck disable=SC1090
    source "$TMP/host-wake.bash"
    HW_ETC="$TMP/wake-units"
    wb_uid=1000 wb_env=4
    mkdir -p "$HW_ETC"
    systemctl() { return 0; }
    _write_host_wake 2 personal '*-*-* 12:00:00' 'personal @ 12:00 daily'
    grep -qx "ExecStart=$0 --env 4 wake personal --user 1000" "$HW_ETC/waterbox-hostwake-2.service"
    systemctl() {
        [[ "$1" == enable ]] && return 1
        return 0
    }
    ! _write_host_wake 1 personal '*-*-* 12:00:00' 'personal @ 12:00 daily' 2>/dev/null
    [[ ! -e "$HW_ETC/waterbox-hostwake-1.timer" ]]
    [[ ! -e "$HW_ETC/waterbox-hostwake-1.service" ]]
) || fail "failed host wake left orphan unit files (or lost its environment)"
ok "host wake creation rolls back when systemd cannot enable the timer"

# Schedule deletion must preserve failure, not print a false success.
awk '
    /^_sched_remove\(\)/ { seen++; if (seen == 2) copying=1 }
    copying { print }
    copying && /^}/ { exit }
' "$WB" > "$TMP/sched-remove.bash"
(
    # shellcheck disable=SC1090
    source "$TMP/sched-remove.bash"
    _helper_current() { return 1; }
    run_priv() { return 0; }
    ! _sched_remove schd-com-1
    _helper_current() { return 0; }
    run_priv() { return 1; }
    ! _sched_remove schd-com-1
) || fail "schedule removal swallowed a helper failure"
ok "schedule deletion propagates missing-helper and removal failures"

# A schedule's calendar must name its zone. The box's systemd would read a bare
# wall-clock time in the box's zone and the host list in the host's zone, so a
# zone mismatch fired commands hours off or collected them before they fired.
awk '
    /^_sched_calendar\(\)/ { copying=1 }
    copying && /^_sched_install\(\)/ { exit }
    copying { print }
' "$TMP/helper.bash" > "$TMP/sched-calendar.bash"
(
    # shellcheck disable=SC1090
    source "$TMP/sched-calendar.bash"
    export TZ=Asia/Tokyo
    [[ "$(_sched_calendar 12:00 once)" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ 03:00:00\ UTC$ ]]
    [[ "$(_sched_calendar 12:00 daily)" =~ ^\*-\*-\*\ [0-9]{2}:[0-9]{2}:00\ [A-Za-z] ]]
) || fail "schedule calendar is not zone-qualified"
awk '
    /^_sched_dump_records\(\)/ { copying=1 }
    copying && /^_sched_calendar\(\)/ { exit }
    copying { print }
' "$TMP/helper.bash" > "$TMP/sched-dump.bash"
sched_units="$TMP/sched-root/etc/systemd/system"
mkdir -p "$sched_units"
sched_timer() {
    printf '%s\n' "# waterbox: sess @ 12:00 $2" "[Timer]" "OnCalendar=$3" \
        > "$sched_units/waterbox-schd-com-$1.timer"
}
sched_timer 1 once  '2026-01-02 03:00:00 UTC'
sched_timer 2 daily '*-*-* 12:00:00 America/New_York'
sched_timer 3 once  '2026-01-02 12:00:00'
sched_timer 4 daily '*-*-* 13:00:00 America/New_York'
sched_timer 5 once  '2026-01-02 12:00:00 America/New_York'
sched_dump=$(
    # shellcheck disable=SC1090
    source "$TMP/sched-dump.bash"
    JAIL_ROOT="$TMP/sched-root" _sched_dump_records | sort | cut -f1,3
)
assert_eq "$(printf 'schd-com-%s\n' \
    $'1\tv2026-01-02 03:00:00 UTC' $'2\tv*-*-* 12:00:00 America/New_York' \
    $'3\tv2026-01-02 12:00:00' $'4\tv' $'5\tv')" "$sched_dump" \
    "schedule record calendars"
if command -v systemd-analyze >/dev/null 2>&1; then
    awk '
        /^_fmt_left\(\)/ { copying=1 }
        copying && /^HW_IDS=/ { exit }
        copying { print }
    ' "$WB" > "$TMP/timer-next.bash"
    (
        # shellcheck disable=SC1090
        source "$TMP/timer-next.bash"
        now=$(date +%s)
        _timer_next a "$(date -u -d "@$((now - 10))" '+%Y-%m-%d %H:%M:%S UTC')" "$now"
        [[ "$_TIMER_LEFT" == due && "$_TIMER_GC" == 0 ]]
        _timer_next b "$(date -u -d "@$((now - 3600))" '+%Y-%m-%d %H:%M:%S UTC')" "$now"
        [[ "$_TIMER_GC" == 1 ]]
    ) || fail "UTC one-shot was not held as due inside the accuracy grace"
else
    skip_test "UTC one-shot due/garbage-collection window (systemd-analyze unavailable)"
fi
ok "schedule calendars are zone-qualified and read consistently by the host"

# Mount-table inspection is host-side and exact. Live detach must use that result
# before changing its user-visible/persistent state.
awk '
    /^_mount_present\(\)/ { copying=1 }
    copying && /^# schedule-command timers/ { exit }
    copying { print }
' "$TMP/helper.bash" > "$TMP/mount-present.bash"
(
    # shellcheck disable=SC1090
    source "$TMP/mount-present.bash"
    MACHINE_NAME=test
    machinectl() { printf '%s\n' "$$"; }
    _mount_present /
    ! _mount_present /definitely-not-a-waterbox-mount
) || fail "host mount-table verifier did not distinguish present/absent mountpoints"
assert_has "$(grep -A28 '^    unshare)' "$TMP/helper.bash")" \
    '_mount_present "$target"' "live detach mount verification"
ok "live detach verifies revocation against the kernel mount table"

# Exact-line bookkeeping avoids regex/path corruption, and stopped-share failures
# have a narrow marker/rollback path rather than poisoning every future boot.
awk '
    /^_remove_share_record\(\)/ { copying=1 }
    copying && /^manage_share\(\)/ { exit }
    copying { print }
' "$WB" > "$TMP/share-records.bash"
(
    # shellcheck disable=SC1090
    source "$TMP/share-records.bash"
    CONFIG_DIR="$TMP/share-config"
    PENDING_SHARE_LIST="$CONFIG_DIR/shared_paths.pending"
    mkdir -p "$CONFIG_DIR"
    printf '%s\n' '/tmp/a[b]' '/tmp/ab' '/tmp/with space' > "$CONFIG_DIR/shared_paths"
    _remove_share_record "$CONFIG_DIR/shared_paths" '/tmp/a[b]'
    ! grep -Fxq '/tmp/a[b]' "$CONFIG_DIR/shared_paths"
    grep -Fxq '/tmp/ab' "$CONFIG_DIR/shared_paths"
    grep -Fxq '/tmp/with space' "$CONFIG_DIR/shared_paths"
) || fail "exact share-record removal damaged another path"
assert_has "$(grep -A70 'local boot_args=(boot)' "$WB")" \
    'WATERBOX_FAILED_SHARE_B64=' "stopped-share failure identity"
assert_has "$(grep -A70 'local boot_args=(boot)' "$WB")" \
    '_remove_share_record "$PENDING_SHARE_LIST" "$failed_share"' \
    "stopped-share pending rollback"
ok "share rollback is exact and stopped additions cannot permanently poison boot"

# A session rename must never claim schedule retargeting after swallowing a helper
# failure. The rename itself remains successful and is reported separately.
rename_body=$(grep -A45 '^_rename_session()' "$WB")
assert_eq 0 "$(printf '%s\n' "$rename_body" | grep -c 'sched-rename.*|| true' || true)" \
    "ignored schedule rename failure count"
assert_has "$rename_body" "scheduled commands could not be repointed" \
    "schedule rename failure warning"
ok "session rename reports schedule retargeting failures truthfully"

# Session restore. The host side only classifies the shutdown: a root-owned marker
# outside the rootfs, set by a successful COLD boot and cleared by a verified stop.
# Unattended paths never boot unsafely, and a wake boot never consumes a restore.
assert_has "$(grep -A3 '^    down)' "$TMP/helper.bash")" 'rm -f "$RESUME_MARK"' \
    "verified stop clears the unclean-shutdown marker"
assert_has "$(grep -A2 '^RESUME_MARK=' "$TMP/helper.bash")" 'RESUME_MARK="$RESUME_MARK-$wb_env"' \
    "each environment has its own restore marker (env 0 keeps live-<uid>)"
assert_eq "power_off" "$(grep -A1 '^    down)' "$TMP/helper.bash" | tail -n1 | tr -d ' ')" \
    "marker is cleared only after power_off succeeded"
assert_eq 2 "$(grep -c 'if \[ "$BOOT_COLD" = 1 \]; then resume_after_boot; fi' "$TMP/helper.bash")" \
    "restore/discard runs after cold boots only"
assert_eq 0 "$(awk '/^boot_min\(\)/,/^}/' "$TMP/helper.bash" | grep -c resume_after_boot || true)" \
    "wake boots never consume a pending restore"
assert_has "$(grep -A5 '^    autostart)' "$TMP/helper.bash")" 'boot_full 0 0 0 0 0 0' \
    "autostart boots secure, without GUI, USB, audio or gamepads"
assert_has "$(grep -B1 'boot_full 0 0 0 0 0 0' "$TMP/helper.bash")" 'unattended_lock' "autostart waits for a wake"
assert_has "$(awk '/^    wake\)/,/boot_min/' "$TMP/helper.bash")" 'unattended_lock' \
    "wake takes the lock before it can boot"
assert_eq 1 "$(grep -c 'RESUME_MARK_DIR="/var/lib/waterbox"' "$TMP/helper.bash")" "root-owned marker directory"
assert_has "$(grep -B3 -A1 'ensure_helper$' "$WB" | grep -A1 'outdated helper')" 'ensure_helper' \
    "reset of a stopped box refreshes the helper before clearing the marker"
assert_has "$(grep -A3 '^        on)' "$WB")" '.waterbox-ready' "autostart refuses an unbuilt box"
# Autostart unit: must not hold up the host's boot, and stops at shutdown.
au_body=$(awk '/^        body=\$\(printf/,/WantedBy=multi-user.target"\)$/' "$TMP/helper.bash")
au_unit=$(wb_uid=1000 wb_env=2; eval "$(sed 's/^ *//' <<< "$au_body")"; printf '%s\n' "$body")
for line in DefaultDependencies=no Type=simple Conflicts=shutdown.target Before=shutdown.target \
        'ExecStart=* --env 2 autostart --user 1000' WantedBy=multi-user.target; do
    grep -qx -- "$line" <<< "$au_unit" || [[ "$line" == *'*'* && "$au_unit" == *" --env 2 autostart --user 1000"* ]] \
        || fail "autostart unit lacks '$line'"
done
! grep -q '^Type=oneshot' <<< "$au_unit" || fail "autostart unit is a oneshot again (blocks multi-user.target)"
assert_has "$(grep -A12 '^ensure_host_privs()' "$WB")" 'run_priv autostart-enable' \
    "start regenerates an enabled autostart unit"
# Autostart waits for a home that is mounted after the host boots.
(
    home="$TMP/late-home"; mkdir -p "$home"
    source "$TMP/env.bash"
    verb=autostart wb_uid=1000 n=0 wb_env=2
    getent() { echo "u:x:1000:1000::$home:/bin/zsh"; }
    sleep() { n=$((n + 1)); [[ "$n" -lt 3 ]] || exit 1; mkdir -p "$home/.waterbox/envs/2/root"; : > "$home/.waterbox/envs/2/root/.waterbox-ready"; }
    eval "$(awk '/^if \[ "\$verb" = autostart \]; then$/,/^fi$/' "$TMP/helper.bash")"
    [[ "$n" == 1 && "$wb_home" == "$home" ]] || { echo "waited $n, home $wb_home"; exit 1; }
) >/dev/null || fail "autostart does not wait for a home mounted later"
[[ "$(grep -n 'unattended_lock$' "$TMP/helper.bash" | head -1 | cut -d: -f1)" -gt \
   "$(grep -n '^if \[ "$verb" = autostart \]; then$' "$TMP/helper.bash" | cut -d: -f1)" ]] \
    || fail "autostart must wait for the home before taking the unattended lock"
ok "autostart never blocks the host boot and waits for a late-mounted home"
# Completion cache follows content, not dates.
(
    CONFIG_DIR="$TMP/cc"; mkdir -p "$CONFIG_DIR"
    eval "$(awk '/^_refresh_completion_cache\(\)/,/^}/' "$WB")"
    emit_completion() { echo "new $1"; }
    echo old > "$CONFIG_DIR/completion.zsh"; touch -d '+1 day' "$CONFIG_DIR/completion.zsh"
    _refresh_completion_cache
    [[ "$(cat "$CONFIG_DIR/completion.zsh")" == "new zsh" ]] || exit 1
    other() { echo "other $*"; }
    _refresh_completion_cache other completion
    [[ "$(cat "$CONFIG_DIR/completion.zsh")" == "other completion zsh" ]]
) || fail "completion cache is not refreshed by content"
ok "completion cache refreshes when its content differs, even if it looks newer"
awk '/^write_resume_helper\(\)/ { copying=1 } /^# Next free schedule-command suffix/ { exit } copying { print }' \
    "$WB" > "$TMP/write-resume.bash"
(
    # shellcheck disable=SC1090
    source "$TMP/write-resume.bash"
    JAIL_ROOT="$TMP/resume-root" USER_NAME=water
    sudo() { "$@"; }
    _guard_jail_path() { :; }
    wb_tee() { mkdir -p "$(dirname "$1")"; cat > "$1"; }
    write_resume_helper
    python3 -c 'import json,sys; h=json.load(open(sys.argv[1]))["hooks"]
assert sorted(h) == ["SessionEnd","SessionStart","Stop","UserPromptSubmit"]' \
        "$JAIL_ROOT/etc/claude-code/managed-settings.json"
    python3 -c 'import tomllib,sys; h=tomllib.load(open(sys.argv[1],"rb"))["hooks"]
assert sorted(h) == ["Interrupt","SessionEnd","SessionStart","Stop","UserPromptSubmit"]
assert all(g[0]["hooks"][0]["command"] == "/usr/local/bin/waterbox-resume hook codex" for g in h.values())' \
        "$JAIL_ROOT/etc/codex/managed_config.toml"
    grep -Fxq 'KillMode=process' "$JAIL_ROOT/etc/systemd/system/waterbox-resume@.service"
    grep -Fxq 'Before=waterbox-resume-snapshot.timer' "$JAIL_ROOT/etc/systemd/system/waterbox-resume@.service"
    grep -Fxq 'Environment=XDG_RUNTIME_DIR=/run/user/1000' "$JAIL_ROOT/etc/systemd/system/waterbox-resume@.service"
    grep -Fxq 'After=user@1000.service' "$JAIL_ROOT/etc/systemd/system/waterbox-resume@.service"
    [[ -f "$JAIL_ROOT/var/lib/systemd/linger/water" ]]
    cmp -s "$JAIL_ROOT/usr/local/bin/waterbox-resume" "$TMP/waterbox-resume"
) || fail "generated session-restore hooks/units are malformed"
ok "session restore: marker lifecycle, unattended-boot limits, and managed agent hooks"

# Functional restore against an isolated tmux server (never the developer's own):
# record a mid-turn chat through the real hook, ignore an agent run BY an agent,
# "crash", restore, and check layout, directories and what each pane reopens.
if command -v tmux >/dev/null 2>&1; then
    rt="$TMP/rt"
    mkdir -p "$rt/home" "$rt/a" "$rt/b c" "$rt/bin" "$rt/rc"
    # Fake `claude rc`: python3 under the name claude runs the script file "rc".
    ln -s "$(command -v python3)" "$rt/bin/claude"
    echo 'import time; time.sleep(60)' > "$rt/rc/rc"
    cat > "$rt/agent.py" <<'AGENT'
# Fake agent: fires the hook the way an agent does. argv: resume event sid [nested]
import json, os, subprocess, sys
resume, event, sid = sys.argv[1:4]
payload = json.dumps({"hook_event_name": event, "session_id": sid, "cwd": os.getcwd(),
                      "transcript_path": ""})
if len(sys.argv) > 4:   # e.g. Claude running `codex exec` through its shell tool
    subprocess.run(["bash", "-c", 'python3 "$0" "$1" "$2" "$3"', __file__, resume, event, sid + "-x"])
else:
    subprocess.run(["sh", "-c", 'exec python3 "$0" hook claude', resume], input=payload, text=True)
AGENT
    (
        unset TMUX TMUX_PANE AGENT_ENV_PROFILE
        export HOME="$rt/home" TMUX_TMPDIR="$rt" SHELL=/bin/sh PATH="$rt/bin:$PATH"
        R="$TMP/waterbox-resume"
        trap 'tmux kill-server 2>/dev/null || true' EXIT
        tmux -f /dev/null new-session -d -s alpha -x 120 -y 40 -c "$rt/a"
        tmux new-window -t =alpha: -c "$rt/b c"
        tmux split-window -h -t =alpha:1 -c "$rt/a"
        tmux new-session -d -s beta -c "$rt/a"
        tmux new-session -d -s delta -c "$rt/rc"
        # Eight panes in one window: splitting without re-tiling runs out of room.
        tmux new-session -d -s gamma -x 120 -y 40 -c "$rt/a"
        for _ in {1..7}; do tmux split-window -t =gamma:0 -c "$rt/a" && tmux select-layout -t =gamma:0 tiled; done
        sleep 0.3
        tmux send-keys -t =alpha:1.1 "AGENT_ENV_PROFILE=work python3 '$rt/agent.py' '$R' UserPromptSubmit aaaa-1" Enter
        tmux send-keys -t =alpha:0.0 "python3 '$rt/agent.py' '$R' UserPromptSubmit bbbb-2 nested" Enter
        tmux send-keys -t =beta:0.0 "python3 '$rt/agent.py' '$R' Stop cccc-3" Enter
        tmux send-keys -t =delta:0.0 "claude rc --name 'x y'" Enter
        for _ in {1..50}; do
            [[ $(ls "$rt/home/.local/state/waterbox-resume/now/panes" 2>/dev/null | wc -l) -ge 2 ]] && break
            sleep 0.1
        done
        sleep 0.5
        python3 "$R" snapshot
        ino=$(stat -c %i "$rt/home/.local/state/waterbox-resume/now/layout.json")
        python3 "$R" snapshot
        [[ "$ino" == "$(stat -c %i "$rt/home/.local/state/waterbox-resume/now/layout.json")" ]] \
            || { echo "unchanged layout was rewritten"; exit 1; }
        before=$(tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index} #{pane_current_path} #{window_layout}')
        tmux kill-server; sleep 0.2                    # the "power cut"
        python3 "$R" restore
        after=$(tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index} #{pane_current_path} #{window_layout}')
        [[ "$(sed 's/%[0-9]*//g' <<< "$before")" == "$(sed 's/%[0-9]*//g' <<< "$after")" ]] \
            || { echo "layout differs: $before /// $after"; exit 1; }
        penv() { tr '\0' '\n' < "/proc/$(tmux display -p -t "$1" '#{pane_pid}')/environ" | grep -E '^(WB_RESUME|AGENT_ENV)' | sort | tr '\n' ' '; }
        [[ "$(penv =alpha:1.1)" == "AGENT_ENV_PROFILE=work WB_RESUME_AGENT=claude WB_RESUME_BUSY=1 WB_RESUME_DIR=$rt/a WB_RESUME_ID=aaaa-1 " ]] \
            || { echo "busy pane env: $(penv =alpha:1.1)"; exit 1; }
        [[ "$(penv =beta:0.0)" == *"WB_RESUME_BUSY=0"*"WB_RESUME_ID=cccc-3 " ]] || { echo "idle pane env"; exit 1; }
        [[ -z "$(penv =alpha:0.0)" ]] || { echo "nested agent was recorded"; exit 1; }
        [[ -z "$(penv =alpha:1.0)" ]] || { echo "plain pane got a chat"; exit 1; }
        # waterbox-rc: own window in the new folder, same profile, args kept intact.
        rm "$rt/bin/claude"     # the restore check above is done; now a fake that prints its args
        printf '#!/bin/sh\nprintf "<%%s>" "$@"; echo; exec sleep 60\n' > "$rt/bin/claude"; chmod +x "$rt/bin/claude"
        tmux send-keys -t =beta:0.0 "AGENT_ENV_PROFILE=work WATERBOX_RC_WAIT=1 bash '$TMP/waterbox-rc' '$rt/p q' --spawn worktree > '$rt/rc.out' 2>&1" Enter
        for _ in {1..50}; do grep -q '<remote-control>' "$rt/rc.out" 2>/dev/null && break; sleep 0.1; done
        grep -qF '<remote-control><--name><p q><--permission-mode><bypassPermissions><--spawn><worktree>' "$rt/rc.out" \
            || { echo "waterbox-rc output: $(cat "$rt/rc.out")"; exit 1; }
        [[ "$(tmux display -p -t '=beta:rc-p q' '#{pane_current_path}')" == "$rt/p q" ]] || { echo "waterbox-rc window"; exit 1; }
        [[ "$(penv '=beta:rc-p q')" == "AGENT_ENV_PROFILE=work " ]] || { echo "waterbox-rc profile"; exit 1; }
        tmux kill-window -t '=beta:rc-p q'
        [[ "$(penv =delta:0.0)" == "WB_RESUME_AGENT=claude WB_RESUME_BUSY=0 WB_RESUME_DIR=$rt/rc WB_RESUME_RUN=remote-control --name 'x y' " ]] \
            || { echo "remote control pane env: $(penv =delta:0.0)"; exit 1; }
        ! tmux show-environment -t =beta | grep -q '^WB_RESUME' || { echo "restore vars leaked into the session env"; exit 1; }
    ) || fail "tmux session restore did not reproduce the saved layout and chats"
    ok "session restore rebuilds the tmux layout and reopens only the pane's own chats and claude rc"
    if command -v zsh >/dev/null 2>&1; then
        run=$(python3 -c 'import shlex, sys; print(shlex.join(sys.argv[1:]))' remote-control --name "x 'y" '' '$HOME')
        assert_eq $'claude\nremote-control\n--name\nx \'y\n\n$HOME' \
            "$(zsh -fc 'cmd=(claude "${(@Q)${(z)1}}"); print -rl -- "${cmd[@]}"' _ "$run")" \
            "zshrc splits the saved claude rc arguments back exactly"
    fi
else
    skip_test "functional tmux session restore (tmux unavailable)"
fi

# Static boundary invariants are intentionally redundant: a future edit should
# fail loudly if either boot path loses its user namespace, device cgroup, cgroup
# limits, mount flags, or if namespace entry becomes partial.
assert_eq 2 "$(grep -c -- '--property=DevicePolicy=closed' "$WB")" "closed device policy boot count"
[[ "$(grep -c -- '--private-users=pick --private-users-ownership=map' "$WB")" -ge 2 ]] \
    || fail "private-user isolation missing from a secure path"
assert_eq 0 "$(grep -E '^[[:space:]]*nsenter ' "$WB" | grep -vc -- '--all' || true)" "partial nsenter count"
assert_eq 0 "$(grep -Ec '^[[:space:]]*machinectl status' "$TMP/helper.bash" || true)" "raw guest process-tree status count"
for setting in TasksMax OOMPolicy; do
    [[ "$(grep -c -- "--property=$setting" "$WB")" -ge 2 ]] \
        || fail "$setting missing from a boot path"
done
# Memory, CPU and I/O limits live on the slice every environment shares, so two
# running boxes together stay inside the single-box budget.
assert_eq 2 "$(grep -c -- '--slice=waterbox.slice' "$TMP/helper.bash")" "both boot paths join the shared slice"
assert_eq 0 "$(grep -cE -- '--property=(MemoryHigh|MemoryMax|MemorySwapMax|CPUWeight|IOWeight)=' "$TMP/helper.bash" || true)" \
    "per-unit memory/CPU/IO limits would bypass the shared cap"
slice_fn=$(awk '/^ensure_slice\(\)/,/^}/' "$TMP/helper.bash")
for setting in MemoryHigh MemoryMax MemorySwapMax CPUWeight IOWeight; do
    assert_has "$slice_fn" "\"$setting=" "shared slice sets $setting"
done
assert_eq 2 "$(grep -c '^    ensure_slice \\$' "$TMP/helper.bash")" "both boot paths fail closed without the slice"
assert_has "$(sed -n '1,/^verb=/p' "$TMP/helper.bash")" 'if [ "${1:-}" = --env ]; then' "helper takes --env first"
assert_has "$(grep -A4 'cat <<EOF' "$WB" | head -0; grep -F 'declare -f _valid_env_id _env_ids_apply _env_dir_for' "$WB")" \
    'declare -f' "helper receives the CLI's environment identity verbatim"
assert_has "$(grep -n 'MOUNT_ATTR_NOSUID.*MOUNT_ATTR_NODEV' "$TMP/helper.bash")" \
    "MOUNT_ATTR_NOSUID" "share mount nosuid/nodev attributes"
assert_has "$(grep -A25 'del|detach)' "$WB")" "is_running && ensure_helper" \
    "live detach helper refresh"
assert_has "$(grep -A40 'del|detach)' "$WB")" "it remains shared" \
    "live detach rollback"
assert_has "$(grep -F -A8 'if [ "$keep_shares" != 1 ]; then' "$WB")" \
    ': > "$PENDING_SHARE_LIST"' "reset pending-share cleanup"
{ cat "$TMP/env.bash"; cat "$TMP/helper.bash"; } > "$TMP/helper-run.bash"
assert_has "$(env -u SUDO_UID bash "$TMP/helper-run.bash" --env 16 state 2>&1 || true)" "bad environment id" \
    "helper rejects an out-of-range environment"
assert_has "$(env -u SUDO_UID bash "$TMP/helper-run.bash" state --env 3 2>&1 || true)" "no valid target user" \
    "helper ignores --env anywhere but first"
assert_has "$(env -u SUDO_UID bash "$TMP/helper-run.bash" --env 3 state 2>&1 || true)" "no valid target user" \
    "helper accepts a valid leading --env"
assert_eq 0 "$(grep -E 'sudo (-n )?"\$HELPER_PATH"' "$WB" | grep -vc '"\$HELPER_PATH" --env "\$WB_ENV"' || true)" \
    "every helper invocation names the active environment"
ok "primary isolation, device, namespace, resource, and share-mount invariants"

# USB sharing is opt-in: the flag must reach the helper, the raw-usbfs bind and
# its DeviceAllow must exist only inside the usb branch of the full boot path,
# a failed access grant must stop the box, and stop must revoke the host ACLs.
assert_has "$(grep -A30 'local boot_args=(boot)' "$WB")" '--usb' "usb boot flag plumbed"
assert_eq 1 "$(grep -c -- '--bind=/dev/bus/usb' "$TMP/helper.bash")" "raw usbfs bind count"
assert_eq 1 "$(grep -c -- 'char-usb_device rw' "$TMP/helper.bash")" "usb DeviceAllow count"
assert_has "$(grep -A3 'usb_grant; then' "$TMP/helper.bash")" 'power_off' "failed usb grant stops the box"
assert_has "$(grep -A2 '^power_off()' "$TMP/helper.bash")" 'usb_revoke' "stop revokes usb ACLs"
ok "usb sharing stays opt-in, helper-validated, and cleaned up on stop"

# Missing readiness may trigger an automatic retry only with Waterbox's separate
# host marker; deleting the in-box marker alone must never authorize a wipe.
assert_has "$(grep -F -A8 'if [ -e "$JAIL_ROOT" ] && [ ! -f "$BOOTSTRAP_IN_PROGRESS" ]; then' "$WB")" \
    "will not erase it automatically" "missing-ready refusal"
assert_has "$(grep -F -A3 '_guard_jail_path "$JAIL_ROOT/etc/pacman.conf"' "$WB")" \
    "sudo sed -i" "post-package pacman guard"
assert_has "$(grep -F -A18 'if ! ( bootstrap_sandbox ); then' "$WB")" \
    "Your original home is safe at" "failed reset home recovery"
ok "bootstrap retry and post-package host-root writes fail closed"

# --- Environments --------------------------------------------------------------
# Env identity is a pure function of the id; env 0 keeps every single-box name.
(
    log_warn() { :; }
    # shellcheck disable=SC1090
    source "$TMP/env.bash"
    HOME="$TMP/envhome"; CONFIG_DIR="$HOME/.waterbox"; ENV_REGISTRY="$CONFIG_DIR/envs.list"
    _env_ids_apply 0
    [[ "$MACHINE_NAME $VE_IFACE $HOST_IP $CONTAINER_IP" == "waterbox ve-waterbox 10.20.30.1 10.20.30.2" ]]
    _env_ids_apply 15
    [[ "$MACHINE_NAME $VE_IFACE $HOST_IP" == "waterbox-15 ve-waterbox-15 10.20.45.1" ]]
    [[ "${#VE_IFACE}" -le 15 ]]
    ! _valid_env_id 16 && ! _valid_env_id 01 && ! _valid_env_id '' && _valid_env_id 7
    _use_env 3; [[ "$JAIL_ROOT" == "$HOME/.waterbox/envs/3/root" && "$AUTOSTART_UNIT" == waterbox-autostart-3.service ]]
    _use_env 0
    [[ "$JAIL_ROOT" == "$HOME/.waterbox/root" && "$SHARE_LIST" == "$HOME/.waterbox/shared_paths" ]]
    [[ "$AUTOSTART_UNIT" == waterbox-autostart.service ]]
    _env_registry_init; [[ "$(_env_rows)" == "0 main" ]]
    id=$(_env_create gaming); [[ "$id" == 1 ]]
    ! _env_create gaming >/dev/null 2>&1
    ! _env_create 'bad name' >/dev/null 2>&1
    ! _env_create -x >/dev/null 2>&1
    mkdir -p "$HOME/.waterbox/envs/2/root"                 # leftover rootfs: slot skipped
    mkdir -p "$HOME/.waterbox/envs/3"; : > "$HOME/.waterbox/envs/3/shared_paths"   # leftover config too
    [[ "$(_env_create third)" == 4 ]]
    _env_rename main agents
    [[ "$(_env_id_of agents)" == 0 && "$(_env_name_of 1)" == gaming ]]
    ! _env_rename agents gaming >/dev/null 2>&1
    printf 'junk\n99 x\n2 ok extra\n' >> "$ENV_REGISTRY"
    [[ "$(_env_rows | wc -l)" == 3 && "$(_env_names)" == "agents gaming third" ]]
    out=$(_env_create 'b d' 2>/dev/null) || true; [[ -z "$out" ]]   # warnings never land in the id
) || fail "environment identity/registry"
ok "environment identity, registry migration, create and rename"

# Environment resolution for per-box commands and the cross-environment picker.
awk '/^_env_label\(\)/ { c=1 } c && /^# `waterbox env \[list/ { exit } c { print }' "$WB" > "$TMP/env-select.bash"
awk '/^_session_rows\(\)/ { c=1 } c && /^# Name a new session in the active/ { exit } c { print }' "$WB" > "$TMP/session-rows.bash"
(
    log_warn() { :; }; log_info() { :; }
    log_error() { echo "ERR:$1"; exit 64; }
    # shellcheck disable=SC1090
    source "$TMP/env.bash"; source "$TMP/env-select.bash"; source "$TMP/session-rows.bash"
    HOME="$TMP/selhome"; CONFIG_DIR="$HOME/.waterbox"; ENV_REGISTRY="$CONFIG_DIR/envs.list"
    mkdir -p "$CONFIG_DIR"; printf '0 main\n' > "$ENV_REGISTRY"
    RUNNING=" "
    is_running() { [[ "$RUNNING" == *" $WB_ENV "* ]]; }
    # One environment: always it, no question asked.
    CLI_ENV_NAME=""; WB_ENV_RESOLVED=0; _resolve_env </dev/null; [[ "$WB_ENV" == 0 ]]
    printf '0 main\n1 gaming\n2 spare\n' > "$ENV_REGISTRY"
    # The only running one wins.
    RUNNING=" 1 "; WB_ENV_RESOLVED=0; _resolve_env </dev/null; [[ "$WB_ENV" == 1 ]]
    # Ambiguous without a terminal: an error naming --env, never a guess.
    RUNNING=" 0 1 "; WB_ENV_RESOLVED=0
    [[ "$( (_resolve_env </dev/null) )" == ERR:*--env* ]]
    # --env wins; an unknown name is an error.
    CLI_ENV_NAME=spare; WB_ENV_RESOLVED=0; _resolve_env; [[ "$WB_ENV" == 2 ]]
    # A later loop over environments must not leak into the resolved choice.
    _use_env 0; _resolve_env; [[ "$WB_ENV" == 2 ]]
    CLI_ENV_NAME=nope; WB_ENV_RESOLVED=0; [[ "$( (_resolve_env) )" == ERR:*nope* ]]
    # The picker lists running environments' sessions with the environment name.
    CLI_ENV_NAME=""
    _live_sessions() { [[ "$WB_ENV" == 0 ]] && printf 'work\nbox\n'; [[ "$WB_ENV" == 1 ]] && echo box; return 0; }
    _session_rows
    [[ "${#SR_NAME[@]}" == 3 && "${SR_ENV[2]}" == 1 && "${SR_LABEL[2]}" == *"[gaming]"* ]]
    CLI_ENV_NAME=gaming; _session_rows; [[ "${#SR_NAME[@]}" == 1 ]]
    # A named start finds the environment that already has that session.
    CLI_ENV_NAME=""
    container_tmux() { [[ "$3" == "=only-gaming" && "$WB_ENV" == 1 ]] || [[ "$3" == "=box" ]]; }
    [[ "$(_session_matches only-gaming)" == 1 ]]
    [[ "$(_session_matches box | paste -sd' ')" == "0 1" ]]
    # Host wakes record their environment; units older than environments mean env 0.
    HOSTWAKE_GLOB="$TMP/selwake/waterbox-hostwake-"; mkdir -p "$TMP/selwake"
    echo 'ExecStart=/h --env 2 wake p --user 1000' > "${HOSTWAKE_GLOB}5.service"
    echo 'ExecStart=/h wake p --user 1000' > "${HOSTWAKE_GLOB}6.service"
    [[ "$(_hostwake_env 5)" == 2 && "$(_hostwake_env 6)" == 0 ]]
) || fail "environment resolution and cross-environment session rows"
start_body=$(awk '/^start_sandbox\(\)/,/^}/' "$WB")
assert_has "$start_body" '_env_ensure_one' "first start creates an environment"
assert_has "$start_body" 'exists in several environments' "an ambiguous named session is refused"
assert_has "$(awk '/^_pick_session\(\)/,/^}/' "$WB")" \
    'Select a session (↑/↓ move · Enter attach · a new · r rename · d kill · q quit):' "picker prompt kept"
assert_has "$(awk '/^_env_menu\(\)/,/^}/' "$WB")" \
    'Select an environment (↑/↓ move · Enter $verb · a new · r rename · d delete · q quit):' "environment menu"
assert_has "$(awk '/^restart_sandbox\(\)/,/^}/' "$WB")" 'CLI_ENV_NAME=' "restart comes back in its environment"
del_body=$(awk '/^_env_delete\(\)/,/^}/' "$WB")
assert_has "$del_body" 'Stop it first' "delete refuses a running environment"
assert_has "$del_body" 'Type the environment name' "delete requires the name typed back"
assert_has "$del_body" 'realpath -e -- "$JAIL_ROOT"' "delete refuses a redirected rootfs path"
[[ "$(grep -n '_remove_env_hostwakes \\' <<< "$del_body" | cut -d: -f1)" -lt \
   "$(grep -n 'sudo rm -rf -- "$JAIL_ROOT"' <<< "$del_body" | cut -d: -f1)" ]] \
    || fail "delete must drop the environment's wakes before its rootfs"
assert_has "$(awk '/^reset_sandbox\(\)/,/^}/' "$WB")" '_remove_env_hostwakes' "reset removes only its environment's wakes"
ok "environment resolution, cross-environment picker and delete safeguards"

# --audio: PipeWire only, fixed host path, the host Pulse socket never exposed;
# the guest runs its own pipewire-pulse against it.
assert_has "$(run_parser start --audio)" "CALL:start" "start accepts --audio"
assert_has "$(run_parser restart --gamepad)" "CALL:restart" "restart accepts --gamepad"
parser_fails status --audio
parser_fails reset --gamepad
parser_fails share list --audio
audio_fn=$(awk '/^collect_audio_mount\(\)/,/^}/' "$TMP/helper.bash")
assert_has "$audio_fn" 'sock="/run/user/$wb_uid/pipewire-0"' "audio accepts only the host user's PipeWire socket"
assert_has "$audio_fn" '[ ! -L "$sock" ]' "audio rejects a symlinked socket"
assert_has "$audio_fn" '[ ! -L "$dir" ]' "audio rejects a symlinked runtime dir"
assert_eq 0 "$(grep -c 'pulse/native' "$WB" || true)" "the host Pulse socket is never mounted"
assert_has "$(grep -F -A4 'allowed_gui = {' "$TMP/helper.bash")" '/tmp/.waterbox-pipewire' "mount shim allows only the fixed audio target"
assert_has "$(cat "$TMP/zshrc")" '[ -f /etc/waterbox/boot-env ] && source /etc/waterbox/boot-env' "shell sources the boot env"
units=$(awk '/^configure_audio_units\(\)/,/^}/' "$WB")
assert_has "$units" 'Environment=PIPEWIRE_REMOTE=/tmp/.waterbox-pipewire' "in-box pipewire-pulse targets the host graph"
for unit in pipewire.service pipewire.socket wireplumber.service; do
    assert_has "$units" "$unit" "in-box $unit is masked"
done
assert_eq "$(grep -c 'sudo ln -sfn' <<< "$units")" "$(grep -c '_guard_jail_path "\$u/\$unit"\|_guard_jail_path "\$u/sockets.target.wants/pipewire-pulse.socket"' <<< "$units")" \
    "every in-rootfs symlink is guarded"
boot_env=$(awk '/^write_boot_env\(\)/,/^}/' "$TMP/helper.bash")
assert_has "$boot_env" '_in_jail "$target"' "boot-env write is contained"
ok "audio is PipeWire-only, fixed-path, and served by the box's own pipewire-pulse"

# --gamepad: joysticks and their own hidraw only, exact-path DeviceAllow, and a
# guard that revokes a node once it is unplugged (its number may go to a keyboard).
awk '/^_is_chardev\(\)/ { c=1 } c && /^# --- end gamepad collect/ { exit } c { print }' "$TMP/helper.bash" > "$TMP/pad.bash"
[[ -s "$TMP/pad.bash" ]] || fail "could not extract gamepad selection"
(
    # shellcheck disable=SC1090
    source "$TMP/pad.bash"
    S="$TMP/pad/sys" U="$TMP/pad/udev" D="$TMP/pad/dev"
    mkdir -p "$S/class/input" "$S/class/hidraw" "$U" "$D/input"
    mk() {  # node minor hid-device udev-props...
        local n=$1 m=$2 hid=$3 in="$S/devices/$3/input/input$2"; shift 3
        mkdir -p "$in/$n"
        ln -s "../../devices/$hid/input/input$m/$n" "$S/class/input/$n"
        ln -s ../.. "$in/device"; ln -s .. "$in/$n/device"
        echo "13:$m" > "$in/$n/dev"
        printf 'E:%s\n' "$@" > "$U/c13:$m"; : > "$D/input/$n"
    }
    mk event5 69 hidpad ID_INPUT=1 ID_INPUT_JOYSTICK=1
    mkdir -p "$S/devices/hidpad/input/input69/js0"; : > "$D/input/js0"
    mk event6 70 hidkbd ID_INPUT=1 ID_INPUT_KEY=1 ID_INPUT_KEYBOARD=1
    mk event7 71 hidcombo ID_INPUT=1 ID_INPUT_JOYSTICK=1 ID_INPUT_KEYBOARD=1
    mk event8 72 hidmouse ID_INPUT=1 ID_INPUT_MOUSE=1
    # A keyboard whose media collection is misdetected as a joystick: same HID
    # device (and hidraw) as its key reports, so nothing of it may pass.
    mk event9 73 hidkbd2 ID_INPUT=1 ID_INPUT_JOYSTICK=1
    mk event10 74 hidkbd2 ID_INPUT=1 ID_INPUT_KEY=1 ID_INPUT_KEYBOARD=1
    for h in 0:hidpad 1:hidkbd 2:hidcombo 3:fidokey 4:hidkbd2; do
        mkdir -p "$S/devices/${h#*:}" "$S/class/hidraw/hidraw${h%%:*}"
        ln -s "../../../devices/${h#*:}" "$S/class/hidraw/hidraw${h%%:*}/device"
        : > "$D/hidraw${h%%:*}"
    done
    _is_chardev() { [ -e "$1" ] && [ ! -L "$1" ]; }
    collect_gamepad_nodes "$S" "$U" "$D"
    [[ "${GAMEPAD_NODES[*]}" == "$D/input/event5 $D/input/js0 $D/hidraw0" ]] \
        || { echo "selected: ${GAMEPAD_NODES[*]}"; exit 1; }
    # Each pick carries the sysfs identity the guard compares against later.
    [[ "${#GAMEPAD_IDS[@]}" == 3 && "${GAMEPAD_IDS[0]}" == "$(realpath "$S/devices/hidpad/input/input69/event5")" ]]
) || fail "gamepad selection must pass only joysticks, their js nodes and their own hidraw"
assert_eq 0 "$(grep -E 'bind=.*uinput|DeviceAllow=.*uinput' "$TMP/helper.bash" | wc -l)" "uinput is never bound or allowed"
assert_eq 0 "$(grep -cE 'char-input|char-hidraw' "$TMP/helper.bash" || true)" "no whole-major input/hidraw DeviceAllow"
full_boot=$(awk '/^boot_full\(\)/,/^}/' "$TMP/helper.bash")
assert_has "$full_boot" 'props+=(--property=DeviceAllow="$n rw")' "each gamepad node is allowed by exact path"
assert_has "$full_boot" 'devguard_start "${allow_list[@]}" || ! gamepad_grant' "guard runs before access is granted, failure stops the box"
guard=$(awk '/^    devguard\)/,/^        ;;$/' "$TMP/helper.bash")
assert_has "$guard" '[ -z "${SUDO_UID:-}" ]' "the guard cannot be driven through sudo"
assert_has "$guard" '"UDEV - "*)' "the guard re-checks nodes once it listens"
assert_has "$(awk '/^devguard_drop\(\)/,/^}/' "$TMP/helper.bash")" 'set-property --runtime "$MACHINE_NAME.service"' \
    "the guard narrows the running unit's DeviceAllow"
assert_has "$(awk '/^devguard_start\(\)/,/^}/' "$TMP/helper.bash")" '--property=BindsTo="$MACHINE_NAME.service"' \
    "the guard lives and dies with its box"
assert_has "$(awk '/^usb_revoke\(\)/,/^}/' "$TMP/helper.bash")" '/dev/hidraw*' "stop revokes gamepad ACLs"
assert_has "$(awk '/^power_off\(\)/,/^}/' "$TMP/helper.bash")" 'devguard_clear' "stop removes the guard and its state"
(
    # devguard_drop rewrites the recorded list and applies all remaining entries.
    eval "$(awk '/^devguard_drop\(\)/,/^}/' "$TMP/helper.bash")"
    DEVGUARD_ALLOW="$TMP/guard-allow" DEVGUARD_PADS="$TMP/guard-pads" MACHINE_NAME=waterbox-2
    printf '%s\n' 'char-pts rw' '/dev/input/event5 rw' '/dev/input/event55 rw' > "$DEVGUARD_ALLOW"
    printf '%s\n' '/dev/input/event5 /sys/a' '/dev/input/event55 /sys/b' > "$DEVGUARD_PADS"
    logger() { :; }
    # A failed narrowing stops the box and keeps the node recorded (fail closed).
    systemctl() { printf '%s\n' "$*" >> "$TMP/guard-fail"; [[ "$1" != set-property ]]; }
    ! devguard_drop /dev/input/event5
    grep -qx 'stop waterbox-2.service' "$TMP/guard-fail"
    grep -qx '/dev/input/event5 rw' "$DEVGUARD_ALLOW"
    systemctl() { printf '%s\n' "$@" > "$TMP/guard-call"; }
    devguard_drop /dev/input/event5
    [[ "$(cat "$DEVGUARD_ALLOW")" == $'char-pts rw\n/dev/input/event55 rw' ]]
    [[ "$(cat "$DEVGUARD_PADS")" == '/dev/input/event55 /sys/b' ]]
    [[ "$(cat "$TMP/guard-call")" == $'set-property\n--runtime\nwaterbox-2.service\nDeviceAllow=\nDeviceAllow=char-pts rw\nDeviceAllow=/dev/input/event55 rw' ]]
) || fail "device guard must drop exactly the removed node, and fail closed"
assert_has "$(awk '/^devguard_start\(\)/,/^}/' "$TMP/helper.bash")" 'changed device during the boot' \
    "a node that changed device before the guard started fails the boot"
assert_has "$(awk '/^devguard_start\(\)/,/^}/' "$TMP/helper.bash")" 'StartLimitIntervalSec=0' \
    "the guard is never rate-limited into staying down"
ok "gamepads: joysticks only, exact-path access, guarded against minor-number reuse"

printf '# %d checks passed, %d skipped\n' "$pass" "$skip"
printf '1..%d\n' "$count"
