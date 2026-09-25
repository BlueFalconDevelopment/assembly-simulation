#!/usr/bin/env python3
"""Generate the neighborhood's map data (stage7/13+, stage8), and check the map.

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
         fence=rgb(140, 100, 60), post=rgb(100, 70, 40), tree=rgb(50, 105, 50),
         grass_light=rgb(112, 156, 90), joint=rgb(150, 150, 146), grain_light=rgb(72, 72, 76),
         grain_dark=rgb(50, 50, 54), chimney=rgb(130, 70, 55), roof_grain=rgb(100, 88, 80),
         ac=rgb(170, 170, 175), ac_edge=rgb(110, 110, 115), ac_fan=rgb(70, 70, 75), ac_hub=rgb(40, 40, 45),
         hinge=rgb(70, 70, 70), handle=rgb(160, 160, 160), wheel=rgb(20, 20, 20), rust=rgb(130, 70, 40),
         chain=rgb(150, 155, 160), chain_dark=rgb(95, 100, 105), chain_post=rgb(80, 85, 90),
         leaf_edge=rgb(30, 70, 30), leaf=rgb(60, 120, 50), leaf_light=rgb(100, 160, 70), leaf_dark=rgb(40, 90, 40),
         lamp_pole=rgb(90, 90, 95), lamp_arm=rgb(120, 120, 125), lamp_housing=rgb(60, 60, 65),
         lamp_glass=rgb(250, 240, 190))
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


# ---- decoration, 8.03: drawing only, checked to sit on open ground ----
trees = [(8, 8), (152, 5), (262, 5), (8, 165), (122, 168), (360, 5), (610, 150), (5, 405),
         (575, 520), (695, 562), (474, 660), (755, 660), (1115, 400), (1150, 620), (1250, 650)]
bushes = [(8, 300), (275, 160), (605, 183), (1250, 290), (962, 405), (540, 402), (880, 560), (132, 305)]
lamps = [(60, 321), (220, 321), (460, 321), (620, 321), (780, 321), (1040, 321), (1200, 321),
         (140, 391), (540, 391), (700, 391), (860, 391), (1000, 391), (1160, 391),
         (291, 150), (291, 520), (351, 250), (351, 460), (891, 60), (891, 520), (951, 250), (951, 470)]
SHADOW = dict(building=7, cwall=4, car=3, dumpster=3, fence=2, tree=5, bush=3, lamp=4)


def sidewalk_rects():
    return [(max(x - SIDEWALK, 0), max(y - SIDEWALK, 0), w + 2 * SIDEWALK, h + 2 * SIDEWALK) for x, y, w, h in streets]


def overlaps(a, b):
    return a[0] < b[0] + b[2] and b[0] < a[0] + a[2] and a[1] < b[1] + b[3] and b[1] < a[1] + a[3]


def check_decor():
    """trees and bushes on open ground; lamps on a sidewalk, off the road"""
    cplx = [v[0] for v in complexes.values()]
    blocked = buildings + cplx + sidewalk_rects() + [lot] + props
    for x, y in trees:
        for b in blocked:
            assert not overlaps((x, y, 22, 22), b), f"tree at {x},{y} overlaps {b}"
    for x, y in bushes:
        for b in blocked:
            assert not overlaps((x, y, 10, 10), b), f"bush at {x},{y} overlaps {b}"
    for x, y in lamps:
        r = (x, y, 8, 8)
        assert any(overlaps(r, sw) for sw in sidewalk_rects()), f"lamp at {x},{y} isn't on a sidewalk"
        for st in streets:
            assert not overlaps(r, st), f"lamp at {x},{y} is on the road"
        for b in buildings + cplx + props:
            assert not overlaps(r, b), f"lamp at {x},{y} overlaps {b}"


def runs(grid, pal, ox, oy, out):
    """emit a pixel grid as runs of same-coloured pixels (0 = skip)"""
    for yy, row in enumerate(grid):
        xx = 0
        while xx < len(row):
            v, run = row[xx], xx
            while run < len(row) and row[run] == v:
                run += 1
            if v and pal.get(v):
                out.append((ox + xx, oy + yy, run - xx, 1, pal[v]))
            xx = run


def dressing():
    """(ground, shadows, objects): coloured rectangles drawn in order
    into the background; shadows darken what's under them, and go
    between the ground and the objects so nothing darkens itself"""
    from gen_sprites import (CAR_ART, CAR_LETTERS, art_grid, rotate_cw, prop_grids)
    P = prop_grids()
    rnd = random.Random(8003)                      # fixed: the same speckles every build
    ground, shadows, objs = [(0, 0, W, H, C['grass'])], [], []
    sws = sidewalk_rects()
    cplx = [v[0] for v in complexes.values()]
    # grass speckles, only on grass
    not_grass = buildings + cplx + sws + [lot]
    n = 0
    while n < 2600:
        x, y = rnd.randrange(W), rnd.randrange(H)
        if any(a <= x < a + c and b <= y < b + d for a, b, c, d in not_grass):
            continue
        ground.append((x, y, 1 + rnd.randrange(2), 1, C['grass_dark'] if rnd.random() < 0.6 else C['grass_light']))
        n += 1
    for r in sws:
        ground.append(r + (C['sidewalk'],))
    for x, y, w, h in sws:                         # sidewalk joints
        if w > h:
            for jx in range(x + 20, x + w, 20):
                ground.append((jx, y, 1, h, C['joint']))
        else:
            for jy in range(y + 20, y + h, 20):
                ground.append((x, jy, w, 1, C['joint']))
    for x, y, w, h in streets:
        ground.append((x, y, w, h, C['asphalt']))
    lx, ly, lw, lh = lot
    ground.append((lx, ly, lw, lh, C['lot']))
    road = streets + [lot]
    n = 0
    while n < 1400:                                # asphalt grain
        x, y = rnd.randrange(W), rnd.randrange(H)
        if not any(a <= x < a + c and b <= y < b + d for a, b, c, d in road):
            continue
        ground.append((x, y, 1, 1, C['grain_light'] if rnd.random() < 0.5 else C['grain_dark']))
        n += 1
    for sx in range(lx + 15, lx + lw - 10, 60):    # parking stall lines
        ground.append((sx, ly + 5, 2, 30, C['paint']))
        ground.append((sx, ly + lh - 35, 2, 30, C['paint']))
    def in_street(x, y):
        return any(a <= x < a + c and b <= y < b + d for a, b, c, d in streets[1:3])
    for x in range(10, W, 40):                     # lane dashes
        if not in_street(x + 10, 359):
            ground.append((x, 358, 20, 3, C['lane']))
    for cx in (324, 924):
        for y in range(10, H, 40):
            if not (330 <= y + 10 < 390):
                ground.append((cx, y, 3, 20, C['lane']))
    for sx in (300, 900):                          # crosswalks
        for y in (318, 392):
            for k in range(0, 50, 8):
                ground.append((sx + k + 2, y, 4, 10, C['paint']))
    for k, (rect, t, doors) in complexes.items():  # lobby floors
        ix, iy, iw, ih = interior(rect, t)
        ground.append((ix, iy, iw, ih, C['floor']))
        for tx in range(ix + 25, ix + iw, 25):
            ground.append((tx, iy, 1, ih, C['tile']))
        for ty in range(iy + 25, iy + ih, 25):
            ground.append((ix, ty, iw, 1, C['tile']))
        for dr in door_rects(rect, t, doors):
            ground.append(dr + (C['mat'],))

    # ---- shadows: the caster shifted down-right (light from the top left) ----
    def cast(r, d):
        shadows.append((r[0] + d, r[1] + d, r[2], r[3]))
    for b in buildings:
        cast(b, SHADOW['building'])
    for k in complexes:
        for wr in cwalls[k]:
            cast(wr, SHADOW['cwall'])
    for c_ in cars:
        cast(c_, SHADOW['car'])
    for d_ in dumpsters:
        cast(d_, SHADOW['dumpster'])
    for f in fences:
        cast(f, SHADOW['fence'])
    for key, pts, d in (('tree', trees, SHADOW['tree']), ('bush', bushes, SHADOW['bush']), ('light', lamps, SHADOW['lamp'])):
        mask = [[1 if v else 0 for v in row] for row in P[key]]
        tmp = []
        runs(mask, {1: 1}, 0, 0, tmp)
        for x, y in pts:
            for rx, ry, rw, rh, _ in tmp:
                shadows.append((x + rx + d, y + ry + d, rw, rh))

    # ---- objects ----
    for i, (x, y, w, h) in enumerate(buildings):
        objs.append((x, y, w, h, C['border']))
        objs.append((x + 3, y + 3, w - 6, h - 6, C['roof'] if i % 2 == 0 else C['roof2']))
        if h < 60:                                 # row houses: a ridge, and a chimney
            objs.append((x + 3, y + h // 2 - 1, w - 6, 2, C['ridge']))
            objs.append((x + w - 20, y + 8, 8, 8, C['chimney']))
            objs.append((x + w - 19, y + 9, 6, 6, C['border']))
        else:                                      # roof grain, and AC units
            for _ in range(w * h // 180):
                gx, gy = x + 4 + rnd.randrange(w - 8), y + 4 + rnd.randrange(h - 8)
                objs.append((gx, gy, 1, 1, C['roof_grain']))
            acp = {1: C['ac'], 2: C['ac_edge'], 3: C['ac_fan'], 4: C['ac_hub']}
            runs(P['ac'], acp, x + w // 4, y + h // 4, objs)
            if w >= 120:
                runs(P['ac'], acp, x + w - w // 3, y + h - h // 3 - 4, objs)
    car = art_grid(CAR_ART, CAR_LETTERS, 40, 20)
    for i, (x, y, w, h) in enumerate(cars):        # cars, as in 8.02
        body = CAR_COLOURS[i % len(CAR_COLOURS)]
        br, bg, bb = body & 0xFF, (body >> 8) & 0xFF, (body >> 16) & 0xFF
        edge = rgb(br * 3 // 5, bg * 3 // 5, bb * 3 // 5)
        pal = {1: body, 2: edge, 3: C['glass'], 4: rgb(80, 100, 130), 5: rgb(200, 30, 30),
               6: rgb(255, 240, 180), 7: rgb(15, 15, 15)}
        g = car if w > h else rotate_cw(car)
        assert (len(g[0]), len(g)) == (w, h), f"car {x},{y} isn't {len(g[0])}x{len(g)}"
        runs(g, pal, x, y, objs)
    dpal = {1: C['dump'], 2: C['dump_lid'], 3: C['hinge'], 4: C['handle'], 5: C['wheel'], 6: C['rust']}
    for x, y, w, h in dumpsters:                   # dumpsters
        g = P['dumpster'] if w > h else rotate_cw(P['dumpster'])
        g = [row[:w] for row in g[:h]]
        runs(g, dpal, x, y, objs)
    for fi, (x, y, w, h) in enumerate(fences):     # fences
        chain = fi < 3                             # the parking lot's
        base, post = (C['chain'], C['chain_post']) if chain else (C['fence'], C['post'])
        objs.append((x, y, w, h, base))
        if chain:                                  # chain-link: a diamond weave
            if w > h:
                for px in range(x, x + w, 2):
                    objs.append((px, y + (px // 2) % 2 * 2, 1, 2, C['chain_dark']))
            else:
                for py in range(y, y + h, 2):
                    objs.append((x + (py // 2) % 2 * 2, py, 2, 1, C['chain_dark']))
        step = 24 if chain else 16
        if w > h:
            for px in range(x, x + w, step):
                objs.append((px, y - 1, 3, h + 2, post))
        else:
            for py in range(y, y + h, step):
                objs.append((x - 1, py, w + 2, 3, post))
    tpal = {1: C['leaf_edge'], 2: C['leaf'], 3: C['leaf_light'], 4: C['leaf_dark']}
    for x, y in trees:
        runs(P['tree'], tpal, x, y, objs)
    for x, y in bushes:
        runs(P['bush'], tpal, x, y, objs)
    lpal = {1: C['lamp_pole'], 2: C['lamp_arm'], 3: C['lamp_housing'], 4: C['lamp_glass']}
    for x, y in lamps:
        runs(P['light'], lpal, x, y, objs)
    return ground, shadows, objs


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
    ground, shadows, objs = dressing()
    col = lambda t: ", ".join(map(str, t[:4])) + f", 0x{t[4]:08X}"
    block("bg_ground", ground, col, "the look, layer 1: ground (x, y, w, h, colour), drawn in order")
    block("bg_shadows", shadows, lambda t: ", ".join(map(str, t)), "layer 2: shadows (x, y, w, h): darken what's there")
    block("bg_objects", objs, col, "layer 3: buildings, cars, dumpsters, fences, trees, lamps")
    block("street_lamps", lamps, lambda t: ", ".join(map(str, t)), "streetlights: x, y (their 8x8 heads), for the night (8.05)")
    doors = [(x + w // 2, y + h // 2) for k in ('west', 'east') for x, y, w, h in door_rects(*complexes[k])]
    block("door_lights", doors, lambda t: ", ".join(map(str, t)), "complex doorways: centre x, y, where lobby light spills out (8.05)")
    out.append(";; ---- END MAP DATA ----")
    return "\n".join(out)


def preview(path):
    from PIL import Image
    im = Image.new("RGBA", (W, H))
    px = im.load()
    ground, shadows, objs = dressing()
    def fill(x, y, w, h, c):
        col = (c & 0xFF, (c >> 8) & 0xFF, (c >> 16) & 0xFF, 255)
        for yy in range(max(y, 0), min(y + h, H)):
            for xx in range(max(x, 0), min(x + w, W)):
                px[xx, yy] = col
    for t in ground:
        fill(*t)
    for x, y, w, h in shadows:
        for yy in range(max(y, 0), min(y + h, H)):
            for xx in range(max(x, 0), min(x + w, W)):
                r, g, b, a = px[xx, yy]
                px[xx, yy] = (r * 5 // 8, g * 5 // 8, b * 5 // 8, a)
    for t in objs + [t + ((0xFFDC783C if k == 'west' else 0xFF3C3CDC),) for k in ('west', 'east') for t in cwalls[k]]:
        fill(*t)
    im.save(path)


if __name__ == "__main__":
    n, worst = check()
    check_decor()
    g_, s_, o_ = dressing()
    print(f"ok: {n} walkable cells, all connected; worst lobby spawn {worst} tries; "
          f"{len(walls)} walls, {len(props)} props; background {len(g_)} ground + {len(s_)} shadow + {len(o_)} object rects",
          file=sys.stderr)
    if len(sys.argv) > 2 and sys.argv[1] == "--write":
        src = open(sys.argv[2]).read()
        a, b = src.index(";; ---- MAP DATA"), src.index(";; ---- END MAP DATA ----") + len(";; ---- END MAP DATA ----")
        open(sys.argv[2], "w").write(src[:a] + nasm() + src[b:])
    elif len(sys.argv) > 2 and sys.argv[1] == "--preview":
        preview(sys.argv[2])
    else:
        print(nasm())
