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

extract "cat <<'FIRE'" '^FIRE$' "$TMP/fire.sh"
sh -n "$TMP/fire.sh"
ok "generated in-box scheduler helper syntax"

extract '^_statusline_body' '^SL$' "$TMP/statusline.sh"
sh -n "$TMP/statusline.sh"
ok "generated statusline POSIX shell syntax"

extract "wb_tee .*[.]zshrc.*<<'EOF'" '^EOF$' "$TMP/zshrc"
if command -v zsh >/dev/null 2>&1; then
    zsh -n "$TMP/zshrc"
    ok "generated zshrc syntax"
else
    skip_test "generated zshrc syntax (zsh unavailable)"
fi
assert_has "$(cat "$TMP/zshrc")" 'known_marketplaces.json' \
    "zshrc self-heals pre-1.9 marketplace installLocation paths"

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
    bash -c '
        set -e
        WATERBOX_GUI=0 WATERBOX_X11=0 WATERBOX_NO_GPU=0 WATERBOX_HERE=0
        WATERBOX_UNSAFE_HOST_ROOT=0 WATERBOX_VERSION=test
        _ensure_user_config() { echo INIT; }
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
assert_has "$(run_parser schedule-command sess 12:00 once -- --gui)" "<--gui>" "literal option-like scheduled command"
assert_has "$(run_parser schedule-command sess 12:00 once "")" \
    "CALL:schedule <add> <sess> <12:00> <once> <>" "empty Enter-only command"
assert_has "$(run_parser share add "/tmp/a b")" \
    "CALL:share:<add>:</tmp/a b>" "share path containing spaces"
parser_fails stop unexpected
parser_fails reset unexpected
parser_fails start alpha beta
parser_fails start --here named
parser_fails status --unsafe-host-root
parser_fails share list unexpected
parser_fails wake-claude list 12:00 daily unexpected
parser_fails schedule-command sess 12:00 once
parser_fails schedule-command sess 12:00 typo ignored
assert_has "$(run_parser schedule-command list 12:00 pwd)" \
    "CALL:schedule <add> <list> <12:00> <pwd>" "session named list"
assert_has "$(run_parser schedule-command del)" "CALL:sched-add:<del>" "session named del"
assert_has "$(run_parser wake-claude del 12:00)" \
    "CALL:wake <add> <del> <12:00>" "profile named del"
assert_has "$(run_parser wake-claude del wake-7)" \
    "CALL:wake <del> <wake-7>" "wake deletion dispatch"
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
old="$TMP/update-target"
remote="$TMP/update-remote"
cache="$TMP/update-cache"
printf '#!/usr/bin/env bash\nWATERBOX_VERSION="1.0"\necho old\n' > "$old"
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
    log_info() { :; }
    log_success() { :; }
    log_warn() { :; }
    log_error() { printf '%s\n' "$1" >&2; exit 1; }
    self_update
)
cmp -s "$old" "$remote" || fail "self-update did not install exact remote bytes"
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
) || fail "net_up swallowed a critical setup failure"
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
    wb_uid=1000
    mkdir -p "$HW_ETC"
    systemctl() {
        [[ "$1" == enable ]] && return 1
        return 0
    }
    ! _write_host_wake 1 personal '*-*-* 12:00:00' 'personal @ 12:00 daily' 2>/dev/null
    [[ ! -e "$HW_ETC/waterbox-hostwake-1.timer" ]]
    [[ ! -e "$HW_ETC/waterbox-hostwake-1.service" ]]
) || fail "failed host wake left orphan unit files"
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

# Static boundary invariants are intentionally redundant: a future edit should
# fail loudly if either boot path loses its user namespace, device cgroup, cgroup
# limits, mount flags, or if namespace entry becomes partial.
assert_eq 2 "$(grep -c -- '--property=DevicePolicy=closed' "$WB")" "closed device policy boot count"
[[ "$(grep -c -- '--private-users=pick --private-users-ownership=map' "$WB")" -ge 2 ]] \
    || fail "private-user isolation missing from a secure path"
assert_eq 0 "$(grep -E '^[[:space:]]*nsenter ' "$WB" | grep -vc -- '--all' || true)" "partial nsenter count"
assert_eq 0 "$(grep -Ec '^[[:space:]]*machinectl status' "$TMP/helper.bash" || true)" "raw guest process-tree status count"
for setting in MemoryHigh MemoryMax MemorySwapMax TasksMax OOMPolicy; do
    [[ "$(grep -c -- "--property=$setting" "$WB")" -ge 2 ]] \
        || fail "$setting missing from a boot path"
done
assert_has "$(grep -n 'MOUNT_ATTR_NOSUID.*MOUNT_ATTR_NODEV' "$TMP/helper.bash")" \
    "MOUNT_ATTR_NOSUID" "share mount nosuid/nodev attributes"
assert_has "$(grep -A25 'del|detach)' "$WB")" "is_running && ensure_helper" \
    "live detach helper refresh"
assert_has "$(grep -A40 'del|detach)' "$WB")" "it remains shared" \
    "live detach rollback"
assert_has "$(grep -F -A8 'if [ "$keep_shares" != 1 ]; then' "$WB")" \
    ': > "$PENDING_SHARE_LIST"' "reset pending-share cleanup"
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

printf '# %d checks passed, %d skipped\n' "$pass" "$skip"
printf '1..%d\n' "$count"
