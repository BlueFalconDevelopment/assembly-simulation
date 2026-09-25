#!/usr/bin/env python3
"""Generate the stand-in city (stage 9.01): stage 8's neighborhood,
tiled 4 x 4 into a 5120 x 2880 world.

It's a test map for the bigger world, until the real one is built. The
two apartment complexes the gangs live in are the west one in tile
(1, 1) and the east one in tile (2, 2), so they're about equally far
from the middle of the map. Every other complex is a plain building.
Pickups lie only in the four middle tiles, where the gangs meet.

Output, both in maps/:
    standin.inc      NASM: the map's size and name, walls, props,
                     lobbies, pickups, lamps, doors, police routes and
                     dog walks, and incbin lines for the background
    standin_bg.bin   the background's three layers of rectangles, as
                     raw little-endian dwords (too many for NASM text)

    python3 tools/gen_standin.py              # check, write maps/
    python3 tools/gen_standin.py --preview x.png
"""
import os, struct, sys, random
from collections import deque

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_neighborhood as g

TW, TH = g.W, g.H                     # one tile: the old neighborhood
COLS, ROWS = 4, 4
W, H = TW * COLS, TH * ROWS
SZ, CELL = g.SZ, g.CELL
HOMES = {(1, 1): 'west', (2, 2): 'east'}          # tile -> kept complex
PICKUP_TILES = {(1, 1), (2, 1), (1, 2), (2, 2)}
COP_SPEED = "COP_SPEED"                           # the .asm's constant

ORIG = dict(buildings=g.buildings, complexes=g.complexes)


def variant(keep):
    """dress one tile with only the complexes in keep; the others become
    plain buildings. Returns the tile's lists, in tile coordinates."""
    cplx = {k: v for k, v in ORIG['complexes'].items() if k in keep}
    converted = [v[0] for k, v in ORIG['complexes'].items() if k not in keep]
    g.complexes = cplx
    g.buildings = ORIG['buildings'] + converted
    g.cwalls = {k: g.complex_walls(*v) for k, v in cplx.items()}
    g.check_decor()
    ground, shadows, objs = g.dressing()
    return dict(buildings=list(g.buildings), cwalls=dict(g.cwalls), complexes=cplx,
                ground=ground, shadows=shadows, objs=objs)


def shift(rects, dx, dy):
    return [(r[0] + dx, r[1] + dy) + tuple(r[2:]) for r in rects]


