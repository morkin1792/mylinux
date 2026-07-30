# AGENTS.md — manodavinci

Context for anyone (human or agent) picking this project up. Everything here was
measured or verified directly; where something is a *decision*, the reasoning is
included so it doesn't get re-litigated for free.

## What this project is

A tool for editing video for social media in **DaVinci Resolve free on Linux**.
That build cannot decode H.264/H.265 video or AAC audio — such clips import as
**nothing at all: no picture, no sound, no error message**. Not a black frame, an
empty void. It also cannot *encode* H.264/H.265/AV1. So footage must be converted
on the way **in**, and the finished export converted on the way **out**.

`./manodavinci` does both.

Audience note: it is written for people new to Resolve. Every user-facing string
targets a beginner in a hurry. Keep that register — short, concrete, no jargon,
no unexplained acronyms.

## Hard rules for `manodavinci`

1. **ONE self-contained file.** No package, no modules, no `requirements.txt`.
2. **Python 3.6+, standard library only.** External deps are `ffmpeg`/`ffprobe`
   at runtime, plus `kdialog`/`zenity` for dialogs (with a terminal fallback).
3. **It is two programs in one**: a CLI and a DaVinci Resolve Utility script.
   A change to one must not break the other. (Double-clicking it in a file
   manager is just the CLI opening a terminal for itself — same code path.)
