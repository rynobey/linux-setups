# Pixel 10 Linux Desktop Architecture

**Status:** decision record, 2026-05-28
**Companion doc:** [`podroid-gpu-strategy.md`](podroid-gpu-strategy.md)

## TL;DR

For a daily Linux experience on the Pixel 10, the architecture that maximises
flexibility and performance is:

```
┌─────────────────────────────────────────────────────────────────────────┐
│ Termux-native + Termux:X11 — primary GUI                                │
│   • all browsing, terminals, daily Termux-native apps                   │
│   • virgl-accelerated GLES (clients off llvmpipe, onto PowerVR)         │
│   • Termux:X11 also acts as the display server for pubuntu X clients    │
│     (direct X over TCP via socat bridge; SSH X-forward as fallback)     │
│                                                                         │
│   ┌────────────────────────────────────────────────────────────────┐   │
│   │ Pubuntu (Podroid AVF VM) reached via SSH on port 9923          │   │
│   │   • dev tools, Docker, real systemd                            │   │
│   │   • GUI apps render in pubuntu, display in Termux:X11          │   │
│   │     via direct-X bridge (~110 MB/s) or ssh -Y (~8 MB/s)        │   │
│   │   • gfxstream HW GPU inside the VM (once tasks #63/#64 land)   │   │
│   └────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────┘
```

proot Ubuntu is **not** part of this architecture. Earlier drafts had it
as an optional fallback layer; subsequent measurements showed proot's
ptrace overhead dominated daily UX, and the Termux-native +
pubuntu-via-SSH path covers every realistic use case.

Winlator stays as a separate APK for gaming. None of this affects it.

## How we got here

This doc records the architectural decision arrived at while debugging
"why is Firefox stuttering in proot Ubuntu when DroidDesk's Firefox felt
smooth on the same device." The investigation overturned a couple of
assumptions; this is the surviving picture.

### Evidence that changed the model

1. **Termux:X11 GLES is software (llvmpipe), not hardware.**
   ```
   $ DISPLAY=:0 glxinfo | grep "OpenGL renderer"
   OpenGL renderer string: llvmpipe (LLVM 21.1.8, 128 bits)
   ```
   The X server itself uses Android EGL → vendor GLES (HW), but Mesa
   clients fall back to llvmpipe. So "go Termux-native to get HW GLES"
   was wrong: Termux-native is also software by default.

2. **Termux Vulkan is software (lavapipe), not hardware.**
   `vulkaninfo` shows `llvmpipe` only — `vulkan-loader-android` isn't
   reaching `vulkan.powervr.so`. Likely cause: linker namespacing blocks
   `dlopen` of vendor libs from a Termux process.

3. **Yet Termux-native Firefox is much smoother than proot-Firefox.**
   User-verified, on the same device, same Termux:X11. The smoothness
   delta has nothing to do with the GPU — both paths are CPU rendering.
   The delta IS proot's `ptrace`-based syscall interception tax. A chatty
   app (browser, hundreds of thousands of syscalls per second) feels the
   per-syscall overhead more than it feels the SW-vs-HW rendering gap.

**Headline implication:** the dominant cost is proot, not GPU drivers.
Eliminating proot delivers the perceived smoothness win even without
touching the graphics stack.

### What that meant for the three layers we were juggling

| Layer | Original role | Final role |
|---|---|---|
| Pubuntu (Podroid VM) | dev/services + occasional GUI via X-forward | unchanged — still the dev/services home |
| proot Ubuntu | GPU-intensive interactive apps (browser, video) | **removed** — no longer in the architecture |
| Termux-native + Termux:X11 | display server only | promoted — runs the desktop and all daily GUI apps |

## The architecture

### Layer A: Termux-native i3 desktop (primary)

- i3 + i3status + rofi + xfce4-terminal installed Termux-side via x11-repo.
- Termux:X11 provides the X server (`com.termux.x11`).
- Lorie (the X server inside Termux:X11) composites via Android EGL on
  the PowerVR vendor GLES driver — that part *is* HW-accelerated.
