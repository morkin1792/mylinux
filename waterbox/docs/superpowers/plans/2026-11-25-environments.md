# Waterbox Environments, Audio and Gamepads Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Several independent boxes ("environments") per host user, a cross-environment session picker, and opt-in `--audio`/`--gamepad` boot flags.

**Architecture:** One per-environment identity function (`_env_ids_apply`) derives machine name, veth, subnet, paths from a numeric ID; it is shared verbatim with the root helper via `declare -f`. The CLI selects one environment with `_use_env <id>` before running the unchanged single-box code, and passes `--env <id>` as the first helper argument. Names live only in the user-side registry `~/.waterbox/envs.list`.

**Tech Stack:** Bash (host CLI + root helper), systemd-run/nspawn, iptables, Python 3 (existing mount shim), zsh (guest), tmux.

**Spec:** `waterbox/docs/superpowers/specs/2026-11-25-environments-design.md`

## Global Constraints

- Single self-contained executable `waterbox/waterbox`; generated pieces stay heredocs.
- Env 0 keeps every current path/identifier: `~/.waterbox/root`, machine `waterbox`, `ve-waterbox`, `10.20.30.0/24`, `live-<uid>`, `waterbox-autostart.service`.
- Env N (1–15): `~/.waterbox/envs/N/`, machine `waterbox-N`, `10.20.(30+N).0/24`.
- Helper: `--env N` only as the first two arguments; missing means 0; validated `^(0|[1-9]|1[0-5])$`.
- `JAIL_ROOT` stays literal; containment checks unchanged.
- `--audio`, `--gamepad`: per boot, never persisted, never used by autostart/wake, warning on enable.
- Never mount the host Pulse socket. Never pass `/dev/uinput`. Per-node `DeviceAllow` only.
- `WATERBOX_VERSION` bumps to `1.23`.
- After every task: `waterbox/tests/test-waterbox.sh`, `bash -n waterbox/waterbox`, `git diff --check`.
- No commits unless the user asks (repository owner's standing rule for this session).

---

### Task 1: Environment identity and registry (CLI side)

**Files:**
- Modify: `waterbox/waterbox` (configuration block lines 13–60, `_ensure_user_config`, `_remove_share_record`, `_config_current`/`CONFIG_VERSION_FILE`, `build_gui_bind_args` xauth path, `reset_sandbox` backup dir)
- Test: `waterbox/tests/test-waterbox.sh`

**Interfaces:**
- Produces: `_valid_env_id <id>`, `_valid_env_name <name>`, `_env_ids_apply <id>` (sets `MACHINE_NAME VE_IFACE HOST_IP CONTAINER_IP`), `_env_dir_for <home> <id>`, `_use_env <id>` (sets `WB_ENV ENV_DIR JAIL_ROOT SHARE_LIST PENDING_SHARE_LIST GUI_ENV_FILE GUI_BINDS_FILE BOOTSTRAP_IN_PROGRESS AUTOSTART_UNIT`), `_env_rows` (prints `id name`), `_env_id_of <name>`, `_env_name_of <id>`, `_env_registry_init`, `_env_write_rows` (stdin), `_env_create <name>` (prints new id), `_env_rename <old> <new>`.

- [ ] **Step 1: Write failing tests** — append to the harness a block that extracts `^_valid_env_id()` … `^# --- end env identity` and asserts:

```bash
extract '^_valid_env_id\(\)' '^# --- end env identity' "$TMP/env.bash"
(
    source "$TMP/env.bash"
    HOME="$TMP/envhome"; CONFIG_DIR="$HOME/.waterbox"; ENV_REGISTRY="$CONFIG_DIR/envs.list"
    _env_ids_apply 0
    [[ "$MACHINE_NAME $VE_IFACE $HOST_IP $CONTAINER_IP" == "waterbox ve-waterbox 10.20.30.1 10.20.30.2" ]]
    _env_ids_apply 15
    [[ "$MACHINE_NAME $VE_IFACE $HOST_IP" == "waterbox-15 ve-waterbox-15 10.20.45.1" ]]
    _valid_env_id 16 && exit 1; _valid_env_id 01 && exit 1; _valid_env_id 7
    _use_env 3; [[ "$JAIL_ROOT" == "$HOME/.waterbox/envs/3/root" ]]
    _use_env 0; [[ "$JAIL_ROOT" == "$HOME/.waterbox/root" && "$SHARE_LIST" == "$HOME/.waterbox/shared_paths" ]]
    _env_registry_init; [[ "$(_env_rows)" == "0 main" ]]
    id=$(_env_create gaming); [[ "$id" == 1 ]]
    _env_create gaming >/dev/null 2>&1 && exit 1          # duplicate
    _env_create 'bad name' >/dev/null 2>&1 && exit 1
    _env_rename main agents; [[ "$(_env_id_of agents)" == 0 && "$(_env_name_of 1)" == gaming ]]
    printf 'junk\n99 x\n2 ok extra\n' >> "$ENV_REGISTRY"; [[ "$(_env_rows | wc -l)" == 2 ]]
) || fail "environment identity/registry"
ok "environment identity, registry migration, create and rename"
```

- [ ] **Step 2: Run** `waterbox/tests/test-waterbox.sh` — expected FAIL "could not extract ^_valid_env_id".

- [ ] **Step 3: Implement** in the configuration block (replace the fixed `JAIL_ROOT`, `SHARE_LIST`, `PENDING_SHARE_LIST`, `GUI_*`, `MACHINE_NAME`, `BOOTSTRAP_IN_PROGRESS`, `HOST_IP`, `CONTAINER_IP`, `VE_IFACE` assignments):

```bash
CONFIG_DIR="$HOME/.waterbox"           # global: registry, update cache, completion
ENV_REGISTRY="$CONFIG_DIR/envs.list"   # "<id> <name>" lines; ordinary-user data only
NET_CIDR="24"
_valid_env_id()   { [[ "$1" =~ ^(0|[1-9]|1[0-5])$ ]]; }
_valid_env_name() { [ "${#1}" -le 64 ] || return 1; case "$1" in ''|.|..|-*|*[!A-Za-z0-9._-]*) return 1 ;; *) return 0 ;; esac; }
# Every host-side identifier of an environment follows from its numeric id. The
# root helper receives this exact function (declare -f), so both sides agree.
_env_ids_apply() {
    if [ "$1" = 0 ]; then MACHINE_NAME="waterbox"; else MACHINE_NAME="waterbox-$1"; fi
    VE_IFACE="ve-$MACHINE_NAME"            # nspawn names the host side ve-<machine>; ≤ 15 chars
    HOST_IP="10.20.$((30 + $1)).1"
    CONTAINER_IP="10.20.$((30 + $1)).2"
}
_env_dir_for() { if [ "$2" = 0 ]; then printf '%s/.waterbox' "$1"; else printf '%s/.waterbox/envs/%s' "$1" "$2"; fi; }
_use_env() {
    WB_ENV="$1"; _env_ids_apply "$1"
    ENV_DIR="$(_env_dir_for "$HOME" "$1")"
    JAIL_ROOT="$ENV_DIR/root"
    SHARE_LIST="$ENV_DIR/shared_paths"; PENDING_SHARE_LIST="$ENV_DIR/shared_paths.pending"
    GUI_ENV_FILE="$ENV_DIR/gui_env"; GUI_BINDS_FILE="$ENV_DIR/gui_binds"
    BOOTSTRAP_IN_PROGRESS="$ENV_DIR/bootstrap-in-progress"
    if [ "$1" = 0 ]; then AUTOSTART_UNIT="waterbox-autostart.service"; else AUTOSTART_UNIT="waterbox-autostart-$1.service"; fi
}
_env_rows() {
    local id name extra
    [ -f "$ENV_REGISTRY" ] || return 0
    while read -r id name extra || [ -n "$id" ]; do
        _valid_env_id "$id" && _valid_env_name "$name" && [ -z "$extra" ] && printf '%s %s\n' "$id" "$name"
    done < "$ENV_REGISTRY" | sort -n -k1,1 -u
}
_env_id_of()   { _env_rows | awk -v n="$1" '$2 == n { print $1; f=1; exit } END { exit !f }'; }
_env_name_of() { _env_rows | awk -v i="$1" '$1 == i { print $2; f=1; exit } END { exit !f }'; }
_env_registry_init() { [ -f "$ENV_REGISTRY" ] || { mkdir -p "$CONFIG_DIR" && printf '0 main\n' > "$ENV_REGISTRY"; }; }
_env_write_rows() {    # stdin = complete new registry; atomic replace
    local tmp; tmp=$(mktemp "$CONFIG_DIR/.envs.XXXXXX") || return 1
    cat > "$tmp" && mv -f -- "$tmp" "$ENV_REGISTRY" || { rm -f -- "$tmp"; return 1; }
}
_env_create() {        # $1 = name; prints the new id
    local name="$1" id
    _valid_env_name "$name" || { log_warn "Invalid environment name '$name' (letters, digits, . _ -; not starting with '-')."; return 1; }
    _env_id_of "$name" >/dev/null && { log_warn "An environment named '$name' already exists."; return 1; }
    for id in $(seq 0 15); do
        _env_name_of "$id" >/dev/null && continue
        [ -e "$(_env_dir_for "$HOME" "$id")/root" ] && continue   # never adopt a leftover rootfs
        { _env_rows; printf '%s %s\n' "$id" "$name"; } | _env_write_rows || return 1
        printf '%s\n' "$id"; return 0
    done
    log_warn "All 16 environment slots are in use."; return 1
}
_env_rename() {
    local old="$1" new="$2" id
    id=$(_env_id_of "$old") || { log_warn "No environment named '$old'."; return 1; }
    [ "$new" = "$old" ] && return 0
    _valid_env_name "$new" || { log_warn "Invalid environment name '$new'."; return 1; }
    _env_id_of "$new" >/dev/null && { log_warn "An environment named '$new' already exists."; return 1; }
    _env_rows | awk -v i="$id" -v n="$new" '$1 == i { $2 = n } { print }' | _env_write_rows
}
# --- end env identity
_use_env 0
```

Then: `_ensure_user_config` becomes `mkdir -p "$ENV_DIR"; touch "$SHARE_LIST"`; `_remove_share_record` uses `mktemp "$(dirname -- "$file")/.share-list.XXXXXX"`; `CONFIG_VERSION_FILE` is computed inside `_config_current`/`_write_config_version` as `"$JAIL_ROOT/etc/waterbox/config-version"`; `build_gui_bind_args` writes `$ENV_DIR/xauth`; `reset_sandbox` parks the home in `mktemp -d "$ENV_DIR/reset-home.XXXXXX"`; `AUTOSTART_UNIT=` constant near `manage_autostart` is removed (set by `_use_env`). `_host_share_allowed` keeps refusing all of `$CONFIG_DIR`.

- [ ] **Step 4: Run** harness — PASS (fix any test that set `CONFIG_DIR` but relied on `SHARE_LIST` defaults).

### Task 2: Helper `--env`, shared slice, per-env host artifacts

**Files:**
- Modify: `waterbox/waterbox` `install_helper` header + `HELPER` heredoc (arg parsing, `JAIL_ROOT`/`WB_CFG`, autostart wait, `resume_after_boot`, `down`, `boot_min`, `boot_full`, `resource_status`, `_write_host_wake`, `autostart-enable/disable`)
- Test: `waterbox/tests/test-waterbox.sh`

**Interfaces:**
- Consumes: `_valid_env_id`, `_env_ids_apply`, `_env_dir_for` (Task 1), emitted into the helper with `declare -f`.
- Produces: helper globals `wb_env`, `RESUME_MARK`, `AUTOSTART_UNIT`; helper function `ensure_slice`; unit bodies `ExecStart=$0 --env $wb_env autostart --user $wb_uid` and `ExecStart=$0 --env $wb_env wake $prof --user $wb_uid`.

- [ ] **Step 1: Failing tests** (replace the old marker/unit assertions):

```bash
assert_has "$(grep -A3 '^    down)' "$TMP/helper.bash")" 'rm -f "$RESUME_MARK"' "verified stop clears this env's marker"
( source <(awk '/^_valid_env_id\(\)/,/^}/; /^_env_ids_apply\(\)/,/^}/; /^_env_dir_for\(\)/' "$TMP/helper.bash")
  _valid_env_id 3 && ! _valid_env_id 16 ) || fail "helper lacks the shared env identity functions"
assert_has "$(sed -n '1,/^verb=/p' "$TMP/helper.bash")" 'if [ "${1:-}" = --env ]; then' "helper takes --env first"
assert_has "$(grep -A40 '^ensure_slice()' "$TMP/helper.bash")" 'MemoryMax=$WATERBOX_MEMORY_MAX' "shared slice carries the memory cap"
assert_eq 2 "$(grep -c -- '--slice=waterbox.slice' "$TMP/helper.bash")" "both boot paths join the shared slice"
assert_eq 0 "$(grep -c -- '--property=MemoryMax=' "$TMP/helper.bash" || true)" "memory caps live on the slice, not per unit"
assert_has "$(grep -A8 '^_write_host_wake()' "$TMP/helper.bash")" 'ExecStart=$0 --env $wb_env wake $prof --user $wb_uid' "wake timer records its env"
```
and change the autostart unit loop's expected line to `'ExecStart=* --env 0 autostart --user 1000'` with `wb_env=0 AUTOSTART_UNIT=waterbox-autostart.service` in the eval, plus the late-home test now sets `wb_env=0` and creates `$home/.waterbox/root/.waterbox-ready` (unchanged path for env 0) and a second case `wb_env=2` creating `$home/.waterbox/envs/2/root/.waterbox-ready`.

- [ ] **Step 2: Run** — FAIL.

- [ ] **Step 3: Implement.**
  - Header: drop `MACHINE_NAME=`, `HOST_IP=`, `CONTAINER_IP=`, `VE_IFACE=` lines; add `NET_CIDR` stays; append `declare -f _valid_env_id _env_ids_apply _env_dir_for` output.
  - Before the `--user` loop:

```bash
# Environment: only as the first two arguments, so no other argument (a tmux
# argument, an API key) can be reinterpreted. Missing means env 0, which keeps
# units written by releases before environments working unchanged.
wb_env=0
if [ "${1:-}" = --env ]; then wb_env="${2:-}"; shift 2 || exit 2; fi
_valid_env_id "$wb_env" || { echo "helper: bad environment id"; exit 2; }
_env_ids_apply "$wb_env"
```
  - Autostart wait uses `"$(_env_dir_for "$wb_home" "$wb_env")/root/.waterbox-ready"`.
  - `WB_CFG="$(_env_dir_for "$wb_home" "$wb_env")"; JAIL_ROOT="$WB_CFG/root"`.
  - `RESUME_MARK="$RESUME_MARK_DIR/live-$wb_uid"; [ "$wb_env" = 0 ] || RESUME_MARK="$RESUME_MARK-$wb_env"`; use it in `down` and `resume_after_boot`.
  - `AUTOSTART_UNIT` same formula as CLI; `autostart-enable` writes `$HW_ETC/$AUTOSTART_UNIT` with `Description=Waterbox: boot environment $wb_env with the host and restore its sessions` and `ExecStart=$0 --env $wb_env autostart --user $wb_uid`; `autostart-disable` acts on `$AUTOSTART_UNIT`.
  - `_write_host_wake` ExecStart as in the test.
  - New:

```bash
# All environments share one budget: today's single-box limits now cap their sum.
# A runtime unit (rewritten whenever its body changes) loads on systemd 249 too.
ensure_slice() {
    local unit=/run/systemd/system/waterbox.slice body
    body=$(printf '%s\n' "# Managed by Waterbox: every environment shares these limits." \
        "[Unit]" "Description=Waterbox environments" "" "[Slice]" \
        "MemoryHigh=$WATERBOX_MEMORY_HIGH" "MemoryMax=$WATERBOX_MEMORY_MAX" \
        "MemorySwapMax=$(swap_limit_bytes)" \
        "CPUWeight=$WATERBOX_CPU_WEIGHT" "IOWeight=$WATERBOX_IO_WEIGHT")
    [ "$(cat "$unit" 2>/dev/null)" = "$body" ] && return 0
    mkdir -p /run/systemd/system && printf '%s\n' "$body" > "$unit" && systemctl daemon-reload
}
```
  - `boot_min`/`boot_full`: call `ensure_slice || { echo "helper: could not set up the shared resource slice" >&2; return 3; }` before `systemd-run`; add `--slice=waterbox.slice`; remove the MemoryHigh/MemoryMax/MemorySwapMax/CPUWeight/IOWeight properties (keep TasksMax, OOMPolicy).
  - `resource_status`: memory + CPU weight from `systemctl show waterbox.slice`, label `RAM (all environments):`; tasks from the unit.

- [ ] **Step 4: Run** — PASS.

### Task 3: CLI → helper wiring

**Files:** Modify `waterbox/waterbox` — `run_priv`, `is_running`, `container_tmux`, `list_sessions_quiet`, `attach_session` exec lines, `teardown_host_network`.

**Interfaces:** Produces `run_priv` (`sudo "$HELPER_PATH" --env "$WB_ENV" "$@"`) and `run_priv_quiet` (`sudo -n …`). Every helper invocation goes through these two.

- [ ] **Step 1: Failing test:**

```bash
assert_eq 2 "$(grep -c '"$HELPER_PATH" --env "$WB_ENV"' "$WB")" "helper wrappers pass the environment"
assert_eq 0 "$(grep -nE 'sudo (-n )?"\$HELPER_PATH" [a-z]' "$WB" | grep -vc 'HELPER_PATH" --env' || true)" \
    "no helper call bypasses the environment wrappers"
```
- [ ] **Step 2: Run** — FAIL.
- [ ] **Step 3: Implement** the two wrappers next to `_helper_current`; replace the six direct call sites (`exec sudo "$HELPER_PATH" shell …` → `exec sudo "$HELPER_PATH" --env "$WB_ENV" shell …`, others → `run_priv`/`run_priv_quiet`). The exec lines keep `exec` and count toward the assertion only through the wrapper form, so change the first assertion's expected count to match the final number of literal occurrences (2 wrappers + 3 exec lines = 5).
- [ ] **Step 4: Run** — PASS.

### Task 4: `--env` option, resolution rules, `waterbox env` command

**Files:** Modify `waterbox/waterbox` — argument parser, arity checks, dispatcher, new `_resolve_env`, `_env_state`, `_env_menu`, `env_cmd`, `_env_delete`, help (`show_help`, new `help_env`), completion.

**Interfaces:**
- Consumes: Task 1 registry functions, Task 3 wrappers, existing `choose_menu`, `log_*`.
- Produces: `CLI_ENV_NAME`; `_resolve_env` (sets the active env or exits); `_env_state <id>` → `running|stopped|not built`; `_env_menu <enter-verb> [preselect-id]` → sets `ENV_PICK`, returns 1 on cancel; `_env_ensure_one` (creates `main` when the registry is empty).

- [ ] **Step 1: Failing parser tests** (extend `run_parser` stubs with `env_cmd() { printf "CALL:env"; printf " <%s>" "$@"; echo; }` and `_resolve_env() { echo RESOLVE:${CLI_ENV_NAME:-}; }`):

```bash
assert_has "$(run_parser env)" "CALL:env" "bare env opens the menu"
assert_has "$(run_parser env create gaming)" "CALL:env <create> <gaming>" "env create"
assert_has "$(run_parser env rename a b)" "CALL:env <rename> <a> <b>" "env rename"
assert_has "$(run_parser --env gaming stop)" "RESOLVE:gaming" "--env before the command"
assert_has "$(run_parser stop --env=gaming)" "RESOLVE:gaming" "--env= form after the command"
parser_fails env create
parser_fails env rename a
parser_fails env delete a b
parser_fails env bogus
parser_fails env list --gui
parser_fails --env gaming update
parser_fails stop --env
```
- [ ] **Step 2: Run** — FAIL.
- [ ] **Step 3: Implement.**
  - Parser: `--env) [ $# -ge 2 ] || log_error "--env needs an environment name."; CLI_ENV_NAME="$2"; CLI_ENV_SEEN=1; shift 2 ;;` and `--env=*) CLI_ENV_NAME="${1#--env=}"; CLI_ENV_SEEN=1; shift ;;`. `--env` is not added to `CLI_FLAGS_SEEN`; instead reject it for `update|version|completion|help|env|setup|refresh-config`.
  - Arity for `env`: `""`(1 arg) | `list`(2) | `create <n>`(3) | `delete <n>`(3) | `rename <o> <n>`(4); boot/here flags invalid.
  - `_resolve_env`:

```bash
_resolve_env() {
    local rows=() row id running=()
    _env_registry_init
    if [ -n "${CLI_ENV_NAME:-}" ]; then
        id=$(_env_id_of "$CLI_ENV_NAME") \
            || log_error "No environment named '$CLI_ENV_NAME'. Existing: $(_env_rows | awk '{print $2}' | paste -sd' ')."
        _use_env "$id"; return 0
    fi
    mapfile -t rows < <(_env_rows)
    [ "${#rows[@]}" -gt 0 ] || log_error "No environments yet. Run 'waterbox' to create one."
    if [ "${#rows[@]}" -eq 1 ]; then _use_env "${rows[0]%% *}"; return 0; fi
    for row in "${rows[@]}"; do _use_env "${row%% *}"; is_running && running+=("${row%% *}"); done
    if [ "${#running[@]}" -eq 1 ]; then
        _use_env "${running[0]}"; log_info "Using environment '$(_env_name_of "$WB_ENV")' (the only one running)."; return 0
    fi
    if [ -t 0 ] && [ -t 1 ]; then
        _env_menu select || exit 0
        _use_env "$ENV_PICK"; return 0
    fi
    log_error "Several environments exist; choose one with --env <name>."
}
```
  - `_env_state`: `_use_env id; if is_running → running; elif [ -f "$JAIL_ROOT/.waterbox-ready" ] → stopped; else not built`. Restore the previous `WB_ENV` afterwards.
  - `_env_menu` — `choose_menu` loop with `MENU_ADD=1 MENU_RENAME=1 MENU_DELETE=1 MENU_QUIT=1 MENU_SELECT=<row of preselect/keep>`, prompt `"Select an environment (↑/↓ move · Enter $1 · a new · r rename · d delete · q quit):"`, rows `printf '%-16s [%s]' name state`. `a` → `read -rep "New environment name: "` → `_env_create`; `r` → `read -rep "New name for '$n': " -i "$n"` → `_env_rename`; `d` → `_env_delete "$n"`; Enter → `ENV_PICK=id; return 0`; empty registry → `_env_ensure_one` first.
  - `_env_delete <name>` — security-relevant, verbatim:

```bash
_env_delete() {
    local name="$1" id typed
    id=$(_env_id_of "$name") || { log_warn "No environment named '$name'."; return 1; }
    _use_env "$id"
    ensure_helper
    if is_running; then log_warn "Environment '$name' is running. Stop it first: waterbox stop --env $name"; return 1; fi
    printf '%s\n' "Deleting environment '$name' destroys:" \
        "  - its rootfs $JAIL_ROOT, including the guest home (agent logins, chat history, workspace)" \
        "  - its share list, wake-claude schedules and autostart setting" \
        "Shared host folders are only unmounted references; their files are not touched." > /dev/tty
    IFS= read -rep "Type the environment name to delete it: " typed < /dev/tty 2>/dev/tty || return 1
    [ "$typed" = "$name" ] || { log_info "Kept '$name'."; return 0; }
    run_priv autostart-disable >/dev/null 2>&1 || true
    _remove_env_hostwakes || { log_warn "Could not remove the wake-claude schedules of '$name'; nothing was deleted."; return 1; }
    run_priv down >/dev/null 2>&1 || true          # clears this env's restore marker
    if [ -e "$JAIL_ROOT" ]; then
        # A symlinked parent would point root's rm somewhere else; JAIL_ROOT is literal.
        [ "$(realpath -e -- "$JAIL_ROOT")" = "$JAIL_ROOT" ] \
            || { log_warn "Refusing to delete: $JAIL_ROOT resolves elsewhere."; return 1; }
        sudo rm -rf -- "$JAIL_ROOT" || { log_warn "Could not delete $JAIL_ROOT; the environment was kept."; return 1; }
    fi
    if [ "$id" = 0 ]; then
        rm -f -- "$SHARE_LIST" "$PENDING_SHARE_LIST" "$GUI_ENV_FILE" "$GUI_BINDS_FILE" "$ENV_DIR/xauth" "$BOOTSTRAP_IN_PROGRESS"
    else
        sudo rm -rf -- "$ENV_DIR"
    fi
    _env_rows | awk -v i="$id" '$1 != i' | _env_write_rows
    log_success "Deleted environment '$name'."
}
```
  - `_remove_env_hostwakes`: loop `HOSTWAKE_GLOB*.service`, read `ExecStart=` with `grep -m1`, env = `--env N` token or 0 when absent, `run_priv remove-host-wake n` for matches. `reset_sandbox` calls it instead of `_remove_all_hostwakes` (delete the old function).
  - `env_cmd`: `""` → `_env_menu start` then `CLI_ENV_NAME=$(_env_name_of "$ENV_PICK"); start_sandbox`; `list` → `printf '%-16s %s\n'` name/state; `create` → `_env_create` + `log_success "Created environment '$n'. Start it with: waterbox start --env $n"`; `rename`/`delete` wrap the helpers (`|| exit 1`).
  - Dispatcher: `stop|restart|reset|share|autostart|schedule-command|_helper` call `_resolve_env` first; `status` calls `_resolve_env` only when `CLI_ENV_NAME` is set, else `status_all`; `env) env_cmd "${@:2}"`.
  - `status_all`: for each env print `name: state`, then `run_priv status` for running ones under a `── name ──` heading.
  - `_sessions`: running envs (or `--env`), each session printed once.
  - Help: `show_help` gains an `Environments` section (`env`, `--env <name>`); new `help_env`; `--help` routing.
  - Completion: `env` in `cmds`; `env)` completes `list create rename delete` then names; `--env` completes names read from `$HOME/.waterbox/envs.list`; profile completion globs `$HOME/.waterbox/root $HOME/.waterbox/envs/*/root`.
- [ ] **Step 4: Run** — PASS.

### Task 5: Start flow across environments

**Files:** Modify `waterbox/waterbox` — `start_sandbox` (split), `attach_session` (split), `restart_sandbox`, `stop_sandbox`/`status_sandbox` messages, `manage_autostart`, `manage_wake_claude add`/`wake_add`, `_hostwake_collect` row label.

**Interfaces:**
- Consumes: `_resolve_env`, `_env_menu`, `_env_ensure_one`, `run_priv`.
- Produces: `_env_up` (old start body: bootstrap … `--here` live mount; requires active env), `_attach <session>` (exec into helper shell), `_session_rows` (fills `SR_ENV[]` `SR_NAME[]` from running envs, filtered by `CLI_ENV_NAME`), `_pick_session` (the picker; ends in `_env_up` + `_attach`).

- [ ] **Step 1: Failing tests** (static, since the picker is TTY-bound):

```bash
start_body=$(awk '/^start_sandbox\(\)/,/^}/' "$WB")
assert_has "$start_body" '_env_ensure_one' "first start creates an environment"
assert_has "$(awk '/^_pick_session\(\)/,/^}/' "$WB")" 'Select a session (↑/↓ move · Enter attach · a new · r rename · d kill · q quit):' "picker prompt kept"
assert_has "$(awk '/^_session_rows\(\)/,/^}/' "$WB")" '[%s]' "picker rows carry the environment name"
assert_has "$(awk '/^restart_sandbox\(\)/,/^}/' "$WB")" 'CLI_ENV_NAME=' "restart keeps its environment for the start half"
(
    source <(awk '/^_session_matches\(\)/,/^}/' "$WB")
    _env_rows() { printf '0 main\n1 gaming\n'; }
    _use_env() { WB_ENV=$1; }; is_running() { return 0; }
    container_tmux() { [[ "$WB_ENV" == 0 || "$4" == "=only-gaming" ]] && [[ "$4" != "=only-gaming" || "$WB_ENV" == 1 ]]; }
    [[ "$(_session_matches only-gaming)" == 1 ]]
) || fail "named start finds the session's environment"
```
- [ ] **Step 2: Run** — FAIL.
- [ ] **Step 3: Implement.**
  - `start_sandbox <want>`: validate name; `require_host_deps`; `_env_registry_init`; `_env_ensure_one`; `ensure_host_privs` (now before any bootstrap); then:
    - `WATERBOX_HERE=1` → `_resolve_env; _env_up; attach_here`.
    - `want` set → `[ -n "$CLI_ENV_NAME" ] && _resolve_env || { ids=$(_session_matches "$want"); case count: 1 → _use_env; >1 → log_error "Session '$want' exists in several environments ($names); add --env <name>."; 0 → _resolve_env; }`; `_env_up`; `_attach "$want"`.
    - else `_pick_session`.
  - `_session_matches <name>`: for each row id, `_use_env id; is_running && container_tmux has-session -t "=$name" 2>/dev/null && echo id`.
  - `_session_rows`: for each env (filtered), if running, `_live_sessions` per env; rows `printf '%-24s [%s]' sess envname`.
  - `_pick_session`: update notice (moved from `attach_session`), then loop:
    - no rows → `if CLI_ENV_NAME → _resolve_env else _env_menu select || return 0; _use_env $ENV_PICK`; `_env_up`; if `_live_sessions` now non-empty and this was the first pass → `continue` (shows restored sessions) else name prompt in that env → `_maybe_offer_share` → `_attach`.
    - rows → `choose_menu` with the old prompt; Enter → `_use_env SR_ENV[i]; _env_up; _attach SR_NAME[i]`; `a` → `_env_menu select <highlighted env>`, `_use_env`, `_env_up`, prompt name, offer share, `_attach`; `r`/`d` → `_use_env SR_ENV[i]` then the existing rename/kill code; keep highlight by `env:name`.
  - `_env_up`: move lines from `bootstrap_sandbox` through the `--here` live mount out of `start_sandbox` unchanged, except the boot log line names the environment: `log_info "Booting environment '$(_env_name_of "$WB_ENV")' ($MACHINE_NAME.service)..."`.
  - `restart_sandbox`: after `_resolve_env` (dispatcher), `CLI_ENV_NAME=$(_env_name_of "$WB_ENV")` before `start_sandbox`.
  - `manage_autostart`: messages name the env; `status` uses `$AUTOSTART_UNIT`; `ensure_host_privs` re-runs `autostart-enable` for every env whose unit is enabled (`for row in $(_env_rows)`), restoring `WB_ENV` afterwards.
  - `wake-claude`: list/del/manager stay global; rows prefixed with the env name parsed from the `.service` `ExecStart` (`--env N`, default 0); `add`/`wake_add` call `_resolve_env` before reading profiles.
- [ ] **Step 4: Run** — PASS.

### Task 6: `--audio`

**Files:** Modify `waterbox/waterbox` — `PKGS`, flag parsing/arity (start/restart only), `start_sandbox` boot args + warnings, `help_start`, completion, zshrc heredoc, `configure_dotfiles`, helper `boot` verb, `boot_full`, `write_boot_env`/`clear_boot_env`, python mount allowlist.

**Interfaces:**
- Produces: CLI `WATERBOX_AUDIO`; helper `boot` option `--audio`; `boot_full <gui> <nogpu> <unsafe> <usb> <audio> <gamepad>`; helper `collect_audio_mount` (sets `AUDIO_SOURCE`), `mount_collected_audio`, `write_boot_env <audio> <gamepad>`.

- [ ] **Step 1: Failing tests:**

```bash
assert_has "$(run_parser start --audio)" "CALL:start" "start accepts --audio"
parser_fails status --audio
parser_fails reset --audio
helper_audio=$(awk '/^collect_audio_mount\(\)/,/^}/' "$TMP/helper.bash")
assert_has "$helper_audio" '"/run/user/$wb_uid/pipewire-0"' "audio accepts only the host user's PipeWire socket"
assert_has "$helper_audio" '! -L' "audio rejects symlinked sockets"
assert_eq 0 "$(grep -c 'pulse/native' "$TMP/helper.bash" || true)" "the host Pulse socket is never mounted"
assert_has "$(cat "$TMP/zshrc")" '/etc/waterbox/boot-env' "shell sources the boot env"
assert_has "$(grep -A30 '^configure_dotfiles()' "$WB")" 'pipewire-pulse.service.d' "in-box pipewire-pulse targets the host graph"
assert_has "$(grep -A6 '^autostart)' "$TMP/helper.bash" ; grep -A5 '^    autostart)' "$TMP/helper.bash")" 'boot_full 0 0 0 0 0 0' "autostart never enables audio or gamepads"
```
(update the existing `boot_full 0 0 0 0` assertions to six zeros.)
- [ ] **Step 2: Run** — FAIL.
- [ ] **Step 3: Implement.**
  - `PKGS += pipewire pipewire-pulse pipewire-alsa`.
  - Parser: `--audio) WATERBOX_AUDIO=1; CLI_BOOT_FLAG_USED=1; CLI_FLAGS_SEEN+=("$1"); shift ;;` (already rejected for non-boot commands through `CLI_FLAGS_SEEN`).
  - `_env_up` cold boot: `if [ "$WATERBOX_AUDIO" = 1 ]; then log_warn "--audio: the box can record your microphone, hear all host audio, and reroute or change host sound devices."; boot_args+=(--audio); fi`. Running box with `--audio` but no audio mount: `log_warn "Audio is set at boot — 'waterbox restart --audio' to enable it."` (detect with `run_priv boot-features` printing `audio`/`gamepad` when `/run/waterbox/features-<uid>-<env>` lists them; the helper writes that root-only file after a successful cold boot).
  - Helper:

```bash
# PipeWire only: the box runs its own pipewire-pulse against this socket, so a
# Pulse client's load-module lands inside the box, never in the host server.
collect_audio_mount() {
    local dir="/run/user/$wb_uid" sock="/run/user/$wb_uid/pipewire-0"
    AUDIO_SOURCE=""
    [ -d "$dir" ] && [ ! -L "$dir" ] && [ "$(stat -c %u "$dir")" = "$wb_uid" ] \
        && [ -S "$sock" ] && [ ! -L "$sock" ] && [ "$(stat -c %u "$sock")" = "$wb_uid" ] \
        || { echo "helper: --audio needs PipeWire on the host ($sock not found)" >&2; return 1; }
    AUDIO_SOURCE="$sock"
}
mount_collected_audio() {
    local map_uid="$wb_uid"
    run_in_approved_box /bin/sh -c '[ -e "$1" ] || : > "$1"; chown -h 1000:1000 "$1"' sh /tmp/.waterbox-pipewire \
        || { echo "helper: could not prepare the audio target" >&2; return 1; }
    unsafe_unit && map_uid="-"
    mount_into_box "$AUDIO_SOURCE" /tmp/.waterbox-pipewire "$map_uid"
}
write_boot_env() {   # $1 audio, $2 gamepad — derived only from what the helper accepted
    local target="$JAIL_ROOT/etc/waterbox/boot-env" tmp
    _in_jail "$target" || { echo "helper: refusing to write boot-env outside the rootfs" >&2; return 1; }
    mkdir -p "$JAIL_ROOT/etc/waterbox"; tmp=$(mktemp)
    [ "$1" = 1 ] && echo 'export PIPEWIRE_REMOTE="/tmp/.waterbox-pipewire"' >> "$tmp"
    [ "$2" = 1 ] && echo 'export SDL_JOYSTICK_DISABLE_UDEV="1"' >> "$tmp"
    install -m 0644 "$tmp" "$target"; local rc=$?; rm -f "$tmp"; return "$rc"
}
```
  `boot_full`: before `systemd-run`, `[ "$audio" = 1 ] && { collect_audio_mount || return 3; }`, `write_boot_env "$audio" "$gamepad" || return 3`; after GUI mounts, `[ "$audio" = 1 ] && ! mount_collected_audio → power_off; return 3`. Python allowlist gains `/tmp/.waterbox-pipewire`.
  - Guest (`configure_dotfiles`, guarded writes): `/etc/systemd/user/pipewire-pulse.service.d/waterbox.conf` with `[Unit] ConditionPathExists=/tmp/.waterbox-pipewire` + `[Service] Environment=PIPEWIRE_REMOTE=/tmp/.waterbox-pipewire`; `/dev/null` symlinks for `pipewire.service pipewire.socket wireplumber.service` under `/etc/systemd/user/` and `sockets.target.wants/pipewire-pulse.socket → /usr/lib/systemd/user/pipewire-pulse.socket`, each via `_guard_jail_path` + `sudo ln -sfn`.
  - zshrc: after gui-env, `[ -f /etc/waterbox/boot-env ] && source /etc/waterbox/boot-env` and `[[ -n $PIPEWIRE_REMOTE ]] && (( ! $+commands[pipewire-pulse] )) && print "waterbox: audio needs PipeWire in this box once: sudo pacman -Syu pipewire pipewire-pulse pipewire-alsa"`.
  - `help_start` gains `--audio` with the warning; completion adds it to start/restart.
- [ ] **Step 4: Run** — PASS.

### Task 7: `--gamepad` with the minor-reuse guard

**Files:** Modify `waterbox/waterbox` — parser, `_env_up` boot args/warning (needs setfacl), `help_start`, completion, helper `boot` verb, `boot_full`, new `collect_gamepad_nodes`, `gamepad_grant`, extended `usb_revoke` → `device_revoke`, new verb `devguard`, guard start in `boot_full`.

**Interfaces:**
- Produces: helper array `GAMEPAD_NODES`; `collect_gamepad_nodes [sysfs-root] [udev-root] [dev-root]` (roots default to `/sys`, `/run/udev/data`, `/dev` so tests can point at fakes); `/run/waterbox/devallow-<uid>-<env>` (one `DeviceAllow` value per line); verb `devguard`.

- [ ] **Step 1: Failing tests:**

```bash
extract '^collect_gamepad_nodes\(\)' '^# --- end gamepad collect' "$TMP/pad.bash"
(
    source "$TMP/pad.bash"
    S="$TMP/pad/sys" U="$TMP/pad/udev" D="$TMP/pad/dev"
    mkdir -p "$S/devices/hidpad" "$S/devices/hidkbd" "$U" "$D/input"
    mk() {  # name minor hid-parent props...
        local n=$1 m=$2 hid=$3; shift 3
        mkdir -p "$S/devices/$hid/input/in$m/$n" "$S/class/input"
        ln -s "../../devices/$hid/input/in$m/$n" "$S/class/input/$n"
        ln -s "../../$hid" "$S/devices/$hid/input/in$m/device"
        ln -s .. "$S/devices/$hid/input/in$m/$n/device"
        echo "13:$m" > "$S/devices/$hid/input/in$m/$n/dev"
        printf 'E:%s\n' "$@" > "$U/c13:$m"; : > "$D/input/$n"
    }
    mk event5 69 hidpad ID_INPUT=1 ID_INPUT_JOYSTICK=1
    mk event6 70 hidkbd ID_INPUT=1 ID_INPUT_KEYBOARD=1
    mk event7 71 hidkbd ID_INPUT=1 ID_INPUT_JOYSTICK=1 ID_INPUT_KEYBOARD=1
    mkdir -p "$S/class/hidraw/hidraw0" "$S/class/hidraw/hidraw1"
    ln -s ../../../devices/hidpad "$S/class/hidraw/hidraw0/device"
    ln -s ../../../devices/hidkbd "$S/class/hidraw/hidraw1/device"
    : > "$D/hidraw0"; : > "$D/hidraw1"
    _is_chardev() { [ -e "$1" ]; }
    collect_gamepad_nodes "$S" "$U" "$D"
    [[ "${GAMEPAD_NODES[*]}" == "$D/input/event5 $D/hidraw0" ]]
) || fail "gamepad selection must pass only joysticks and their own hidraw"
assert_eq 0 "$(grep -c '/dev/uinput' "$TMP/helper.bash" || true)" "uinput is never passed"
assert_eq 0 "$(grep -c 'char-input' "$TMP/helper.bash" || true)" "no whole-major input DeviceAllow"
assert_has "$(awk '/^    devguard\)/,/;;/' "$TMP/helper.bash")" 'set-property --runtime' "guard narrows DeviceAllow on removal"
assert_has "$(grep -A20 'devguard' "$TMP/helper.bash")" "BindsTo=\$MACHINE_NAME.service" "guard lives and dies with the box"
assert_has "$(awk '/^device_revoke\(\)/,/^}/' "$TMP/helper.bash")" '/dev/hidraw*' "stop revokes gamepad ACLs"
```
- [ ] **Step 2: Run** — FAIL.
- [ ] **Step 3: Implement.**

```bash
_is_chardev() { [ -c "$1" ] && [ ! -L "$1" ]; }
# Joystick event nodes (never a keyboard), their js nodes, and only the hidraw
# nodes of those same HID devices: a security key's or keyboard's hidraw stays out.
collect_gamepad_nodes() {
    local sys="${1:-/sys}" udev="${2:-/run/udev/data}" dev="${3:-/dev}" ev n mm hid hr js
    local -A pad_hid=()
    GAMEPAD_NODES=()
    for ev in "$sys"/class/input/event*; do
        n=${ev##*/}
        _is_chardev "$dev/input/$n" || continue
        mm=$(cat "$ev/dev" 2>/dev/null) || continue
        [[ "$mm" =~ ^[0-9]+:[0-9]+$ ]] || continue
        grep -qx 'E:ID_INPUT_JOYSTICK=1' "$udev/c$mm" 2>/dev/null || continue
        grep -qx 'E:ID_INPUT_KEYBOARD=1' "$udev/c$mm" 2>/dev/null && continue
        GAMEPAD_NODES+=("$dev/input/$n")
        for js in "$ev"/device/js*; do
            [ -e "$js" ] && _is_chardev "$dev/input/${js##*/}" && GAMEPAD_NODES+=("$dev/input/${js##*/}")
        done
        hid=$(realpath -e "$ev/device/device" 2>/dev/null) && pad_hid[$hid]=1
    done
    for hr in "$sys"/class/hidraw/hidraw*; do
        hid=$(realpath -e "$hr/device" 2>/dev/null) || continue
        [ -n "${pad_hid[$hid]:-}" ] && _is_chardev "$dev/${hr##*/}" && GAMEPAD_NODES+=("$dev/${hr##*/}")
    done
}
# --- end gamepad collect
```
  - `boot_full`: when `gamepad=1`: `collect_gamepad_nodes`; none → warn and continue without; each node → `--bind="$n"` and `--property=DeviceAllow="$n rw"`. Write the full DeviceAllow value list (base + drm/usb/pad entries, one per line) to `/run/waterbox/devallow-$wb_uid-$wb_env` (`install -d -m 0700 /run/waterbox`). After successful boot: grant ACLs like `usb_grant` on exactly `GAMEPAD_NODES` (failure → `power_off`, return 3), then start the guard:

```bash
systemd-run --unit="$MACHINE_NAME-devguard" --collect --quiet \
    --property=BindsTo="$MACHINE_NAME.service" --property=After="$MACHINE_NAME.service" \
    --property=Restart=always \
    "$0" --env "$wb_env" devguard --user "$wb_uid" "${GAMEPAD_NODES[@]}" \
    || { echo "helper: could not start the device guard; stopping the box" >&2; power_off || true; return 3; }
```
  - Verb `devguard` (root unit only — refuse when `SUDO_UID` is set):

```bash
    devguard)
        # A removed pad frees its minor number; the next input/hidraw device may
        # receive it. Drop the node from the box's device cgroup before that.
        [ -z "${SUDO_UID:-}" ] || { echo "helper: devguard runs only as the box's guard unit" >&2; exit 2; }
        list="/run/waterbox/devallow-$wb_uid-$wb_env"
        [ -f "$list" ] && [ ! -L "$list" ] || exit 1
        guarded=("$@")
        apply() {
            local args=(DeviceAllow=) line keep n
            while IFS= read -r line; do
                keep=1
                for n in "${dropped[@]}"; do [ "$line" = "$n rw" ] && keep=0; done
                [ "$keep" = 1 ] && args+=("DeviceAllow=$line")
            done < "$list"
            systemctl set-property --runtime "$MACHINE_NAME.service" "${args[@]}"
        }
        dropped=()
        for n in "${guarded[@]}"; do [ -c "$n" ] || dropped+=("$n"); done
        [ "${#dropped[@]}" -eq 0 ] || apply
        udevadm monitor --udev --property --subsystem-match=input --subsystem-match=hidraw \
        | while IFS= read -r line; do
            case "$line" in
                ACTION=*) action="${line#ACTION=}" ;;
                DEVNAME=*)
                    [ "$action" = remove ] || continue
                    for n in "${guarded[@]}"; do
                        [ "${line#DEVNAME=}" = "$n" ] && { dropped+=("$n"); apply; }
                    done ;;
            esac
        done
        ;;
```
  - `device_revoke` replaces `usb_revoke` and also loops `/dev/input/event* /dev/input/js* /dev/hidraw*`; `power_off` calls it.
  - `_env_up`: `--gamepad` needs setfacl (same message style as `--usb`), warning `"--gamepad: the box reads every input of the controllers present now and can use their rumble/LED/firmware interfaces. Controllers connected later need a restart."`.
  - Validate helper `boot` options: add `--audio`, `--gamepad`; `boot_full` gets six positional values; `autostart` passes six zeros.
- [ ] **Step 4: Run** — PASS.

### Task 8: Documentation, version, final verification

**Files:** Modify `waterbox/AGENTS.md`, `waterbox/waterbox` (`WATERBOX_VERSION="1.23"`, `show_help`, `help_autostart`), spec status line.

- [ ] **Step 1:** AGENTS.md — new settled-design sections "Environments are separate boxes" (identity table, names user-side only, helper `--env` first-arg rule, delete semantics, shared slice + its OOM consequence), "Audio is PipeWire-only", "Gamepads are explicit, per node, and guarded" (selection rule, no uinput, devguard rationale); update the resource-limits section (limits on `waterbox.slice`), the session-restore section (per-env marker/autostart units), code map rows (`_env_ids_apply`, `_use_env`, `_resolve_env`, `_pick_session`, `_env_up`, `devguard`), known limitations (Ctrl-b s per box, gamepad hotplug, seat-change ACL reset, `--usb` serial nodes still lack a minor-reuse guard).
- [ ] **Step 2:** Bump version; run:

```bash
waterbox/tests/test-waterbox.sh && bash -n waterbox/waterbox && git diff --check
```
Expected: all checks pass, no whitespace errors.
- [ ] **Step 3:** Hand the real-host checklist from the spec's Testing section to the user (cannot be run from inside a box).
