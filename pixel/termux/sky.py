#!/data/data/com.termux/files/usr/bin/python
"""
Sky Almanac — a centered terminal "home page": a large 8-bit block clock with sun/moon +
planet rise/set and tonight visibility below, in a cyberpunk/8-bit theme.

Offline astronomy via PyEphem:   pip install ephem
Location: GPS (termux-location, needs Termux:API) -> IP fallback -> manual override below.
Big clock ticks every second; astronomy recomputes each minute. Ctrl-C to quit.
"""
import ephem
import math
import sys
import time
import json
import re
import shutil
import subprocess
import threading
import urllib.request
import os
import select
import signal

# ---- manual override (set both to skip auto-detect) ------------------------
LAT = None   # e.g. -33.9249
LON = None   # e.g. 18.4241
# ----------------------------------------------------------------------------

E = "\033"
def col(code, s): return f"{E}[{code}m{s}{E}[0m"
# Palette derived from the terminal background image (warm taupe / tan / muted teal) — truecolor.
NEON = "38;2;224;203;180"   # light warm tan — clock + key values
PINK = "38;2;122;166;166"   # muted teal — frame / dividers
LIME = "38;2;160;196;148"   # soft sage — "visible tonight"
AMB  = "38;2;212;170;104"   # warm amber-tan — sun
VIO  = "38;2;176;186;196"   # cool slate — moon
GREY = "38;2;150;140;128"   # warm taupe-grey — labels / dim
RED  = "38;2;206;128;104"   # muted terracotta — errors
BOLD = "1"
ANSI = re.compile(r"\x1b\[[0-9;]*m")
def vlen(s): return len(ANSI.sub("", s))   # visible width (ANSI codes don't count)

BIG = {
    "0": ["███", "█ █", "█ █", "█ █", "███"], "1": ["  █", "  █", "  █", "  █", "  █"],
    "2": ["███", "  █", "███", "█  ", "███"], "3": ["███", "  █", "███", "  █", "███"],
    "4": ["█ █", "█ █", "███", "  █", "  █"], "5": ["███", "█  ", "███", "  █", "███"],
    "6": ["███", "█  ", "███", "█ █", "███"], "7": ["███", "  █", "  █", "  █", "  █"],
    "8": ["███", "█ █", "███", "█ █", "███"], "9": ["███", "█ █", "███", "  █", "███"],
    ":": ["   ", " █ ", "   ", " █ ", "   "],
}


def big(text):
    rows = ["", "", "", "", ""]
    for ch in text:
        g = BIG.get(ch, ["   "] * 5)
        for i in range(5):
            rows[i] += "".join(c * 2 for c in g[i]) + "  "
    return [r[:-2] for r in rows]  # drop the uniform trailing gap; keep all rows EQUAL width (align)


# Location is resolved on a background thread so startup is instant. _loc is updated in place:
# fast IP geo first (astro appears in ~1s), then upgraded to GPS when termux-location returns.
_loc = {"lat": LAT, "lon": LON, "src": ("manual" if LAT is not None else "locating"), "place": ""}


def ip_geo():
    try:
        with urllib.request.urlopen(
            "http://ip-api.com/json/?fields=lat,lon,city,regionName,countryCode", timeout=5) as r:
            j = json.loads(r.read().decode())
            place = ", ".join(p for p in (j.get("city", ""), j.get("countryCode", "")) if p)
            return float(j["lat"]), float(j["lon"]), place
    except Exception:
        return None, None, ""


def gps_loc():
    try:
        out = subprocess.run(["termux-location", "-p", "network"],
                             capture_output=True, text=True, timeout=15)
        if out.returncode == 0 and out.stdout.strip():
            j = json.loads(out.stdout)
            return float(j["latitude"]), float(j["longitude"])
    except Exception:
        pass
    return None, None


def locator():
    if LAT is not None:
        return
    lat, lon, place = ip_geo()
    if lat is not None and _loc["src"] == "locating":
        _loc.update(lat=lat, lon=lon, src="ip", place=place)
    glat, glon = gps_loc()                       # slower, more accurate — upgrade when it lands
    if glat is not None:
        _loc.update(lat=glat, lon=glon, src="gps")
    while True:                                  # keep it current if you move
        time.sleep(3600)
        glat, glon = gps_loc()
        if glat is not None:
            _loc.update(lat=glat, lon=glon, src="gps")


def lt(date):
    if date is None:
        return "--:--"
    try:
        return ephem.localtime(date).strftime("%H:%M")
    except Exception:
        return "--:--"


def observer(lat, lon, when=None):
    o = ephem.Observer()
    o.lat, o.lon = str(lat), str(lon)
    o.elevation = 0
    o.pressure = 0
    o.date = when if when is not None else ephem.now()
    return o


