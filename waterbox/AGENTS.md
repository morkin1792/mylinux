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

Waterbox is a self-contained Bash program that creates and operates Arch Linux
root filesystems ("environments") under `~/.waterbox` using `systemd-nspawn`. It is intended
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

### Environments are separate boxes

One host user can own up to 16 environments. Each is a complete, independent box:
own rootfs, guest home, packages, shares, systemd machine and veth subnet. The use
case is one main environment for agent work plus occasional special-purpose ones
(for example a gaming box) whose packages and devices should not mix with it.

Identity:

| | env 0 | env N (1–15) |
|---|---|---|
| Config dir | `~/.waterbox` | `~/.waterbox/envs/N` |
| Rootfs | `~/.waterbox/root` | `~/.waterbox/envs/N/root` |
| Machine / unit | `waterbox` | `waterbox-N` |
| Host iface | `ve-waterbox` | `ve-waterbox-N` |
| Subnet | `10.20.30.0/24` | `10.20.(30+N).0/24` |
| Restore marker | `/var/lib/waterbox/live-<uid>` | `/var/lib/waterbox/live-<uid>-N` |
| Autostart unit | `waterbox-autostart.service` | `waterbox-autostart-N.service` |

- Env 0 keeps every path and identifier of the single-box releases, so upgrading
  moves no data and old autostart units/wake timers keep targeting it.
- Every identifier follows from the numeric id through `_env_ids_apply`, which
  the helper receives verbatim (`declare -f`). Never derive one twice.
- Names are labels in the ordinary-user registry `~/.waterbox/envs.list`
  (`<id> <name>`). Nothing privileged reads it. Rename edits only that line and is
  allowed while the environment runs. An upgrade from a single-box release
  writes `0 main` for the existing box. A first run starts with an empty
  registry; `_env_ensure_one` then creates `main`, asking on a terminal whether
  it is a gaming environment (scripts and pipes get an ordinary one).
- The CLI activates one environment with `_use_env <id>` and then runs the
  single-box code unchanged. Every helper call goes through `run_priv` /
  `run_priv_quiet` (or the literal `exec … --env "$WB_ENV" shell`), which pass
  `--env <id>` as the first two arguments. The helper accepts `--env` only there,
  so no later argument (a tmux argument, an API key) can be reinterpreted; a
  missing `--env` means env 0.
- Per-box commands pick the environment with `_resolve_env`: `--env <name>`, else
  the only environment, else the only running one, else the environment menu on a
  terminal, else an error. Never guess between several.
- The session picker lists sessions of every running environment with the
  environment name. Enter attaches in that session's environment without asking;
  `a` asks which environment (booting it if needed). Session names are unique only
  within one environment; a named `start` that matches several is refused.
- Delete refuses a running environment, requires the name typed back, removes the
  environment's wakes and autostart first, refuses a `JAIL_ROOT` that resolves
  elsewhere, and uses interactive sudo like reset. Shared host folders are never
  touched. A new environment never adopts a leftover rootfs under a free id.
- Environments never reach each other over the network: `net_up` keeps one
  `FORWARD -i ve-waterbox+ -o ve-waterbox+ -j DROP` above every per-environment
  ACCEPT (re-inserted on top each time); `net_down` removes it once no other
  environment's veth exists. Without it, MASQUERADE would even present one box's
  traffic to another as coming from `host`. Each still reaches the host itself.
- Host-root containment is unchanged: `JAIL_ROOT` stays literal per environment.
  Shares may never include any part of `~/.waterbox` (it holds every rootfs and
  the files each helper trusts), in the CLI and the helper alike.

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
- A share added while the box is stopped remains pending until one cold boot
  mounts it successfully. If the helper identifies that exact pending source as
  unsupported, remove only that entry and retry the boot automatically.

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
- Accept Wayland only from `/run/user/<host-uid>/wayland-N`, and reject symlinked
  display sockets/auth files. A caller-controlled Unix socket must never become a
  general host-capability bridge through the passwordless helper.
- Plain Wayland mode exposes only Wayland. Never silently add Xwayland/X11.
- X11 is off by default because X11 clients can observe and inject input into
  other X clients.
