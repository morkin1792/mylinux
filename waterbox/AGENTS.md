# AGENTS.md — Waterbox

Context and operating rules for anyone—human or agent—working on Waterbox.
Read this before changing `waterbox`. The script is a security boundary for
untrusted AI-agent code, so apparently small changes to mounts, namespaces,
privilege transitions, or host integration can turn into host compromise.

This is a public repository. Keep documentation, tests, comments, and commits
portable and impersonal: describe distributions and desktop environments
generically (for example, “on Linux Mint” or “on X11”), never a contributor’s
username, home path, machine name, hardware inventory, account names, or other
local details.

## What Waterbox is

Waterbox is a self-contained Bash program that creates and operates an Arch Linux
root filesystem under `~/.waterbox/root` using `systemd-nspawn`. It is intended
for running CLI AI agents in their least restrictive/bypass modes while making
the container—not each agent’s own sandbox—the security boundary.

The host may be Arch, Debian, Ubuntu, Linux Mint, Fedora, openSUSE, or another
systemd-based Linux distribution. The guest is always Arch so agent tooling can
stay current even when host packages are old.

The user-facing executable is:

```text
waterbox/waterbox
```

Keep it executable and self-contained. Generated configuration, the privileged
host helper, in-box helpers, shell configuration, and tmux configuration are
embedded in this one file as heredocs. Do not split runtime pieces into separately
downloaded files without an explicit project-level decision: a single auditable
and atomically updatable artifact is a core property.

## Product priorities

When reviewing or changing Waterbox, prioritize:

1. Preventing a process inside the box from escaping to the host.
2. Preventing data loss, especially during reset, update, share detach, and failed
   bootstrap/rebuild operations.
3. Preventing crashes, broken startup, unusable sessions, and misleading success
   messages.
4. Keeping important workflows portable across current Arch and older
   Debian-family hosts.
5. Preserving straightforward UX. Avoid per-desktop or per-distribution branches
   when a standard terminal/Linux mechanism works everywhere.

Tiny cosmetic issues are lower priority unless they obscure a security warning or
recovery action.

## Threat model

Assume code running inside the box is actively malicious:

- It can become container root.
- It can replace guest binaries and libraries.
- It can create symlinks anywhere it can write in the rootfs.
- It can race host-side maintenance code.
- It can consume memory, processes, CPU, disk, and network connections.
- It can modify writable shared projects, including scripts the user may later run
  on the host.
- It can call every verb exposed by the passwordless Waterbox helper as the
  invoking user.

Do not treat “the agent probably will not do that” as a defense.

Waterbox reduces risk; it does not make every exposed host service safe. Writable
shares and intentionally reachable host ports remain trust channels. Make those
tradeoffs clear rather than claiming perfect isolation.

## Settled design decisions

These choices were made deliberately. Do not reverse them incidentally while
fixing an adjacent problem.

### Private users are the primary boundary

Normal build and boot paths use:

```text
--private-users=pick --private-users-ownership=map
```

Container UID 0 must not equal host UID 0. Capabilities, seccomp, device policy,
and namespace restrictions are defense in depth; they are not substitutes for a
user namespace.

Waterbox probes the real rootfs instead of trusting a version number because
support depends on systemd, kernel, and the backing filesystem. Feature detection
is preferred over version checks because distributions backport features.

### The unsafe compatibility mode is deliberately difficult to enter

Some live systems use overlay-backed or otherwise incompatible storage where the
rootfs cannot be ID-mapped. The hidden `--unsafe-host-root` option exists for this
case and restores the old host-root behavior.

Rules for this mode:

- Do not show it in ordinary help.
- Do not accept it through an environment variable or persistent configuration.
- Require it explicitly on every relevant invocation.
- Permit it only after the exact secure ID-map probe fails with an
  “ID-mapped mounts unavailable/not supported” error.
- Refuse it when secure ID mapping works.
- Refuse it for unrelated boot/probe failures.
- Print a prominent warning whenever it is active.
- Never silently fall back to it.
- Unattended wake operations must not cold-boot an unsafe box.

The remaining hardening still applies in unsafe mode, but it cannot compensate
fully for container root being real host root.

### Older systemd hosts remain supported

Do not raise the requirement to systemd-nspawn 256 merely to use its
`owneridmap` bind syntax. Waterbox implements live owner-ID-mapped shares with
Linux mount APIs (`open_tree`, `mount_setattr`, and `move_mount`) through the
embedded helper, allowing older Debian-family systemd releases to work.