def safe(fn):
    try:
        return fn()
    except Exception:
        return None


def alt_deg(body_cls, lat, lon, when):
    o = observer(lat, lon, when)
    b = body_cls()
    b.compute(o)
    return math.degrees(float(b.alt))


def build_astro(lat, lon, src):
    out = []
    if lat is None:
        out.append(col(RED, "no location — install Termux:API (pkg install termux-api)"))
        out.append(col(GREY, "or set LAT/LON at the top of this script."))
        return out

    o = observer(lat, lon)
    sun = ephem.Sun()
    sr = safe(lambda: o.next_rising(sun))
    ss = safe(lambda: o.next_setting(sun))
    o.horizon = "-18"
    dusk = safe(lambda: o.next_setting(sun, use_center=True))
    dawn = safe(lambda: o.next_rising(sun, use_center=True))
    o.horizon = "0"
    mid = safe(lambda: o.next_antitransit(ephem.Sun()))

    # day length = the sunrise preceding the next sunset
    daylen = ""
    if ss is not None:
        od = observer(lat, lon, ss)
        srd = safe(lambda: od.previous_rising(ephem.Sun()))
        if srd is not None:
            h = (ss - srd) * 24.0
            daylen = f"{int(h)}h {int(round((h - int(h)) * 60)) % 60:02d}m"

    m = ephem.Moon(o)
    illum = m.phase
    pnm = ephem.previous_new_moon(o.date)
    nnm = ephem.next_new_moon(o.date)
    lun = (o.date - pnm) / (nnm - pnm)
    names = [("New", "🌑"), ("Waxing Crescent", "🌒"), ("First Quarter", "🌓"),
             ("Waxing Gibbous", "🌔"), ("Full", "🌕"), ("Waning Gibbous", "🌖"),
             ("Last Quarter", "🌗"), ("Waning Crescent", "🌘")]
    mname, glyph = names[int(lun * 8 + 0.5) % 8]
    mr = safe(lambda: o.next_rising(m))
    ms = safe(lambda: o.next_setting(m))
    nf = ephem.localtime(ephem.next_full_moon(o.date)).strftime("%d %b")
    nn = ephem.localtime(nnm).strftime("%d %b")

    LBL = 11
    def lbl(g, name):
        s = f"{g} {name}"
        return s + " " * max(0, LBL - len(s))
    pad = " " * LBL

    out.append(col(AMB, lbl("☼", "SUN")) + col(GREY, "rise ") + col(BOLD, lt(sr)) +
               col(GREY, "   set ") + col(BOLD, lt(ss)) +
               (col(GREY, "   day ") + col(BOLD, daylen) if daylen else ""))
    out.append(pad + col(GREY, "night ") + col(NEON, f"{lt(dusk)} → {lt(dawn)}"))
    out.append("")
    out.append(col(VIO, lbl("☾", "MOON")) + col(GREY, "rise ") + col(BOLD, lt(mr)) +
               col(GREY, "   set ") + col(BOLD, lt(ms)) +
               col(GREY, "   ") + col(BOLD, f"{illum:.0f}%") + col(GREY, " lit"))
    out.append(pad + col(BOLD, mname) + " " + glyph + col(GREY, f"   full {nf} · new {nn}"))
    out.append("")
    out.append(col(PINK, f"{'▚ PLANETS':<10}") +
               col(GREY, f"{'rise':>6}{'set':>7}{'alt':>6}{'mag':>6}  tonight"))

    samples = [t for t in (dusk, mid, dawn) if t is not None]
    planets = [("MERCURY", ephem.Mercury), ("VENUS", ephem.Venus), ("MARS", ephem.Mars),
               ("JUPITER", ephem.Jupiter), ("SATURN", ephem.Saturn),
               ("URANUS", ephem.Uranus), ("NEPTUNE", ephem.Neptune)]
    for label, cls_ in planets:
        b = cls_()
        b.compute(o)
        alt_now = math.degrees(float(b.alt))
        mag = float(b.mag)
        rise = safe(lambda: o.next_rising(b))
        set_ = safe(lambda: o.next_setting(b))
        up_night = any(alt_deg(cls_, lat, lon, t) > 0 for t in samples) if samples else alt_now > 0
        if mag > 6.0:
            tag = col(GREY, "telescope")
        elif not up_night:
            tag = col(GREY, "—")
        else:
            when = "✓"
            if dusk and alt_deg(cls_, lat, lon, dusk) > 0:
                when = "✓ evening"
            elif dawn and alt_deg(cls_, lat, lon, dawn) > 0:
                when = "✓ morning"
            tag = col(LIME, when)
        alt_s = f"{alt_now:+.0f}°"
        mag_s = f"{mag:.1f}"
        out.append(col(BOLD, f"{label:<10}") +
                   col(GREY, f"{lt(rise):>6}{lt(set_):>7}") +
                   col(LIME if alt_now > 0 else GREY, f"{alt_s:>6}") +
                   col(GREY, f"{mag_s:>6}") + "  " + tag)

    return out


