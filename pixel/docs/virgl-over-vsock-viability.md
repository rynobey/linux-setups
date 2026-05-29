# virgl-over-vsock — Path D viability findings

**Status:** partial viability test, 2026-05-28
**Parent doc:** [`pixel-desktop-architecture.md`](pixel-desktop-architecture.md)

Goal: verify whether pubuntu-side Mesa apps can be hardware-accelerated by
serialising GL commands across the AVF vsock channel to a `virglrenderer`
server running in Termux, which renders on the PowerVR GPU via Android EGL.

## Headline result

**Path D compute half proven end-to-end on 2026-05-28.** pubuntu Mesa
client successfully reached the Termux-side virgl server over the AVF
NAT (no vsock required — plain TCP on `10.198.187.116:55555` was
reachable from pubuntu) and rendered through PowerVR:

```
$ ssh -Y ryno@10.0.3.120
pubuntu$ GALLIUM_DRIVER=virpipe LIBGL_ALWAYS_SOFTWARE=0 \
         VTEST_SOCKET_NAME=/tmp/virgl-bridge.sock glxinfo | head -5
OpenGL vendor   : Mesa
OpenGL renderer : virgl (PowerVR D-Series DXT-48-1536)
OpenGL version  : 2.1 Mesa 25.2.8-0ubuntu0.24.04.1
direct rendering: Yes
```

Termux side: virgl_test_server_android (Bionic) + socat TCP→Unix bridge.
Pubuntu side: socat Unix→TCP forward + Mesa virpipe. Two socats and
one env var. No virglrenderer patches, no kernel changes, no vsock
plumbing. The fact that AVF NAT routes pubuntu → Android-host TCP made
the bridge architecturally trivial.

**Presentation half — structurally blocked, tested 2026-05-28.**

`glxgears` failed end-to-end. Errors from pubuntu side:

```
No headers available
failed to get fd
```

repeating on each frame attempt. Window briefly appeared then closed
on glxgears exit. Same error with `LIBGL_DRI3_DISABLE=1`,
`MESA_NO_DRI3=1`, and `GBM_BACKEND=null` — DRI3 isn't where the
failure happens.

**Root cause:** virgl-test protocol uses `SCM_RIGHTS` over Unix
sockets to pass file descriptors for shared GPU buffers (textures,
vertex buffers, framebuffers — every allocated resource). TCP and
vsock cannot carry SCM_RIGHTS payloads — they're kernel objects, not
bytes. socat faithfully relays the byte stream but the bytes alone
are incomplete: the receiving end gets the protocol headers without
the fd attachments they reference. Hence "no headers available" /
"failed to get fd" *before* anything reaches the X presentation
layer. DRI3-disable cannot help — virgl can't create the underlying
resources in the first place.

**Implication:** the virgl-test protocol is fundamentally
local-IPC-bound. Tunneling it across a VM boundary needs either:

1. Patching virgl protocol to use AHB/dmabuf handle *names* in
   place of fds, on both Mesa client and virglrenderer server. ~weeks
   of C work, hard to upstream.
2. A custom virgl-aware proxy that intercepts resource-allocation
   messages, allocates buffers in both address spaces, and translates
   handles. Architecturally clean but a real project.
3. Switch entirely to **gfxstream**, which is purpose-built for
   VM-to-host GPU bridging on Android. The fd-passing happens
   host-side only, never crossing the VM boundary. This is what
   tasks #63 / #64 cover and was the right path all along for
   accelerating pubuntu.

**Verdict for Path D as a daily-use architecture: blocked.** Don't
invest further in the socat bridge. The compute-only path remains
proven (glxinfo confirms hardware GL contexts can be created remotely)
which is interesting for niche compute-only workloads, but isn't a
practical desktop architecture for pubuntu apps.

This actually clarifies the two-pronged plan: keep Path A
(Termux-native + virgl, proven win) for daily; invest in Path C
(gfxstream in pubuntu) for pubuntu GPU when it matters; pair
gfxstream with VNC or waypipe (which ship rendered frames over bytes,
no fd-passing) for the display side.

## What was tested

### 1. Termux-native virgl path — ✅ PROVEN (with caveat: read per-scene FPS, not the score)