def build():
    cache = {}
    tiles = []
    for r in range(ROWS):
        for c in range(COLS):
            keep = HOMES.get((c, r))
            if keep not in cache:
                cache[keep] = variant({keep} if keep else set())
            tiles.append((c, r, cache[keep]))
    m = dict(walls=[], props=[], cwalls={}, lobbies={}, doors=[], pickups=[], lamps=[],
             ground=[], shadows=[], objs=[])
    for c, r, v in tiles:
        dx, dy = c * TW, r * TH
        m['walls'] += shift(v['buildings'], dx, dy)
        m['props'] += shift(g.props, dx, dy)
        m['lamps'] += shift(g.lamps, dx, dy)
        if (c, r) in PICKUP_TILES:
            m['pickups'] += shift(g.pickups, dx, dy)
        for k, (rect, t, doors) in v['complexes'].items():
            m['cwalls'][k] = shift(v['cwalls'][k], dx, dy)
            m['lobbies'][k] = shift([g.interior(rect, t)], dx, dy)[0]
            m['doors'] += [(x + w // 2 + dx, y + h // 2 + dy) for x, y, w, h in g.door_rects(rect, t, doors)]
    # the layers go down one at a time across the whole map, so a shadow
    # cast over a tile edge isn't painted over by the next tile's ground
    for layer in ('ground', 'shadows', 'objs'):
        for c, r, v in tiles:
            m[layer] += shift(v[layer], c * TW, r * TH)
    m['walls'] += m['cwalls']['west'] + m['cwalls']['east']
    # police lanes: every avenue and cross street, each way (the tile's
    # lanes, as in 14, repeated across the map)
    routes = []
    for r in range(ROWS):
        routes.append((-40, 363 + r * TH, 40, 20, COP_SPEED, 0))
        routes.append((W, 337 + r * TH, 40, 20, "-" + COP_SPEED, 0))
    for c in range(COLS):
        for sx in (300, 900):
            x = sx + c * TW
            routes.append((x + 3, -40, 20, 40, 0, COP_SPEED))
            routes.append((x + 27, H, 20, 40, 0, "-" + COP_SPEED))
    m['routes'] = routes
    m['walks'] = [w for r in range(ROWS) for w in ((-40, 320 + r * TH, 1), (W + 20, 390 + r * TH, -1))]
    return m


def check(m):
    solid = m['walls'] + m['props']
    for p in m['walls'] + m['props'] + [(x, y, 16, 1) for x, y, _ in m['pickups']]:
        assert 0 <= p[0] and p[0] + p[2] <= W and 0 <= p[1] and p[1] + p[3] <= H, f"off the map: {p}"
    # buckets of 128 px, so each cell only tests the rects near it
    B = 128
    buckets = {}
    for rc in solid:
        x, y, w, h = rc
        for by in range(y // B, (y + h) // B + 1):
            for bx in range(x // B, (x + w) // B + 1):
                buckets.setdefault((bx, by), []).append(rc)
    def box_hits(x0, y0, x1, y1):     # any solid over [x0, x1) x [y0, y1)?
        seen = set()
        for by in range(y0 // B, (y1 - 1) // B + 1):
            for bx in range(x0 // B, (x1 - 1) // B + 1):
                for rc in buckets.get((bx, by), ()):
                    if rc in seen:
                        continue
                    seen.add(rc)
                    a, b, c, d = rc
                    if x1 > a and x0 < a + c and y1 > b and y0 < b + d:
                        return True
        return False
    GW, GH = (W - SZ + CELL - 1) // CELL + 1, (H - SZ + CELL - 1) // CELL + 1
    rng = lambda k, hi: (max(CELL * k - 8, 0), min(CELL * k, hi))
    walk = bytearray(GW * GH)
    for cy in range(GH):
        y0, y1 = rng(cy, H - SZ)
        for cx in range(GW):
            x0, x1 = rng(cx, W - SZ)
            walk[cy * GW + cx] = not box_hits(x0, y0, x1 + SZ, y1 + SZ)
    cells = [i for i in range(GW * GH) if walk[i]]
    seen = bytearray(GW * GH)
    seen[cells[0]] = 1
    q = deque([cells[0]])
    n = 1
    while q:
        i = q.popleft()
        x, y = i % GW, i // GW
        for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            a, b = x + dx, y + dy
            if 0 <= a < GW and 0 <= b < GH and walk[b * GW + a] and not seen[b * GW + a]:
                seen[b * GW + a] = 1; q.append(b * GW + a); n += 1
    assert n == len(cells), f"{len(cells) - n} walkable cells unreachable"
    for x, y, _ in m['pickups']:
        assert not box_hits(x, y, x + SZ, y + SZ), f"pickup in something: {x},{y}"
    return GW, GH, len(cells)


def write(m):
    here = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "maps")
    blob = bytearray()
    offs = {}
    for name, key, fmt in (("bg_ground", 'ground', '<iiiiI'), ("bg_shadows", 'shadows', '<iiii'),
                           ("bg_objects", 'objs', '<iiiiI')):
        offs[name] = (len(blob), len(m[key]), struct.calcsize(fmt))
        for t in m[key]:
            blob += struct.pack(fmt, *t)
    open(os.path.join(here, "standin_bg.bin"), "wb").write(blob)

    out = [";; ---- MAP (generated by tools/gen_standin.py; don't edit by hand) ----",
           ";; the stand-in city: stage 8's neighborhood, tiled 4 x 4", "",
           f"MAP_W equ {W}", f"MAP_H equ {H}", "", "section .data"]
    out += ['    map_name db "Stand-in"', "    map_name_len equ $ - map_name"]
    def block(name, rows, comment):
        out.append(f"    ; {comment}")
        out.append(f"    {name}:")
        for row in rows:
            out.append("        dd " + ", ".join(str(v) for v in row))
        out.append(f"    {name}_count equ {len(rows)}")
    block("map_walls", m['walls'], "walls: x, y, w, h (buildings, then both complexes' walls)")
    block("map_props", m['props'], "low cover: x, y, w, h (cars, dumpsters, fences)")
    for k in ('west', 'east'):
        block(f"cwalls_{k}", m['cwalls'][k], f"the {k} complex's walls, drawn in its gang's colour")
    block("lobbies", [m['lobbies']['west'], m['lobbies']['east']],
          "lobby interiors: x, y, w, h (spawn and respawn areas), west then east")
    block("map_pickups", m['pickups'], "weapon pickups: x, y, type")
    block("street_lamps", m['lamps'], "streetlights: x, y (their 8x8 heads)")
    block("door_lights", m['doors'], "complex doorways: centre x, y, where lobby light spills out")
    block("cop_routes", m['routes'], "police routes: x, y, w, h, dx, dy (a lane, from off the map)")
    block("dog_walks", m['walks'], "dog walks: start x, y, dx (along a sidewalk, from off the map)")
    out.append("    ; the background, in maps/standin_bg.bin: ground (x, y, w, h, colour),")
    out.append("    ; shadows (x, y, w, h), objects (x, y, w, h, colour)")
    for name, (off, n, size) in offs.items():
        out.append(f"    {name}: incbin \"maps/standin_bg.bin\", {off}, {n * size}")
        out.append(f"    {name}_count equ {n}")
    out.append(";; ---- END MAP ----")
    open(os.path.join(here, "standin.inc"), "w").write("\n".join(out) + "\n")


def preview(m, path, scale=4):
    from PIL import Image
    im = Image.new("RGB", (W // scale, H // scale))
    px = im.load()
    def fill(x, y, w, h, c):
        col = (c & 0xFF, (c >> 8) & 0xFF, (c >> 16) & 0xFF)
        for yy in range(max(y, 0) // scale, min(y + h, H) // scale):
            for xx in range(max(x, 0) // scale, min(x + w, W) // scale):
                px[xx, yy] = col
    for t in m['ground']:
        fill(*t)
    for t in m['objs']:
        fill(*t)
    for k, col in (('west', 0xFFDC783C), ('east', 0xFF3C3CDC)):
        for t in m['cwalls'][k]:
            fill(*t, col)
    im.save(path)


if __name__ == "__main__":
    m = build()
    gw, gh, n = check(m)
    print(f"ok: {W}x{H}, grid {gw}x{gh}, {n} walkable cells, all connected; {len(m['walls'])} walls, "
          f"{len(m['props'])} props, {len(m['pickups'])} pickups, {len(m['lamps'])} lamps, "
          f"{len(m['routes'])} police routes; background {len(m['ground'])} + {len(m['shadows'])} + "
          f"{len(m['objs'])} rects", file=sys.stderr)
    if len(sys.argv) > 2 and sys.argv[1] == "--preview":
        preview(m, sys.argv[2])
    else:
        write(m)
