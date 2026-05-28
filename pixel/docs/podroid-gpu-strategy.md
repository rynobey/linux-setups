# Pixel 10 — Podroid, GPU & Display Strategy

_Last updated: 2026-05-27. Captures the full investigation: the Podroid dev-VM
work, the GPU de-risk, the display reality, the Winlator/proot alternative, and
a concrete plan to extend Vortek for the Pixel 10's PowerVR GPU._

---

## 0. Goal

Turn the Pixel 10 into a capable **Linux dev environment** (Docker, editors,
toolchains) with an **accelerated desktop**, and explore how far GPU / light
gaming can go. The bar is "a workable no-dGPU-laptop desktop," not a gaming rig.

---

## 1. The hardware

| | |
|---|---|
| SoC | Google **Tensor G5** (TSMC 3nm) |
| GPU | **Imagination PowerVR DXT-48-1536** (D-Series), ~1.6 TFLOPS FP32, Vulkan 1.4, **no RT enabled**. Google dropped Mali for PowerVR. |
| CPU | Geekbench 6 ≈ **2,285 single / 6,191 multi** → ~**base-M1 / mid-ultrabook** class. Single-thread ≈ M1; multi ≈ 75% of M1. |
| Frame of reference | CPU ≈ base-M1 MacBook Air. GPU ≈ Steam Deck / entry Iris-Xe **on paper** (~1.6 TFLOPS), but **driver-limited well below that in practice**. |

**Verdict:** for a desktop/dev box, CPU + GPU are comfortably sufficient. For
gaming, it's a poor target — **driver ecosystem**, not silicon, is the limiter.

---

## 2. The driver reality (the crux of everything)