Baseline `glxinfo` before any virgl:

```
$ DISPLAY=:0 glxinfo | grep "OpenGL renderer"
OpenGL renderer string: llvmpipe (LLVM 21.1.8, 128 bits)
```

After starting the virgl test server and exporting the env vars:

```
$ virgl_test_server_android --socket-path $PREFIX/tmp/virgl_test.sock &
$ export DISPLAY=:0 \
         GALLIUM_DRIVER=virpipe \
         LIBGL_ALWAYS_SOFTWARE=0 \
         VTEST_SOCKET_NAME=$PREFIX/tmp/virgl_test.sock
$ glxinfo | grep "OpenGL renderer"
OpenGL renderer string: virgl (PowerVR D-Series DXT-48-1536)
```

This confirms three things in one shot:

1. `virglrenderer-android` is wired correctly to the Android EGL stack and
   actually loads the PowerVR vendor GLES driver.
2. Mesa's `virpipe` driver speaks the same protocol as
   `virgl_test_server_android` (no ABI skew).
3. Termux-native clients can be HW-accelerated **today**, with zero
   additional packaging work.

The Mesa `virgl` device exposes `OpenGL 2.1 Mesa 26.0.4` — virgl's
GL feature ceiling. That's enough for Firefox compositor (WebRender),
xfce4, mousepad, most desktop apps. It's not enough for modern Vulkan-
via-Zink or GL 4.6 niche cases.

**glmark2 score caveat (measured 2026-05-28):**

The headline glmark2 score actually came out *lower* with virgl (77)
than with llvmpipe (87) at 800×600. But the score is the arithmetic mean
across scenes and obscures the actual behaviour. Per-scene picture:

| Scene | llvmpipe FPS | virgl FPS | Δ |
|---|---|---|---|
| `refract` (heavy frag shader) | 6 | 45 | virgl 7.5× |
| `loop fragment-uniform=true` | 68 | 93 | virgl 1.4× |
| trivial `conditionals/function/loop` scenes | 90–104 | 83–99 | llvmpipe wins by 5–20% |

Two regimes:

- **Heavy shaders (the ones that visibly stutter):** virgl wins big.
  `refract` is the test case that user reported as "I could see lag in
  llvmpipe but not in virgl" — confirmed by the 7.5× FPS jump.
- **Trivial scenes:** llvmpipe slightly faster because virgl pays
  per-call latency to marshal GL commands over the Unix socket.

Implication: **virgl raises the FPS *floor* but slightly lowers the
ceiling on trivial work.** For real apps (browsers, video,
compositor-heavy desktops) the floor dominates perceived smoothness —
the moments that visibly lag matter more than the average. So virgl is
the right default even when the glmark2 score doesn't say so.

If you want to confirm with a more realistic benchmark, compare Firefox
playing a video frame-by-frame, or scroll a heavy webpage — those hit
the `refract`-like regime, not the trivial-loop regime.

**Fullscreen (2248×974) glmark2 run (also 2026-05-28):**

Same pattern, larger spread. 19 scenes, picked headline rows:

| Scene | llvmpipe | virgl | Δ | Category |
|---|---|---|---|---|
| terrain | 1 | 21 | virgl **21×** | heavy textured 3D |
| refract | 4 | 25 | virgl 6.3× | heavy fragment shader |
| desktop blur | 6 | 33 | virgl 5.5× | compositor |
| desktop shadow | 10 | 38 | virgl 3.8× | compositor |
| jellyfish | 14 | 33 | virgl 2.4× | animated 3D |
| pulsar | 58 | 36 | llvm 1.6× | trivial textured quads |
| conditionals (×3) | 46–52 | 35 | llvm 1.3–1.5× | synthetic shader |
| function/loop (×5) | 33–49 | 35–37 | llvm slight | synthetic shader |

Summary stats:

| | llvmpipe | virgl |
|---|---|---|
| **Minimum FPS** | **1** | **21** |
| Maximum FPS | 58 | 38 |
| Range | 57 | 17 |
| Arithmetic mean (≈glmark2 score) | 39 | 33 |
| **Geometric mean** | ~23 | ~32 |