- `--x11` is the explicit opt-in on a Wayland host.
- `--gui` on a native X11 host is also an explicit acceptance of the X11 risk.
- A user-owned X socket (a desktop's per-session Xwayland, often mode 0755) is
  owner-mapped like the Wayland socket, or the box cannot connect; a root-owned
  one stays unmapped, since mapping it would map container uid 1000 to host root.
  The box's processes never match the X server's `localuser` rule, so access
  depends on the copied cookie; `--x11` warns when it cannot forward a display or
  copy the cookie.
- GPU `/dev/dri` forwarding is on by default and can be disabled with `--no-gpu`.

Avoid desktop-specific policy such as “Cinnamon does X, KDE does Y.” Detect the
actual socket/protocol or use a universal fallback.

### USB sharing is explicit opt-in and shared, not moved

`--usb` (on `start`/`restart`) binds `/dev/bus/usb` (raw usbfs for libusb tools)
plus the ttyUSB/ttyACM serial nodes present at boot. The binds are the host's
own device nodes, so devices remain simultaneously usable on the host;
concurrency limits are per-device (USB interface claiming, serial port
contention), not imposed by Waterbox.

Rules for this feature:

- Never enable it by default and never persist it; it applies to the current
  boot only, like the display flags.
- `DevicePolicy=closed` stays; USB adds only explicit `DeviceAllow` entries
  (`char-usb_device`, and `char-ttyUSB`/`char-ttyACM` only when such nodes
  exist at boot).
- Inside the user namespace the nodes belong to an unmapped owner, so the
  helper grants access with an ACL for the host UID that container UID 1000
  maps to, applied only after a successful boot. A failed grant stops the box.
- Stop revokes those ACLs (skipped under the identity map of unsafe mode, where
  UID 1000 is normally the real host user). The globs are fixed host `/dev`
  paths on kernel-managed devtmpfs; no caller input reaches them.
- Print a warning when enabling: the box gets raw access to every attached USB
  device and could reprogram one or talk to a plugged-in security key.
- Hotplug is partial by design: raw usbfs devices plugged in later appear in
  the live directory bind but lack the ACL until the next `--usb` boot; serial
  nodes plugged in later are not bound at all. Do not add udev hooks or a
  device manager without a new design decision.

### Audio goes through a sandboxed Pulse bridge

`--audio` (on `start`/`restart`) never gives the box the host's PipeWire or Pulse
socket. Reasons, verified in the PipeWire source (1.6):

- A PipeWire client can create nodes in the daemon (`adapter`,
  `spa-node-factory`) with its own properties. `library.name` cannot escape the
  SPA plugin directory (`../` is stripped), but audioconvert honours
  `audioconvert.filter-graph.N` (a LADSPA plugin is `dlopen`ed by absolute path)
  and `debug.wav-path` (writes a file). Either is code execution or an arbitrary
  file write as the host user.
- A Pulse client's stream proplist becomes the `pw_stream` properties, and the
  stream's audioconvert runs inside the Pulse server process, so the same
  properties work through the host's Pulse server; `load-module` adds more.

Design:

- The helper starts `<machine>-pulse.service`: the host's `pipewire-pulse`, as the
  user, with a generated config (`/run/waterbox-pulse/<uid>-<env>.conf`) that
  listens only on `/run/waterbox-pulse/<uid>-<env>/native`, has
  `pulse.allow-module-loading = false`, no D-Bus name and no TCP. It is a normal
  client of the user's PipeWire (`PIPEWIRE_REMOTE`).
- The bridge is sandboxed so stream properties cannot turn into code or writes:
  `NoExecPaths=/` + `ExecPaths=/usr -/lib -/lib64`, `MemoryDenyWriteExecute`,
  `ProtectSystem=strict` with only its own directory writable, `ProtectHome=tmpfs`
  (+ `BindPaths` of the PipeWire socket), removable-media paths inaccessible,
  `RestrictAddressFamilies=AF_UNIX`, `NoNewPrivileges`. `BindsTo=` the box unit;
  `power_off` also stops it and removes its files.
- Only the bridge socket enters the box, ID-mapped, at `/tmp/.waterbox-pulse`;
  `boot-env` exports `PULSE_SERVER` and a managed `client.conf.d` names it too.
- The box's own `pipewire`, `wireplumber` and `pipewire-pulse` user units are
  masked. PipeWire-native programs (SDL tries PipeWire first) then fall back to
  Pulse instead of an empty local graph, and no box socket can refuse
  connections: libpulse clients such as Steam recurse until their stack
  overflows on a Pulse socket that refuses, while an absent server is handled
  cleanly. Do not unmask `pipewire.service` alone: `pipewire-pulse.service`
  requires it (a masked dependency left its socket failed and refusing).
- Remaining exposure, stated in the warning: microphone, all host audio, and
  changing/rerouting sound devices; plus memory-safety bugs in the bridge's
  Pulse protocol code (sandboxed, but still a client of the user's PipeWire).
- No PipeWire or no `pipewire-pulse` on the host: clear error, no fallback.
- Per boot, never persisted (except that a gaming environment boots with `--game`
  every time), never used by autostart or wake.
- `/etc/waterbox/boot-env` is written by the helper from what it accepted; never
  copy a user-writable file there.
- Packages (`libpulse pulseaudio-alsa`) are in `PKGS` for new builds. Existing
  boxes are never upgraded implicitly.

### X11 programs on Wayland use an X server of the box's own

On Wayland-only GUI boots, when the box has `xwayland-satellite` (in `PKGS`), the
helper exports `DISPLAY=:42` in `gui-env` and starts the box's
`waterbox-xwayland.service` (a system unit running as the guest user) after the
Wayland socket is mounted. X11-only programs (Steam, Wine, Proton games) then
open as normal Wayland windows and see only the box's other X11 clients, never
the host's. `--x11` still shares the host's X server, and then the satellite is
not started. Boxes without the package keep `DISPLAY` unset, so toolkits never
pick a dead X11 display.

### `--game` is a fixed bundle

`--game` = `--gui` + `--audio` + `--gamepad` (GPU is already the default). It
never includes `--x11` or `--usb`, which stay separate explicit decisions, and
the audio/gamepad warnings still print. Like the flags it bundles, it applies
to one boot only — except in a gaming environment (below).

### Gaming environments

`waterbox env create <name> --game` (or answering yes in the menu's `a`) records
the kind in the registry (`<id> <name> game`). Such an environment:

- installs `wine-staging` (it provides `wine`) and `winetricks` at build time and
  prepares `~/.wine` as the
  guest user (`WINE_PREFIX_SCRIPT`): Mono/Gecko prompts skipped, DXVK, and Wine's
  virtual desktop on by default through `HKCU\Software\Wine\Explorer`
  `Desktop`/`Desktops` (checked against Wine 11's explorer), so a plain
  `wine program.exe` opens in one window and launchers that embed another
  process's window draw on the box's own X server. Failure only warns;
- boots with `--game` on every cold boot. This is the one place device flags are
  remembered, because the user chose it explicitly when creating the
  environment. An explicit `--no-gui` still wins for the display, and on a host
  without Wayland a warning states that the box then uses the host's X11;
- never preinstalls Steam (`pacman -S steam` already asks nothing).

Ordinary environments are unchanged and stay light.

### Gamepads are explicit, exact, and guarded

`--gamepad` (on `start`/`restart`) passes the controllers present at boot:

- `/dev/input/event*` whose udev record has `ID_INPUT_JOYSTICK=1`, their `js*`
  nodes, and only the `hidraw*` nodes of those same devices — skipping any device
  where any input node is `ID_INPUT_KEYBOARD=1` (keyboards with a misdetected
  media/"joystick" collection share their HID interface and hidraw with the key
  reports). Security keys' hidraw never qualifies.
- Each node's sysfs identity is recorded at selection; `devguard_start` fails the
  boot if any node changed device before the guard runs.
- Each node gets its own `--bind` and exact-path `DeviceAllow`; never the
  `char-input`/`hidraw` majors (unsafe-mode root could otherwise mknod a keyboard).
- ACLs like `--usb`, granted after a successful boot, revoked on stop.
- `/dev/uinput` is never passed: a virtual keyboard could type into the host
  session. Steam Input virtual pads do not work; native controller support does.
- The box gets `SDL_JOYSTICK_DISABLE_UDEV=1`; no udev database is synthesized.
- **Minor-number reuse guard.** Bind and device cgroup both work by major:minor.
  When a pad is unplugged its minor is freed and the next input/hidraw device (a
  keyboard, a security key) may receive it. The helper therefore starts
  `<machine>-devguard.service` (`BindsTo=` the box, `Restart=always`) before
  granting access. It follows `udevadm monitor` and, when a passed node goes away,
  rewrites `/run/waterbox/devallow-<uid>-<env>` without it and reapplies the list
  with `systemctl set-property --runtime`. Once listening (and after every
  restart) it re-checks each node's sysfs identity, so removals are never missed.
  Any `add` event re-checks all nodes too (covers a missed remove). The narrowed
  list is applied before it is recorded; if `set-property` fails the guard stops
  the box (fail closed). `StartLimitIntervalSec=0` keeps a crashing guard
  restarting. The guard refuses to run through sudo. A guard that cannot start
  fails the boot.
- Per boot, never persisted (except that a gaming environment boots with `--game`
  every time), never used by autostart or wake. Hotplugged
  controllers need another `--gamepad` boot.

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

All environments run in `waterbox.slice`, a runtime unit the helper writes
(`/run/systemd/system/waterbox.slice`, rewritten only when its body changes). The
memory, swap, CPU and I/O limits live on that slice, so every running environment
together stays inside the single-box budget; per-unit memory limits would bypass
it. `TasksMax` and `OOMPolicy` stay per environment. Consequence: under memory
pressure the kernel may OOM-kill a process in any running environment, not only
the one using most. A failure to write the slice fails the boot.

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
plain output when piped: current RAM (all environments), maximum, remaining RAM,
pressure threshold, CPU policy/weight, and current/max tasks. Without `--env` it
first lists every environment's state. Swap does not need a prominent status
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

Claude Code starts with its fullscreen renderer and focus view enabled through
the user settings keys `"tui": "fullscreen"` and `"viewMode": "focus"`. Focus
shows the latest prompt, compact tool summaries/diffstats, and the final response.
Apply these keys as defaults to existing profiles only when absent, so an explicit
per-account preference remains respected.

Claude Code also defaults to the Opus model with `"effortLevel": "high"`. Existing
profiles matching Waterbox’s former exact default of Opus + `xhigh` are migrated
to Opus + `high`; other explicit model/effort combinations are preserved.

Claude Code stores absolute `installLocation` paths in each profile's
`plugins/known_marketplaces.json`. The pre-1.9 → 1.9 layout migration moved the
files but historically not those strings, and Claude Code rejects a marketplace
whose recorded path is outside the real config root (it compares strings, so
the `~/.claude-env` compat symlink does not help). The generated zshrc contains
an idempotent guest-side self-heal that rewrites stale `~/.claude-env/` prefixes
in that file before any interactive `claude` launch. Keep it guest-side: a
host-root rewrite of this guest-controlled file would need the full jail-write
discipline for no added benefit.

Deleting the active/default profile must:

- succeed even if `.default` is already absent;
- clear the default only when it names the deleted profile;
- select another profile when possible;
- avoid alarming but harmless “file not found” shell errors.

### Claude Code temp files live on disk, not on `/tmp`

The box's `/tmp` is normally a tmpfs that systemd-nspawn mounts per boot, sized as
a fraction of host memory. It is emptied only when the box stops, the stock
tmpfiles age for it is far longer than agent files live, and its contents count
against the box memory limit. Session scratchpads routinely hold hundreds of
megabytes (package installs, build output), so a box that stays up for days fills
it.

The generated zshrc therefore exports `CLAUDE_CODE_TMPDIR=/var/tmp/claude`, and a
managed `/etc/tmpfiles.d/waterbox-claude-tmp.conf` makes the box's own systemd
create that directory (`0700`, guest user) at boot and remove entries untouched for
7 days.

- Keep creation and cleanup guest-side through tmpfiles. Do not add a host-root
  sweep of this guest-controlled tree.
- The export is conditional: if the directory is missing or not owned by the
  user, the variable stays unset and Claude Code falls back to `/tmp`.
- Keep the path short. Claude Code places Unix sockets under its temp dir and
  socket paths have a small fixed length limit.
- The zshrc path and the tmpfiles path must stay identical; the harness checks
  both.
- Do not enlarge the `/tmp` tmpfs as the fix: that only spends more memory on
  discardable files.
- Files there survive a box stop, unlike `/tmp`; the age rule is what bounds them.
  Other tools that write straight to `/tmp` are unaffected.

### Sessions come back after an unexpected shutdown

A server running the box may lose power or reboot on its own. The next cold boot
after any shutdown that was not a verified `waterbox stop`/`restart`/`reset`
recreates the box's tmux sessions, windows, pane layout and directories, and
reopens the Claude Code/Codex chat that ran in each pane. Chats that were mid-turn
continue on their own with one fixed prompt telling the agent to check its
interrupted work. A clean stop restores nothing: the user closed those sessions.

Split of responsibilities:

- **Host helper classifies, nothing more.** `resume_after_boot` keeps a root-owned
  marker `/var/lib/waterbox/live-<uid>`. A successful cold `boot`/`autostart`
  creates it; `down` removes it only after `power_off` succeeded. A cold boot that
  still finds it starts `waterbox-resume@restore` inside the box, otherwise
  `waterbox-resume@discard`, through `systemctl -M` with a deadline. Never fatal.
- The marker stays outside the rootfs (the box cannot forge or delete it) and
  outside the user's home (the NOPASSWD caller could otherwise aim the root write
  at another file through a symlink).
- `boot_min` (unattended wake-claude) never calls it: a wake boot must neither
  consume a pending restore nor clear the marker.
- A graceful host reboot also counts as unclean, deliberately: the user never
  stopped the box, so "same environment back" applies.
- **Everything else is guest-side** in `/usr/local/bin/waterbox-resume`, run as the
  guest user. The host never reads what it records, so none of it needs the
  host-side read discipline.
- Agent hooks are installed as **managed** config: `/etc/claude-code/managed-settings.json`
  and `/etc/codex/managed_config.toml` (both Waterbox-owned, rewritten on refresh).
  Managed hooks cover every profile without editing account settings, and Codex
  silently skips unmanaged hooks until a person trusts them in `/hooks`.
- Claude Code gets only SessionStart/UserPromptSubmit/Stop/SessionEnd: an event
  name an older Claude Code does not know could invalidate the whole managed file.
  Codex also gets `Interrupt`; it tolerates unknown event names.
- A hook records a chat only when the agent firing it was started by the pane's own
  shell (only shells between them). An agent run by another agent (`codex exec`
  from Claude's Bash tool) inherits `TMUX_PANE` and must not replace the pane's
  chat. Records are keyed by pane id **and** pane shell pid, because pane ids
  restart at `%0` with every tmux server.
- `claude remote-control` (alias `rc`) is a server, not one chat: the hooks cannot
  reopen it, and the sessions it spawns are agents run by an agent. The snapshot
  therefore reads each pane's foreground job from `/proc` and, only when it is
  exactly `claude rc|remote-control ...`, saves its arguments; restore re-runs
  `claude remote-control <same args>` in that directory after waiting for the
  network. Keep this an exact allowlist: re-running arbitrary pane commands could
  repeat one with side effects.
- `claude rc` cannot choose a folder per chat; every chat it spawns has the
  daemon's folder as project root (history, `CLAUDE.md`, memory). The in-box
  `waterbox-rc <folder> [rc options]` creates the folder and starts one daemon
  there in a new tmux window (same agent-env profile, `--name` defaulting to the
  folder name and `--permission-mode` to `bypassPermissions`, because Remote
  Control does not start its sessions in the account's `defaultMode`), typed into the window's shell so restore sees and restarts it.
  It is guest-side convenience only; the host never runs it.
- Claude Code fires no Stop hook on an Esc interrupt, so restore downgrades a busy
  Claude chat whose transcript ends with "[Request interrupted by user" to idle.
- A snapshot timer saves the layout every 30 s, writing only when it changed. It
  starts only via `Wants=` from the restore/discard unit, ordered after it, so it
  never runs on a wake boot, never overwrites the layout a crash left with an
  empty one, and never saves a half-restored layout.
- Restore re-tiles a window after each split; splitting the newest pane alone runs
  out of room after about six panes and silently drops the rest.
- The restore unit is `RemainAfterExit=yes` + `KillMode=process`: the tmux server it
  starts must outlive the oneshot. Panes are created with `-e` variables that the
  generated zshrc consumes; `new-session -e` lands in the session environment, so
  restore unsets those right after the first pane exists.
- The restore unit starts tmux with no login session, so the box's user lingers
  (`/var/lib/systemd/linger/<user>`): its manager, `/run/user/1000` and session bus
  exist at every boot, and the unit hands tmux `XDG_RUNTIME_DIR` and the bus
  address. Without it, every pane of a restored server, including sessions opened
  later, lacks `systemctl --user`, D-Bus and the keyring until the next stop.
- The helper's `wake` and `autostart` verbs take turns through a `flock` on
  `/run/waterbox-unattended.lock`. A wake timer due while the host boots would
  otherwise boot the box first, autostart would see it running and skip the
  restore, and the wake would then stop the box again. Interactive verbs do not
  take the lock, so a manual start never waits behind a wake.
- Busy chats wait (at most 5 minutes, in the pane) for the agent's API to be
  reachable before continuing, because the network may come back after the host.

Autostart is opt-in (`waterbox autostart on`): one fixed host unit, generated by the
helper, runs `waterbox-helper autostart --user <uid>` after `network-online.target`.
It always boots the secure mode, without GUI or USB. A box that only boots in
explicit unsafe mode simply fails to autostart. Do not add an unsafe or GUI variant.

- The unit has `DefaultDependencies=no` and `Type=simple`. A target waits for every
  unit it pulls in unless that unit opts out, so the default oneshot held the host's
  `multi-user.target`, and with it the login screen, behind network-online plus
  the box's boot and restore. Keep the restated `Conflicts=`/`Before=shutdown.target`.
- The home may be mounted after the host boots (an encrypted volume unlocked over
  SSH). The helper's `autostart` verb waits for `~/.waterbox/root/.waterbox-ready`,
  checking once a minute, before it takes the unattended lock, so a long wait never
  starves a wake. Shutdown stops the wait.
- `waterbox start` (via `ensure_host_privs`) re-runs `autostart-enable` when the unit
  is enabled; the helper rewrites the unit only when its body changed. That is how
  an enabled unit from an older release gets the current body.

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
- A rootfs without `.waterbox-ready` is not automatically disposable. Only the
  separate host-side `bootstrap-in-progress` marker authorizes retrying an
  interrupted bootstrap; a box can delete its own in-rootfs marker.
- After a failed reset rebuild, clear the automatic-retry marker so a later
  ordinary start cannot perform another wipe while a preserved home is parked
  outside the rootfs.
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
- Use `_read_jail_regular` for small host-side reads of guest-controlled files.
  Direct `cat`/`grep` can follow symlinks, block forever on a FIFO, or consume an
  unbounded file even when no write follows.
- Use `chown -h` when an attacker-controlled destination might be a symlink.
- Validate parent paths as well as final files.
- Keep `JAIL_ROOT` literal in containment checks. A bind mount at
  `~/.waterbox` safely relocates storage while preserving that path; accepting a
  symlinked root would let the NOPASSWD helper's caller redirect fixed host-root
  operations elsewhere.
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

Non-interactive namespace entries also need finite `timeout`/kill deadlines. The
guest controls `/bin/sh`, `tmux`, `getent`, and every other in-rootfs executable;
correct namespace isolation prevents escape but does not prevent one from hanging
the host-side command forever. Do not apply this deadline to the intentionally
interactive attached shell.

### Device access

Waterbox boots nspawn with `--keep-unit`, so nspawn does not supply its usual
service-unit device policy. The transient host unit must therefore set:

- `DevicePolicy=closed`;
- explicit access for PTYs, `/dev/net/tun`, and `/dev/fuse`;
- DRM access only when `/dev/dri` is intentionally bound;
- gamepad nodes only by exact path, under the device guard (see above).

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

The helper derives `/etc/waterbox/gui-env` from the fixed display targets it
accepted. It must never copy the ordinary-user `gui_env` diagnostic file into the
rootfs as root; that file is mutable and could be redirected to disclose host
data.

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
| Environment identity | `_env_ids_apply`, `_use_env`, registry `_env_*` functions |
| Environment selection | `_resolve_env`, `_env_menu`, `_env_delete`, `env_cmd`, `status_all` |
| Agent extensibility | `AGENTS`, `_agent_settings_template` |
| Rootfs write safety | `_in_jail`, `wb_tee` |
| Arch image trust | `verify_tarball` |
| Secure build/userns probe | `_nspawn_build`, `_require_rootfs_idmap` |
| Rootfs/bootstrap | `bootstrap_sandbox`, `configure_dotfiles` |
| Profiles | generated `agent-env` functions, migration helpers |
| GUI forwarding | `build_gui_bind_args`, helper GUI collectors |
| Sessions/TUI | `_pick_session`, `_session_rows`, `attach_session`, chooser/task-manager helpers |
| Update | `_spawn_update_check`, `_update_notice`, `self_update` |
| Lifecycle | `start_sandbox`, `_env_up`, `stop_sandbox`, `restart_sandbox`, `reset_sandbox` |
| Audio / gamepads | helper `collect_audio_mount`, `collect_gamepad_nodes`, `devguard_*`, verb `devguard`; guest `configure_audio_units` |
| Status/resources | `status_sandbox`, helper `resource_status` |
| Privileged boundary | `install_helper` and its `HELPER` heredoc |
| Live shares | host share policy plus helper `mount_into_box` |
| Scheduling | wake and schedule managers, generated `waterbox-fire` |
| Session restore | `write_resume_helper` (guest), helper `resume_after_boot`, `manage_autostart` |
| CLI | completion, global flag parsing, final command dispatch |

The config-version marker is a checksum of the entire executable. A changed script
causes managed guest configuration to refresh on a safe cold start. On
`waterbox`/`waterbox start`, an outdated running box is automatically stopped and
refreshed when tmux confirms it has no live sessions. If sessions exist—or the
session query fails—leave it running and warn that a restart is required. Never
perform host-root config writes into a live rootfs.

`WATERBOX_VERSION` remains the public release version and controls self-update
ordering. Every bug fix intended for publication must bump it before release;
otherwise existing installations at the same version will refuse to download the
changed script. User-visible features and behavior changes also require a bump.
Documentation-only edits may keep the current version. Do not use a version bump
as a substitute for the checksum-based config refresh.

## Networking summary

The guest uses a private veth with fixed Waterbox addresses. Host rules provide:

- outbound internet through source-based masquerading;
- forwarding that continues to work across common VPN route changes;
- access from the guest to host loopback services through DNAT;
- the names `host` and, when safe, the host’s hostname;
- DNS repair when the guest inherits an unreachable loopback resolver.

The live `/etc/resolv.conf` policy is exactly three or fewer entries: the host's
first usable resolver (for VPN/split-DNS), followed by `1.1.1.1` and `8.8.8.8`
with duplicates removed. Keep the public fallbacks within glibc's three-server
limit and use a short timeout so a stale resolver from a previous host network
does not strand the running box. Every `waterbox start`, including attach to an
already-running box, reasserts this file even if DNS currently resolves; a VPN
inside the box may still replace it later during that session.

Networking cleanup must be idempotent. Failed boot/stop/reset paths should not
leave stale firewall rules behind.

Every critical veth address, forwarding sysctl, and firewall operation must
propagate failure. A cold boot whose host networking cannot be configured should
be stopped and reported as failed; attaching to an already-running box should
reassert the fixed networking rules so a firewall-manager reload does not leave a
silently disconnected session.

## Scheduling summary

There are two different scheduling models:

- `schedule-command` targets a live tmux session and is managed inside the
  container. Session deletion/rename hooks clean up or retarget schedules.
- `wake-claude` uses a narrowly generated host timer because it must work while the
  box is stopped. It may boot a secure box, perform the fixed quota-primer action,
  and return it to the prior stopped state.

Schedule-command message files are private (`0600`) but owned by the guest user,
not guest root, because the fixed timer service runs as that user. Keep the
in-namespace legacy repair: older versions created root-owned files that neither
the timer nor guest user could read.

Scheduled delivery must resolve the session's active pane, cancel tmux copy/scroll
mode before injecting keys, and check the message read plus every `send-keys`
operation. Empty messages mean Enter-only and are valid. Never log successful
delivery after a read/send failure; return nonzero so systemd records the failure.

Creation and deletion are transactional. If a command timer cannot be installed,
remove its private message and partial units. If removal fails, do not print
success. Host-wake creation must likewise remove partial unit files when systemd
cannot enable the timer. Session killing must be verified before its schedules
are discarded.

Interactive command timers use a short accuracy window so their wall-clock delivery
is not needlessly coalesced. More importantly, never garbage-collect a one-shot as
soon as its calendar expression becomes past: systemd may still be holding it
inside `AccuracySec`. The shared timer display/cleanup path must retain a grace
period longer than every supported accuracy window and show such timers as due.
After successful delivery, a one-shot removes its own fixed unit/message record;
failed sends remain briefly for systemd/journal diagnosis before stale cleanup.
Refresh must migrate the older command-timer accuracy setting without changing
their calendar, command, target, or recurrence.

Command-timer calendars always name their zone. The helper computes the time on
the host from the host-local `HH:MM` the user typed, but the timer runs in the
box's systemd, and the host list/garbage-collection parses the same string again.
A bare wall-clock calendar is read in the box's zone by one and the host's zone by
the other; nspawn only aligns the box's zone at boot, so they diverge whenever the
host changes zone under a running box or the box sets its own. The command then
fires hours off, or the host collects a one-shot before the box fires it. One-shots
are therefore written as an absolute UTC instant and dailies carry the host's zone
name so they follow that zone's DST. Do not write a bare calendar, and do not
"fix" a mismatch by rewriting the box's zone from the host as a side effect. Bare
calendars from older releases are still listed but are not migrated, because the
zone they were created in is unknown.

The command-line form is `<session> <HH:MM> "<command>" [once|daily]`: the mode is
optional, defaults to `once`, and comes last. A mode-shaped token anywhere else is
rejected rather than typed into the session.

Host-side schedule inspection must go through the immutable helper's bounded
record reader. That reader walks the rootfs using directory file descriptors,
rejects symlinks and non-regular files, caps display data, and escapes terminal
control characters. Do not directly `cat`/`grep` live `.timer` or `.msg` paths:
the box controls them, can race path checks, and may use them to reach host paths,
hang a host command, or consume unbounded host memory. The helper reader also
avoids assuming the invoking host user has guest UID 1000.

Do not generalize host timers into arbitrary host command execution. Timer names,
profiles, times, users, unit bodies, and invoked commands must remain
helper-generated and validated.

Session rename is two operations: tmux rename and schedule retargeting. If the
first succeeds but the helper cannot complete the second, keep the renamed
session and warn clearly; never claim that schedules were repointed.

## UX conventions

- Errors are short, concrete, and actionable.
- Security warnings state the consequence, not only the mechanism.
- Never print success before the operation is verified.
- TUI cancellation is normal and should not resemble a crash.
- `Ctrl-C` restores the cursor.
- `--help` must never boot, mutate, or interpret itself as a session name.
- Validate option scope and exact arity before configuration, sudo, or lifecycle
  work. Extra arguments are errors; destructive commands must never ignore them.
- Global options may appear around the command. `--` preserves an option-like
  share path or scheduled command; session names still cannot begin with `-`.
- Every command, subcommand and option belongs in the zsh completion
  (`emit_completion`, the only completion Waterbox ships), which must also work
  when options come before the command. The harness drives it with stubbed
  `compadd`; extend that check with each new option.
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
- New boxes enable Arch's `[multilib]` (exactly that stanza, never
  `[multilib-testing]`) before the first sync, so 32-bit libraries come from the
  official repos instead of AUR look-alikes. Existing boxes are not changed.
- New boxes get the Vulkan driver of the host's Mesa GPU (`_host_mesa_vulkan`:
  Intel → `vulkan-intel`, AMD → `vulkan-radeon`; NVIDIA is never chosen because
  its userspace must match the host driver version) and `ttf-dejavu`. The 32-bit
  driver is not installed (too large for boxes that never need it). Instead
  `LIB32_VULKAN_REPO_SCRIPT` puts an empty package named `lib32-vulkan-driver`,
  depending on the matching `lib32-vulkan-*`, in a box-local repository
  (`/var/lib/waterbox/repo`, `[waterbox]` in `pacman.conf`). pacman resolves a
  dependency to a package with that exact name before asking among providers,
  so Steam/Wine get the right 32-bit driver instead of the alphabetically first
  (NVIDIA) one, and only when they are installed. The package ships nothing and
  conflicts with/replaces nothing; another driver installed explicitly satisfies
  the dependency as well. Removing the repository directory requires removing
  the `[waterbox]` stanza too, or `pacman -Sy` fails. The harness checks the
  choice against a real pacman with fake providers.
- The box runs on the host kernel and never installs a kernel package. Arch's
  `wine` (through `ntsync-autoload`) needs the virtual `NTSYNC-MODULE`, so
  bootstrap installs `waterbox-uses-host-kernel` (`HOST_KERNEL_PKGBUILD`): empty,
  explicitly installed, providing only that name, with no conflicts/replaces so a
  real kernel can still sit beside it. Its failure is a warning, never a failed
  bootstrap. Existing boxes are not changed; they can install it by hand.
- Verify the downloaded Arch bootstrap signature against the pinned signing key.
- Dependency installation may vary by package manager; security behavior must not.
- Do not add desktop-environment branches merely to handle terminal behavior.
- Test paths with spaces and unusual but allowed names; quote expansions.

## Testing expectations

Run the repository regression harness after every behavioral edit:

```bash
waterbox/tests/test-waterbox.sh
```

It covers the outer script and generated Bash/POSIX-shell/Zsh/Python/tmux
artifacts, CLI option grammar, non-mutating inspection, self-update, path
containment, Wayland/X11 policy, DNS ordering, network failure propagation, timer
rollback, session restore (against an isolated tmux server), and static isolation
invariants. Also run:

```bash
bash -n waterbox/waterbox
git diff --check
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
- cold boot and live add/detach for shares;
- session restore: a hard host power-off with a busy and an idle chat, a graceful
  host reboot, a clean `waterbox stop` (must restore nothing), and autostart;
- two environments running at once (both reach the internet and `host`, nonzero
  uid_map, closed device policy, slice caps their sum, stopping one leaves the
  other's firewall rules), autostart/wake/restore for env N, and env delete;
- `--audio` playback and capture; `--gamepad` with Steam and an SDL game, a
  keyboard and a security key not passed, unplugging a pad drops it from the
  unit's `DeviceAllow` (`systemctl show waterbox-N -p DeviceAllow`).

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
- Unsafe host-root mode assumes the host account is UID/GID 1000 for writable
  share ownership. On hosts using another UID, raw compatibility-mode shares may
  be unwritable or show mismatched ownership. Do not silently chown user data or
  change the guest identity as a small compatibility fix; that requires a
  separately designed migration.
- A saturated `TasksMax` may block new in-box sessions; recover from the host.
- USB sharing covers devices present at boot; hotplugged devices need another
  `--usb` boot for access (raw usbfs) or for the bind itself (serial nodes).
  The `--usb` serial nodes have no minor-number reuse guard yet (the gamepad
  guard could cover them).
- Gamepads cover controllers present at boot. A controller that shares a HID
  device with a keyboard collection is not passed at all. A host seat change (fast user
  switching) can reset device ACLs; boot again with `--gamepad`.
- Ctrl-b s inside a box lists only that box's sessions; the host picker lists all.
- The box's own X server (xwayland-satellite) manages windows minimally. A Wine
  program that embeds another process's window (the Nexon launcher's browser
  view, for example) stays white; the same program works with `--x11` (a full
  window manager) or inside Wine's virtual desktop
  (`wine explorer /desktop=<name>,<WxH> <exe>`), which is the recommended fix
  because it keeps the host's X server out of the box. Help text says so.
- `--audio` still exposes the microphone and host audio routing, and the
  bridge's Pulse protocol code; it no longer exposes PipeWire's plugin loading.
- All running environments share one memory budget; there is no per-environment
  budget.
- Disk usage has no equivalent simple hard quota yet.
- Session restore brings back panes, directories, agent chats and a running
  `claude rc`, not other programs running in a pane (editors, dev servers) or background processes an
  agent had started. Chats started before the hooks existed are not recorded.
- Codex restore depends on Codex honouring `/etc/codex/managed_config.toml`; if a
  future Codex drops that file, its chats stop being recorded (Claude is unaffected).
- Autostart keeps the box down when a configured share cannot be mounted at boot
  (for example an external drive that is not attached yet), as a manual start would.
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