Probe optional nspawn features such as `--restrict-address-families`; do not infer
them solely from the reported systemd version.

The secure rootfs and share paths still require kernel/filesystem ID-mapped-mount
support. Common native filesystems such as ext4, btrfs, and XFS are the expected
case. FUSE, network, removable-drive, and overlay filesystems may reject secure
mapping. Fail closed and give an actionable error.

### Shares must remain live

`waterbox share add`, `share detach`, and `start --here` must take effect on an
already-running box. Removing live mounting is a meaningful UX regression.

Share invariants:

- Shares are read/write by design.
- Secure mode maps only container UID/GID 1000 to the source owner; container root
  remains unmapped.
- Mounts use `nosuid,nodev`.
- The host side and root helper both validate sources.
- Allowed sources are user-owned directories inside the user’s home or under
  `/mnt`, `/media`, or `/run/media`.
- Refuse the home directory itself, `~/.ssh`, `~/.gnupg`, `~/.config`, and
  `~/.waterbox`.
- Destinations are basename-based under `~/workspace`; two sources with the same
  basename must fail clearly rather than silently selecting one.
- Detach unmounts only. It never deletes host files.
- Warn before detaching a share still used by guest processes.
- If a live mount or boot mount fails, roll back newly persisted share entries so
  future starts are not poisoned.

Writable shares inherently let a malicious box alter project files the host user
may later execute. ID mapping prevents those files from being created as host
root; it does not make their contents trustworthy.

### Host-port access is intentional

The private veth/NAT setup intentionally lets the box reach host services,
including services listening only on host loopback, through the `host` alias.
This supports local development servers and MCP-like integrations.

Do not restrict host ports as an incidental hardening change. It is an explicit
product requirement. Document the consequence: an unauthenticated host service
that exposes shell execution, a container API, or equivalent authority can become
an escape route.

### GUI policy follows the display protocol, not the desktop brand

- On Wayland, GUI forwarding is enabled automatically when a live Wayland socket
  is available.
- Plain Wayland mode exposes only Wayland. Never silently add Xwayland/X11.
- X11 is off by default because X11 clients can observe and inject input into
  other X clients.
- `--x11` is the explicit opt-in on a Wayland host.
- `--gui` on a native X11 host is also an explicit acceptance of the X11 risk.
- GPU `/dev/dri` forwarding is on by default and can be disabled with `--no-gpu`.

Avoid desktop-specific policy such as “Cinnamon does X, KDE does Y.” Detect the
actual socket/protocol or use a universal fallback.

### Clipboard behavior is universal

tmux mouse mode stays enabled everywhere so scrolling and pane interaction work.
Use:

```text
set -s set-clipboard external
```

This allows tmux’s own copy operation to use OSC 52 without allowing arbitrary
applications to use tmux’s clipboard channel. Do not change it to
`set-clipboard on`.

Terminals that support OSC 52 can copy a normal tmux selection. The portable
fallback is terminal-native selection: hold Shift while selecting, then use the
terminal’s copy shortcut (normally Ctrl+Shift+C). Keep that hint visible in the
welcome banner.

Do not:

- disable tmux mouse mode globally;
- branch by Cinnamon/KDE/GNOME/etc.;
- leave a tmux-owned highlight pretending it can be copied by the outer terminal;
- add an X11/Wayland clipboard bridge without a new security decision, because it
  gives guest processes another channel to the host clipboard.

### Resource limits are static and intentionally simple

Current defaults:

```text
MemoryHigh=60%
MemoryMax=70%
MemorySwapMax=10% of configured host swap (converted to bytes)
TasksMax=2048
CPUWeight=50
IOWeight=50
no hard CPU quota
OOMPolicy=continue
```

`MemoryHigh` applies reclaim/pressure before the hard boundary.
`MemoryMax` is the hard cgroup limit. At the hard limit, the kernel selects
memory-consuming process(es) in the cgroup for OOM killing; `OOMPolicy=continue`
tells systemd not to tear down the entire service merely because a process was
OOM-killed. Do not print a static “OOM behavior” line in status.

`TasksMax` limits processes and threads. A fork bomb at the limit may also prevent
a new shell from being created inside the box. Recovery remains available from
the host with `waterbox stop`/`restart`; do not weaken the task limit merely to
guarantee an in-box rescue shell.