The score still favours llvmpipe at 39 vs 33, but every other meaningful
summary stat — geometric mean, minimum FPS, consistency — favours
virgl. The 21× minimum-FPS gap (terrain: 1 vs 21) means llvmpipe is
the difference between "responsive" and "frozen" on real content,
while virgl stays in a consistent 21–38 FPS band across every scene.

Category-wise interpretation:

- virgl decisively wins every **real-world-resembling** scene
  (compositor effects, heavy textured 3D, shaded scenes).
- llvmpipe wins **synthetic shader micro-benchmarks** where there's
  almost no per-pixel work — there virgl's per-call protocol overhead
  exceeds the actual rendering cost.

The "score" being a flat arithmetic mean is the artefact: glmark2 has
many trivial shader scenes and few heavy ones, so the mean is dominated
by the trivial regime and obscures the catastrophic minima of the
heavy regime. Geometric mean and minimum FPS are the honest summaries.

**Conclusion for the architecture:** keep virgl on as the default. Real
apps live in the regime where virgl wins, not the regime where llvmpipe
"wins by score". Confirmed for daily UX on Pixel 10 + Termux:X11.

**Implication for the architecture:** Path A of
[`pixel-desktop-architecture.md`](pixel-desktop-architecture.md) is
upgraded from "expected to work" to "confirmed working". Bake it into the
Termux-native desktop start-up.

### 2. Socket-bridge transparency — ✅ PROVEN

The virgl test server only supports `--socket-path` (Unix) — no native TCP
or vsock listener. So any cross-VM use needs a bridge. Tested whether a
straightforward socat Unix → TCP → Unix chain is transparent to the virgl
protocol:

```
client → UNIX-CONNECT(bridged.sock)
       → socat UNIX-LISTEN:bridged.sock,fork TCP-CONNECT:127.0.0.1:55555
       → socat TCP-LISTEN:55555,fork  UNIX-CONNECT:virgl_test.sock
       → virgl_test_server_android
```

Re-ran `glxinfo` with `VTEST_SOCKET_NAME=$PREFIX/tmp/virgl_via_bridge.sock`:

```
OpenGL renderer string: virgl (PowerVR D-Series DXT-48-1536)
```

Result survives the bridge unchanged. socat is fully transparent to the
virgl wire protocol. This is the bridge mechanism a vsock-based Path D
would use — just swap TCP for vsock at one or both hops.

### 3. socat vsock support — ✅ AVAILABLE

```
$ socat -hh | grep -i vsock
      VSOCK-CONNECT:<cid>:<port>
      VSOCK-LISTEN:<port>
```

Termux's `socat 1.8.1.1` supports both ends of a vsock bridge. No build
work needed for the transport.

## What's still unknown / untested

### A. Can Termux hold a vsock listener reachable from pubuntu?

In AVF, vsock listeners on the *host* side are usually bound by the app
that owns the VM (Podroid). Whether a *different* Android app (Termux)
can bind a vsock listener on the same CID that pubuntu can connect to is
unverified.

**Two plausible answers:**

- **Yes** — Android's vsock is process-agnostic; any process with
  permission can bind. In that case the architecture is simply:
  ```
  pubuntu socat:  UNIX-LISTEN:/tmp/.virgl_test  VSOCK-CONNECT:2:55555
  termux socat:   VSOCK-LISTEN:55555            UNIX-CONNECT:.../virgl_test.sock
  ```
  Test: run a `VSOCK-LISTEN` socat in Termux while Podroid is up and try
  to `VSOCK-CONNECT` from pubuntu.
- **No** — vsock is namespaced to the app that owns the VM. In that case
  Podroid itself needs to host the vsock listener and forward inside
  Android to Termux (over loopback TCP or an abstract Unix socket).
  Means a small Podroid-side service addition.

### B. Does pubuntu's AVF NAT route to Termux on Android TCP loopback?

If pubuntu's network NAT bridges out to the Android host network, pubuntu
should be able to reach `<android-host-ip>:<termux-port>` over plain TCP.
In that case **vsock is unnecessary** — the bridge collapses to:

