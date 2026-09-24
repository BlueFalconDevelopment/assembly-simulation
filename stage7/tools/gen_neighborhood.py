#!/usr/bin/env python3
"""Generate the neighborhood's map data (13_neighborhood.asm, 14_events.asm), and check the map.

The neighborhood is laid out here, in Python, because it is data: a few
dozen rectangles for collision and a few hundred coloured rectangles for
the look. This script checks the layout (every walkable spot reachable,
both lobbies fit 50 soldiers, pickups on open ground), then prints the
NASM data block that goes between the MAP DATA markers in the .asm:

    python3 tools/gen_neighborhood.py --write 13_neighborhood.asm
    python3 tools/gen_neighborhood.py --preview hood.png   # needs PIL
"""
import sys, random
from collections import deque

W, H, SZ, CELL = 1280, 720, 16, 9

# ---- ground: drawing only ----
streets = [(0, 330, 1280, 60), (300, 0, 50, 720), (900, 0, 50, 720), (350, 600, 550, 40)]
SIDEWALK = 10
lot = (395, 200, 470, 115)               # parking lot, lighter asphalt

# ---- solid buildings: block walking AND bullets ----
buildings = [
    (40, 40, 110, 110), (170, 60, 100, 90), (40, 200, 90, 100), (160, 200, 110, 90),   # houses
    (400, 40, 200, 140), (650, 40, 220, 100),                                          # store, offices
    (380, 420, 150, 150), (560, 420, 120, 90), (720, 420, 150, 150),                   # centre-south
    (370, 665, 100, 45), (500, 665, 120, 45), (650, 665, 100, 45), (780, 665, 100, 45),  # row houses
    (990, 430, 120, 110), (1140, 430, 110, 160), (990, 590, 120, 100),                 # SE block
]

# ---- apartment complexes: outer rect, wall thickness, doors (side, offset, length) ----
complexes = {
    'west': ((30, 410, 250, 290), 10, [('n', 90, 40), ('e', 110, 40)]),
    'east': ((970, 30, 270, 270), 10, [('s', 110, 40), ('w', 100, 40)]),
}

# ---- props: low cover, block walking but not bullets ----
cars = [(420, 215, 40, 20), (480, 215, 40, 20), (600, 215, 40, 20), (720, 215, 40, 20), (780, 215, 40, 20),
        (420, 275, 40, 20), (540, 275, 40, 20), (660, 275, 40, 20), (820, 275, 40, 20),
        (640, 607, 40, 20)]
# (14 took the cars that were parked on the avenue and the two cross
# streets off the map: the police car drives those lanes.)
dumpsters = [(540, 540, 26, 16), (690, 540, 26, 16), (1115, 610, 16, 26), (180, 300, 26, 16), (880, 150, 16, 26)]
fences = [(390, 195, 480, 4), (390, 315, 4, 15), (866, 199, 4, 116), (150, 160, 4, 40), (1120, 560, 4, 30)]

# ---- weapon pickups: x, y, type (1 pistol, 2 shotgun) ----
pickups = [(320, 300, 1), (330, 410, 2), (200, 360, 1), (90, 340, 2), (560, 350, 1), (700, 360, 2),
           (470, 580, 1), (620, 620, 2), (930, 410, 1), (1000, 360, 2), (1100, 320, 1), (1200, 400, 2),
           (760, 300, 2), (520, 300, 1), (310, 560, 2), (925, 150, 1)]