CPU and I/O weights are contention priorities, not hard caps: the box may use idle
host capacity, while ordinary host work wins under contention. A dynamic
host-memory controller was considered and rejected as unnecessary complexity.

`waterbox status` should show the useful live values with color on a terminal and
plain output when piped: current RAM, maximum, remaining RAM, pressure threshold,
CPU policy/weight, and current/max tasks. Swap does not need a prominent status
line.

### Agent accounts are unified across supported agents

`agent-env` treats one profile name as one account identity spanning Claude Code
and Codex. Credentials/config are separate per agent and profile under
`~/.agent-env`, while selected chat-history paths are shared across profiles for
the same agent.

The `AGENTS` registry near the top of the script is the extension point. Adding a
supported agent should normally mean adding one registry row plus a settings
template, not duplicating profile-management logic.

The agents run in bypass/danger-full-access modes intentionally because Waterbox
is their sandbox. Do not “harden” the in-agent settings in a way that makes normal
work fail while leaving the actual container boundary unchanged.

Deleting the active/default profile must:

- succeed even if `.default` is already absent;
- clear the default only when it names the deleted profile;
- select another profile when possible;
- avoid alarming but harmless “file not found” shell errors.

### Self-update is atomic

The canonical update URL is:

```text
https://raw.githubusercontent.com/morkin1792/mylinux/master/waterbox/waterbox
```

The earlier root-level URL was intentionally retired when the project moved into
this directory. Releases that only know the old URL require a one-time manual
download; this compatibility break was accepted.

Never overwrite the running script with `cp -f`, `tee`, or shell redirection.
Bash may still be reading it; truncating/replacing its contents in place can make
the old process continue at an offset inside new text and execute comment words as
commands. The updater must construct a complete sibling file and atomically
rename it over `SELF_PATH`, preserving mode and ownership, with a sudo path for
root-owned installations.

Both foreground updates and background version checks must handle a missing or
moved URL:

- `waterbox update` points users to
  `https://github.com/morkin1792/mylinux` immediately.
- The detached check records an error marker, and a later launch shows a short
  warning with the project URL.
- A response that is not a Bash Waterbox script is rejected.

### Reset is conservative with user data

Reset is destructive only after dependency/security preflight and explicit user
confirmation.

- Confirm the running box has stopped before touching the rootfs.
- If keeping the home directory, move it atomically to a sibling backup first.
- If preservation fails, do not delete the rootfs.
- If rebuild or restore fails, leave the preserved backup in place and print its
  recovery location.
- Shares and wake schedules are separately selectable.
- Detaching a share and resetting the box are distinct operations; never conflate
  them.

## Security invariants

Treat this section as a regression checklist.

### Host-root writes into the rootfs

A malicious container can place symlinks in the rootfs. The host script and the
root helper run outside the guest user namespace as real host root, so user
namespaces do not protect their file operations.

- Validate every managed destination with `_in_jail`/`realpath -m`.
- Use `wb_tee` for generated root-owned writes.
- Use `chown -h` when an attacker-controlled destination might be a symlink.
- Validate parent paths as well as final files.
- Do not refresh managed rootfs files while the box is running. A running rootfs
  is attacker-controlled even when no tmux sessions are visible.
- Fail closed and recommend reset when a managed path resolves outside
  `JAIL_ROOT`.

Do not reduce these checks because private users are enabled; they address a
different privilege boundary.

### Privileged helper

Normal runtime operations use a root-owned helper installed under
`/usr/local/lib/waterbox` with one narrow NOPASSWD sudoers entry. Bootstrap and
reset may request interactive sudo because those operations are inherently broad.

- Keep helper verbs fixed and narrowly scoped.
- Validate every profile, session, timer ID, path, and option again inside the
  helper; the caller is untrusted.
- Do not add arbitrary command execution or arbitrary destination paths.
- Do not reintroduce a broad sudo credential cache.
- The helper’s generated version marker must remain tied to the main script so it
  refreshes after relevant edits.

### Namespace entry

Every host helper path that executes guest-controlled binaries must enter all
guest namespaces:

```text
nsenter --target "$leader" --all ...
```

Never enter only the mount namespace. A guest-controlled binary running with host
PID/network/IPC namespaces could reach host processes or abstract sockets even if
filesystem mounts look isolated.

### Device access