def setup_winch():
    """Self-pipe woken by SIGWINCH so the loop recenters the instant the terminal is resized/rotated,
    instead of waiting out the up-to-60s minute sleep. Returns (read_fd, resized_flag) or (None, flag)
    if signals aren't available here (e.g. not the main thread) — caller then falls back to time.sleep."""
    flag = {"v": False}
    try:
        r, w = os.pipe()
        os.set_blocking(r, False)
        os.set_blocking(w, False)
        signal.signal(signal.SIGWINCH, lambda *_: flag.__setitem__("v", True))
        signal.set_wakeup_fd(w)            # any signal also pokes the pipe → select() returns at once
        return r, flag
    except (ValueError, OSError, AttributeError):
        return None, flag                  # SIGWINCH/set_wakeup_fd unsupported → plain sleep fallback


def render(now, lat, lon, src, astro, ts):
    clock = big(now.strftime("%H:%M"))
    # rows tagged: "C" = centered within the block, "L" = left within the block, "HR" = rule
    rows = [("C", col(BOLD, col(NEON, r))) for r in clock]
    rows += [("C", "")] * 4                                    # a few lines between clock and info
    rows.append(("HR", ""))
    if lat is None:
        rows.append(("C", col(GREY, "◌ locating…")))
    else:
        rows += [("L", a) for a in astro]
        rows.append(("C", ""))
        rows.append(("HR", ""))      # same purple rule before the location footer
        place = _loc.get("place", "")
        where = f"  ·  {place}" if place else ""
        rows.append(("C", col(GREY, f"loc {src}  {lat:.3f}, {lon:.3f}{where}   ^C to quit")))

    blockW = max([vlen(p) for k, p in rows if k != "HR"] + [40])
    gm = " " * max(0, (ts.columns - blockW) // 2)   # center horizontally
    top = max(0, (ts.lines - len(rows)) // 2)        # center vertically
    # No [2J wipe: home the cursor and clear each line as we paint (per-line [K + trailing [J). This
    # fully covers a shrunk terminal with no stale glyphs AND no black flash on resize → smooth recenter.
    buf = E + "[H" + (E + "[K\n") * top
    for k, p in rows:
        if k == "HR":
            line = col(PINK, "═" * blockW)
        elif k == "C":
            line = " " * max(0, (blockW - vlen(p)) // 2) + p   # center within block
        else:
            line = p
        buf += gm + line + E + "[K\n"
    buf += E + "[J"
    sys.stdout.write(buf)
    sys.stdout.flush()


def main():
    sys.stdout.write(E + "[2J" + E + "[?25l")  # clear, hide cursor
    threading.Thread(target=locator, daemon=True).start()  # resolve location off the UI path
    wake_r, resized = setup_winch()
    astro, last_min, last_loc, last_size = [], None, None, None
    try:
        while True:
            now = ephem.localtime(ephem.now())
            lat, lon, src = _loc["lat"], _loc["lon"], _loc["src"]
            cur_loc = (lat, lon)
            ts = shutil.get_terminal_size((80, 24))
            size = (ts.columns, ts.lines)
            # recompute astronomy each new minute / on location change (the only expensive step)
            if lat is not None and (now.minute != last_min or cur_loc != last_loc):
                astro = build_astro(lat, lon, src)

            # repaint ONLY when something visible actually changed — minute, location, terminal geometry,
            # or a SIGWINCH (resize/rotate). Idle frames cost nothing, so resize feels instant + no flicker.
            if now.minute != last_min or cur_loc != last_loc or size != last_size or resized["v"]:
                resized["v"] = False
                render(now, lat, lon, src, astro, ts)
                last_min, last_loc, last_size = now.minute, cur_loc, size

            # SIGWINCH (via wake_r) breaks the wait instantly for resize/rotate; the short cap is just a
            # belt-and-suspenders poll (≤1.5s) so geometry still recenters if a winch is ever missed.
            timeout = 1 if lat is None else max(1, min(1.5, 60 - now.second))
            if wake_r is not None:
                try:
                    if select.select([wake_r], [], [], timeout)[0]:
                        try:
                            while os.read(wake_r, 4096):  # drain pending signal bytes
                                pass
                        except BlockingIOError:
                            pass
                except InterruptedError:
                    pass
            else:
                time.sleep(timeout)
    except KeyboardInterrupt:
        sys.stdout.write(E + "[?25h" + E + "[2J" + E + "[H")
        sys.exit(0)


if __name__ == "__main__":
    main()