# ---- colours: 0xAABBGGRR, as the game's RGBA32 pixels are stored ----
def rgb(r, g, b): return 0xFF000000 | (b << 16) | (g << 8) | r
C = dict(grass=rgb(96, 140, 78), grass_dark=rgb(70, 115, 60), sidewalk=rgb(170, 170, 165),
         asphalt=rgb(60, 60, 64), lot=rgb(80, 80, 84), paint=rgb(220, 220, 220), lane=rgb(230, 200, 60),
         border=rgb(55, 50, 48), roof=rgb(120, 105, 95), roof2=rgb(105, 92, 84), vent=rgb(160, 160, 165),
         ridge=rgb(90, 78, 70), floor=rgb(200, 190, 170), tile=rgb(185, 175, 155), mat=rgb(150, 120, 90),
         glass=rgb(50, 60, 80), dump=rgb(40, 90, 50), dump_lid=rgb(30, 65, 38),
         fence=rgb(140, 100, 60), post=rgb(100, 70, 40), tree=rgb(50, 105, 50))
CAR_COLOURS = [rgb(200, 200, 210), rgb(170, 40, 40), rgb(40, 70, 150), rgb(220, 200, 70), rgb(120, 50, 140),
               rgb(230, 230, 230), rgb(90, 140, 90), rgb(150, 90, 40)]


def complex_walls(rect, t, doors):
    x, y, w, h = rect
    out = []
    sides = {'n': (x, y, w, True), 's': (x, y + h - t, w, True), 'w': (x, y, h, False), 'e': (x + w - t, y, h, False)}
    for sd, (sx, sy, L, horiz) in sides.items():
        pos, segs = 0, []
        for a, l in sorted((a, l) for s, a, l in doors if s == sd):
            segs.append((pos, a)); pos = a + l
        segs.append((pos, L))
        for a, b in segs:
            if b > a:
                out.append((sx + a, sy, b - a, t) if horiz else (sx, sy + a, t, b - a))
    return out


def door_rects(rect, t, doors):
    x, y, w, h = rect
    out = []
    for s, a, l in doors:
        out.append({'n': (x + a, y, l, t), 's': (x + a, y + h - t, l, t),
                    'w': (x, y + a, t, l), 'e': (x + w - t, y + a, t, l)}[s])
    return out


def interior(rect, t):
    x, y, w, h = rect
    return (x + t, y + t, w - 2 * t, h - 2 * t)


cwalls = {k: complex_walls(*v) for k, v in complexes.items()}
walls = buildings + cwalls['west'] + cwalls['east']
props = cars + dumpsters + fences
solid = walls + props


def box_blocked(x, y, rects):
    if x < 0 or y < 0 or x + SZ > W or y + SZ > H:
        return True
    return any(x + SZ > a and x < a + c and y + SZ > b and y < b + d for a, b, c, d in rects)


def check():
    for i, a in enumerate(solid):
        for b in solid[i + 1:]:
            if a[0] < b[0] + b[2] and b[0] < a[0] + a[2] and a[1] < b[1] + b[3] and b[1] < a[1] + a[3]:
                if not (a in walls and b in walls):
                    raise SystemExit(f"overlap {a} {b}")
    GW, GH = (W - SZ + CELL - 1) // CELL + 1, (H - SZ + CELL - 1) // CELL + 1
    rng = lambda k, hi: (max(CELL * k - 8, 0), min(CELL * k, hi))
    walk = [[False] * GW for _ in range(GH)]
    for cy in range(GH):
        y0, y1 = rng(cy, H - SZ)
        for cx in range(GW):
            x0, x1 = rng(cx, W - SZ)
            walk[cy][cx] = not any(x1 + SZ > a and x0 < a + c and y1 + SZ > b and y0 < b + d for a, b, c, d in solid)
    cells = [(cx, cy) for cy in range(GH) for cx in range(GW) if walk[cy][cx]]
    seen = {cells[0]}; q = deque([cells[0]])
    while q:
        x, y = q.popleft()
        for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            a, b = x + dx, y + dy
            if 0 <= a < GW and 0 <= b < GH and walk[b][a] and (a, b) not in seen:
                seen.add((a, b)); q.append((a, b))
    assert len(seen) == len(cells), f"{len(cells) - len(seen)} walkable cells unreachable"
    for p in pickups:
        assert not box_blocked(p[0], p[1], solid), f"pickup in something: {p}"
    random.seed(1)
    worst = 0
    for k, v in complexes.items():
        ix, iy, iw, ih = interior(v[0], v[1])
        x0, y0, x1, y1 = ix + 2, iy + 2, ix + iw - SZ - 2, iy + ih - SZ - 2
        for _ in range(300):
            placed = []
            for n in range(50):
                tries = 0
                while True:
                    tries += 1
                    x, y = random.randint(x0, x1), random.randint(y0, y1)
                    if all(abs(x - a) >= 20 or abs(y - b) >= 20 for a, b in placed):
                        break
                    assert tries < 100000, f"{k} lobby jams"
                placed.append((x, y)); worst = max(worst, tries)
    return len(cells), worst