Waterbox boots nspawn with `--keep-unit`, so nspawn does not supply its usual
service-unit device policy. The transient host unit must therefore set:

- `DevicePolicy=closed`;
- explicit access for PTYs, `/dev/net/tun`, and `/dev/fuse`;
- DRM access only when `/dev/dri` is intentionally bound.

This is critical. Without the closed device policy, a retained capability such as
`CAP_MKNOD` can become useful for creating a host block-device node and mounting
host storage. Private users remain the primary defense, but the device policy must
not be weakened.

### Mount construction

The live-share helper holds source and destination by file descriptor across the
namespace transition, applies ID mapping to a detached clone, and moves that mount
into the guest. Preserve this shape; naive path-based `mount --bind` sequences
reintroduce symlink-swap and namespace-visibility races.

Secure-mode shares must not fall back to raw host-ID binds. Raw binds exist only
inside the explicitly approved unsafe compatibility mode and still use
`nosuid,nodev`.

### GUI and network

Treat GUI sockets, host networking, and GPU devices as security-sensitive host
interfaces. Validate generated bind specifications again in the root helper.
Never accept arbitrary bind arguments from a user-writable file.

## Architecture and code map

The executable has three privilege contexts:

1. **Ordinary host user** — CLI, menus, display detection, share list, update
   checks, and orchestration.
2. **Host root helper** — installed immutable helper, systemd unit creation,
   namespace entry, secure mounts, device policy, networking, and guarded rootfs
   maintenance.
3. **Guest user/root** — Arch bootstrap commands, tmux sessions, agent tools,
   in-container systemd services, and generated shell helpers.

Important areas in `waterbox`:

| Area | Main symbols/section |
|---|---|
| Global policy and dependencies | configuration near the top |
| Agent extensibility | `AGENTS`, `_agent_settings_template` |
| Rootfs write safety | `_in_jail`, `wb_tee` |
| Arch image trust | `verify_tarball` |
| Secure build/userns probe | `_nspawn_build`, `_require_rootfs_idmap` |
| Rootfs/bootstrap | `bootstrap_sandbox`, `configure_dotfiles` |
| Profiles | generated `agent-env` functions, migration helpers |
| GUI forwarding | `build_gui_bind_args`, helper GUI collectors |
| Sessions/TUI | `attach_session`, chooser/task-manager helpers |
| Update | `_spawn_update_check`, `_update_notice`, `self_update` |
| Lifecycle | `start_sandbox`, `stop_sandbox`, `restart_sandbox`, `reset_sandbox` |
| Status/resources | `status_sandbox`, helper `resource_status` |
| Privileged boundary | `install_helper` and its `HELPER` heredoc |
| Live shares | host share policy plus helper `mount_into_box` |
| Scheduling | wake and schedule managers, generated `waterbox-fire` |
| CLI | completion, global flag parsing, final command dispatch |

The config-version marker is a checksum of the entire executable. A changed script
causes managed guest configuration to refresh on a safe cold start. If the box is
already running, Waterbox warns that a restart is required instead of performing
host-root writes into the live rootfs.

`WATERBOX_VERSION` remains the public release version and controls self-update
ordering. Decide explicitly when a change warrants a release bump; do not use a
version bump as a substitute for the checksum-based config refresh.

## Networking summary

The guest uses a private veth with fixed Waterbox addresses. Host rules provide:

- outbound internet through source-based masquerading;
- forwarding that continues to work across common VPN route changes;
- access from the guest to host loopback services through DNAT;
- the names `host` and, when safe, the host’s hostname;
- DNS repair when the guest inherits an unreachable loopback resolver.

Networking cleanup must be idempotent. Failed boot/stop/reset paths should not
leave stale firewall rules behind.

## Scheduling summary

There are two different scheduling models:

- `schedule-command` targets a live tmux session and is managed inside the
  container. Session deletion/rename hooks clean up or retarget schedules.
- `wake-claude` uses a narrowly generated host timer because it must work while the
  box is stopped. It may boot a secure box, perform the fixed quota-primer action,
  and return it to the prior stopped state.

Do not generalize host timers into arbitrary host command execution. Timer names,
profiles, times, users, unit bodies, and invoked commands must remain
helper-generated and validated.

## UX conventions