4. **Re-run `python3 manodavinci install` after every edit.** Resolve executes
   the *installed copy* at
   `~/.local/share/DaVinciResolve/Fusion/Scripts/Utility/manodavinci.py`, not the
   source. A stale install already caused one phantom bug ("it detected audio as
   video") that does not exist in the source.

## Verified constraints of Resolve free / Linux

**Every codec statement below was verified on DaVinci Resolve free for Linux
21.0.3**, via `GetRenderFormats()` / `GetRenderCodecs()` run in Resolve's own
Console. It was first checked on 21.0.2 and re-checked on 21.0.3: the codec lists
came back byte-identical — 22 formats, zero codecs added or removed. A point
upgrade is not worth re-checking; only a major version jump is.

- **Import**: no H.264, no H.265, no AAC. Accepted: DNxHR/DNxHD, ProRes, MPEG-4
  Part 2, MJPEG, CineForm, APV, AV1 (plays, but decode was CPU-only in testing).
  Audio: PCM16/24, ALAC, MP3, FLAC (FLAC needs mp4/mkv, not mov).
- **Export**: **no H.264/H.265/AV1 encoder anywhere.** `mp4` offers only
  `APVYUV422_10`. `mov` offers ProRes (all six tiers — ProRes encode *is*
  available on Linux free now, contrary to the old Mac-only belief), DNxHR/DNxHD,
  CineForm, Grass Valley, FFV1, Photo JPEG, MPEG4 Video, JPEG 2000, APV,
  uncompressed. **The two-step master → `deliver` round trip is therefore
  permanent**, not a workaround waiting for a fix.
- **Scripting**: the **write** API is blocked in free (`ImportMedia`,
  `ReplaceClip` → "buy Studio" popup). The **read** API works
  (`GetSelectedClips`, `GetClipProperty`). So the script reads the selection,
  converts, opens the output folder, and tells the user to drag files in.
- **External scripting is blocked too** — `bmd.scriptapp('Resolve')` returns
  `None` from outside. To query a running instance, use Workspace → Console
  (Py3) inside Resolve. That is the only way.
- Scripts **can** be bound to a keyboard shortcut (Ctrl+Alt+K, search "mano").
  `keyboard.preset.xml` is a proprietary binary blob (hex UTF-16, scripts not
  stored by name) — **never try to edit it programmatically**; `do_install()`
  prints manual steps instead.
- DNxHR **LB/SQ/HQ are labelled "12-bit"** in Resolve's dropdown but store 8-bit
  4:2:2 per spec. Only HQX/444 actually carry 10/12-bit. Don't "fix" the label.

## Settled decisions (evidence below — don't redo the work)

| Question | Answer |
|---|---|
| Default import profile | `mpeg4_q3` (small, fast, VMAF ~99, ≈ source size) |
| Import profile for heavy scrubbing | `dnxhr_lb` |
| Export/master codec out of Resolve | **QuickTime + Avid DNxHR + DNxHR LB 12-bit** |
| Upload codec | H.264 (`deliver` default) |
| AV1 as an import profile | Kept but not default — slow to encode, CPU-only decode |
| ProRes anywhere | No. Worse quality per MB *and* ~9× slower than DNxHR |

**Import benchmark** (1080p50, 62 s, VMAF vs source): `mpeg4_q3` 152 MB / VMAF 99
(smaller than the source, inter-frame) · `dnxhr_lb` 555 MB / VMAF 99.8
(intra-frame, smoothest scrubbing) · VP9 58 MB / 97.6 but ~5 min CPU encode ·
AV1 ~95 s encode, no niche vs mpeg4.

**Export/intermediate benchmark** (20 s of 1080p50 H.264 at 26 Mb/s;
master → x264 CRF20 → VMAF vs the original source):

| master | size | render | deliver | upload | VMAF |
|---|---|---|---|---|---|
| direct 1-gen (impossible in Resolve) | – | – | 57 s | 27.6 MB | 98.00 |
| **DNxHR LB** | 188 MB | 8 s | 63 s | 33.2 MB | **97.48** |
| ProRes 422 Proxy | 186 MB | 75 s | 64 s | 25.9 MB | 88.32 |
| ProRes 422 LT | 449 MB | 83 s | 65 s | 24.5 MB | 95.38 |
| DNxHR SQ | 606 MB | 13 s | 60 s | 26.1 MB | 97.63 |
| DNxHR HQX | 918 MB | 56 s | 65 s | 26.1 MB | 97.78 |

Higher tiers buy ≤ 0.3 VMAF — invisible, since **VMAF's just-noticeable
difference is ≈ 6 points**. LB's only real cost is that its compression noise
makes the final upload ~27 % bigger. Go to SQ only for 4K/grain/archiving, HQX
only if a heavy grade bands. CineForm and APV masters are **untested** — ffmpeg
8.1.2 decodes both (`cfhd`, `apv`) but cannot encode either, so testing needs a
render from Resolve.

Also settled: "Network Optimization" in the Deliver page = moov atom at the front
(streaming), irrelevant for a local intermediate. `deliver` already applies
`-movflags +faststart` to the upload MP4.

Upload compatibility: H.264 everywhere · H.265 YouTube + usually IG/TikTok · AV1
**YouTube only**. All platforms re-encode server-side, so a fancier upload codec
buys no quality — only bandwidth.

## Code map

| Area | Where |
|---|---|
| Colour (`palette`, `paint`) | top of file, right after `VERSION` |
| Help text | `INTRO`, `GETTING_STARTED`, `HELP`, `SHORT`, `LIST` |
| Codec tables | `PROFILES`, `AUDIO`, `AUDIO_ONLY_EXT`, `DELIVER_*` |
| Probe / encode | `probe`, `default_output`, `deliver_output`, `convert` |
| Input collection | `gather_inputs` → `(files, problems)` |
| Batch loop (shared) | `_run_plans`, with `run_batch` / `run_deliver` on top |
| Dialogs | `class Dialogs` — kdialog / zenity / terminal, plain text only |
| Resolve entry point | `get_resolve`, `resolve_flow` |
| CLI | `cli`, `deliver_cli`, `main` |

Flow: `main` dispatches → `cli`/`deliver_cli` parse args → `gather_inputs` →
`run_batch`/`run_deliver` build `[(inp, out, tail, dur)]` plans → `_run_plans`
confirms overwrites, encodes with progress, prints where files landed.

## Conventions

- **Output naming**: `NAME.mov` next to the input (not `NAME.dr.mov`). Encoded to
  a temp file, then `os.replace` — no half-written outputs. Overwrites ask first
  unless `-f`. Deterministic naming matters: it lets Resolve relink by path when
  a proxy is regenerated (see archival note below).
- **Run from inside Resolve** → outputs go to a `davinci_mov_files/` subfolder
  (`RESOLVE_SUBDIR`) created next to each source clip; the CLI keeps writing
  beside the input. Output folders are created **lazily** in `_run_plans` so a
  cancelled overwrite prompt leaves no empty directory behind.
- **Colour** is gated in `palette()`: off when piped, on `TERM=dumb`, or with
  `NO_COLOR`. Dialogs must get `paint(..., color=False)` — ANSI codes in a
  kdialog box are garbage. Meanings: `H` heading, `G` read-this-if-nothing-else,
  `C` a command to type, `Y` a setting/default, `D` side note.
- **`--help` vs no arguments**: no arguments (or a double-click) prints `SHORT` =
  intro + the whole GETTING STARTED + "Run manodavinci --help to see all the
  options." `--help` prints everything. Both build from the same `INTRO` and
  `GETTING_STARTED` constants so the steps can't drift apart.
- **Never fail silently.** Any path that doesn't exist, any folder with no media,
  aborts the whole batch before a single file is touched, lists every bad path,
  and exits 1. A mistyped subcommand gets a `difflib` suggestion
  (`deliverr` → "did you mean 'deliver'?"). This was a real bug:
  `manodavinci deliverr video.mp4` used to silently ignore `deliverr` and run the
  import path instead.
- **Always tell the user where the file went** (`print_written`) — one absolute
  path for a single file, a folder + basenames (capped at 8) for a batch.

## Traps that already cost time

- Editing the source and testing in Resolve **without reinstalling**.
- `open_help_in_terminal()` spawns a terminal running `manodavinci` with no
  arguments. That child exports **`MANODAVINCI_NO_SPAWN=1`** and `main()` checks
  it — without the guard, a non-tty stdout in the child would spawn another
  terminal, forever.
- `/usr/bin/time` does not exist here. Time shell steps with
  `s=$(date +%s.%N); …; echo "$(date +%s.%N) - $s" | bc`.
- Loading the script in a test harness: it has no `.py` extension, so use
  `import importlib.machinery` + `SourceFileLoader(...).load_module()`.
- When stubbing `have()` in tests, stub *selectively*
  (`lambda c: False if c == "xdg-open" else _have(c)`) — a blanket `False` also
  hides ffmpeg and every test "passes" doing nothing.
- Run CLI tests with the **absolute** script path; a relative one from `/tmp`
  silently resolves to nothing useful.
- Test any `%`-formatted dialog string end to end. A placeholder/argument
  mismatch in the Resolve-only success path is invisible until a user hits it.

## Testing

No test suite; verify by exercising the real paths:

```bash
# make a tiny sample
ffmpeg -v quiet -f lavfi -i testsrc=d=1:s=320x240 -c:v libx264 t/video.mp4

python3 manodavinci t/video.mp4          # convert in
python3 manodavinci deliver t/video.mov  # convert out
python3 manodavinci t/                   # folder
python3 manodavinci nope.mp4             # must error, exit 1, touch nothing
python3 manodavinci deliverr t/video.mp4 # must suggest 'deliver'
python3 manodavinci --help | cat -v | grep '\^\['   # colour must vanish when piped
env -u DISPLAY -u WAYLAND_DISPLAY python3 manodavinci   # SHORT intro, no spawn
python3 manodavinci install              # then re-test inside Resolve
```

For the Resolve-only flow, drive `resolve_flow()` with a fake `resolve` object
exposing `GetProjectManager()` → project → media pool → `GetSelectedClips()` and
`GetClipProperty("File Path")`, plus a `Dialogs` instance forced to
`kind = "term"`. That covers the no-selection dialog and the success dialog
without launching Resolve.

## Known gaps

- `MEDIA_EXTS` (the folder-scan filter) now includes audio extensions, so
  re-running on a folder also picks up outputs from an earlier run. The overwrite
  prompt catches it, but it is noise.
- `deliver file.mov` writes `file.mp4` — if the original `file.mp4` is still
  there, it triggers the overwrite prompt. Working as designed, mildly confusing.
- CineForm and APV as export masters remain unmeasured (see above).
- Frame rate is deliberately untouched: no `-r`, no `-fps_mode`/`-vsync`, no `fps`
  filter anywhere, so output inherits the source's rate and timestamps. A VFR
  source (phone, screen capture) therefore reaches Resolve still VFR, which is
  where real drift would come from. If normalising is ever added, `-r` /
  `-fps_mode cfr` must go **after** `-i`: there they dup/drop frames onto the
  target grid, preserving wall-clock duration. `-r` *before* `-i` instead
  re-stamps input timestamps and changes playback speed. (`-fps_mode` is
  output-only — ffmpeg errors out if you put it before `-i`.)

## Archival policy

Keep only the original camera `.mp4` plus the Resolve project `.drp`. Delete the
`.mov` proxies **and** the final upload MP4 — both are reproducible: re-run
`manodavinci` on the original (deterministic path → Resolve relinks), re-render,
re-`deliver`.

## Hardware acceleration — what is and isn't possible

Not an ffmpeg limitation: ffmpeg exposes every hardware encoder the silicon has.
GPU media engines are fixed-function blocks that implement only **delivery**
codecs — H.264, HEVC, AV1, VP9, VP8, MPEG-2, JPEG — which is precisely the set
Resolve free cannot use. The **editing** codecs it does accept have little or no
silicon support anywhere, in any tool. Installing something does not change this.

| codec | hardware encoder? |
|---|---|
| DNxHD / DNxHR | **None, on any vendor.** CPU only, everywhere |
| MPEG-4 Part 2 | None on modern GPUs (`mpeg4_v4l2m2m` exists for some embedded SoCs) |
| ProRes | No fixed-function block on PC GPUs. Apple Silicon has `prores_videotoolbox`; ffmpeg 8.x also ships `prores_ks_vulkan`, a compute-shader encoder |
| MJPEG | **Yes** — `mjpeg_vaapi`, `mjpeg_qsv` (verified working) |
| H.264 / HEVC / AV1 / VP9 | Yes — `*_vaapi`, `*_qsv`, `*_nvenc`, `*_amf` |

`prores_ks_vulkan` measured on a 10 s 1080p50 clip: **60.6 s wall / 17 s CPU** vs
**49.8 s wall / 295 s CPU** for software `prores_ks` — GPU-bound and *slower* in
wall time, with a much larger file. Not a win, and ProRes is rejected on quality
per MB anyway.

So: a GPU speeds up **source decode** (already used, see `gpu_method`) and could
speed up the encode only if the tool switched to MJPEG on the import side. The
`deliver` step *could* use `h264_vaapi`/`h264_qsv`, but fixed-function encoders
lose quality per byte against `x264 -crf`, and a once-per-video upload master is
exactly where slow-and-better is correct. Keep it on the CPU. The timings in the
tables above scale with core count, not with the graphics card.

The benchmark inputs, VMAF JSON, CSVs and plots live outside this repo, in the
local working folder where the measurements were run.