def dressing():
    """Coloured rectangles, drawn in order into the background once."""
    r = [(0, 0, W, H, C['grass'])]
    for x, y, w, h in [(40, 320 - 6, 6, 6)]:
        pass
    # trees / bushes on the grass (drawing only)
    for x, y in [(200, 20), (60, 170), (290 - 30, 300), (620, 150), (950 + 20, 330 - 30), (1255, 320),
                 (360, 400), (540, 575), (700, 590), (880, 560), (1255, 420), (1130, 700), (15, 395)]:
        r.append((x, y, 14, 14, C['tree']))
    for x, y, w, h in streets:
        r.append((max(x - SIDEWALK, 0), max(y - SIDEWALK, 0), w + 2 * SIDEWALK, h + 2 * SIDEWALK, C['sidewalk']))
    for x, y, w, h in streets:
        r.append((x, y, w, h, C['asphalt']))
    lx, ly, lw, lh = lot
    r.append((lx, ly, lw, lh, C['lot']))
    for sx in range(lx + 15, lx + lw - 10, 60):          # parking stall lines
        r.append((sx, ly + 5, 2, 30, C['paint']))
        r.append((sx, ly + lh - 35, 2, 30, C['paint']))
    # lane dashes, skipping intersections
    def in_street(x, y):
        return any(a <= x < a + c and b <= y < b + d for a, b, c, d in streets[1:3])
    for x in range(10, W, 40):
        if not in_street(x + 10, 359):
            r.append((x, 358, 20, 3, C['lane']))
    for cx in (324, 924):
        for y in range(10, H, 40):
            if not (330 <= y + 10 < 390):
                r.append((cx, y, 3, 20, C['lane']))
    # crosswalks where the side streets meet the avenue
    for sx in (300, 900):
        for y in (318, 392):
            for k in range(0, 50, 8):
                r.append((sx + k + 2, y, 4, 10, C['paint']))
    # buildings: dark edge, roof, vents or a ridge
    for i, (x, y, w, h) in enumerate(buildings):
        r.append((x, y, w, h, C['border']))
        r.append((x + 3, y + 3, w - 6, h - 6, C['roof'] if i % 2 == 0 else C['roof2']))
        if h < 60:                                        # row houses: a ridge line
            r.append((x + 3, y + h // 2 - 1, w - 6, 2, C['ridge']))
        else:
            r.append((x + w // 4, y + h // 4, 12, 10, C['vent']))
            r.append((x + w - w // 3, y + h - h // 3, 10, 12, C['vent']))
    # complex lobbies: floor, tile lines, door mats (the walls are drawn
    # at run time, in the colour of whichever gang lives there)
    for k, (rect, t, doors) in complexes.items():
        ix, iy, iw, ih = interior(rect, t)
        r.append((ix, iy, iw, ih, C['floor']))
        for tx in range(ix + 25, ix + iw, 25):
            r.append((tx, iy, 1, ih, C['tile']))
        for ty in range(iy + 25, iy + ih, 25):
            r.append((ix, ty, iw, 1, C['tile']))
        for dr in door_rects(rect, t, doors):
            r.append(dr + (C['mat'],))
    # props
    for i, (x, y, w, h) in enumerate(cars):
        r.append((x, y, w, h, CAR_COLOURS[i % len(CAR_COLOURS)]))
        if w > h:
            r.append((x + 8, y + 3, 6, h - 6, C['glass'])); r.append((x + w - 12, y + 3, 5, h - 6, C['glass']))
        else:
            r.append((x + 3, y + 8, w - 6, 6, C['glass'])); r.append((x + 3, y + h - 12, w - 6, 5, C['glass']))
    for x, y, w, h in dumpsters:
        r.append((x, y, w, h, C['dump']))
        if w > h: r.append((x, y + h // 2 - 1, w, 2, C['dump_lid']))
        else: r.append((x + w // 2 - 1, y, 2, h, C['dump_lid']))
    for x, y, w, h in fences:
        r.append((x, y, w, h, C['fence']))
        if w > h:
            for px in range(x, x + w, 16): r.append((px, y - 1, 3, h + 2, C['post']))
        else:
            for py in range(y, y + h, 16): r.append((x - 1, py, w + 2, 3, C['post']))
    return r


def nasm():
    out = [";; ---- MAP DATA (generated by tools/gen_neighborhood.py; don't edit by hand) ----"]
    def block(name, rows, fmt, comment):
        out.append(f"    ; {comment}")
        out.append(f"    {name}:")
        for row in rows:
            out.append("        dd " + fmt(row))
        out.append(f"    {name}_count equ ($ - {name}) / {4 * len(rows[0]) if not isinstance(rows[0], int) else 4}")
    block("map_walls", walls, lambda t: ", ".join(map(str, t)), "walls: x, y, w, h (buildings, then both complexes' walls)")
    block("map_props", props, lambda t: ", ".join(map(str, t)), "low cover: x, y, w, h (cars, dumpsters, fences)")
    for k in ('west', 'east'):
        block(f"cwalls_{k}", cwalls[k], lambda t: ", ".join(map(str, t)), f"the {k} complex's walls, drawn in its gang's colour")
    out.append("    ; lobby interiors: x, y, w, h (spawn and respawn areas), west then east")
    out.append("    lobbies:")
    for k in ('west', 'east'):
        out.append("        dd " + ", ".join(map(str, interior(*complexes[k][:2]))))
    block("map_pickups", pickups, lambda t: ", ".join(map(str, t)), "weapon pickups: x, y, type")
    d = dressing()
    block("bg_rects", d, lambda t: ", ".join(map(str, t[:4])) + f", 0x{t[4]:08X}", "the look: x, y, w, h, colour, drawn in order")
    out.append(";; ---- END MAP DATA ----")
    return "\n".join(out)


def preview(path):
    from PIL import Image
    im = Image.new("RGBA", (W, H))
    px = im.load()
    for x, y, w, h, c in dressing() + [t + ((0xFFDC783C if k == 'west' else 0xFF3C3CDC),) for k in ('west', 'east') for t in cwalls[k]]:
        col = (c & 0xFF, (c >> 8) & 0xFF, (c >> 16) & 0xFF, 255)
        for yy in range(max(y, 0), min(y + h, H)):
            for xx in range(max(x, 0), min(x + w, W)):
                px[xx, yy] = col
    im.save(path)


if __name__ == "__main__":
    n, worst = check()
    print(f"ok: {n} walkable cells, all connected; worst lobby spawn {worst} tries; "
          f"{len(walls)} walls, {len(props)} props, {len(dressing())} background rects", file=sys.stderr)
    if len(sys.argv) > 2 and sys.argv[1] == "--write":
        src = open(sys.argv[2]).read()
        a, b = src.index(";; ---- MAP DATA"), src.index(";; ---- END MAP DATA ----") + len(";; ---- END MAP DATA ----")
        open(sys.argv[2], "w").write(src[:a] + nasm() + src[b:])
    elif len(sys.argv) > 2 and sys.argv[1] == "--preview":
        preview(sys.argv[2])
    else:
        print(nasm())