- Errors are short, concrete, and actionable.
- Security warnings state the consequence, not only the mechanism.
- Never print success before the operation is verified.
- TUI cancellation is normal and should not resemble a crash.
- `Ctrl-C` restores the cursor.
- `--help` must never boot, mutate, or interpret itself as a session name.
- Color is used only on terminals and respects `NO_COLOR`; piped output remains
  clean.
- Prefer one universal Linux behavior over a growing compatibility matrix.
- Arch Linux with KDE should feel polished; other mainstream environments,
  including Linux Mint with Cinnamon, must remain functional with documented
  standard fallbacks.

## Portability rules

- Keep host-side code compatible with the Bash and core utilities normally
  available on supported Debian-family releases.
- Avoid depending on the newest systemd parser when a feature probe or kernel API
  provides a safe compatible path.
- Do not assume the host has Arch tools such as `pacstrap`.
- Bootstrap with the guest’s pacman inside nspawn.
- Verify the downloaded Arch bootstrap signature against the pinned signing key.
- Dependency installation may vary by package manager; security behavior must not.
- Do not add desktop-environment branches merely to handle terminal behavior.
- Test paths with spaces and unusual but allowed names; quote expansions.

## Testing expectations

There is no complete automated suite, so validation must be proportional to the
change. At minimum after every edit:

```bash
bash -n waterbox
git diff --check
```

Also syntax-check the generated root helper, not only the outer script. One
portable approach from this directory is:

```bash
helper_start=$(rg -n "cat <<'HELPER'" waterbox | cut -d: -f1)
helper_end=$(rg -n '^HELPER$' waterbox | cut -d: -f1)
sed -n "$((helper_start + 1)),$((helper_end - 1))p" waterbox | bash -n
```

For tmux changes, use an isolated server/socket and confirm options against the
oldest supported tmux where possible. Never disturb the developer’s live tmux
server.

For self-update changes:

- use temporary copies and a `file://` URL;
- simulate an older local version and a newer remote version;
- verify the output file is byte-identical to the remote;
- verify executable mode is preserved;
- verify there is no trailing `command not found` output;
- test an absent URL and a non-Waterbox response;
- test the background error-marker/notice path.

For security/lifecycle changes, exercise on a real host—not only inside another
container—when device cgroups, systemd units, namespaces, ID-mapped mounts,
iptables, GUI sockets, or OOM behavior are involved. Important platform coverage:

- a current Arch/systemd host;
- an older supported Debian-family systemd host;
- Wayland without Xwayland exposure;
- native X11 only with explicit GUI enablement;
- a Linux Mint live/overlay environment for the secure failure and explicit unsafe
  path;
- native and unsupported share filesystems;
- cold boot and live add/detach for shares.

Before considering a security change complete, inspect these regressions:

- normal boot has a nonzero host start in `/proc/<leader>/uid_map`;
- helper rejects an unapproved legacy host-root box;
- device policy is closed with only intended devices allowed;
- shares are ID-mapped and `nosuid,nodev`;
- Wayland mode has no X11 socket unless explicitly requested;
- every `nsenter` of guest-controlled code uses `--all`;
- rootfs writes cannot follow a guest-planted symlink outside `JAIL_ROOT`;
- failed home preservation cannot proceed to reset deletion;
- a failed live share does not remain persisted;
- status works with and without a TTY;
- a memory-hog process can be OOM-killed without systemd intentionally stopping
  the whole unit;
- host `stop` still recovers a box that cannot create more processes.

## Known intentional limitations

- The box can reach all host ports. Host services must defend themselves.
- Writable shares can contain malicious content later executed by the host user.
- Secure ID-mapped mounts do not work on every filesystem.
- Unsafe host-root mode is not a secure sandbox.
- A saturated `TasksMax` may block new in-box sessions; recover from the host.
- Disk usage has no equivalent simple hard quota yet.
- X11 forwarding fundamentally exposes other X11 clients.
- Old releases pointing at the retired root-level update URL cannot discover the
  new location automatically.

When a limitation changes, update this file and the relevant user-facing help in
the same change.

## Working discipline

- Preserve unrelated work in a dirty tree.
- Avoid destructive Git commands.
- Read the whole affected function and its generated/helper counterpart before
  editing.
- Keep comments focused on why a security or compatibility constraint exists.
- Do not remove an odd-looking guard until you understand the exploit or failure
  it prevents.
- Do not report a security fix as complete based only on syntax checks.
- When behavior changes materially, update this document so the next maintainer
  inherits the decision and its rationale rather than repeating the investigation.