- Mesa clients (Firefox, mousepad, etc.) hooked to virgl (see "Quick
  wins" below) to take them off llvmpipe.
- All daily apps run here: browser, terminals, editor, file manager.

### Layer B: Pubuntu (Podroid AVF VM) (secondary)

- Real Ubuntu in an AVF microVM (pKVM-isolated, real kernel, systemd,
  Docker, etc.). See [`podroid-gpu-strategy.md`](podroid-gpu-strategy.md)
  for the GPU passthrough story.
- Reached via SSH from Termux for shell work.
- X-forward (`ssh -Y pubuntu firefox` etc.) when a Linux-side GUI app is
  needed — apps render in pubuntu, X protocol travels over SSH to
  Termux:X11, Lorie composites and displays.
- Once gfxstream lands (tasks #63 / #64), pubuntu's apps render fast
  too. The display path stays "X over SSH" which is fine for 2D widget
  UIs, slow for 3D / video.

### Layer C: Winlator (gaming)

- Standalone APK. Doesn't interact with anything above.
- Has its own Vortek-based Vulkan bridge for hardware acceleration of
  Windows games.

## The three GPU-acceleration paths (and why we picked the cheap one)

### Path A — virgl on the Termux side (recommended, near-zero cost)

Mesa supports a `virpipe` backend. Client GL calls get serialised over
a Unix or TCP socket to `virglrenderer`, which executes them via Android
EGL on the real GPU. We already have the server installed
(`virglrenderer-android` from `x11-repo`); just wire it in:

1. Start `virgl_test_server_android &` at desktop startup.
2. Launch each client with:
   ```
   GALLIUM_DRIVER=virpipe LIBGL_ALWAYS_SOFTWARE=0 firefox
   ```
3. Mesa picks the virpipe driver; GL calls hit virglrenderer;
   rendering happens on PowerVR; result composited back.

**Effort:** an evening of wiring + testing.
**Value:** likely moves daily apps off llvmpipe.
**Risk:** virgl tops out around GL 4.3 / GLES 3.0. Fine for browsers,
xfce4, etc. Won't help for modern Vulkan-via-Zink workflows.

### Path B — Termux-native HW Vulkan (parked)

`vulkan-loader-android` returns llvmpipe. Fixing it would need either
patching the loader for adrenotools-style linker namespace escapes, or
embedding Vortek as a library inside the Termux process.

**Effort:** days-to-weeks of Android Vulkan/linker work.
**Value:** small. Almost no daily Linux desktop apps need Vulkan.
Gaming already has Winlator. Defer until a concrete Vulkan-only app
appears.

### Path C — Pubuntu HW GPU via gfxstream (tasked, not done)

Tasks #63 / #64. Pubuntu gets virtio-GPU + Mesa gfxstream guest drivers
so apps inside the VM use the host's PowerVR via AVF's GPU
passthrough. Display still shipped as pixmaps over X-SSH, but render
itself is fast.

**Effort:** days of build engineering (gfxstream guest is well-trodden
by Google).
**Value:** high if pubuntu becomes a serious GUI dev environment;
moderate if pubuntu stays mostly headless SSH-only.

### Path D (R&D) — virgl over vsock between pubuntu and Termux — TESTED, BLOCKED

**Empirically blocked, 2026-05-28.** `glxinfo` works across the
bridge (compute path proven), but `glxgears` and anything that
actually allocates GPU resources fails with "failed to get fd". The
virgl-test protocol uses SCM_RIGHTS for resource sharing, which TCP
can't carry. See [`virgl-over-vsock-viability.md`](virgl-over-vsock-viability.md)
for the full diagnosis.

The compute half worked because `glxinfo` never allocates renderable
resources — it just queries the context. As soon as any real
rendering tries to start, the missing fd payload kills it.

Original scope (kept for context — not currently a viable workflow):

- Termux runs `virgl_test_server_android` listening on a Unix socket.
- A socket bridge (vsock ↔ Unix on Termux side; vsock ↔ TCP/Unix on
  pubuntu side) connects pubuntu's Mesa virgl client to Termux's virgl
  server.
- Mesa in pubuntu serialises GL calls over vsock. Termux executes them
  on PowerVR. **GL compute is hardware-accelerated.**
- **Presentation caveat:** because pubuntu and Termux don't share memory,
  Mesa can't use DRI3 to hand the rendered AHardwareBuffer directly to
  Lorie. So `glXSwapBuffers` falls back to readback + XPutImage — pixels
  travel pubuntu → bridge → pubuntu (readback) → SSH X11 → Termux:X11.
  The display path is still pixmap-shipping over the X channel.
- **Net effect for pubuntu apps:** meaningful but not transformative —
  faster compute, same display bottleneck. Better than software-rendering-
  plus-X-forward; not as smooth as Termux-native virgl.
- **For pubuntu apps to feel as smooth as Termux-native ones, the
  display problem needs solving separately.** See "Pubuntu display
  alternatives" below.

**Effort:** unknown. virglrenderer doesn't ship a vsock transport;
needs either a socat-style bridge or upstream patch.
**Value:** highest theoretical perf for pubuntu GUI apps.

A viability test for this path is recorded in
[`virgl-over-vsock-viability.md`](virgl-over-vsock-viability.md).

### Pubuntu display alternatives — solving the presentation half

For pubuntu apps that need to feel as smooth as Termux-native ones, the
display path matters at least as much as the GL compute path. Three
realistic options:

| Approach | GL compute | Display transport | Effort |
|---|---|---|---|
| X-forward + virgl bridge (Path D) | HW via virgl | X over SSH (pixmap-shipped) | medium — partial win |
| gfxstream in pubuntu + X-forward (#63/#64) | HW via gfxstream | X over SSH (pixmap-shipped) | medium — same display floor |
| Pubuntu desktop + **VNC viewer** in Termux | HW via gfxstream | VNC frame stream (compressed) | medium — mature solution |
| Pubuntu desktop + **waypipe** | HW via gfxstream | waypipe (designed for VM↔host frames) | medium — likely cleanest |

The bottom two move the display problem onto a mature, optimised
transport that knows it's shipping frames across a network. That's how
production "Linux-in-VM on Android" setups handle it. Path D's vsock
bridge is interesting for GL-heavy pubuntu apps but doesn't replace
the display-transport question — they're complementary.

## Sequencing

1. **Drop proot from the daily-desktop role.** Build a `setup-termux-native-desktop.sh`
   parallel to `setup-desktop.sh`. Keep the proot install scripts for
   anyone who explicitly wants that fallback.
2. **Wire virgl into Termux:X11 startup.** Path A — cheapest win.
3. **Finish task #69** (pubuntu SSH + X-forward bridge) so the
   pubuntu-window-into-i3 workflow is one command.
4. **Pursue #63 / #64** (gfxstream in pubuntu) only when you actually
   spend time in pubuntu GUIs.
5. **Park #67 / #68** (Vortek) until a Vulkan-only need surfaces.
6. **Optionally chase Path D** (virgl over vsock) as a long-term
   ideal, only if pubuntu GUI use intensifies and X-SSH starts hurting.

## What this *doesn't* change

- Podroid + pubuntu plan — still the dev/services box, still uses pKVM
  isolation, still needs the existing gfxstream + balloon kernel work.
- Snapshot/restore flow — `02-snapshot.sh` already handles the case
  where no proot is installed (skips the artifact).
- Vortek work in the `rynobey/termux-x11` fork — the Phase 1 scaffold
  stays in the branch as future R&D, just not in any near-term
  critical path.

# Measured 2026-05-29 — X-forward profile + the SSH bottleneck

After settling on `ssh -Y pubuntu` as the canonical pubuntu→Termux:X11
display path, we measured its real ceiling end-to-end and discovered a
significant surprise: **the SSH transport itself caps X-forward at
~8 MB/s, ~14× below what the underlying network can actually carry**.
Going direct over a small bridge instead of SSH unlocks ~110 MB/s and
shifts pubuntu GUI usability dramatically.

This section records the experimental evidence, the bottleneck
decomposition that the evidence forced, and the resulting hybrid
recommendation. The earlier sections of this doc remain accurate; this
adds the measured profile and the refined display path.

## What we measured and how

All numbers from the rebuilt pubuntu (after the destroy/recreate flow),
with no other GUI workloads running on the device. Stack involved:

```
[pubuntu]  app → DISPLAY=...
   ↓ depending on path
   ── (a) SSH X-forward via `ssh -Y`
   ── (b) Direct X over TCP via a socat bridge in Termux
   ↓
[Termux]   Lorie X server (Termux:X11), composites via Android EGL/GLES
   ↓
[Pixel screen]
```

Both paths transit pubuntu → LXC bridge → Alpine → vsock-agent → vsock
→ Podroid TCP listener → Termux. They differ only in what wraps the X
protocol traffic on top of TCP.

### Baseline — what the underlying network can actually carry

iperf3 between endpoints, run on the same hardware in the same session:

| Path | TCP throughput | Comment |
|---|---|---|
| Termux loopback (CPU baseline) | 38 Gbit/s | RAM/CPU bandwidth ceiling |
| Alpine → Termux (vsock + AVF TAP) | 6.7 Gbit/s | one network hop |
| Pubuntu → Termux (LXC bridge + Alpine + AVF TAP) | 1.5 Gbit/s | adds bridge + iptables MASQUERADE |

So pubuntu has **~190 MB/s of raw TCP capacity** to Termux on the same
physical device. That's our hard upper bound — anything X-forward
achieves must fit under this.

### Test 1 — `xset q` latency

Single command, ~7 internal X round-trips:

| Path | `real` time | Comment |
|---|---|---|
| SSH X-forward | 426 ms | mostly process spawn (~350ms) + X RTTs |
| Direct X over TCP | 206 ms | 2.1× faster |

`xdpyinfo` (~50 X RTTs) took essentially the same wall time as `xset q`
in both paths, indicating per-X-roundtrip latency is sub-ms in both
cases. The 2× headline reflects the lower per-process overhead of the
direct path more than a per-RTT improvement.

### Test 2 — pure pixel throughput (`xwd` and `ffmpeg x11grab`)

Full-screen capture (1080×2251 = 9.27 MB/frame) repeated to measure
sustained bandwidth:

| Path | Sustained throughput | FPS at 9.27 MB/frame |
|---|---|---|
| SSH X-forward (`xwd × 10` loop, `> /dev/null`) | 4.5 MB/s | (xwd not framed) |
| SSH X-forward (`ffmpeg x11grab`, 10s) | 7.85 MB/s | 0.85 fps |
| **Direct X over TCP** (`ffmpeg x11grab`, 10s) | **100 MB/s** | **10.7 fps** |
| **Direct X over TCP** (`ffmpeg x11grab`, 20s) | **110 MB/s** | **11.7 fps** |
| Raw TCP ceiling (iperf3) | 190 MB/s | — |

**Direct X over TCP runs at 58% of raw TCP capacity** vs SSH X-forward
at 4%. The remaining ~45% loss from raw-TCP to direct-X is split between
Lorie's framebuffer pull + protocol packing (single-threaded), the LXC
bridge, vsock relays, and the X protocol's request/response nature.

### Test 3 — software 3D (`glxgears` in pubuntu, llvmpipe)

3D rendering happens in pubuntu's CPU (llvmpipe). Frame ships over the
display path. Two factors stack: render time + transport time.

| Path | glxgears FPS (default 300×300) | glxgears FPS (smaller window) |
|---|---|---|
| SSH X-forward | 5–9 | (not tested) |
| Direct X over TCP | 11–13 | 16–18 |

Both paths scale with pixel count (smaller window = higher FPS), so 3D
is pixel-bound either way. SSH X-forward made transport the cap below
the rendering rate; direct TCP raised transport above rendering, so we
now see the **actual llvmpipe rendering ceiling**. For higher 3D FPS,
the lever is real GPU in pubuntu (gfxstream, tasks #63/#64) — not
transport.

### Test 4 — what SSH itself costs

Two experiments to isolate SSH overhead:

**4a. Cipher swap (AES-128-GCM with hardware AES vs default ChaCha20)**:

| Cipher | Throughput | Conclusion |
|---|---|---|
| ChaCha20-Poly1305 (default) | 7.85 MB/s | baseline |
| AES-128-GCM (with Tensor G5 hw AES) | 8.04 MB/s | **+2% — within noise** |

Crypto is not the bottleneck. AES-GCM should be ~2× faster than ChaCha
on this hardware. Zero benefit observed → SSH's cost is NOT in the
encrypt/decrypt loop.

**4b. SSH compression (`-C`)**:

| Mode | Throughput |
|---|---|
| `ssh -Y` (no compression) | 7.85 MB/s |
| `ssh -CY` (zlib compression) | 6.70 MB/s — **15% slower** |

Pixmap data compresses poorly with zlib, and the per-frame
compress/decompress CPU cost adds to the already-bottlenecked
single-thread pipeline. Net negative for image data. (Compression
should help for text-heavy 2D apps where the X protocol is small
drawing commands — not tested separately, but theoretically a small
win there.)

**4c. Parallel ffmpeg (two streams simultaneously)**:

| Streams | Per-stream FPS | Total FPS |
|---|---|---|
| 1 ffmpeg | 0.85 | 0.85 |
| 2 ffmpeg in parallel | 0.70 each | 1.40 total (~1.65×) |

Per-stream drops only 18% under contention; aggregate grows 1.65×. So
some shared-resource cap exists (single-thread X server pull on
Lorie's side), but ~65% of the apparent ceiling is per-stream pipeline
cost. **For multi-app daily use, the system has more total bandwidth
than any single app can extract.**

## Why SSH X-forward is so slow — corrected attribution

We originally framed the X-forward shortfall as "MIT-SHM is unavailable
over network, so every byte gets copied 6×". Direct X over TCP
falsifies that as the dominant cause — it's also a remote X path
(client and server in different processes/namespaces, no shared
memory), and yet it hits 110 MB/s, 14× faster than SSH X-forward.

The actual dominant cost is **OpenSSH's single-thread, single-channel
data-path throughput cap**. Components:

1. **OpenSSH per-channel pipeline is one thread per direction**:
   receive packet → MAC check → decrypt → demux to channel → write to
   forwarded X socket. Pure single-CPU work, saturates a core well
   before the network is full.
2. **SSH channel windowing**: default 2 MB SSH window with lazy
   WINDOW_ADJUST messages causes brief stalls under sustained
   throughput.
3. **Many small buffer copies** in OpenSSH's data path; mainline
   OpenSSH has rejected high-performance patches (HPN-SSH) that fix
   this.
4. **Crypto cost**: ~30% of single-thread CPU time on encrypt+decrypt
   combined — confirmed minor by the cipher-swap test.

Revised cost decomposition for the SSH X-forward path:

| Factor | Estimated share of slowdown vs raw TCP |
|---|---|
| OpenSSH single-thread pipeline | **~12× — dominant** |
| Lorie + X protocol packing (single-thread) | ~1.5–2× when contended |
| LXC bridge + vsock relays | ~1.2× |
| ~~SSH encryption~~ | ~~ruled out~~ |
| ~~No MIT-SHM (originally suspected)~~ | ~~not the dominant cause~~ |

This matches the well-known limitation that **OpenSSH single-channel
throughput caps near 100 Mbit/s (~12 MB/s)** on modern ARM regardless
of cipher choice, even when the network can carry many times that.

## Recommended hybrid setup

**For daily pubuntu GUI display**: use SSH for the shell session,
**direct X over TCP for the display channel**. The two channels have
different requirements and we shouldn't conflate them.

```
[Termux:X11 listener]
  bind=10.198.187.116:6000   (AVF TAP only — not LAN, not Tailscale)
  ↑ socat bridge to /tmp/.X11-unix/X0
  ↑
[Termux] ssh -p 9923 ryno@pixel   (shell channel: SSH auth + encrypt + vsock-forward)
  ↑                                  no -Y, no SSH X-forward
[Termux] export DISPLAY=10.198.187.116:0   (X channel: direct TCP, no SSH wrapping)
  ↑
[pubuntu] app reads/writes X protocol directly over TCP
```

Setup commands (already verified, 2026-05-29):

```bash
# In Termux — one-time daemon at startup
nohup socat TCP-LISTEN:6000,fork,reuseaddr,bind=10.198.187.116 \
            UNIX-CONNECT:$PREFIX/tmp/.X11-unix/X0 \
            </dev/null >>$PREFIX/tmp/socat_x11.log 2>&1 &
disown

# When connecting to pubuntu
ssh -p 9923 ryno@pixel
# Inside pubuntu — no -Y on the ssh, we set DISPLAY ourselves:
export DISPLAY=10.198.187.116:0
xeyes &   # or any X app
```

Result: 110 MB/s display path, 2× lower latency, 14× more bandwidth
than `ssh -Y`. Real-world equivalent: previously full-screen redraws
took ~1.2 s; now ~80 ms. 1080p video in pubuntu's Firefox went from
"completely unwatchable at 0.85 fps" to "decent at 10–12 fps".

## Security analysis — what's different between the two paths

This is the load-bearing trade-off. **Direct X over TCP gives up
several SSH-provided protections** that SSH X-forward provides for
free. Understanding exactly what is lost lets you reason about whether
the trade-off is acceptable for your threat model.

### What SSH X-forward provides

- **Authenticated channel**: each SSH connection requires a key match.
  Only the user holding the right private key can open the channel.
- **Encrypted transport**: the entire X protocol stream is encrypted
  end-to-end. An attacker sniffing the wire sees only ciphertext.
- **Per-session xauth cookie**: SSH generates a fresh X11 authorisation
  cookie per session. Only clients holding that cookie can connect to
  the forwarded X server. Provides a layer of access control on top of
  network reachability.
- **Session-scoped lifetime**: the forwarded X socket exists only while
  the SSH session is open. When you close SSH, the X channel is gone.

### What direct X over TCP provides

- **Network-reachability authentication only**: anything that can open
  a TCP connection to `10.198.187.116:6000` and complete the X
  handshake can use the X server. No key, no cookie, no encryption.
- **Cleartext X protocol**: keystrokes (passwords, SSH keys typed),
  pixel data (anything visible on screen), clipboard contents (any
  pasted secret), and input events all traverse the wire as plaintext.
- **Persistent socket**: socat keeps the X port open until you kill it,
  independent of any SSH session.

### What an attacker on the X server can do

If a malicious process can open and complete a connection to a
permissive X server (`-ac` flag set, no xauth required), it can:

1. **Capture all keyboard input** (`XQueryKeymap` / passive grabs).
   Including SSH passwords / 2FA tokens typed into any terminal.
2. **Take screenshots of any window** (`XGetImage` on the root).
   Captures anything visible — including secrets displayed in apps.
3. **Read clipboard contents** (X selections). Captures pasted
   passwords / tokens.
4. **Inject keystrokes** (`XTestFakeKey`). Can type into any focused
   window — e.g., open a terminal and run commands as the logged-in user.
5. **Inject mouse events**. Click buttons, drag files, dismiss
   warnings.
6. **Spoof UI** with override-redirect windows. Show fake authentication
   prompts that capture credentials.
7. **Track cursor position** as input proxy for understanding what
   the user is doing.

This is the standard X11 trust model: connecting to an X server gives
you total interactive control over the session. The X protocol was
designed in 1987 with the assumption that all clients of a server are
trusted.

### Threat model — who can actually attack this in our setup?

The socat bridge is bound to `10.198.187.116` (Termux's AVF TAP IP).
Who has TCP reachability to that address?

| Source | Reachable? | Notes |
|---|---|---|
| Inside pubuntu (LXC) | ✅ yes | via Alpine's NAT/forwarding |
| Inside Alpine (Podroid VM) | ✅ yes | direct on AVF TAP |
| Termux (Android side, by some other Termux process) | ✅ yes | Termux binds to it |
| Other Android apps | ❌ no, in practice | most apps have no permission to bind raw sockets / no route to AVF TAP namespace |
| LAN devices (Wi-Fi) | ❌ no | no route to 10.198.187.0/24 from outside |
| Tailscale peers | ❌ no | Tailscale traffic arrives on tun0, not avf_tap_fixed |
| Internet attackers | ❌ no | NATted away |

**Effective exposure: processes inside Podroid VM only.** Since the
processes inside pubuntu are *your* code that you trust (it's *your*
dev environment), the X server is exposed to the same trust boundary
as everything else in pubuntu.

### Compared to SSH X-forward

SSH X-forward adds **defense-in-depth** but **does not change the
fundamental trust model**: any process that can read your `~/.Xauthority`
or write to the forwarded socket inside pubuntu can already do
everything an X attacker could. If pubuntu is compromised at the user
level, the attacker has both file access and process-injection
capability — X is already pwned.

So the realistic delta between the two paths is:

- **If a non-trusted process appears inside pubuntu** (e.g., a docker
  container with port forwarding to pubuntu's network, a buggy web
  service): under SSH X-forward, it'd need the xauth cookie to attack
  X; under direct TCP, it doesn't. **Modest hardening loss.**
- **If a separate Termux process is malicious**: same delta. SSH
  required cookie, direct TCP doesn't. But Termux's other apps don't
  generally include malicious processes — this is your phone.
- **For traffic in transit**: SSH encrypts; direct TCP doesn't. But
  the "wire" is `lo` / `avf_tap_fixed` on the same physical chip — no
  external observer. The encryption is providing zero practical
  protection in this topology.

### Concrete things to watch out for

If you adopt the direct-X-over-TCP hybrid, be deliberate about:

1. **Bind socat to `10.198.187.116`, NOT `0.0.0.0`**. Default behaviour
   without explicit `bind=` is to listen on every interface, which
   *would* expose port 6000 over LAN/Tailscale/etc. The recommended
   setup above pins it correctly.
2. **Don't run a Tailscale-routed forward for port 6000**. Some
   Tailscale "serve" configs could expose any local port to your
   tailnet. Keep 6000 off any such config.
3. **Stop socat when not using pubuntu GUI**, especially before sharing
   the device or installing untrusted Android apps. `pkill -f "socat
   TCP-LISTEN:6000"` to stop.
4. **Don't run untrusted X clients in pubuntu while sensitive apps are
   active in Termux:X11**. E.g., if you're going to test a random
   downloaded X11 binary, kill the i3 desktop / browser first or use a
   separate Termux:X11 instance.
5. **Be aware that pubuntu's network namespace can reach the X server**
   — any process running in any Docker container in pubuntu shares
   pubuntu's network namespace by default. If you run untrusted Docker
   images, they can talk to X. Either use `--network=none` for those
   containers, or stop socat before docker-running anything dodgy.
6. **Don't type any password into a terminal in pubuntu (or any X
   client of Termux:X11) under the assumption that it's safe from
   logging**. With X11's open-keyboard model, any X client can keylog.
   This is true even under SSH X-forward; it's just more theoretically
   constrained there.

### When SSH X-forward is the right choice anyway

Despite the speed loss, prefer SSH X-forward for:

- **Running X clients from sources you don't fully trust**. The xauth
  cookie limits which clients can attach.
- **Demo or shared-device scenarios** where someone might briefly
  have shell access to a different Termux session or Alpine.
- **Daily-use simplicity** if the SSH ~8 MB/s ceiling doesn't bother
  you — you've already proven 2D widget apps feel native at that rate.

### Default hardening (since 2026-05-29): xauth cookies

The runtime setup defaults to `USE_XAUTH=1` (cookie auth on Termux:X11,
auto-deployed to pubuntu over SSH). The `-ac` no-auth mode is opt-out
via `USE_XAUTH=0` in `~/proot.env`. Reasoning below.

For the threat we care about — a Docker container or other untrusted
code path *inside* pubuntu attaching to the X server — the protection
is xauth cookies, NOT host-based ACLs.

**Why host-based ACLs (`xhost +inet:10.0.3.20`) don't work here:**
The socat bridge connects to Termux:X11 via a *local Unix socket*.
From Lorie's perspective, every client is "a local Unix socket
connection", regardless of who originally made the TCP connection on
the socat-listening side. Lorie can't see pubuntu's IP — socat masks
it. So `xhost +inet:<ip>` rules never fire.

**Why xauth cookies do work:** Cookies are checked at the X protocol
handshake layer, *above* the socket layer. The client sends a
magic-cookie value in its connection setup; the server compares it
against the cookies in its auth database. This works identically over
Unix sockets, TCP, vsock, anything.

**The Docker container threat specifically:**

By default, a Docker container in pubuntu shares pubuntu's network
namespace (or has its own bridged network — either way reaches
`10.198.187.116:6000`). But the container has its own filesystem,
isolated from pubuntu's `~/.Xauthority` unless you explicitly bind-mount
it. So:

| Setup | Container reaches X port? | Container has cookie? | X access? |
|---|---|---|---|
| Today (`-ac`, no auth) | yes | n/a (no auth needed) | ⚠️ yes — exposed |
| Cookies, don't mount `~/.Xauthority` | yes | ❌ no | ✅ **rejected at handshake** |
| Cookies, you `-v ~/.Xauthority:...:ro` | yes | ✅ yes (you opted in) | ✅ granted (per-container opt-in) |

Net effect: cookies make X access **opt-in per Docker container**.
Default-deny instead of default-allow.

**Setup, when you want this hardening:**

```bash
# In Termux — one-time, store cookie in $HOME/.Xauthority
COOKIE=$(openssl rand -hex 16)
touch ~/.Xauthority && chmod 600 ~/.Xauthority
xauth -f ~/.Xauthority add :0                MIT-MAGIC-COOKIE-1 $COOKIE
xauth -f ~/.Xauthority add wild              MIT-MAGIC-COOKIE-1 $COOKIE

# Restart Termux:X11 WITHOUT -ac, WITH -auth so it consults the cookie file
pkill -f "termux-x11 :"
nohup termux-x11 :0 -auth ~/.Xauthority \
    >>$PREFIX/tmp/termux-x11.log 2>&1 &

# Securely transfer the cookie to pubuntu (over SSH, which we've got)
# Run this from Termux:
scp -P 9923 ~/.Xauthority ryno@localhost:~/.Xauthority

# In pubuntu, the X11 client library finds ~/.Xauthority automatically.
# To verify:
DISPLAY=10.198.187.116:0 xset q   # should succeed
```

Cost: ~5 commands. Benefit: untrusted Docker containers (or other
non-trusted code inside pubuntu) can't talk to X without you
explicitly granting them the cookie file via bind-mount.

For Docker specifically, the opt-in pattern looks like:

```bash
# Container that NEEDS X (e.g., a GUI dev env)
docker run --rm -it \
    -e DISPLAY=10.198.187.116:0 \
    -v ~/.Xauthority:/root/.Xauthority:ro \
    -e XAUTHORITY=/root/.Xauthority \
    myapp

# Container that DOESN'T need X — just omit the -v and -e DISPLAY.
# Even if it has network reach to 10.198.187.116:6000, it can't authenticate.
docker run --rm -it untrusted-image
```

This is genuine defense-in-depth and worth setting up if you run any
non-trivial Docker workloads in pubuntu.

## Wider architectural impact

The X-forward investigation closes the loop on several earlier
hypotheses:

- **Confirmed**: 2D pubuntu GUI apps over X-forward are daily-viable.
  At 110 MB/s direct, comfortably so. At 8 MB/s SSH, also fine for
  typical text/widget workloads (the per-frame bandwidth need is well
  under 8 MB/s for those).
- **Refined**: 3D in pubuntu is bottlenecked by **llvmpipe rendering**,
  not transport. Confirmed by glxgears improving only ~2× with the
  transport upgrade — the remaining ceiling is CPU rendering. gfxstream
  (#63/#64) is the right next investment if pubuntu 3D matters.
- **Refined**: video from pubuntu Firefox is now feasible at moderate
  resolution/quality via direct-X. Previously we said "unwatchable
  except via gfxstream + VNC"; that was specifically for the SSH path.
- **Ruled out**: virgl-over-vsock (Path D) doesn't gain anything. We
  proved earlier its presentation half is structurally blocked; we
  also now know transport wasn't where the problem was.
- **Ruled out**: HPN-SSH style patching for our particular path. Would
  unlock the OpenSSH cap but is a fork-and-maintain commitment;
  direct-X-over-TCP solves the same problem with a 6-line socat
  invocation.

## Sequence updates

To the existing sequencing checklist, add:

7. **Bake `socat TCP-LISTEN:6000` into `~/start-x11.sh`** so the direct-X
   bridge is available by default when Termux:X11 is up. Bind to
   `10.198.187.116` only.
8. **Set `export DISPLAY=10.198.187.116:0`** in `pubuntu`'s
   `~/.bashrc` so every SSH session lands with the direct-X DISPLAY
   already set. Or use SSH's `SendEnv DISPLAY` from Termux.
9. **Document the security-vs-speed trade-off** in the project README
   so future-you (or anyone reading) knows why the direct-X path
   exists.