```
pubuntu Mesa client →  UNIX-CONNECT(/tmp/.virgl_test)
                    →  socat UNIX-LISTEN:/tmp/.virgl_test TCP-CONNECT:<gw>:55555
                    →  android TCP loopback
                    →  socat TCP-LISTEN:55555 UNIX-CONNECT:virgl_test.sock
                    →  virgl_test_server_android
```

Simpler, no Podroid service work needed. Test once pubuntu is back up:

```
pubuntu$  ip route get $(curl -s ifconfig.me)   # find host IP
pubuntu$  nc -zv <android-host-ip> <termux-port>
```

### C. AHardwareBuffer interop

Even if the virgl call stream goes through to PowerVR and renders, the
rendered framebuffer needs to be **presented** somewhere. In the Termux
case (#1 above) the buffer lives in EGL's drawing surface and is
implicitly presented via the X server's Lorie compositor when the client
sends an `XPresentPixmap` (DRI3) or `glXSwapBuffers`.

In the cross-VM case, the buffer would be rendered on Termux's side but
the client's X window is also "on" Termux:X11 (via SSH X-forward). So
the same Lorie path should work — it's still receiving a local AHB from a
local virgl-rendered context, just one whose draw commands originated on
another machine. This is plausible but not proven.

A likely subtle bug: if the X11 protocol channel and the virgl GL channel
take different paths (X over SSH; GL over vsock), the X server might not
have a way to wait for / synchronize GL completion with X events. May
need a fence/sync extension to negotiate. Worth a smoke test before
committing to the design.

## Pending tests (need Podroid + pubuntu running)

1. Bring up Podroid (task #71). Verify pubuntu reaches Android host on
   TCP (test B above).
2. If TCP works: bypass vsock entirely. Just run the socat pair with TCP
   on both sides. Validate `glxinfo` from pubuntu returns
   `virgl (PowerVR …)`.
3. If TCP doesn't work: try vsock listener in Termux. Validate `nc`-style
   reachability before the full GL path.
4. If Termux vsock listener isn't reachable: add a small forwarder in
   Podroid (vsock-listener → loopback-TCP).
5. Once a `glxinfo` round-trip works: smoke-test `glxgears`,
   `glmark2-es2`, and Firefox under X-forward.
6. Synchronisation/presentation testing — make sure GL frames present in
   X windows without tearing / dropped frames.

## Sample wire-up (Termux start-up shim)

For the local-Termux case (#1, ready to use today), this script fragment
belongs in the Termux-native desktop start-up:

```bash
# start virgl rendering server (Path A)
VIRGL_SOCK="$PREFIX/tmp/virgl_test.sock"
mkdir -p "$(dirname $VIRGL_SOCK)"
if ! pgrep -x virgl_test_server_android >/dev/null; then
    nohup virgl_test_server_android --socket-path "$VIRGL_SOCK" \
        >>"$PREFIX/tmp/virgl_test.log" 2>&1 &
fi

# expose env so clients pick up virgl by default
export GALLIUM_DRIVER=virpipe
export LIBGL_ALWAYS_SOFTWARE=0
export VTEST_SOCKET_NAME=$VIRGL_SOCK
```

For Path D, add the matching socat bridge once pubuntu is up — flesh out
after the tests above.

## Summary

| Component | State |
|---|---|
| Termux virgl server reaches PowerVR | ✅ proven (`OpenGL renderer: virgl (PowerVR D-Series DXT-48-1536)`) |
| Mesa client speaks virgl protocol over Unix socket | ✅ proven |
| socat Unix↔TCP↔Unix bridge transparent to virgl | ✅ proven |
| socat speaks vsock (VSOCK-LISTEN / VSOCK-CONNECT) | ✅ available |
| Pubuntu reaches Termux on Android-host TCP (plain TCP option) | ❓ untested (Podroid down) |
| Pubuntu reaches Termux-bound vsock listener | ❓ untested |
| AHB / presentation in X11 with cross-machine GL | ❓ unverified, plausible |
| Sync between SSH-X channel and virgl channel | ❓ design risk, needs smoke test |
| Path A (Termux-native virgl) | ✅ ready to bake in |
| Path D (virgl-over-vsock or TCP) | viable in principle; ~1 day of work once Podroid is up |