- **No Turnip** (that's Adreno-only). **Mesa's open PowerVR (`PVR`) driver** is
  Rogue-only (IMG AXE/BXS) at Vulkan 1.0/1.2 — the **DXT D-Series is unsupported**.
  So the **only usable Vulkan on this GPU is the closed Imagination vendor driver**
  (`/vendor/lib64/hw/vulkan.powervr.so`).
- Device currently reports **Vulkan 1.4.303**, driver `25.1@6794074` (the improved
  DDK 25.1 RTM2 / `v1.634` that shipped in Android 16 QPR3 ~March 2026). The launch
  driver (v24.3 / v1.602) lacked Vulkan 1.4.
- **Underperformance is two gaps:** the "worse than it should be" gap (e.g. losing
  to the older Mali Pixel 9 in emulation) is **driver immaturity — recoverable**;
  the "not a flagship" gap (~2× behind Snapdragon 8 Elite / Adreno 840) is
  **hardware — a deliberately modest GPU config, fixed for this gen**.
- **Trajectory:** Imagination keeps shipping DDKs (25.2 exists, adds
  `VK_KHR_cooperative_matrix`); the Pixel lags by ~half a year while Google
  integrates them. **Watch the driver version, not the Android version.**
- **Thermals** are *not* the main problem — stress stability is actually good
  (~95% WildLife Extreme); peak power is just modest.

---

## 3. Podroid — the dev VM (current setup)

AVF/pKVM VM: **Alpine host-guest + `pubuntu` (Ubuntu) LXC + Docker**. This is the
dev box (Hardhat/solc compiles, etc.). Fork: `~/projects/rynobey/Podroid` (real
upstream is `github.com/ExTV/Podroid`).

Key findings from this work:

- **VM kills — two mechanisms:** (1) **LMK under memory pressure** (the VM's RAM
  is a memfd; footprint ratchets to the high-water mark); (2) **Doze** evicting
  the non-battery-exempt cached app overnight (also dropped adbd). Fix for (2):
  `dumpsys deviceidle whitelist +com.excp.podroid.debug`.
- **Ballooning de-risk:** the host enabled `useAutoMemoryBalloon` +
  `--balloon-page-reporting`, but the **guest kernel had no `VIRTIO_BALLOON`
  driver** → all of it was inert (footprint never reclaimed). Added
  `VIRTIO_BALLOON` + `MEMORY_BALLOON` + `PAGE_REPORTING` to the guest kernel.
- **SMP corruption (the hard bug):** with the balloon driver active **and
  multiple vCPUs**, free-page-reporting raced → guest memory corruption →
  `ext4 bad block bitmap checksum` → `podroid-vsock`/`podroid-network` cascade
  failures / boot reboot. 1 vCPU was stable. **Fix:** keep the balloon
  (inflate/deflate, the LMK-prevention value) but **disable free-page-reporting**
  by removing `VIRTIO_BALLOON_F_REPORTING` from the driver's feature table via a
  build-time `sed` (kept `PAGE_REPORTING=y` so `virtballoon_probe` still links —
  it hard-references `page_reporting_register`).
- **`make modules` is needed:** an attempt to drop it (everything is `=y`) broke
  **early init** — the stub `/lib/modules` was incomplete and `depmod`/`modprobe`
  rebooted the VM before hvc0 came up. **Reverted** to the full `modules_install`
  + prune. (The optimization could be redone by generating *complete* module
  metadata, but it's not worth it.)
- **CI keystore:** the GitHub Actions keystore cache was unreliable (branch
  scope/eviction) → in-place upgrades failed. **Committed a fixed debug keystore**
  (`app/podroid-debug.keystore`) + `debugFixed` signingConfig. Now **in-place
  `adb install -r` works across all branches** that share the commit. (Upstream
  merges must keep the keystore.)
- **CI build:** native-output `actions/cache` keys on the **whole Dockerfile**, so
  any kernel tweak rebuilds the slow emulated rootfs. **Planned improvement:** split
  into per-stage caches — rootfs (its own `Dockerfile.rootfs`) keyed on
  `build-rootfs/**`, qemu on the `.c` files, kernel on `Dockerfile` +
  `podroid_kernel.config`. (Docker *layer* ordering won't help — ephemeral runners,
  no buildx gha cache.)

---

## 4. GPU de-risk — **PASSED**

The big unknown (could a non-platform app attach a GPU at all?) is resolved:

- `AvfReflect.tryEnableGpu` builds a **gfxstream `GpuConfig`** (`backend=gfxstream`,
  `contextTypes=[gfxstream-vulkan]`, renderer flags) → **`virtualizationservice`
  accepts it** (privilege gate passes) → crosvm launches with
  `--gpu=backend=gfxstream,context-types=gfxstream-vulkan,...` → the guest's
  `DRM_VIRTIO_GPU` driver binds → **`/dev/dri/card0` + `renderD128` appear**.
  Confirmed on the device (capset id 3 = gfxstream-vulkan).
- **Enable** via `podroid.gpu=1` in Settings → "kernel extra cmdline" (the
  `gpuEnabled` field is never set from UI; the marker is the switch). No GPU
  device is attached without it.
- **GpuConfig tuning:** added `setRendererUseGlx(true)` (X11 GL apps). The
  `GET_CAPSET` error is **benign** (driver probing unprovided capsets). The
  **47/142 Vulkan-extension limit is a host gfxstream cap** — no GpuConfig setter
  raises it (and the AVF 17-QPR1 Terminal hits the same 47/142).

---

## 5. Display reality — native scanout is **platform-locked**

The Stock Terminal shows its desktop via a native `SurfaceView`. We traced the
binding: `IVirtualizationServiceInternal.waitDisplayService()` →
**`android.crosvm.ICrosvmAndroidDisplayService.setSurface(surface, isForCursor)`**
— **system-internal AIDLs**, SELinux-gated to platform components. The **public
`VirtualMachine` API has no Surface-attach method** (confirmed). HiddenApiBypass
only exempts public-framework `@hide`/`@SystemApi` methods — it does **not** let a
regular app bind system-server-internal services.

**→ A non-platform app cannot do the native scanout view.** Podroid's display
**stays VNC** (`Xvnc` in the guest → built-in `VncClient`). **GPU rendering still
accelerates** (gfxstream renders on the GPU; apps present to Xvnc; the framebuffer
streams via VNC). Only the *display transport* is software. Input on the VNC path
is via RFB (the framework `sendKeyEvent`/`sendMouseEvent` methods pair with the
*native* display, so they're unused here).

**Current Podroid GPU architecture (settled):**
```
guest app → gfxstream Vulkan driver (renders on GPU) → presents to X11 window
          → Xvnc captures framebuffer → RFB/VNC → Podroid VncClient (the view)
```

---

## 6. Guest GPU userspace driver (for Podroid)

To actually *render* with the GPU device, pubuntu needs a **gfxstream Vulkan
guest driver** — upstreamed into Mesa 24.3+ (current 26.1). Build it from source:
- `pixel/lxc/helper/build-gfxstream-mesa.sh` — Mesa with `-Dvulkan-drivers=gfxstream`
  + Zink (GL-on-Vulkan). Sets `VK_ICD_FILENAMES`; validate with `vulkaninfo`/`vkcube`.
- `/dev/dri` into the LXC: `pixel/podroid/helper/enable-gpu-mount.sh` (idempotent,
  for an existing container) + the entry added to `create-lxc.sh`.

Expectation: usable but limited (~47/142 extensions; some buggy; occasionally
slower than software). Fine for a desktop.

---

## 7. The Winlator / proot alternative (GPU + gaming)

Two ways to reach the GPU from Linux:

| Path | How it reaches the GPU | On Adreno | On **PowerVR (us)** |
|---|---|---|---|
| **gfxstream (VM)** — Podroid, Stock Terminal | virtio-gpu → gfxstream → host vendor driver | works | **works** (47/142, the only working path) |
| **proot, native Mesa** — DroidDesk | in-container Mesa driver | Turnip (great) | **software** (no Turnip, Mesa-PVR can't do DXT) |
| **proot + Vortek** — Winlator | Bionic server loads the **vendor** driver, glibc client forwards over IPC | great | **unproven** (this is the opportunity) |

Key insight: **on PowerVR, gfxstream is the *only* working GPU path today**,
because the vendor driver is Android-only and gfxstream is the bridge that lets a
Linux guest reach it. proot has no virtio-gpu and can't load the Android driver —
so proot = software, **unless** a Vortek-style bridge is made to work.

- **DroidDesk** (`github.com/orailnoor/DroidDesk`): proot + Termux-X11 desktop,
  "native performance," runs VS Code/Blender/etc. **Validates the proot+native-display
  architecture** (its Termux-X11 display beats VNC), but its GPU is **Adreno-Turnip
  only → software on PowerVR**. No real Docker (proot limitation).
- **Vortek** (`github.com/brunodev85/vortek`, open source): a **userspace
  Vulkan-forwarding bridge** — glibc client (Wine/box64) → **IPC ring buffer** →
  **Bionic server loads the system Vulkan driver** → executes. No VM. It exists to
  solve (a) the Bionic↔glibc split and (b) **driver gaps via per-driver workarounds**
  (BCn decompression, Mali `gl_ClipDistance` SPIR-V stripping…). **Mali/Adreno-tuned;
  PowerVR DXT unproven.** This is the thing to extend.

**If Vortek-on-PowerVR works**, the proot path could **exceed** both Podroid and
the Stock Terminal: native vendor driver (potentially >47 extensions), no
gfxstream serialization, no VM boundary, and native Termux-X11 display (no VNC) —
all gated by the DXT driver's own quality.

---

## 8. Decision matrix

| Goal | Use | Notes |
|---|---|---|
| **Dev box** (Docker, isolation, toolchains) | **Podroid (VM)** | Real Docker; GPU via gfxstream; VNC display. The justified default. |
| **Light desktop, smoothest display** | proot/DroidDesk | Native CPU + native display; **software GPU** on PowerVR; no real Docker. |
| **GPU / gaming, best case** | **Vortek-PowerVR (R&D)** | proot + native driver *if* extended. Parallel to Podroid (proot ≠ VM → can run alongside, no AVF one-VM conflict). |

---

## 9. PLAN (b) — Extend Vortek for the PowerVR DXT

**Objective:** get Vortek's forwarding bridge working against `vulkan.powervr.so`
so a proot/Winlator stack gets *native-driver* GPU on the Pixel 10.

**Architecture to work with:** glibc client → IPC ring buffer → **Bionic server
loads the system Vulkan ICD** → vendor driver. The server is GPU-agnostic by
design; the gap is **PowerVR-DXT-specific workarounds** (Vortek's existing ones
target Mali/Adreno).

**Steps:**
1. **Baseline test (= section 10 / step a):** install Winlator 11.0, select the
   Vortek renderer, observe how far it gets on PowerVR — does it enumerate the
   DXT device, how many extensions, does it render/glitch/crash? This sizes the gap
   before any coding.
2. **Build Vortek from source** — clone `github.com/brunodev85/vortek`; build the
   Bionic **renderer server** + the glibc **`libvulkan_vortek.so` ICD**. Confirm a
   clean build.
3. **Point the server at the PowerVR driver** — confirm the Bionic server loads
   `vulkan.powervr.so`, enumerates the DXT device, and lists its extension set.
   Compare that count to gfxstream's 47 (this is the "do we beat gfxstream?" check).
4. **Capture the DXT driver's gaps** — run DXVK/Vulkan workloads with **Vulkan
   validation** on; log what the DXT driver rejects/lacks (missing extensions,
   unsupported formats e.g. BCn, SPIR-V capabilities). Vortek's Mali/Adreno
   workarounds are the template, not the answer.
5. **Author PowerVR-DXT workarounds** — follow the Vortek workaround pattern
   (Vortek Internals Pt.2): BCn texture decompression if absent, SPIR-V transforms
   for missing caps, format emulation. Iterate per failing title.
6. **Validate + measure** — `vkcube`, then DXVK games; compare extensions / FPS /
   latency vs Podroid-gfxstream.
7. **Integrate** — into Winlator (gaming) and/or DroidDesk's proot stack (a
   GPU-accelerated proot desktop).

**Resources:** `brunodev85/vortek` (source) · Vortek Internals
[Pt.1](https://leegao.github.io/winlator-internals/2025/06/01/Vortek1.html) /
[Pt.2](https://leegao.github.io/winlator-internals/2025/06/02/Vortek2.html)
(architecture + workaround patterns) · `leegao/vortek-deep-dive` (RE) ·
`leegao/vortek-patcher` (example community fix).

**Honest framing:** real graphics-compat engineering (Vulkan validation debugging
+ workaround authoring), **gated by the DXT driver's own quality**, uncertain
payoff — but tractable, open source, and the community already extends Vortek this
way. It's a **parallel R&D bet for the GPU/gaming goal**, not a replacement for
Podroid.

---

## 10. STEP (a) — first, cheap, no-code test (DO THIS FIRST)

> **✓ WORKING BASELINE (2026-05-27) — Winlator 11.0 + Vortek + DXVK 2.4.1 on PowerVR
> DXT.** Real DX9/DX11 content (Unigine Heaven) renders with **correct geometry** (with
> tessellation OFF — tessellation ON hangs, see below) on the native PowerVR GPU. Vulkan device exposes **137 extensions** (vs gfxstream's 47).
> The earlier scrambled-geometry "garbage" was a **DXVK-version incompatibility** —
> fixed by pinning **DXVK 2.4.1** (newer DXVK breaks geometry; 2.4.1 is the known-good).
> Only remaining artifact: **shadows render too dark/black** (cosmetic, fragment-stage —
> see below). **No custom Vortek/BCn dev was needed** — the whole (b) plan turned out
> unnecessary for basic function. GameNative v0.9.2 (PowerVR-tuned, Steam/Epic/GOG) is
> an optional alternative front-end.

See section 11 / the handoff. Install **Winlator 11.0** (or the bionic-vortek
build), select **Vortek** as the graphics driver, and observe whether it sees the
PowerVR driver + renders. This decides whether (b) is worth the effort.

**Result — 2026-05-27 (enumeration de-risk PASSED):** Winlator 11.0 + Vortek;
GPU Caps Viewer (Vulkan tab) reports a **PowerVR** device inside the proot/Wine
environment. → Vortek's Bionic server **loads `vulkan.powervr.so` and forwards the
real device to the glibc/Wine side**. The Bionic↔glibc Vulkan bridge — the crux of
plan (b) — **works on PowerVR DXT unmodified**.

**Extension count (decisive):** Vortek exposes **137 device extensions** (13
instance) — versus **gfxstream's 47**. That's ~the **full native PowerVR set**
(~142) forwarded through, **~3× the VM path**. Vortek is **not filtering** the
driver's capability the way gfxstream does → the proot/Vortek route can plausibly
**exceed Podroid+gfxstream on GPU feature surface**.

**Rendering confirmed (core de-risk COMPLETE):** a D3D test renders with the DXVK
HUD `devinfo` line reporting **PowerVR** as the device (~2000 FPS on a light scene
— far above any software/llvmpipe path). So DXVK→Vortek→native-driver works
end-to-end on PowerVR DXT: it **enumerates the full extension set AND renders on
the real GPU**. Everything plan (b) fundamentally depended on is proven.

**What's left is *sizing*, not de-risking:** run a **heavy, real scene** to see how
many DXT-specific artifacts/crashes appear under load. That = the body of plan (b)
(per-title workarounds), not a go/no-go gate.

**Sizing result — 2026-05-27 (Unigine Heaven, official Winlator 11.0 + Vortek):**
renders **on PowerVR with a real framerate**, but the image is **heavily corrupted
("garbage")**. Pipeline works; output is wrong under load. **Prime suspect: BC/DXT
texture compression** — desktop DX games ship BC1–BC7 textures, but mobile PowerVR
uses ASTC/ETC/PVRTC and likely reports `textureCompressionBC = false`, so DXVK's BC
textures decode to garbage (geometry/FPS are fine, texture data is wrong). This is
**the #1 known Vortek issue on non-Adreno GPUs and has a known fix**: BCn JIT
software decompression — already implemented for Mali in Vortek / leegao's
`vortek-patcher`. → plan (b) is **"real work but a solved problem class"**:
port/enable BCn decompression for PowerVR.

**⚠ DIAGNOSIS UNVERIFIED — the BC-texture theory below is inference, not evidence.**
We have NOT confirmed what the corruption actually is. "Garbage" is equally
consistent with vertex/geometry corruption, shader (SPIR-V) miscompilation,
render-target/format mismatch, or depth/sync issues. The `textureCompressionBC`
flag was never read (Caps Viewer crashed), and the corruption was never visually
characterized. **Do NOT invest in a BC-specific fix until evidence is gathered:**
1. **Characterize the corruption visually** — recognizable geometry w/ noisy
   *surfaces* (→ textures) vs scrambled/exploding *geometry* (→ vertex/shader) vs
   correct-shapes-wrong-colors (→ format/colorspace) vs flicker/z-fight (→ depth).
2. **DXVK logs** — `DXVK_LOG_LEVEL=info` (+ `DXVK_LOG_PATH=<dir>`); read what
   DXVK/driver report: shader-compile failures, format fallbacks, unsupported
   features. This is the authoritative signal.
3. **2nd, different app** — consistent corruption across apps = systemic
   (shader/format); only texture-heavy scenes corrupt = textures.
4. **`textureCompressionBC` flag** — read it directly (vulkaninfo.exe / another tool).
The vortek-patcher debug APK is then a *hypothesis test* (fixes it ⇒ it was BC;
doesn't ⇒ it wasn't), NOT an assumed cure. Everything below is the leading
hypothesis pending this verification.

**EVIDENCE UPDATE — 2026-05-27 (BC theory FALSIFIED; pivot to vertex/shader):**
Actual feature flags read in GPU Caps Viewer: **`textureCompressionBC`,
`textureCompressionETC2`, `textureCompressionASTC_LDR` are ALL `true`.** The device
advertises full BC support and DXVK (which *requires* BC) is satisfied → **the
corruption is NOT a texture-compression problem.** And the corruption **visually
resembles scrambled GEOMETRY**, not noisy surfaces on intact shapes. → Leading
candidate is now a **vertex / shader-compiler problem** — the "**vertex explosion**"
class. Notably Winlator 10.0 already shipped a *Mali-specific* "vertex explosion
fix," and Vortek carries Mali SPIR-V workarounds (e.g. `gl_ClipDistance` stripping);
plausibly PowerVR's shader compiler mishandles the same SPIR-V and the Mali fix
isn't gated to fire for PowerVR. **Everything in the BC/BCn sections below is
SUPERSEDED — kept only as record.** Hold this new candidate loosely too; confirm via
the **DXVK log** (shader/pipeline warnings) and whether a 2nd app scrambles the same
way before committing to any fix.

**Evidence update 2 — 2026-05-27 (DXVK log CLEAN):** with `DXVK_LOG_LEVEL=info`,
Heaven's log shows **no errors** — DXVK selected the device, compiled shaders, built
pipelines, submitted draws, all valid. Combined with scrambled geometry, that's the
signature of a **silent failure BELOW DXVK**: either (1) **PowerVR's Vulkan shader
compiler miscompiles** DXVK's SPIR-V (wrong vertex positions), or (2) **Vortek's
command/data forwarding** corrupts the vertex/buffer path. No DXVK-level fix applies.
Community: no PowerVR scrambled-geometry report found (brunodev85/winlator issues are
disabled); Pixel 10 GPU drivers widely reported immature. **This is no longer a
small/known patch — it's an open debugging problem.** (Trivial geometry — the ~2000
FPS test — rendered fine, so it's triggered by complex vertex shaders/layouts.)

**Localization plan (cheap → definitive):**
- **DX11 vs DX9** Heaven (different DXVK/shader path; DX11 may OOM/crash ~10 min per
  community reports, but a short run shows whether geometry is correct).
- **A 2nd, simpler DX game** (systemic vs Heaven-specific; find the complexity
  threshold between the working trivial test and Heaven).
- **Definitive discriminator = the gfxstream cross-check (Podroid pubuntu):** same
  PowerVR vendor driver, *different* transport (gfxstream, not Vortek). Heaven-class
  content clean on gfxstream ⇒ bug is in **Vortek** (fixable in Vortek). Also
  scrambles on gfxstream ⇒ bug is in the **PowerVR driver itself** (immature — both
  the Vortek and Podroid paths then wait on Google/Imagination driver updates). This
  overlaps the already-planned Podroid GPU work (#63/#64) — not wasted effort.

Note: **same garbage on BOTH DX9 and DX11** (entirely separate DXVK code paths /
shader models) → the bug is in a layer **common to both**: Vortek's forwarding or the
PowerVR shader compiler. Not a per-D3D-version translation issue.

**STRONG LEAD — GameNative (2026-05-27):** `github.com/utkarshdalal/GameNative`
(★7k+, "Native PC gaming … Steam/Epic/GOG integration") is a Winlator fork that
**added initial Pixel 10 PowerVR GPU support in v0.9.0** — the *only* build with
PowerVR-specific handling. Current stable **v0.9.2** → asset `gamenative-v0.9.2.apk`
on the GitHub releases (avoid winlator.me / mirrors). Bundles recent Turnip +
updated Box64. **Test on the same Heaven scene:** geometry clean ⇒ the bug was in
the Winlator/Vortek PowerVR handling and GameNative fixes it (→ use it; proot GPU
path becomes viable); still scrambled ⇒ deeper (PowerVR driver) → confirm via the
gfxstream cross-check, else wait on driver updates. Caveat: "initial support" —
expect rough perf; what we're checking is geometry *correctness*, not FPS.

**✓ ROOT CAUSE FOUND — 2026-05-27 (DXVK version):** switching DXVK to **2.4.1** makes
geometry render **correctly**. The scrambled geometry was a **DXVK-version
incompatibility** — newer DXVK emitted SPIR-V/Vulkan usage the young PowerVR driver
(or Vortek) mishandled; **DXVK 2.4.1 sidesteps it**. Matches the evidence exactly:
silent, below DXVK, identical across DX9+DX11, no log errors (DXVK did valid work the
driver miscompiled). **The fix is config, not code — pin DXVK 2.4.1.** → the
proot/Vortek + PowerVR GPU path is **VIABLE for real content**. This supersedes the
BCn-patch and Vortek-source-patch plans entirely; (b) is no longer needed for basic
function. GameNative now **optional** (nice for Steam/Epic/GOG + PowerVR-tuned
defaults, but not required for the fix).

**Remaining artifact (clarified 2026-05-27): shadows / shaded areas render too dark
or fully black — NOT textures.** Geometry is correct; this is a **fragment-stage**
issue. Leading candidate: the **shadow-map depth-comparison-sampler / depth-format
path** (PCF comparison samplers + D16/D24/D32 shadow maps) being mishandled so
shadowed pixels clamp to 0/black; less likely an ambient/lighting shader term. Cheap
confirmation: **toggle shadows OFF in-app** — black areas vanish ⇒ shadow-map path;
persist ⇒ lighting/ambient shader. Mitigate via DXVK-version sweep (the proven lever
here) and/or wait on PowerVR driver updates. Cosmetic — the path is usable now.

**⚠ Tessellation HARD-HANGS the GPU (2026-05-27):** Heaven at **medium + normal
tessellation** rendered broken, then **froze the entire phone** — a full device hang
requiring a force-reboot (Power held ~30s), not just an app kill. A GPU lockup takes
down all of Android because the same PowerVR GPU drives the system compositor.
Tessellation uses a separate hull/domain shader path (never exercised during the
DXVK-2.4.1 geometry fix), is weak on mobile GPUs, and can amplify geometry/memory
into a hang. → **Keep tessellation OFF — it is not merely a quality knob; it can
hard-hang the device.** The working baseline stands at **tessellation off + DXVK
2.4.1**. Most titles treat tessellation as optional, so this is an acceptable limit.
(If isolating: a medium preset with tessellation OFF should be stable — confirms
tessellation specifically, not the preset.)

**Refined finding (2026-05-27):** official **Winlator 10.0+ already implements BCn
software decompression** (`textureCompressionBC` emulation + a Mali vertex-explosion
fix) — but it's **gated on the driver reporting `textureCompressionBC = false`**.
Heaven was still garbage even on **DX9 with tessellation/AA off** (rules out
tess/MSAA; DX9 still uses DXT1/3/5 = BC1/2/3) → consistent with: **PowerVR DXT
claims BC support (flag = true) yet renders it wrong**, so stock Winlator trusts the
flag and skips decompression. That makes (b) potentially **config, not code**: force
BCn decompression regardless of the flag.

**Cheapest next step (may avoid custom dev):** rerun the same DX9 Heaven test on a
**Mali-targeted build that FORCES decompression** — `github.com/Fcharan/WinlatorMali`
(latest **v2.0**; **Glibc** variant = standard Vortek+DXVK). It exists for exactly
this case (non-Adreno GPUs lacking BC). Clean render ⇒ (b) collapses to "use the
Mali build / force the toggle"; still garbage ⇒ genuine PowerVR-specific work.
(SEGAINDEED bionic-vortek = dead end — release assets don't load.) Also worth a
30-sec look in the current Winlator's Vortek/advanced settings for a
force-decompress toggle before installing anything.

**Update — WinlatorMali = no Vortek:** WinlatorMali v2.0 (Glibc) exposes **only
VirGL** (CPU/software GL), so it can't test the GPU path — it bypasses both the
PowerVR GPU *and* the BC issue (full Mesa decodes BC correctly, just slowly on the
CPU). Useful only as a "content renders fine" sanity check. **Net: no off-the-shelf
build targets PowerVR's BC quirk** — the forks force BCn only for *detected*
Mali/Adreno, and the Mali build swaps Vortek out for VirGL. → (b) is confirmed as a
**small, targeted patch on official Winlator's (already-working) Vortek**: force the
existing BCn decompression on for PowerVR regardless of the `textureCompressionBC`
flag (container setting if exposed; else `leegao/vortek-patcher` or a Vortek-source
build). There is no free-lunch build — but the fix is small and well-understood.

**vortek-patcher specifics (the (b) mechanism) — 2026-05-27:**
`leegao/vortek-patcher` patches Winlator's Vortek **BCn decoder** and ships a
**pre-built debug APK** in releases. The fix is **CPU-side decompression** (intercept
BC textures → decode to uncompressed RGBA on the CPU → upload), which is
**GPU-agnostic**: once decompressed, any GPU incl. PowerVR displays it correctly. The
"Mali/Adreno 6XX" label is only the **activation trigger**, not the decode. So (b) ≈
**make the trigger fire for PowerVR** (force it on / widen the gate) — the hard part
(the decoder) already exists and is hardware-independent. Repo internals:
`patch_vortek.py` + C/C++ decoder + `uber-apk-signer` (re-signs the patched APK).

**Direct test:** install the vortek-patcher **debug APK**, run the same DX9 Heaven
test. Clean textures ⇒ trigger already fires for PowerVR — done. Still garbage ⇒
force the trigger (small source tweak). Install caveat: debug-signed, so it likely
**won't install over the official Winlator** (signature mismatch) — uninstall
official first (lose containers, recreatable) or expect a separate package id.

---

## 11. Artifacts created this session

- **Podroid (`feat/gpu-support` / boot-fix branches):** guest-kernel
  `VIRTIO_BALLOON`+`PAGE_REPORTING`; `VIRTIO_BALLOON_F_REPORTING` feature-table
  `sed` (disable reporting, keep balloon); committed debug keystore +
  `debugFixed` signing; CI timeout bump; `setRendererUseGlx` in `tryEnableGpu`.
- **linux-setups:** `pixel/lxc/helper/build-gfxstream-mesa.sh`,
  `pixel/lxc/helper/install-desktop-gpu.sh`, `pixel/podroid/helper/enable-gpu-mount.sh`,
  `/dev/dri` passthrough in `pixel/podroid/helper/create-lxc.sh`, this doc.

## 12. Open / next

1. **Validate the boot-fix build** boots **multi-vCPU** (the page-reporting/SMP fix).
2. Restore pubuntu → run `build-gfxstream-mesa.sh` → validate GPU (`vulkaninfo`/`vkcube`).
3. **(a)** Test Winlator 11.0 + Vortek on the Pixel 10 (sizes the Vortek-PowerVR gap).
4. **(b)** If (a) shows promise, execute the Vortek extension plan (section 9).
5. Land the CI 3-cache split; do the upstream `ExTV/Podroid` merge (8 releases behind, kernel 7.0.10 + host-bridge).

---

## 13. NEW GOAL — native Ubuntu on proot + Termux-X11 with REAL GPU (Vortek bridge)

Goal: a native-Linux (not Wine) Ubuntu desktop in **Termux + proot-distro**, displayed
via **Termux-X11**, with **hardware** GPU acceleration on PowerVR DXT.

**Why the obvious paths don't work on PowerVR:**
- Termux's normal hardware path is **Turnip + Zink — Adreno/Qualcomm only**. Turnip is
  an open Mesa Vulkan driver that runs in glibc and talks straight to `/dev/dri`;
  **PowerVR has no glibc-loadable Vulkan driver** (Mesa PVR = Rogue-only; the only
  PowerVR Vulkan is the **Bionic vendor blob** `vulkan.powervr.so`).
- Non-Adreno SoCs fall back to **virglrenderer-android = software-ish, poor perf**.
- So hardware Vulkan in a glibc proot needs a **Bionic-side server that loads the blob
  and speaks a protocol to a glibc client** — i.e. exactly **Vortek**. (The "Termux
  Vulkan-loader → proot" idea is a dead end: a glibc app still can't load a Bionic blob.)

**Vortek architecture (from `github.com/brunodev85/vortek`, LGPL-2.1, C):**
- The repo is the **CLIENT only** — a glibc Vulkan ICD `libvulkan_vortek.so` (+
  `vortek_icd.aarch64.json`). Builds via CMake/`build.sh`.
- The **SERVER is CLOSED** (bundled in the Winlator/GameNative app) and does the real
  work: loads `vulkan.powervr.so`, **format emulation, SPIR-V inspection, texture
  decoding** (the workarounds).
- **IPC is portable** (the key enabler): client `connect()`s a **filesystem Unix socket**
  `VORTEK_SERVER_PATH = /data/data/com.winlator/files/rootfs/tmp/.vortek/V0`, sends
  `CREATE_CONTEXT`, server returns **2 shm fds via SCM_RIGHTS** → both `mmap` lock-free
  ring buffers (4 MiB server / 256 KiB client). Unix socket + fd-passing + shared mmap
  all work fine across the Termux(Bionic)↔proot(glibc) boundary.

**Feasibility verdict:** the bridge CAN be standalone. Client is open + recompilable
(can change the socket path / install paths). The IPC is runtime-agnostic. **The one
make-or-break unknown: can the closed server run under Termux outside the Winlator
app** (load `vulkan.powervr.so`, create its socket, serve)? Risk: it may be embedded in
the Winlator Java app / expect Android service context / hardcode the Winlator rootfs.

**Spike plan (cheapest → fullest):**
- **Spike 0 — locate the server:** unpack a Winlator (or GameNative) APK; find the
  server in `lib/arm64-v8a/` (e.g. `libvortek*server*.so`) and/or the imagefs/rootfs
  asset; confirm the client `libvulkan_vortek.so` + ICD json location.
- **Spike 1-alt (FAST proof, do first) — piggyback inside Winlator's rootfs:** Winlator
  already runs the server + a glibc rootfs with the client wired. Drop a native-Linux
  Vulkan test (`vulkaninfo`/`vkcube`) into Winlator's rootfs and run it with the Vortek
  ICD while Winlator is up. Renders on PowerVR ⇒ native-Linux-app GPU via Vortek is
  proven, *zero* server extraction.
- **Spike 1 — run server standalone under Termux:** launch the extracted server as a
  Bionic process (Termux is Bionic); make `…/tmp/.vortek/V0` reachable (recompile the
  client's `VORTEK_SERVER_PATH`, and/or bind-mount the socket dir into proot).
- **Spike 2 — client in proot:** build the open client for `aarch64-linux-gnu`, install
  ICD + `VK_ICD_FILENAMES`, run `vulkaninfo`/`vkcube` → hardware Vulkan in proot.
- **Spike 3 — GL + desktop:** add **Zink** (GL→Vulkan→Vortek→PowerVR); run XFCE on
  Termux-X11 over it.

**Risks / caveats:** closed server may resist standalone launch (the big one); server
hardcodes the Winlator rootfs socket path (workable via recompiled-client path +
bind-mount); Vortek's workarounds are DXVK-tuned (native Zink may hit different paths);
**GPU hangs are real on this driver** (Heaven tessellation hard-hung the whole device).
LGPL covers the client; the server is bruno's closed component (local personal use only).

**Spike 0 findings (2026-05-27, dissected Winlator 11.0 APK):**
- Server = **`lib/arm64-v8a/libvortekrenderer.so`** (598 KB Bionic lib). Client =
  `assets/graphics_driver/vortek-2.1.tzst` → `usr/lib/libvulkan_vortek.so` +
  `vortek_icd.aarch64.json`. Zink 22.2.5 and **DXVK 2.4.1** are also bundled assets
  (the working DXVK is one of Winlator's own).
- The server is a **JNI library, NOT a standalone daemon.** Exported entry points:
  `Java_com_winlator_xenvironment_components_VortekRendererComponent_{createVkContext,
  handleExtraDataRequest}`. It `NEEDED`s **`libwinlator.so`** + `libandroid`,
  `libEGL`/`libGLESv2`/`libGLESv3`, `libjnigraphics`. Loads the vendor Vulkan via
  **adrenotools** (`adrenotools_open_libvulkan`). Exports `ashmemCreateRegion`,
  `RingBuffer_create`, `createVkContext`, `initVulkanInstance/Device` — so the native
  lib creates the shm rings + does Vulkan, while the **socket accept / fd-passing loop
  is in Winlator's Java** (`VortekRendererComponent` — open in brunodev85/winlator).
- → Running it outside Winlator needs a **minimal Android host app** reimplementing
  that Java harness and hosting the lib (the Android-API + EGL/GLES deps make a
  pure-Termux-CLI launch unlikely). NOT a clean daemon you just start under Termux.

**Revised options (server is app-coupled):**
- **A. Piggyback (cheapest GPU proof):** run native-Linux Vulkan/GL apps *inside
  Winlator's own glibc rootfs* while its server is up — client+server already wired.
  Caveat: Wine-tailored rootfs + Winlator's X display, not a clean separate Ubuntu.
- **B. Minimal Vortek-host app (the real project for the clean goal):** a small Android
  app that loads `libvortekrenderer.so`+`libwinlator.so`, reimplements
  `VortekRendererComponent`'s socket/serve loop (open reference), and serves a
  *separate* proot Ubuntu's Vortek client over the Unix socket. Yields the clean
  "proot Ubuntu + Termux-X11 + GPU", but it's a multi-day Android/JNI effort (closed
  native lib, but we have its binary + symbol ABI + the open Java harness + open client).
- **C. Hybrid (no dev):** software (virgl) Ubuntu desktop on Termux-X11 for general use
  + Winlator/GameNative (Vortek GPU) for the GPU/gaming apps. No new code.
- **D. Wait:** GameNative/community may package Vortek for general Termux use; PowerVR
  drivers are improving.

Recommendation: **A** first (cheap proof native Linux apps get GPU via Vortek); if a
clean separate Ubuntu is required, **B** is now well-scoped; **C** is the no-regrets
fallback for a usable desktop today.

### 13.1 Project B — detailed scope (after reading the harness, 2026-05-27)

Read `VortekRendererComponent.java` (open; `brunodev85/winlator` pulls **submodules** —
app = `brunodev85/winlator-app`, vortek, gladio).

**Native ABI a host must drive:**
- `initVulkanWrapper(String nativeLibraryDir, String libvulkanPath)` — loads the wrapper
  + vendor Vulkan via adrenotools (`libvulkanPath=null` → system driver).
  `nativeLibraryDir` must contain `libvortekrenderer.so` + its dep `libwinlator.so`.
- `createVkContext(int clientFd, Options)` — per connection; creates the shm rings and
  **sends the fds back over `clientFd`** (the accepted socket) internally; returns a ctx ptr.
- `destroyVkContext(ptr)`, `handleExtraDataRequest(ptr,id,len)`.
- `Options`: vkMaxVersion (default 1.3.128), maxDeviceMemory, imageCacheSize(256),
  resourceMemoryType, exposedDeviceExtensions, libvulkanPath.

**Socket server:** Winlator's `XConnectorEpoll` (epoll Unix-socket server) on the
`UnixSocketConfig` path; 8-byte header {int code, int len}; code 1 = CREATE_CONTEXT,
(>>16)==2 = SEND_EXTRA_DATA. Small, reimplementable.

**⚠ The catch — presentation is welded to a host X server via AHardwareBuffer.** The
native lib calls BACK into the host (@Keep): `getWindowWidth/Height(windowId)`,
**`getWindowHardwareBuffer(windowId, halBGRA8888)`** → an `AHardwareBuffer` it renders
into, and `updateWindowContent(windowId)` → tell the host compositor to redraw. So
Vortek does **not** use standard Vulkan WSI — it renders into **per-window
AHardwareBuffers owned by the host X server** (Winlator's Java XServer + GLES compositor
→ its Surface). The GPU *compute* path is portable; the **presentation path is bound to
a host window system**.

**∴ B's realistic form = integrate Vortek into Termux-X11 (a fork), not a tiny daemon.**
Termux-X11 already has an X server + AHardwareBuffer-backed windows + a GLES/Surface
display path — exactly what the callbacks need. Work: (1) reimplement the epoll socket
server [easy]; (2) `initVulkanWrapper` with a nativeLibraryDir holding
`libvortekrenderer.so`+`libwinlator.so` [medium]; (3) **wire `getWindowHardwareBuffer` /
`updateWindowContent` to Termux-X11's window buffers** [hard — the core integration];
needs an Android Activity/Context. **Effort: weeks** (Android graphics AHWB/EGL/GLES +
JNI + Termux-X11 internals + RE of the closed lib's wire protocol/callback contract,
only partially knowable from the open client + this Java).

**Reframes A vs B:** option A is cheap *precisely because it reuses Winlator's
XServer+compositor* — the hard part of B. A is not a throwaway PoC; it leverages the
exact subsystem B must otherwise rebuild. If Winlator's rootfs+display are acceptable, A
may be the endpoint; if a clean Ubuntu+Termux-X11 is required, B = the Termux-X11+Vortek
fork (weeks).

**Open/closed map (verified 2026-05-27):** bruno's public repos = `vortek` (the Vulkan
*client*, LGPL), `winlator-app` (Java harness + open native source incl.
**`gladiorenderer`** and **`libadrenotools`** with a BCn `bcenabler`), `gladio`, custom
Wine/Box64, etc. **No published source for `libvortekrenderer.so`** (the Vulkan
*server/renderer*) — not in winlator-app/cpp, no separate repo. So it's bruno's own code
shipped binary-only, loaded by the open Java via `System.loadLibrary("vortekrenderer")`.
"Closed" = his own unreleased component, not a third-party blob. For B we can *host* it
(we have its JNI ABI + the open client's wire side + the open harness) but not modify it
→ RE risk on its internal protocol/buffer contract.

**Alternative B foundation — gladio (fully OPEN):** `gladio` is bruno's *OpenGL-through-
GLES* renderer (`app/src/main/cpp/gladiorenderer/*`, same client/server pattern, incl.
`stb_dxt`/compressed-texture handling). A native Linux **desktop is overwhelmingly GL,
not Vulkan**, so B could be built on gladio (GL→GLES→PowerVR vendor GLES driver) with
**full source control and no closed binary** — losing only the Vulkan/DXVK path (kept
via Winlator/GameNative anyway). For a GPU-accelerated Ubuntu *desktop* (vs gaming),
gladio-open is likely the better foundation than hosting the closed Vulkan renderer.

**RE resources retire most of the closed-binary risk (2026-05-27):**
`leegao/vortek-deep-dive` = a **full disassembly** of Winlator 10.0's Vortek
(`libvortekrenderer.objdump/.asm/.txt` + the client dumps), and `possiblyquestionable`/
leegao **"Vortek Internals" Pt.1–2** document it. So `libvortekrenderer.so` is already
substantially reverse-engineered. Concretely:
- **Wire protocol:** serialized Vulkan RPC over the two ring buffers. Request =
  `{opcode, bufferSize}` (8B) + serialized args; response = `{vk_result, size}` (8B) +
  data; each call has a server `vt_handle_*`. The serialization is **defined by the open
  client** (`vulkan_calls.c` + `vortek_serializer.h`) and confirmed by the disassembly →
  fully recoverable.
- **Presentation/WSI (B's crux):** the server **removes `VK_KHR_surface`/`xlib_surface`**
  and does its **own WSI via `VK_ANDROID_external_memory_android_hardware_buffer`** —
  rendering into **AHardwareBuffer-backed VkImages** the host composites. The RE notes
  the WSI integrates "directly with the **Lorie** renderer" — and **Termux-X11's X server
  IS Lorie-based** → strong sign the Termux-X11 target is *what Vortek's WSI already
  expects*, with the AHB external-memory import as the seam. (Verify exact present path in
  Pt.1 / the disassembly before building.)
- **Workarounds (server-side, Mali/Qcom-targeted):** BCn = JIT CPU/NEON decompress at
  `vkQueueSubmit` (format→`R8G8B8A8_UNORM`); SPIR-V = `gl_ClipDistance` removal +
  `*SCALED`→`*INT`+`OpConvertSToF` vertex-format emulation via `ShaderInspector`;
  `vkCreateDevice` injects external-memory/AHB/dedicated-alloc exts + disables unsupported
  features. (The scaled-vertex-format fixup is a plausible cousin of the scrambled geometry
  that **DXVK 2.4.1** sidestepped on PowerVR.)

**Revised B outlook:** the closed binary is documented enough to **host as-is**; the work
narrows to (1) the epoll/socket harness [easy]; (2) satisfying the lib's load deps
(`libwinlator.so` + an Android Activity/Context) [medium]; (3) feeding it
**AHardwareBuffer-backed windows from Termux-X11/Lorie** and driving its AHB WSI [the core
— but a now-known seam, not a black box]. Still a real graphics project, but the RE
unknowns are largely retired, and Termux-X11/Lorie looks like the *intended* host.

### 13.2 Presentation flow & concrete B integration design (2026-05-28)

**Flow (from `libvortekrenderer.so.txt` disassembly + Pt.1 blog):**
1. **Connect / context** — client opens `AF_UNIX SOCK_STREAM` at `VORTEK_SERVER_PATH`,
   sends a single byte `1`, the server creates two **ashmem** regions (server ring 4 MiB,
   client ring 256 KiB), sends both fds back via `sendmsg`/`SCM_RIGHTS`. A dedicated
   server worker thread (`vortek_renderer_thread_main_loop`) `AttachCurrentThread`s and
   caches JNI method IDs for `getWindowWidth/Height/HardwareBuffer/updateWindowContent`.
2. **Surface** — client `vkCreateXlibSurfaceKHR(display, window)` →
   `vt_call_vkCreateXlibSurfaceKHR` carries the **X Window XID** to the server as its
   `windowId`. (Pt.2's "removes xlib_surface" wording refers to the *reported extension
   list*, not the handler — the call is implemented.)
3. **Swapchain** — `vt_handle_vkCreateSwapchainKHR` → `createSwapchain(...)` allocates
   N **AHardwareBuffers** (`AHardwareBuffer_allocate/describe/getFd`) sized from JNI
   `getWindowWidth/Height(windowId)`, and imports them as `VkImage`s via
   `VK_ANDROID_external_memory_android_hardware_buffer`. Standard `VK_KHR_swapchain`.
4. **Present** — `vt_handle_vkQueuePresentKHR` → `presentImage(...)` makes the rendered
   AHB visible in the host's window AHB (`getWindowHardwareBuffer(windowId, halBGRA)`
   returns the host's per-window AHB) and calls JNI `updateWindowContent(windowId)` to
   damage/redraw. *Confirm before building:* blit-from-swapchain-AHB-to-window-AHB vs
   import-window-AHB-as-swapchain-image.
- Extensions confirmed in data: `VK_KHR_swapchain`, `VK_KHR_android_surface`,
  `VK_ANDROID_external_memory_android_hardware_buffer`;
  `vkGetAndroidHardwareBufferPropertiesANDROID` handled.

**B integration design (Termux-X11/Lorie host):**
1. **Fork Termux-X11.** It already has the Activity, Surface, GLES compositor, Lorie X
   server, and per-X-window AHB pixmaps (DRI3 / `EXT_image_dma_buf_import`) — i.e. the
   subsystem the Vortek callbacks need is largely present.
2. **Bundle libs** into the fork's `lib/arm64-v8a/`: `libvortekrenderer.so` +
   `libwinlator.so` (extracted from the Winlator APK already pulled to `/tmp`). Ship
   `vortek-2.1.tzst` for placement into the proot rootfs at a *recompile-fixed*
   `VORTEK_SERVER_PATH` (rebuild the open client with our chosen path / bind-mount).
3. **Reimplement the harness** — a small Java component analogous to
   `VortekRendererComponent`: `LocalServerSocket`/epoll Unix socket, handshake byte,
   `static { System.loadLibrary("vortekrenderer"); }`, native methods
   `initVulkanWrapper(nativeLibDir, libvulkanPath)`,
   `createVkContext(clientFd, Options)`, `destroyVkContext(ptr)`,
   `handleExtraDataRequest(ptr,id,len)`.
4. **JNI callbacks (the integration crux)** — `@Keep` methods on the host:
   `getWindowWidth/Height(windowId)`, `getWindowHardwareBuffer(int windowId, boolean
   halBGRA8888) → long` (returns Lorie's per-XID AHB pointer; allocate-on-first-call,
   resize on configure), `updateWindowContent(int windowId)` (damage + Lorie redraw).
5. **Bring-up:**
   a. Build/install the Termux-X11 fork; verify the X display still works.
   b. In the proot Ubuntu: install the Vortek ICD (`VK_ICD_FILENAMES=…vortek_icd.aarch64.json`).
   c. `DISPLAY=:0 vulkaninfo` → expect PowerVR (Vortek loads, connects to fork's socket).
   d. `vkcube` → renders into a Lorie window via Vortek → composited on the Surface.
   e. Install **Zink** in the proot (GL→Vulkan→Vortek) → XFCE.

**Open questions to confirm against the disassembly before/during build:**
- Exact `presentImage` semantics (blit vs swap-in-place) — determines whether Lorie
  allocates AHBs the server writes to, or just exposes the window AHB.
- `getWindowHardwareBuffer` return type (raw `AHardwareBuffer*` as `long`, vs an
  opaque handle the server unwraps).
- `libwinlator.so`'s own deps — it's also closed; verify a Termux-X11 process satisfies
  them (libandroid/EGL/GLES/jnigraphics — present on-device, Lorie already uses GLES).

**Effort estimate (revised down from "weeks"):** with the RE done and Termux-X11 as the
host, ~**a few intense days to a working `vkcube`**, incremental from there to GL/Zink
and a usable desktop. Termux-X11/Lorie may already do most of the AHB-backed-window
plumbing — if so the JNI callbacks are mostly glue.

**✓ Confirmed semantics & ABI from the disassembly (2026-05-28):**
- **`createSwapchain`** (per image, N times): JNI `getWindowHardwareBuffer(windowId,
  halBGRA)` → AHB → `AHardwareBuffer_describe` → `vkCreateImage` (with
  `VkExternalMemoryImageCreateInfo`) → `vkGetAndroidHardwareBufferPropertiesANDROID(AHB)`
  → `vkAllocateMemory` (with `VkImportAndroidHardwareBufferInfoANDROID(AHB)` in pNext)
  → `vkBindImageMemory`. **All N swapchain images alias the same backing AHB** —
  Winlator's host returns the same pointer each call (the window's one GPUImage). The
  swapchain is effectively single-buffered onto the window's AHB; double-buffering is
  the host compositor's job.
- **`presentImage` = swap-in-place, NO BLIT.** Optional fence wait then *only* JNI
  `updateWindowContent(windowId)`. The rendered frame is already in the window's AHB
  (because the swapchain images *are* the window AHB).
- → Host's job for B reduces to: per X window, provide an `AHardwareBuffer*` (the
  window's pixmap backing) and damage/recompose on `updateWindowContent`. Standard
  X-server-with-AHB-pixmaps; Lorie already does this for accelerated rendering.
- JNI vtable offsets observed: `getWindowHardwareBuffer = 0x1a0` (`CallLongMethod`),
  `updateWindowContent = 0x1e8` (`CallVoidMethod`). Signatures from the open Java:
  `getWindowWidth/Height: (I)I`, `getWindowHardwareBuffer: (IZ)J`,
  `updateWindowContent: (I)V`. ABI fully nailed.

**Effort revised again — ~1–2 days to `vkcube`** if Lorie's per-window AHB is reachable
from JNI; the only sizable remaining unknown is `libwinlator.so`'s deps when loaded
outside its app (libandroid/EGL/GLES are on-device, Lorie already uses them).
