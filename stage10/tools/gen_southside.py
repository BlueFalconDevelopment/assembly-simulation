#!/usr/bin/env python3
"""The south side map (stage 9.02): real streets, compressed.

Reads maps/southside_osm.json -- a stripped OpenStreetMap snapshot, in
metres east and south of the NW corner of the play area -- and lays it
out 5120 px wide: about 1.56 px a metre, where the game's own scale is
about 9 (a 40 px car is 4.5 m). So distances shrink, things don't:
roads keep their real positions but get the game's widths, and a block
holds a handful of houses instead of a dozen.

What comes from the data: every street (alleys and driveways left
out), the real buildings (mostly the commercial strip on Lee), parks,
pitches, playgrounds, school grounds, parking lots, streams, and the
expressway. What's made up, placed by rules below:

  - houses along the residential streets, two rows back to back
  - the gangs' two apartment complexes, each two blocks joined across
    a street: west at SW 20th St & Monroe, east at SW 9th St &
    Jefferson (the short piece of street between the blocks goes)
  - the big park in the southwest: trees, paths, ball fields, a
    shelter and a parking lot
  - the airport in the middle south, fenced, on both sides of the
    diagonal road: a runway and taxiway to the south-east of it,
    hangars, planes and a terminal
  - wrecker lots in the south-east: fenced yards of junk cars
  - chain-link along both sides of the expressway, open where a road
    crosses it
  - trees, bushes, parked cars, streetlights; police lanes on the
    straight roads that cross the whole map; weapon pickups

Output, like gen_standin.py's: maps/southside.inc and
maps/southside_bg.bin.

    python3 tools/gen_southside.py                # check, write maps/
    python3 tools/gen_southside.py --preview x.png [--scale 4]
"""
import json, math, os, random, struct, sys
from collections import deque

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
MAPS = os.path.join(HERE, "..", "maps")
SNAP = os.path.join(MAPS, "southside_osm.json")

from PIL import Image, ImageDraw, ImageFilter

MAP_W = 5120
MARGIN = 48                   # the boundary roads sit this far in
SZ, CELL = 16, 9              # soldier size, pathfinding cell
ROAD_W = dict(motorway=96, primary=60, primary_link=30, secondary=52, tertiary=44,
              residential=36, unclassified=36)
SIDEWALK = 8
RNG = random.Random(9002)     # fixed: the same map every build
# the gangs' homes (10.03): SITES apartment complexes, each two blocks
# joined across an avenue beside a street, picked spread out over the
# neighborhoods, starting from the two 9.02 homes (the corner, and
# which side of the street). Any two far enough apart make a candidate
# pair; batches score each pair (tools/score_pairs.py, into
# maps/pair_scores.json) and only the fair ones go in the map. Each
# game picks one of those pairs; the other sites are closed buildings.
FIRST_SITES = [('Southwest 20th Street', 'Southwest Monroe Avenue', True),
               ('Southwest 9th Street', 'Southwest Jefferson Avenue', False)]
SITES = 6
PAIR_DIST = (1500, 3600)       # centre to centre, px
SCORES = os.path.join(MAPS, "pair_scores.json")
# the map's files: a new name whenever the format changes, so older steps
# keep building against the files they were made with (southside.inc is
# 9.02's format, from stage9/tools/gen_southside.py)
MAP_FILE = "southside5"       # 10.14: + each crossing's neighbours (southside4 is
                              # 10.13's, southside3 10.07's, southside2 10.03's)
DOOR_GAP = 10                 # a door spot: a soldier box this far out from a wall
                              # (2 was too close for the 9 px grid to see: 204 of 595 houses)
MIN_JOB = 600                 # px: the game won't offer a delivery shorter than this
FAIR = 0.045                   # a pair is fair within 50% +- this, over
FAIR_GAMES = 480               # at least this many games


def rgb(r, g, b):
    return 0xFF000000 | (b << 16) | (g << 8) | r


def unrgb(c):
    return (c & 0xFF, (c >> 8) & 0xFF, (c >> 16) & 0xFF)


# colours as (r, g, b); the .inc gets 0xAABBGGRR
C = dict(grass=(96, 140, 78), grass_dark=(70, 115, 60), grass_light=(112, 156, 90),
         park=(104, 150, 82), airfield=(120, 150, 86), gravel=(128, 118, 100), gravel_dark=(104, 96, 82),
         gravel_light=(150, 140, 120), sidewalk=(170, 170, 165), joint=(150, 150, 146),
         asphalt=(60, 60, 64), motorway=(70, 70, 76), grain_light=(72, 72, 76), grain_dark=(50, 50, 54),
         lot=(80, 80, 84), paint=(220, 220, 220), lane=(230, 200, 60), runway=(52, 52, 56),
         apron=(150, 150, 146), school=(196, 180, 140), pitch=(90, 150, 80), infield=(170, 120, 80),
         playground=(200, 170, 120), water=(60, 110, 170), water_light=(90, 140, 200), path=(185, 175, 150),
         floor=(200, 190, 170), tile=(185, 175, 155), mat=(150, 120, 90))
BORDER = (55, 50, 48)
ROOFS = [((120, 105, 95), (100, 88, 80)), ((105, 92, 84), (88, 76, 70)), ((125, 80, 70), (105, 64, 56)),
         ((95, 105, 100), (78, 88, 84)), ((130, 120, 100), (110, 100, 84)), ((80, 80, 88), (64, 64, 72))]
CAR_COLOURS = [(200, 200, 210), (170, 40, 40), (40, 70, 150), (220, 200, 70), (120, 50, 140),
               (230, 230, 230), (90, 140, 90), (150, 90, 40), (40, 40, 44)]
JUNK_COLOURS = [(130, 95, 70), (110, 110, 105), (90, 70, 60), (140, 120, 90), (100, 80, 70),
                (120, 60, 50), (80, 90, 100), (150, 140, 120)]
SHADOW = dict(building=7, house=5, cwall=4, hangar=8, car=3, fence=2, tree=5, bush=3, lamp=4, plane=4)

# a small high-wing plane, 32 x 28, facing north: soldiers can walk
# under the wing, so only the fuselage (and tail) is a prop
PLANE_ART = """
...............WW...............
..............WWWW..............
...............KK...............
WWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWW
WwwwwwwwwwwwwwGGGGwwwwwwwwwwwwwW
WWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWW
..............WGGW..............
..............WWWW..............
..............WWWW..............
..............WWWW..............
..............WRRW..............
..............WWWW..............
..............WWWW..............
..............WWWW..............
...............WW...............
...............WW...............
...............WW...............
...............WW...............
...............WW...............
...............WW...............
...............WW...............
...............WW...............
..........WWWWWWWWWWWW..........
..........WwwwwwwwwwwW..........
..........WWWWWWWWWWWW..........
...............WW...............
...............WW...............
................................
"""
PLANE_PAL = {'W': (235, 235, 235), 'w': (200, 200, 205), 'G': (60, 80, 110), 'K': (40, 40, 40), 'R': (200, 40, 40)}


# ---------------------------------------------------------------- data

class Map:
    pass


def load():
    s = json.load(open(SNAP))
    m = Map()
    m.k = (MAP_W - 2 * MARGIN) / s['width_m']
    m.W = MAP_W
    m.H = round((s['height_m'] * m.k + 2 * MARGIN) / 16) * 16
    m.ky = (m.H - 2 * MARGIN) / s['height_m']
    m.P = lambda x, y: (x * m.k + MARGIN, y * m.ky + MARGIN)
    m.feats = [dict(tags=f['tags'], lines=[[m.P(x, y) for x, y in ln] for ln in f['lines']])
               for f in s['features']]
    m.roads = []
    for f in m.feats:
        hw = f['tags'].get('highway')
        if hw in ROAD_W:
            for ln in f['lines']:
                m.roads.append((hw, f['tags'].get('name', ''), ln))
    return m


def near_point(m, a, b):
    """where the streets named a and b meet (their closest nodes)"""
    A = [p for hw, n, ln in m.roads if n == a for p in ln]
    B = [p for hw, n, ln in m.roads if n == b for p in ln]
    return min(((math.dist(p, q), p) for p in A for q in B))[1]


def diagonal(m):
    """the unnamed diagonal secondary road, as one polyline, SW end first"""
    lns = [ln for hw, n, ln in m.roads if hw == 'secondary' and not n]
    pts = max(lns, key=lambda ln: math.dist(ln[0], ln[-1]))
    return sorted(pts, key=lambda p: -p[1]) if pts[0][1] < pts[-1][1] else pts


def diag_x(dg, y):
    """the diagonal's x at height y (None outside it)"""
    for (x0, y0), (x1, y1) in zip(dg, dg[1:]):
        if min(y0, y1) <= y <= max(y0, y1) and y0 != y1:
            return x0 + (x1 - x0) * (y - y0) / (y1 - y0)
    return None


def line_x(m, name):
    xs = [p[0] for hw, n, ln in m.roads if n == name for p in ln]
    return sum(xs) / len(xs)


# ---------------------------------------------------------------- masks

class Mask:
    """one byte a pixel: 0 = free"""
    def __init__(self, w, h, data=None):
        self.w, self.h = w, h
        self.b = bytearray(data) if data is not None else bytearray(w * h)

    def rect(self, x, y, w, h, v=1):
        x0, y0, x1, y1 = max(int(x), 0), max(int(y), 0), min(int(x + w), self.w), min(int(y + h), self.h)
        if x1 > x0:
            row = bytes([v]) * (x1 - x0)
            for yy in range(y0, y1):
                self.b[yy * self.w + x0: yy * self.w + x1] = row

    def free(self, x, y, w, h):
        x0, y0, x1, y1 = int(x), int(y), int(x + w), int(y + h)
        if x0 < 0 or y0 < 0 or x1 > self.w or y1 > self.h:
            return False
        z = bytes(x1 - x0)
        return all(self.b[yy * self.w + x0: yy * self.w + x1] == z for yy in range(y0, y1))

    def get(self, x, y):
        x, y = int(x), int(y)
        return 0 <= x < self.w and 0 <= y < self.h and self.b[y * self.w + x]


def to_mask(img):
    return Mask(img.width, img.height, img.tobytes())


def thick(dr, ln, w, fill):
    dr.line(ln, fill=fill, width=int(w))
    r = w / 2
    for x, y in ln:
        dr.ellipse((x - r, y - r, x + r, y + r), fill=fill)


# ---------------------------------------------------------------- layout

def layout():
    m = load()
    W, H = m.W, m.H
    dg = diagonal(m)
    x11 = line_x(m, 'Southwest 11th Street')
    x6 = line_x(m, 'Southwest 6th Street')
    x17 = line_x(m, 'Southwest 17th Street')
    # the zones (see the header), in map px
    y_park = MARGIN + 785 * m.ky
    y_south = MARGIN + 810 * m.ky
    zone = Image.new("L", (W, H), 0)          # 1 park, 2 airport, 3 wrecker
    zd = ImageDraw.Draw(zone)
    zd.rectangle((0, y_park, x17, H), fill=1)
    ymerge = max(p[1] for p in dg)
    # airport: west of the diagonal between 11th and 6th, and everything
    # south-east of it down to Bishop; the triangle north-west of it too
    tri = [(x11, y_south)] + [p for p in dg if p[1] >= y_south] + [(x11, ymerge)]
    zd.polygon([(x11, y_south), (diag_x(dg, y_south), y_south), *[p for p in dg[::-1] if p[1] > y_south], (x11, ymerge)], fill=2)
    y6 = diag_x_inv(dg, x6)
    zd.polygon([(x11, ymerge), *[p for p in dg if p[0] <= x6], (x6, y6), (x6, H), (x11, H)], fill=2)
    zd.rectangle((x6, y_south, W, H), fill=3)
    m.zone = zone

    # ---- roads: the ground image, and a mask of road + sidewalk ----
    ground = Image.new("RGB", (W, H), C['grass'])
    gd = ImageDraw.Draw(ground)
    road_img = Image.new("L", (W, H), 0)      # 1 sidewalk, 2 road, 3 motorway
    rd = ImageDraw.Draw(road_img)
    rank = ['residential', 'unclassified', 'tertiary', 'primary_link', 'secondary', 'primary', 'motorway']
    roads = sorted(m.roads, key=lambda r: rank.index(r[0]))
    for hw, _, ln in roads:
        if hw != 'motorway':
            thick(rd, ln, ROAD_W[hw] + 2 * SIDEWALK, 1)
    for hw, _, ln in roads:
        thick(rd, ln, ROAD_W[hw], 3 if hw == 'motorway' else 2)
    # the complexes cover their joined blocks: find the blocks first
    rmask = to_mask(road_img)
    m.complexes = pick_sites(m, rmask)
    for k, (cx, cy, cw, ch) in enumerate(m.complexes):
        rd.rectangle((cx - 6, cy - 6, cx + cw + 5, cy + ch + 5), fill=0)   # the street piece goes
    rmask = to_mask(road_img)
    m.rmask = rmask

    # ---- areas from the data ----
    def poly(ln, col):
        if len(ln) >= 3:
            gd.polygon(ln, fill=col)
    zm = to_mask(zone)
    m.zm = zm
    # airport and park ground first, then the data's areas
    for y in range(0, H, 1):
        pass
    zone_ground = Image.new("RGB", (W, H), C['grass'])
    zg = ImageDraw.Draw(zone_ground)
    ground.paste(Image.new("RGB", (W, H), C['park']), mask=zone.point(lambda v: 255 if v == 1 else 0))
    ground.paste(Image.new("RGB", (W, H), C['airfield']), mask=zone.point(lambda v: 255 if v == 2 else 0))
    for f in m.feats:
        t = f['tags']
        for ln in f['lines']:
            if t.get('leisure') == 'park':
                poly(ln, C['park'])
            elif t.get('amenity') == 'school':
                poly(ln, C['school'])
    for f in m.feats:
        t = f['tags']
        for ln in f['lines']:
            if t.get('leisure') == 'pitch':
                poly(ln, C['pitch'])
            elif t.get('leisure') == 'playground':
                poly(ln, C['playground'])
            elif t.get('amenity') == 'parking':
                poly(ln, C['lot'])
    for f in m.feats:
        if 'waterway' in f['tags']:
            for ln in f['lines']:
                thick(gd, ln, 12, C['water'])
                thick(gd, ln, 4, C['water_light'])
    m.gd, m.ground = gd, ground

    # ---- what's taken: solids, props, and ground that isn't free ----
    m.occ = Mask(W, H, bytes(rmask.b))          # roads and sidewalks
    m.occ.b = bytearray(1 if v else 0 for v in m.occ.b)
    m.walls, m.props, m.objs, m.shadows, m.decor = [], [], [], [], []
    m.lamps, m.pickups, m.doors = [], [], {}
    m.cwalls, m.lobbies = {}, {}
    m.plugs = []                                 # closed sites' doors, per pair
    m.biz_doors, m.house_doors = [], []          # delivery spots, candidates (10.07)
    m.fence_px = []                              # (x, y, w, h, style) drawn later
    m.cars = []                                  # so a car can be taken away again
    m.gone_objs, m.gone_shadows = set(), set()

    build_complexes(m)
    buildings(m)
    airport(m, dg, x11, x6, y_south, ymerge)
    wreckers(m)
    expressway_fence(m, roads)
    park(m, x17, y_park)
    houses(m, roads)
    parked_cars(m, roads)
    plug_cracks(m)
    trees(m)
    lamps(m, roads)
    paint_roads(m, roads, road_img)
    m.routes, m.walks = routes(m)
    pairs(m)
    return m


def pick_sites(m, rmask):
    """SITES complexes: FIRST_SITES, then, one at a time, the valid
    candidate farthest from those already picked. A candidate is a
    street-and-avenue corner outside the made-up areas, with a complex
    of about two blocks that fits 50 soldiers and covers no real
    building."""
    at = {}
    for hw, n, ln in m.roads:
        if hw in ('residential', 'unclassified', 'tertiary') and n:
            for p in ln:
                at.setdefault((round(p[0], 1), round(p[1], 1)), set()).add(n)
    blds = []
    for f in m.feats:
        if 'building' in f['tags']:
            for ln in f['lines']:
                xs, ys = [p[0] for p in ln], [p[1] for p in ln]
                blds.append((min(xs), min(ys), max(xs) - min(xs), max(ys) - min(ys)))
    def valid(r):
        x, y, w, h = r
        if not (150 <= w <= 240 and 250 <= h <= 340):
            return False
        if x < 120 or y < 90 or x + w > m.W - 120 or y + h > m.H - 90:
            return False
        if any(m.zone.getpixel((int(px), int(py))) for px in (x, x + w - 1) for py in (y, y + h - 1)):
            return False
        return not any(ov(r, b) for b in blds)
    cands = []
    for (px, py), ns in sorted(at.items()):
        st = [n for n in ns if 'Street' in n]
        av = [n for n in ns if 'Avenue' in n]
        if st and av:
            for east in (True, False):
                r = complex_at(rmask, px, py, east)
                if valid(r):
                    cands.append(r)
    picked = []
    for a, b, east in FIRST_SITES:
        hx, hy = near_point(m, a, b)
        r = complex_at(rmask, hx, hy, east)
        assert valid(r), f"first site {a} & {b} isn't valid: {r}"
        picked.append(r)
    centre = lambda r: (r[0] + r[2] / 2, r[1] + r[3] / 2)
    while len(picked) < SITES:
        best = max((c for c in cands if not any(ov(c, p) for p in picked)),
                   key=lambda c: min(math.dist(centre(c), centre(p)) for p in picked))
        picked.append(best)
    return picked


def pairs(m):
    """every two sites PAIR_DIST apart; with the scores file, only the
    fair ones. For each pair: close the other sites' doors, check the
    map, and lay its pickups"""
    centre = lambda r: (r[0] + r[2] / 2, r[1] + r[3] / 2)
    n = len(m.complexes)
    cand = [(a, b) for a in range(n) for b in range(a + 1, n)
            if PAIR_DIST[0] <= math.dist(centre(m.complexes[a]), centre(m.complexes[b])) <= PAIR_DIST[1]]
    m.scores = json.load(open(SCORES)) if os.path.exists(SCORES) else None
    if m.scores is not None:
        def fair(a, b):
            s = m.scores.get(site_key(m, a, b))
            return s and s['games'] >= FAIR_GAMES and abs(s['first_wins'] / s['games'] - 0.5) <= FAIR
        cand = [p for p in cand if fair(*p)]
        assert cand, "no fair pairs in " + SCORES
    m.pairs, m.pair_pickups = [], []
    ok_biz = [list(c) for c in m.biz_doors]      # candidates still good, per place
    ok_house = [list(c) for c in m.house_doors]
    for a, b in cand:
        m.plugs = [d for k in range(n) if k not in (a, b) for d in m.site_doors[k]]
        connect(m)
        for k in (a, b):
            ix, iy, iw, ih = m.lobbies[k]
            assert in_main(m, ix + iw // 2, iy + ih // 2), f"site {k}'s lobby is cut off (pair {a}-{b})"
        m.pickups = []
        pickups(m, a, b)
        m.pairs.append((a, b))
        m.pair_pickups.append(m.pickups)
        # delivery spots: clear, and reachable with this pair too
        for lst in (ok_biz, ok_house):
            for cs in lst:
                cs[:] = [c for c in cs if not box_hits(m, c[0], c[1], c[0] + SZ, c[1] + SZ)
                         and in_main(m, c[0], c[1])]
    m.plugs = []
    m.biz_points = [cs[0] for cs in ok_biz if cs]
    m.house_points = [cs[0] for cs in ok_house if cs]


def site_key(m, a, b):
    """a pair's name in the scores file: its two lobbies' corners, so
    it survives renumbering"""
    return "%d,%d-%d,%d" % (m.lobbies[a][:2] + m.lobbies[b][:2])


def diag_x_inv(dg, x):
    """the diagonal's y at x"""
    for (x0, y0), (x1, y1) in zip(dg, dg[1:]):
        if min(x0, x1) <= x <= max(x0, x1) and x0 != x1:
            return y0 + (y1 - y0) * (x - x0) / (x1 - x0)
    return dg[-1][1]


def complex_at(rmask, hx, hy, east):
    """two blocks joined across the E-W street at (hx, hy), on the east
    (or west) side of the N-S street: the grass between the sidewalks"""
    dx = 1 if east else -1
    hx, hy = int(hx), int(hy)
    def run(x, y, sx, sy, want):
        """step until the road mask reads want (0 grass, 1 sidewalk, 2 road)"""
        while 0 <= x < rmask.w and 0 <= y < rmask.h and rmask.get(x, y) != want:
            x += sx; y += sy
        return x, y
    # leave the N-S street, sideways (its road, then its sidewalk:
    # the complex takes the sidewalks round its blocks too)
    x, _ = run(hx, hy - 50, dx, 0, 1)
    x2, _ = run(x, hy - 50, dx, 0, 2)               # to the next road
    xa, xb = sorted((x, x2 - dx))
    # up and down from the E-W street, to the next roads
    cxm = (xa + xb) // 2
    _, ya = run(cxm, hy, 0, -1, 0)
    _, ya = run(cxm, ya, 0, -1, 2)
    _, yb = run(cxm, hy, 0, 1, 0)
    _, yb = run(cxm, yb, 0, 1, 2)
    ins = 2
    return tuple(int(v) for v in (xa + ins, ya + 1 + ins, xb - xa - 2 * ins, yb - ya - 1 - 2 * ins))


def add_wall(m, r, kind='building'):
    m.walls.append(tuple(int(v) for v in r))
    m.occ.rect(r[0] - 4, r[1] - 4, r[2] + 8, r[3] + 8)
    cast(m, r, SHADOW[kind])


def add_prop(m, r, shadow=None):
    m.props.append(tuple(int(v) for v in r))
    m.occ.rect(r[0] - 2, r[1] - 2, r[2] + 4, r[3] + 4)
    if shadow:
        cast(m, r, shadow)


def cast(m, r, d):
    m.shadows.append((int(r[0]) + d, int(r[1]) + d, int(r[2]), int(r[3])))


def runs(grid, pal, ox, oy, out):
    """a pixel grid as runs of same-coloured pixels (0 or '.' = skip)"""
    for yy, row in enumerate(grid):
        xx = 0
        while xx < len(row):
            v, r = row[xx], xx
            while r < len(row) and row[r] == v:
                r += 1
            if v not in (0, '.') and pal.get(v) is not None:
                out.append((ox + xx, oy + yy, r - xx, 1, pal[v]))
            xx = r


# ---------------------------------------------------------------- pieces

def build_complexes(m):
    for k, (x, y, w, h) in enumerate(m.complexes):
        t = 10
        # a door in the middle of each side (the sides facing the other
        # gang and the streets); 40 px, like stage 8's
        doors = [('n', w // 2 - 20, 40), ('s', w // 2 - 20, 40), ('w', h // 4 - 20, 40),
                 ('w', 3 * h // 4 - 20, 40), ('e', h // 4 - 20, 40), ('e', 3 * h // 4 - 20, 40)]
        import gen_neighborhood as g
        walls = g.complex_walls((x, y, w, h), t, doors)
        m.cwalls[k] = walls
        for r in walls:
            m.walls.append(r)
            cast(m, r, SHADOW['cwall'])
        m.occ.rect(x - 4, y - 4, w + 8, h + 8)
        ix, iy, iw, ih = x + t, y + t, w - 2 * t, h - 2 * t
        m.lobbies[k] = (ix, iy, iw, ih)
        m.gd.rectangle((ix, iy, ix + iw - 1, iy + ih - 1), fill=C['floor'])
        for tx in range(ix + 25, ix + iw, 25):
            m.gd.line((tx, iy, tx, iy + ih - 1), fill=C['tile'])
        for ty in range(iy + 25, iy + ih, 25):
            m.gd.line((ix, ty, ix + iw - 1, ty), fill=C['tile'])
        m.site_doors = getattr(m, 'site_doors', {})
        m.site_doors[k] = []
        for dr_ in g.door_rects((x, y, w, h), t, doors):
            m.gd.rectangle((dr_[0], dr_[1], dr_[0] + dr_[2] - 1, dr_[1] + dr_[3] - 1), fill=C['mat'])
            m.site_doors[k].append(tuple(int(v) for v in dr_))
        # keep the ground just outside every door clear
        for dr_ in g.door_rects((x, y, w, h), t, doors):
            m.occ.rect(dr_[0] - 20, dr_[1] - 20, dr_[2] + 40, dr_[3] + 40)


def roof(m, r, rnd, flat):
    x, y, w, h = r
    base, dark = ROOFS[rnd.randrange(len(ROOFS))]
    m.objs.append((x, y, w, h, BORDER))
    m.objs.append((x + 2, y + 2, w - 4, h - 4, base))
    if flat:
        for _ in range(w * h // 200):
            m.objs.append((x + 3 + rnd.randrange(max(w - 6, 1)), y + 3 + rnd.randrange(max(h - 6, 1)), 1, 1, dark))
        if w >= 40 and h >= 30:
            from gen_sprites import prop_grids
            ac = prop_grids()['ac']
            acp = {1: (170, 170, 175), 2: (110, 110, 115), 3: (70, 70, 75), 4: (40, 40, 45)}
            grid_runs(ac, acp, x + w // 4, y + h // 4, m.objs)
    else:                                          # a gable: ridge on the long axis
        if w >= h:
            m.objs.append((x + 2, y + 2, w - 4, (h - 4) // 2, dark))
            m.objs.append((x + 2, y + h // 2 - 1, w - 4, 2, BORDER))
        else:
            m.objs.append((x + 2, y + 2, (w - 4) // 2, h - 4, dark))
            m.objs.append((x + w // 2 - 1, y + 2, 2, h - 4, BORDER))
        if rnd.random() < 0.5:
            cx = x + 6 + rnd.randrange(max(w - 18, 1))
            cy = y + 6 + rnd.randrange(max(h - 18, 1))
            m.objs.append((cx, cy, 7, 7, (130, 70, 55)))
            m.objs.append((cx + 1, cy + 1, 5, 5, BORDER))


def grid_runs(grid, pal, ox, oy, out):
    """prop_grids' numbered grids -> runs"""
    for yy, row in enumerate(grid):
        xx = 0
        while xx < len(row):
            v, r = row[xx], xx
            while r < len(row) and row[r] == v:
                r += 1
            if v and v in pal:
                out.append((ox + xx, oy + yy, r - xx, 1, pal[v]))
            xx = r


def buildings(m):
    """the real buildings: their footprints' boxes, pushed off the (wider
    than real) roads; too small what's left, and they go"""
    rnd = random.Random(1)
    for f in m.feats:
        if 'building' not in f['tags']:
            continue
        for ln in f['lines']:
            xs, ys = [p[0] for p in ln], [p[1] for p in ln]
            x0, y0, x1, y1 = int(min(xs)), int(min(ys)), int(max(xs)) + 1, int(max(ys)) + 1
            if m.zm.get((x0 + x1) // 2, (y0 + y1) // 2) in (1, 2, 3):
                continue                           # zones get their own
            # trim the side that's on a road until it's clear
            for _ in range(200):
                if x1 - x0 < 14 or y1 - y0 < 14:
                    break
                hits = dict(t=sum(m.rmask.get(x, y0 - 3) for x in range(x0, x1)),
                            b=sum(m.rmask.get(x, y1 + 2) for x in range(x0, x1)),
                            l=sum(m.rmask.get(x0 - 3, y) for y in range(y0, y1)),
                            r=sum(m.rmask.get(x1 + 2, y) for y in range(y0, y1)))
                side = max(hits, key=hits.get)
                if hits[side] == 0:
                    break
                if side == 't': y0 += 1
                elif side == 'b': y1 -= 1
                elif side == 'l': x0 += 1
                else: x1 -= 1
            r = (x0, y0, x1 - x0, y1 - y0)
            if r[2] < 14 or r[3] < 14 or not m.occ.free(*r):
                continue
            add_wall(m, r)
            roof(m, r, rnd, flat=True)
            # its door spots, street side first (deliveries, 10.07)
            x, y, w, h = r
            cands = [(x + w // 2 - 8, y - 16 - DOOR_GAP), (x + w // 2 - 8, y + h + DOOR_GAP),
                     (x - 16 - DOOR_GAP, y + h // 2 - 8), (x + w + DOOR_GAP, y + h // 2 - 8)]
            cands.sort(key=lambda c: 0 if m.rmask.get(c[0] + 8, c[1] + 8) else 1)
            m.biz_doors.append(cands)


def fence_rects(pts, step=4):
    """a fence along a polyline, as 4 x 4 blocks on a 4 px lattice"""
    cells = set()
    for (x0, y0), (x1, y1) in zip(pts, pts[1:]):
        n = max(int(math.dist((x0, y0), (x1, y1)) / 2), 1)
        for i in range(n + 1):
            x, y = x0 + (x1 - x0) * i / n, y0 + (y1 - y0) * i / n
            cells.add((int(x) // step, int(y) // step))
    return cells


def add_fence(m, cells, style, gaps=(), step=4):
    """cells -> props (merged into runs), skipping gaps and taken ground"""
    keep = set()
    for cx, cy in cells:
        x, y = cx * step, cy * step
        if any(gx <= x < gx + gw and gy <= y < gy + gh for gx, gy, gw, gh in gaps):
            continue
        if m.rmask.get(x + 2, y + 2) or not m.occ.free(x, y, step, step):
            continue
        keep.add((cx, cy))
    # horizontal runs, then vertical runs of what's left alone
    done = set()
    for cx, cy in sorted(keep, key=lambda c: (c[1], c[0])):
        if (cx, cy) in done:
            continue
        n = 1
        while (cx + n, cy) in keep and (cx + n, cy) not in done:
            n += 1
        if n == 1:
            while (cx, cy + n) in keep and (cx, cy + n) not in done:
                n += 1
            r = (cx * step, cy * step, step, n * step)
            for i in range(n):
                done.add((cx, cy + i))
        else:
            r = (cx * step, cy * step, n * step, step)
            for i in range(n):
                done.add((cx + i, cy))
        m.props.append(r)
        m.fence_px.append(r + (style,))
        cast(m, r, SHADOW['fence'])
    for cx, cy in keep:
        m.occ.rect(cx * step - 2, cy * step - 2, step + 4, step + 4)


def airport(m, dg, x11, x6, y_south, ymerge):
    rnd = random.Random(3)
    gd = m.gd
    in_ap = lambda x, y: m.zm.get(x, y) == 2 and not m.rmask.get(x, y)
    # the runway: north-south, in the widest part (next to 6th St)
    rx = int(x6 - 260)
    ry0 = int(diag_x_inv(dg, rx) + 110)
    ry1 = m.H - MARGIN - 70
    gd.rectangle((rx, ry0, rx + 56, ry1), fill=C['runway'])
    for y in range(ry0 + 60, ry1 - 60, 48):                      # centreline
        gd.rectangle((rx + 27, y, rx + 28, y + 23), fill=C['paint'])
    for yy in (ry0 + 6, ry1 - 30):                                # thresholds
        for x in range(rx + 4, rx + 52, 7):
            gd.rectangle((x, yy, x + 3, yy + 24), fill=C['paint'])
    gd.rectangle((rx + 2, ry0, rx + 2, ry1), fill=C['paint'])
    gd.rectangle((rx + 53, ry0, rx + 53, ry1), fill=C['paint'])
    # a taxiway to the west of it, joined at both ends and the middle
    tx = rx - 90
    gd.rectangle((tx, ry0 + 20, tx + 24, ry1 - 20), fill=C['asphalt'])
    for y in (ry0 + 20, (ry0 + ry1) // 2, ry1 - 44):
        gd.rectangle((tx, y, rx, y + 24), fill=C['asphalt'])
    for y in range(ry0 + 30, ry1 - 30, 20):
        gd.rectangle((tx + 11, y, tx + 12, y + 9), fill=C['lane'])
    m.occ.rect(rx - 6, ry0 - 6, 68, ry1 - ry0 + 12)
    m.occ.rect(tx - 4, ry0 + 16, rx - tx + 4, ry1 - ry0 - 32)
    # the apron: west of the taxiway, with hangars and planes
    ax0, ax1 = int(x11 + 60), tx - 10
    ay0 = int(ymerge + 60)
    ay1 = min(ay0 + 420, m.H - MARGIN - 80)
    if ax1 - ax0 > 200:
        gd.rectangle((ax0, ay0, ax1, ay1), fill=C['apron'])
        for x in range(ax0 + 30, ax1, 30):
            gd.line((x, ay0, x, ay1), fill=C['joint'])
        for y in range(ay0 + 30, ay1, 30):
            gd.line((ax0, y, ax1, y), fill=C['joint'])
        gd.rectangle((ax1, (ay0 + ay1) // 2 - 12, tx, (ay0 + ay1) // 2 + 12), fill=C['apron'])
        x = ax0 + 10
        while x + 110 < ax1:                       # hangars along the west side
            r = (x, ay0 + 10, 100, 80)
            if m.occ.free(*r):
                add_wall(m, r, 'hangar')
                m.objs.append((r[0], r[1], r[2], r[3], BORDER))
                m.objs.append((r[0] + 2, r[1] + 2, r[2] - 4, r[3] - 4, (150, 155, 160)))
                for sx in range(r[0] + 6, r[0] + r[2] - 4, 8):
                    m.objs.append((sx, r[1] + 2, 1, r[3] - 4, (125, 130, 135)))
            x += 120
        for i, (px, py) in enumerate(((ax0 + 30, ay0 + 150), (ax0 + 110, ay0 + 160), (ax0 + 200, ay0 + 150),
                                      (ax0 + 70, ay0 + 270), (ax0 + 170, ay0 + 280))):
            if px + 40 < ax1 and py + 40 < ay1:
                plane(m, px, py)
        m.occ.rect(ax0 - 4, ay0 - 4, ax1 - ax0 + 8, ay1 - ay0 + 8)
    # the terminal and its parking, in the triangle north-west of the diagonal
    tx0, ty0 = int(x11 + 60), int(y_south + 60)
    r = (tx0, ty0, 140, 70)
    if in_ap(tx0, ty0) and in_ap(tx0 + 140, ty0 + 70) and m.occ.free(*r):
        add_wall(m, r)
        roof(m, r, rnd, flat=True)
        gd.rectangle((tx0, ty0 + 90, tx0 + 180, ty0 + 170), fill=C['lot'])
        for sx in range(tx0 + 10, tx0 + 180, 30):
            gd.rectangle((sx, ty0 + 92, sx + 1, ty0 + 112), fill=C['paint'])
            gd.rectangle((sx, ty0 + 148, sx + 1, ty0 + 168), fill=C['paint'])
        m.occ.rect(tx0, ty0 + 86, 184, 88)
    # chain-link round both parts, a step in from the roads, with gates
    zone2 = m.zone.point(lambda v: 255 if v == 2 else 0)
    road_near = m.road_img_dilated = None
    fence_zone(m, 2, style='chain', gate_every=500)


def fence_zone(m, z, style, gate_every):
    """a fence just inside the edge of zone z, clear of the roads"""
    W, H = m.W, m.H
    zimg = m.zone.point(lambda v: 255 if v == z else 0)
    roads = Image.frombytes("L", (W, H), bytes(255 if v else 0 for v in m.rmask.b))
    roads = roads.filter(ImageFilter.MaxFilter(21))            # 10 px clear of them
    inside = Image.eval(zimg, lambda v: v)
    inside.paste(0, mask=roads)
    # the edge: inside minus inside shrunk by 4 px
    shrunk = inside.filter(ImageFilter.MinFilter(9))
    ib, sb = inside.tobytes(), shrunk.tobytes()
    cells = set()
    for i in range(0, W * H):
        if ib[i] and not sb[i]:
            cells.add(((i % W) // 4, (i // W) // 4))
    # walk each line of cells in order (depth first follows a thin
    # line end to end), drop crumbs shorter than 6 cells, and leave a
    # gate every gate_every px along what's left
    left, keep, gaps = set(cells), set(), []
    step = max(gate_every // 4, 1)
    while left:
        start = min(left)
        stack, line = [start], []
        left.discard(start)
        while stack:
            c = stack.pop()
            line.append(c)
            for dx in (-1, 0, 1):
                for dy in (-1, 0, 1):
                    n = (c[0] + dx, c[1] + dy)
                    if n in left:
                        left.discard(n)
                        stack.append(n)
        if len(line) < 6:
            continue
        keep.update(line)
        for cx, cy in line[step // 4:]:
            x, y = cx * 4, cy * 4
            if all(math.dist((x, y), (gx + 20, gy + 20)) > gate_every for gx, gy, _, _ in gaps):
                gaps.append((x - 20, y - 20, 44, 44))
    add_fence(m, keep, style, gaps)


def plane(m, x, y):
    grid = [row for row in PLANE_ART.strip("\n").split("\n")]
    pal = {k: v for k, v in PLANE_PAL.items()}
    runs(grid, pal, x, y, m.objs)
    add_prop(m, (x + 14, y + 2, 4, 25))                     # fuselage and tail
    m.props.append((x, y + 3, 32, 3)) if False else None
    for yy, row in enumerate(grid):
        for xx, ch in enumerate(row):
            pass
    m.shadows.append((x + 4, y + 7, 32, 3))
    m.shadows.append((x + 18, y + 6, 4, 22))
    m.occ.rect(x - 2, y - 2, 36, 32)


def wreckers(m):
    """fenced yards of junk cars, packed into the wrecker zone"""
    rnd = random.Random(4)
    from gen_sprites import CAR_ART, CAR_LETTERS, art_grid, rotate_cw
    car = art_grid(CAR_ART, CAR_LETTERS, 40, 20)
    W, H = m.W, m.H
    tries = 0
    y = int(MARGIN + 810 * m.ky)
    lots = []
    for y in range(int(MARGIN + 810 * m.ky), H - 100, 8):
        for x in range(0, W - 100, 8):
            if m.zm.get(x, y) != 3:
                continue
            # sized to the cars: k to a row, n rows, every gap either
            # too small to enter or two lanes wide (see cracks())
            k, n = rnd.choice((3, 4, 5)), rnd.choice((2, 3))
            lw, lh = 12 + k * 44 - 4 + 12, 12 + n * 20 + (n - 1) * 48 + 12
            if not (m.zm.get(x + lw, y + lh) == 3 and m.occ.free(x - 20, y - 20, lw + 40, lh + 40)):
                continue
            lots.append((x, y, lw, lh))
            m.occ.rect(x - 20, y - 20, lw + 40, lh + 40, 2)
    # mark them free again for the fences and cars, lot by lot
    for x, y, lw, lh in lots:
        m.occ.rect(x, y, lw, lh, 0)
    for x, y, lw, lh in lots:
        m.gd.rectangle((x, y, x + lw - 1, y + lh - 1), fill=C['gravel'])
        for _ in range(lw * lh // 60):
            m.gd.point((x + rnd.randrange(lw), y + rnd.randrange(lh)),
                       fill=C['gravel_dark'] if rnd.random() < 0.6 else C['gravel_light'])
        # the fence, with a gate on the side nearest a road
        side = min('ns', key=lambda s: road_dist(m, x, y, lw, lh, s))
        k = (lw - 20) // 44
        slot = k // 2                                  # this car slot is the lane
        gx = x + 12 + slot * 44 - 4 + 6
        gate = {'n': (gx, y - 4, 36, 8), 's': (gx, y + lh - 8, 36, 12)}[side]
        pts = [(x, y), (x + lw - 4, y), (x + lw - 4, y + lh - 4), (x, y + lh - 4), (x, y)]
        add_fence(m, fence_rects(pts), 'wood', [gate])
        # rows of junk cars, an aisle between each two rows
        cy = y + 12
        while cy + 20 <= y + lh - 12:
            for i in range(k):
                if i != slot and rnd.random() < 0.85:
                    junk_car(m, car, x + 12 + i * 44, cy, rnd)
            cy += 20 + 48                           # an aisle two lanes wide
        m.occ.rect(x - 4, y - 4, lw + 8, lh + 8)


def road_dist(m, x, y, w, h, side):
    px, py, dx, dy = {'n': (x + w // 2, y, 0, -1), 's': (x + w // 2, y + h, 0, 1),
                      'w': (x, y + h // 2, -1, 0), 'e': (x + w, y + h // 2, 1, 0)}[side]
    for d in range(0, 400, 4):
        if m.rmask.get(px + dx * d, py + dy * d):
            return d
    return 999


def junk_car(m, car, x, y, rnd):
    o0 = len(m.objs)
    body = JUNK_COLOURS[rnd.randrange(len(JUNK_COLOURS))]
    edge = tuple(v * 3 // 5 for v in body)
    pal = {1: body, 2: edge, 3: (40, 45, 50), 4: (70, 80, 95), 5: (120, 40, 30), 6: (180, 170, 140), 7: (15, 15, 15)}
    if rnd.random() < 0.3:
        pal[7] = None                               # wheels gone
    g = [row[::-1] for row in car] if rnd.random() < 0.5 else car
    grid_runs(g, {k: v for k, v in pal.items() if v}, x, y, m.objs)
    for _ in range(6):                               # rust
        m.objs.append((x + 4 + rnd.randrange(32), y + 3 + rnd.randrange(14), 2, 1, (130, 70, 40)))
    add_prop(m, (x, y, 40, 20), SHADOW['car'])
    m.cars.append(dict(rect=(x, y, 40, 20), objs=(o0, len(m.objs)), shadow=len(m.shadows) - 1))


def expressway_fence(m, roads):
    for hw, _, ln in roads:
        if hw != 'motorway':
            continue
        for side in (-1, 1):
            off = side * (ROAD_W['motorway'] / 2 + 10)
            pts = []
            for (x0, y0), (x1, y1) in zip(ln, ln[1:]):
                L = math.dist((x0, y0), (x1, y1)) or 1
                nx, ny = -(y1 - y0) / L, (x1 - x0) / L
                pts += [(x0 + nx * off, y0 + ny * off), (x1 + nx * off, y1 + ny * off)]
            add_fence(m, fence_rects(pts), 'chain')


def park(m, x17, y_park):
    """the big park: paths, two ball fields, a shelter, a parking lot"""
    rnd = random.Random(5)
    gd = m.gd
    x0, y0, x1, y1 = MARGIN + 40, int(y_park) + 40, int(x17) - 50, m.H - MARGIN - 40
    # ball fields: a diamond of dirt in a square of grass
    for fx, fy in ((x0 + 60, y0 + 60), (x0 + 60, y1 - 260)):
        gd.rectangle((fx, fy, fx + 200, fy + 200), fill=C['pitch'])
        gd.polygon([(fx + 20, fy + 180), (fx + 100, fy + 100), (fx + 180, fy + 180), (fx + 100, fy + 260 - 60)],
                   fill=C['infield'])
        for bx, by in ((fx + 18, fy + 178), (fx + 98, fy + 98), (fx + 178, fy + 178), (fx + 98, fy + 198)):
            gd.rectangle((bx, by, bx + 4, by + 4), fill=C['paint'])
        m.occ.rect(fx - 10, fy - 10, 220, 220)
        # a backstop behind home plate
        add_fence(m, fence_rects([(fx + 70, fy + 212), (fx + 130, fy + 212)]), 'chain')
    # paths: a loop and a cross
    mxp, myp = (x0 + x1) // 2 + 80, (y0 + y1) // 2
    loop = [(x0 + 300, y0 + 40), (x1 - 40, y0 + 40), (x1 - 40, y1 - 40), (x0 + 300, y1 - 40), (x0 + 300, y0 + 40)]
    thick(gd, loop, 10, C['path'])
    thick(gd, [(x0 + 300, myp), (x1 - 40, myp)], 10, C['path'])
    # the shelter and the lot, where the paths cross
    r = (mxp - 30, myp - 70, 60, 40)
    m.occ.rect(x0 + 295, y0 + 35, 10, y1 - y0 - 70)   # paths stay clear of trees
    if m.occ.free(*r):
        add_wall(m, r, 'house')
        roof(m, r, rnd, flat=False)
    lx, ly = x1 - 210, y0 + 60
    gd.rectangle((lx, ly, lx + 170, ly + 110), fill=C['lot'])
    for sx in range(lx + 10, lx + 170, 30):
        gd.rectangle((sx, ly + 2, sx + 1, ly + 22), fill=C['paint'])
        gd.rectangle((sx, ly + 88, sx + 1, ly + 108), fill=C['paint'])
    m.occ.rect(lx - 4, ly - 4, 178, 118)
    # a pond
    px, py = x0 + 420, y1 - 330
    gd.ellipse((px, py, px + 220, py + 130), fill=C['water'])
    gd.ellipse((px + 20, py + 15, px + 200, py + 115), fill=C['water_light'])
    m.pond = (px, py, 220, 130)
    m.occ.rect(px - 6, py - 6, 232, 142)
    # the park's paths clear of trees
    for (ax, ay), (bx, by) in zip(loop, loop[1:]):
        m.occ.rect(min(ax, bx) - 8, min(ay, by) - 8, abs(bx - ax) + 16, abs(by - ay) + 16)
    m.occ.rect(x0 + 300, myp - 8, x1 - x0 - 340, 16)
    m.park_box = (x0, y0, x1, y1)


def houses(m, roads):
    """along each residential street, both sides, a lot every LOT px,
    set back from the sidewalk"""
    rnd = random.Random(6)
    LOT, SET = 60, 8
    for hw, _, ln in roads:
        if hw not in ('residential', 'unclassified', 'tertiary'):
            continue
        half = ROAD_W[hw] / 2 + SIDEWALK + SET
        for (ax, ay), (bx, by) in zip(ln, ln[1:]):
            L = math.dist((ax, ay), (bx, by))
            if L < LOT:
                continue
            ux, uy = (bx - ax) / L, (by - ay) / L
            horiz = abs(ux) > abs(uy)
            if min(abs(ux), abs(uy)) > 0.2:            # not a grid street
                continue
            t = LOT / 2
            while t < L - LOT / 2:
                cx, cy = ax + ux * t, ay + uy * t
                for side in (-1, 1):
                    w = rnd.randint(40, 52)
                    d = rnd.randint(36, 48)
                    if horiz:
                        r = (cx - w / 2, cy + half if side > 0 else cy - half - d, w, d)
                    else:
                        r = (cx + half if side > 0 else cx - half - d, cy - w / 2, d, w)
                    r = tuple(int(v) for v in r)
                    if m.zm.get(r[0] + r[2] // 2, r[1] + r[3] // 2):
                        continue
                    if m.occ.free(r[0] - 4, r[1] - 4, r[2] + 8, r[3] + 8):
                        add_wall(m, r, 'house')
                        roof(m, r, rnd, flat=False)
                        # its door spot, on the street side (10.07)
                        x, y, w_, h_ = r
                        if horiz:
                            door = (x + w_ // 2 - 8, y - 16 - DOOR_GAP if side > 0 else y + h_ + DOOR_GAP)
                        else:
                            door = (x - 16 - DOOR_GAP if side > 0 else x + w_ + DOOR_GAP, y + h_ // 2 - 8)
                        m.house_doors.append([door])
                t += LOT


def parked_cars(m, roads):
    """now and then a car at the kerb of a residential street"""
    rnd = random.Random(7)
    from gen_sprites import CAR_ART, CAR_LETTERS, art_grid, rotate_cw
    car = art_grid(CAR_ART, CAR_LETTERS, 40, 20)
    for hw, _, ln in roads:
        if hw not in ('residential', 'unclassified'):
            continue
        half = ROAD_W[hw] / 2
        for (ax, ay), (bx, by) in zip(ln, ln[1:]):
            L = math.dist((ax, ay), (bx, by))
            ux, uy = (bx - ax) / (L or 1), (by - ay) / (L or 1)
            if L < 140 or min(abs(ux), abs(uy)) > 0.05:
                continue
            horiz = abs(ux) > abs(uy)
            t = 50 + rnd.randrange(60)
            while t < L - 60:
                if rnd.random() < 0.3:
                    cx, cy = ax + ux * t, ay + uy * t
                    side = rnd.choice((-1, 1))
                    if horiz:
                        r = (int(cx - 20), int(cy + half - 21) if side > 0 else int(cy - half + 1), 40, 20)
                    else:
                        r = (int(cx + half - 21) if side > 0 else int(cx - half + 1), int(cy - 20), 20, 40)
                    if all(m.rmask.get(x, y) == 2 for x, y in ((r[0], r[1]), (r[0] + r[2] - 1, r[1] + r[3] - 1))) \
                            and not any(ov(r, p) for p in m.props[-40:]):
                        body = CAR_COLOURS[rnd.randrange(len(CAR_COLOURS))]
                        edge = tuple(v * 3 // 5 for v in body)
                        pal = {1: body, 2: edge, 3: (50, 60, 80), 4: (80, 100, 130), 5: (200, 30, 30),
                               6: (255, 240, 180), 7: (15, 15, 15)}
                        g = car if horiz else rotate_cw(car)
                        if (horiz and side < 0) or (not horiz and side > 0):
                            g = [row[::-1] for row in g[::-1]]
                        o0 = len(m.objs)
                        grid_runs(g, pal, r[0], r[1], m.objs)
                        m.props.append(r)
                        cast(m, r, SHADOW['car'])
                        m.cars.append(dict(rect=r, objs=(o0, len(m.objs)), shadow=len(m.shadows) - 1))
                t += 70 + rnd.randrange(80)


def ov(a, b):
    return a[0] < b[0] + b[2] and b[0] < a[0] + a[2] and a[1] < b[1] + b[3] and b[1] < a[1] + a[3]


CRACK = (SZ, 48)              # a gap this wide traps or jams soldiers (see below)


def cracks(m):
    """gaps between two solid things that are trouble:
      - 16..31 px: a soldier fits in, but the pathfinding grid can't
        see in (a cell is walkable only if a 24 x 24 window on a 9 px
        lattice is clear, which a gap is sure to hold only from 32 px).
        One who squeezes into a long one stays there: 9.02's first
        batch had a stalemate that way.
      - 32..47 px: one lane of cells. Soldiers going opposite ways jam
        in it for good: in the second batch, most of one gang stood in
        a line behind a teammate going the other way, for thousands of
        ticks, and the other home won 78%.
    Deliberate openings aren't gaps: a complex's doors, fence gates.
    Returns (a, b, the gap between them)."""
    solids = m.walls + m.props + [(-8, -8, m.W + 16, 8), (-8, m.H, m.W + 16, 8),
                                  (-8, 0, 8, m.H), (m.W, 0, 8, m.H)]
    same = [set(v) for v in m.cwalls.values()] + [set(f[:4] for f in m.fence_px)]
    bk = buckets_of([r for r in solids], 64)
    out = []
    seen = set()
    for a in solids:
        ax, ay, aw, ah = a
        near = set()
        for by in range((ay - CRACK[1]) // 64, (ay + ah + CRACK[1]) // 64 + 1):
            for bx in range((ax - CRACK[1]) // 64, (ax + aw + CRACK[1]) // 64 + 1):
                near.update(bk.get((bx, by), ()))
        for b in near:
            if (b, a) in seen or a == b or any(a in g_ and b in g_ for g_ in same):
                continue
            seen.add((a, b))
            bx_, by_, bw, bh = b
            g = None
            oy0, oy1 = max(ay, by_), min(ay + ah, by_ + bh)
            ox0, ox1 = max(ax, bx_), min(ax + aw, bx_ + bw)
            if oy1 > oy0:                                  # side by side
                if CRACK[0] <= bx_ - (ax + aw) < CRACK[1]:
                    g = (ax + aw, oy0, bx_ - (ax + aw), oy1 - oy0)
                elif CRACK[0] <= ax - (bx_ + bw) < CRACK[1]:
                    g = (bx_ + bw, oy0, ax - (bx_ + bw), oy1 - oy0)
            if g is None and ox1 > ox0:                    # one above the other
                if CRACK[0] <= by_ - (ay + ah) < CRACK[1]:
                    g = (ox0, ay + ah, ox1 - ox0, by_ - (ay + ah))
                elif CRACK[0] <= ay - (by_ + bh) < CRACK[1]:
                    g = (ox0, by_ + bh, ox1 - ox0, ay - (by_ + bh))
            if g is None:
                continue
            # something else already in the gap: not a gap between these two
            if any(ov(g, r) for r in near if r != a and r != b):
                continue
            out.append((a, b, g))
    return out


def plug_cracks(m):
    """a crack next to a car loses the car (a hedge there could close a
    street); any other gets a hedge. Until there are none"""
    rnd = random.Random(12)
    for _ in range(20):
        found = cracks(m)
        if not found:
            return
        cars = {c['rect']: c for c in m.cars}
        for a, b, g in found:
            car = cars.get(a) or cars.get(b)
            if car:
                if car['rect'] in m.props:
                    m.props.remove(car['rect'])
                    m.gone_objs.update(range(*car['objs']))
                    m.gone_shadows.add(car['shadow'])
                continue
            if any(ov(g, r) for r in m.props[-200:]) or box_hits(m, *g[:2], g[0] + g[2], g[1] + g[3]):
                continue                                   # a plug got there first
            m.props.append(g)
            m.objs.append(g + ((45, 95, 40),))                # a hedge
            for _ in range(g[2] * g[3] // 12):
                m.objs.append((g[0] + rnd.randrange(g[2]), g[1] + rnd.randrange(g[3]), 1, 1,
                               (70, 125, 55) if rnd.random() < 0.5 else (35, 75, 30)))
            cast(m, g, SHADOW['fence'])
            m.occ.rect(g[0] - 2, g[1] - 2, g[2] + 4, g[3] + 4)
    raise SystemExit("cracks keep coming back")


def trees(m):
    """trees and bushes on free grass: thick in the park, a few in yards"""
    rnd = random.Random(8)
    from gen_sprites import prop_grids
    P = prop_grids()
    tpal = {1: (30, 70, 30), 2: (60, 120, 50), 3: (100, 160, 70), 4: (40, 90, 40)}
    def place(n, box, size, key, density_zone=None):
        x0, y0, x1, y1 = box
        k = 0
        for _ in range(n * 30):
            if k >= n:
                break
            x, y = rnd.randrange(x0, x1 - size), rnd.randrange(y0, y1 - size)
            if density_zone is not None and m.zm.get(x, y) != density_zone:
                continue
            if m.occ.free(x - 2, y - 2, size + 4, size + 4):
                grid_runs(P[key], tpal, x, y, m.objs)
                mask = [[1 if v else 0 for v in row] for row in P[key]]
                tmp = []
                grid_runs(mask, {1: 1}, 0, 0, tmp)
                d = SHADOW[key]
                for rx, ry, rw, rh, _ in tmp:
                    m.shadows.append((x + rx + d, y + ry + d, rw, rh))
                m.occ.rect(x - 2, y - 2, size + 4, size + 4)
                k += 1
    # clusters in the park
    if hasattr(m, 'park_box'):
        x0, y0, x1, y1 = m.park_box
        for _ in range(14):
            cx, cy = rnd.randrange(x0, x1 - 200), rnd.randrange(y0, y1 - 200)
            place(12, (cx, cy, cx + 200, cy + 200), 22, 'tree', 1)
        place(120, (x0, y0, x1, y1), 22, 'tree', 1)
        place(60, (x0, y0, x1, y1), 10, 'bush', 1)
    # the rest of the map: yards and verges
    place(700, (0, 0, m.W, m.H), 22, 'tree', 0)
    place(500, (0, 0, m.W, m.H), 10, 'bush', 0)
    place(40, (0, 0, m.W, m.H), 22, 'tree', 2)


def lamps(m, roads):
    """streetlights on the sidewalks of the bigger roads, every so often"""
    from gen_sprites import prop_grids
    lp = prop_grids()['light']
    lpal = {1: (90, 90, 95), 2: (120, 120, 125), 3: (60, 60, 65), 4: (250, 240, 190)}
    rnd = random.Random(9)
    for hw, _, ln in roads:
        if hw == 'motorway':
            continue
        gap = 200 if hw in ('primary', 'secondary', 'tertiary') else 330
        off = ROAD_W[hw] / 2 + SIDEWALK / 2
        acc = rnd.randrange(gap)
        side = 1
        for (ax, ay), (bx, by) in zip(ln, ln[1:]):
            L = math.dist((ax, ay), (bx, by))
            if L == 0:
                continue
            ux, uy = (bx - ax) / L, (by - ay) / L
            t = gap - acc
            while t < L:
                x = ax + ux * t - uy * off * side - 4
                y = ay + uy * t + ux * off * side - 4
                r = (int(x), int(y), 8, 8)
                corners = ((r[0], r[1]), (r[0] + 7, r[1]), (r[0], r[1] + 7), (r[0] + 7, r[1] + 7))
                if m.rmask.get(r[0] + 4, r[1] + 4) == 1 and all(m.rmask.get(px, py) != 2 for px, py in corners) \
                        and not box_hits(m, r[0], r[1], r[0] + 8, r[1] + 8):
                    m.lamps.append((r[0], r[1]))
                    grid_runs(lp, lpal, r[0], r[1], m.objs)
                    mask = [[1 if v else 0 for v in row] for row in lp]
                    tmp = []
                    grid_runs(mask, {1: 1}, 0, 0, tmp)
                    for rx, ry, rw, rh, _ in tmp:
                        m.shadows.append((r[0] + rx + 4, r[1] + ry + 4, rw, rh))
                    m.occ.rect(r[0] - 30, r[1] - 30, 68, 68, 1) if False else None
                    side = -side
                t += gap
            acc = (acc + L) % gap


def paint_roads(m, roads, road_img):
    """sidewalks, asphalt, joints, lane lines, speckles, into the ground"""
    rnd = random.Random(10)
    W, H = m.W, m.H
    # the road image says where: 1 sidewalk, 2 road, 3 motorway
    sw = road_img.point(lambda v: 255 if v == 1 else 0)
    ro = road_img.point(lambda v: 255 if v == 2 else 0)
    mo = road_img.point(lambda v: 255 if v == 3 else 0)
    base = m.ground
    # speckles on the grass first (then roads cover what's under them)
    px = base.load()
    for _ in range(W * H // 180):
        x, y = rnd.randrange(W), rnd.randrange(H)
        c = px[x, y]
        if c in (C['grass'], C['park']):
            px[x, y] = C['grass_dark'] if rnd.random() < 0.6 else C['grass_light']
            if rnd.random() < 0.5 and x + 1 < W:
                px[x + 1, y] = px[x, y]
    base.paste(Image.new("RGB", (W, H), C['sidewalk']), mask=sw)
    # sidewalk joints: a darker line every 20 px, where x or y is a multiple
    joints = Image.new("L", (W, H), 0)
    jd = ImageDraw.Draw(joints)
    for x in range(0, W, 20):
        jd.line((x, 0, x, H), fill=255)
    for y in range(0, H, 20):
        jd.line((0, y, W, y), fill=255)
    from PIL import ImageChops
    base.paste(Image.new("RGB", (W, H), C['joint']), mask=ImageChops.multiply(joints, sw))
    base.paste(Image.new("RGB", (W, H), C['asphalt']), mask=ro)
    base.paste(Image.new("RGB", (W, H), C['motorway']), mask=mo)
    gd = ImageDraw.Draw(base)
    # lane lines: dashed yellow down the middle of the bigger roads'
    # straight stretches; white edge lines and a dashed divide on the motorway
    for hw, _, ln in roads:
        if hw not in ('primary', 'secondary', 'motorway'):
            continue
        for (ax, ay), (bx, by) in zip(ln, ln[1:]):
            L = math.dist((ax, ay), (bx, by))
            if L < 30:
                continue
            ux, uy = (bx - ax) / L, (by - ay) / L
            t = 10
            while t + 20 < L - 10:
                x, y = ax + ux * t, ay + uy * t
                if hw == 'motorway':
                    gd.line((x, y, x + ux * 20, y + uy * 20), fill=C['paint'], width=2)
                else:
                    gd.line((x, y, x + ux * 20, y + uy * 20), fill=C['lane'], width=3)
                t += 40
            if hw == 'motorway':
                for s in (-1, 1):
                    o = s * (ROAD_W['motorway'] / 2 - 5)
                    gd.line((ax - uy * o, ay + ux * o, bx - uy * o, by + ux * o), fill=C['paint'], width=2)
    # asphalt grain
    for _ in range(W * H // 400):
        x, y = rnd.randrange(W), rnd.randrange(H)
        if px[x, y] in (C['asphalt'], C['motorway'], C['lot']):
            px[x, y] = C['grain_light'] if rnd.random() < 0.5 else C['grain_dark']
    # the complexes' floors went down before the roads were painted:
    # paint them again on top
    for k, (x, y, w, h) in enumerate(m.complexes):
        t = 10
        ix, iy, iw, ih = x + t, y + t, w - 2 * t, h - 2 * t
        gd.rectangle((x, y, x + w - 1, y + h - 1), fill=C['grass'])
        gd.rectangle((ix, iy, ix + iw - 1, iy + ih - 1), fill=C['floor'])
        for tx in range(ix + 25, ix + iw, 25):
            gd.line((tx, iy, tx, iy + ih - 1), fill=C['tile'])
        for ty in range(iy + 25, iy + ih, 25):
            gd.line((ix, ty, ix + iw - 1, ty), fill=C['tile'])


def pickups(m, a, b):
    """80 guns in 40 pairs, between the homes, each pair mirrored through
    the point halfway between the two lobbies: whatever lies near one
    home lies as near the other. (Placed at random, the guns near one home decided games:
    knife carriers arm first, so the gang with more guns nearby armed
    at home while the other walked over with knives. 9.02's second
    batch: the west home won 124 of 144.)"""
    rnd = random.Random(1000 * a + b)            # the pair's own: stable when pairs drop out
    (ax, ay, aw, ah), (bx, by, bw, bh) = m.lobbies[a], m.lobbies[b]
    if ax > bx:
        (ax, ay, aw, ah), (bx, by, bw, bh) = (bx, by, bw, bh), (ax, ay, aw, ah)
    mx, my = (ax + aw / 2 + bx + bw / 2) / 2, (ay + ah / 2 + by + bh / 2) / 2
    # only between the homes: a gun behind a home pulls that gang's
    # knife carriers away from the fight, and when it's the last one
    # left they crowd round it and jam (9.02's fourth batch)
    hw = (bx + bw / 2 - ax - aw / 2) / 2 - 60                  # half the box
    hh = min(my - MARGIN, m.H - MARGIN - my) - 10
    lob = list(m.lobbies.values())
    def ok(x, y):
        r = (x, y, SZ, SZ)
        return (0 <= x and 0 <= y and x + SZ <= m.W and y + SZ <= m.H
                and not any(ov(r, s_) for s_ in lob)
                and not any(abs(x - p[0]) < 24 and abs(y - p[1]) < 24 for p in m.pickups)
                and not box_hits(m, x, y, x + SZ, y + SZ) and in_main(m, x, y))
    def near_ok(x, y):
        """the nearest good spot within 24 px, looking outward"""
        for d in range(0, 25, 2):
            for dx, dy in ((0, 0), (d, 0), (-d, 0), (0, d), (0, -d), (d, d), (-d, -d), (d, -d), (-d, d)):
                if ok(int(x + dx), int(y + dy)):
                    return int(x + dx), int(y + dy)
        return None
    for i in range(40):
        t = 1 if i % 5 < 3 else 2
        for _ in range(5000):
            x = rnd.uniform(mx - hw, mx + hw) - SZ / 2
            y = rnd.uniform(my - hh, my + hh) - SZ / 2
            p = near_ok(x, y)
            if not p:
                continue
            m.pickups.append(p + (t,))
            q = near_ok(2 * mx - p[0] - SZ, 2 * my - p[1] - SZ)
            if q:
                m.pickups.append(q + (t,))
                break
            m.pickups.pop()
        else:
            raise SystemExit("no room for a pair of pickups")


def routes(m):
    """police lanes: every road that runs straight across the whole map;
    dog walks: the sidewalks of the ones that run east-west"""
    by_name = {}
    for hw, n, ln in m.roads:
        if n and hw in ROAD_W and hw != 'motorway':
            by_name.setdefault((n, hw), []).extend(p for p in ln if 0 <= p[0] <= m.W and 0 <= p[1] <= m.H)
    rs, walks = [], []
    seen_x, seen_y = set(), set()
    for (n, hw), pts in by_name.items():
        if not pts:
            continue
        xs, ys = [p[0] for p in pts], [p[1] for p in pts]
        med = lambda v: sorted(v)[len(v) // 2]     # real roads drift a little
        half = ROAD_W[hw] / 2
        if max(xs) - min(xs) < 40 and min(ys) <= MARGIN + 30 and max(ys) >= m.H - MARGIN - 30:
            c = round(med(xs))
            if any(abs(c - s) < 30 for s in seen_x):
                continue
            seen_x.add(c)
            # the proper lane each way: south on the west half, north on
            # the east (a narrow street's two lanes overlap a little)
            o = 22 if half >= 26 else 18
            rs.append((c - o, -40, 20, 40, 0, "COP_SPEED"))
            rs.append((c + o - 20, m.H, 20, 40, 0, "-COP_SPEED"))
        if max(ys) - min(ys) < 40 and min(xs) <= MARGIN + 30 and max(xs) >= m.W - MARGIN - 30:
            c = round(med(ys))
            if any(abs(c - s) < 30 for s in seen_y):
                continue
            seen_y.add(c)
            o = 22 if half >= 26 else 18
            rs.append((-40, c + o - 20, 40, 20, "COP_SPEED", 0))
            rs.append((m.W, c - o, 40, 20, "-COP_SPEED", 0))
            walks.append((-40, c - int(half) - SIDEWALK, 1))
            walks.append((m.W + 20, c + int(half), -1))
    return rs, walks


RUN_MIN = 200                 # px: the shortest stretch of road worth driving (10.13)
RUN_STRAIGHT = 8              # px a stretch may wander off its line
CAR_L, CAR_T = 40, 20         # the police car, long way and across


def road_net(m):
    """the road network (10.13): every straight east-west or north-south
    stretch of road ("runs"), cut wherever either lane is blocked, and
    where they cross ("junctions"). A car drives a run in its lane and
    can turn at a junction. Runs: axis (0 east-west, 1 north-south),
    the centre line's coordinate, from, to, lane offset, road half-width.
    Junctions: the east-west run, the north-south run, x, y"""
    raw = []
    for hw, n, ln in m.roads:
        if hw not in ROAD_W or hw == 'motorway':
            continue
        half = ROAD_W[hw] / 2
        for ax in (0, 1):
            # chains of points that stay within RUN_STRAIGHT of a line
            i = 0
            while i < len(ln) - 1:
                j = i + 1
                while j < len(ln):
                    pts = ln[i:j + 1]
                    cs = [p[1 - ax] for p in pts]
                    along = [p[ax] for p in pts]
                    mono = all(b > a for a, b in zip(along, along[1:])) or \
                        all(b < a for a, b in zip(along, along[1:]))
                    if max(cs) - min(cs) > 2 * RUN_STRAIGHT or not mono:
                        break
                    j += 1
                pts = ln[i:j]
                if len(pts) >= 2:
                    along = [p[ax] for p in pts]
                    cs = sorted(p[1 - ax] for p in pts)
                    a, b = min(along), max(along)
                    if b - a >= RUN_MIN // 2:
                        raw.append([ax, cs[len(cs) // 2], a, b, half])
                i = max(j - 1, i + 1)
    # one street drawn as several ways: join pieces on the same line
    raw.sort(key=lambda r: (r[0], r[1], r[2]))
    merged = []
    for r in raw:
        for q in merged:
            if q[0] == r[0] and abs(q[1] - r[1]) < 12 and r[2] <= q[3] + 40 and q[2] <= r[3] + 40:
                q[2], q[3], q[4] = min(q[2], r[2]), max(q[3], r[3]), max(q[4], r[4])
                break
        else:
            merged.append(list(r))
    runs = []
    for ax, c, a, b, half in merged:
        c = round(c)
        o = 22 if half >= 26 else 18
        a, b = max(int(a), -CAR_L), min(int(b), (m.W if ax == 0 else m.H) + CAR_L)
        # both lanes clear, the whole car, every 4 px along
        ok = []
        for t in range(a, b - CAR_L + 1, 4):
            if ax == 0:
                lanes = [(t, c + o - CAR_T), (t, c - o)]
                clear = all(not box_hits(m, max(x, 0), y, min(x + CAR_L, m.W), y + CAR_T)
                            for x, y in lanes)
            else:
                lanes = [(c - o, t), (c + o - CAR_T, t)]
                clear = all(not box_hits(m, x, max(y, 0), x + CAR_T, min(y + CAR_L, m.H))
                            for x, y in lanes)
            ok.append((t, clear))
        start = None
        for t, clear in ok + [(None, False)]:
            if clear and start is None:
                start = t
            elif not clear and start is not None:
                end = (t if t is not None else ok[-1][0] + 4) - 4 + CAR_L
                if end - start >= RUN_MIN:
                    runs.append((ax, c, start, end, o, int(half)))
                start = None
    runs.sort()
    joins = []
    for i, (ax, c, a, b, o, half) in enumerate(runs):
        if ax != 0:
            continue
        for k, (ax2, c2, a2, b2, o2, half2) in enumerate(runs):
            if ax2 == 1 and a - 30 <= c2 <= b + 30 and a2 - 30 <= c <= b2 + 30:
                joins.append((i, k, c2, c))
    return runs, joins


def join_nbrs(joins):
    """for each crossing: the crossings either side of it along each of
    its two runs, -1 where there's none (a route planner's graph, 10.14)"""
    out = []
    for i, (h, v, x, y) in enumerate(joins):
        west = [(jx, k) for k, (h2, v2, jx, jy) in enumerate(joins) if h2 == h and jx < x]
        east = [(jx, k) for k, (h2, v2, jx, jy) in enumerate(joins) if h2 == h and jx > x]
        north = [(jy, k) for k, (h2, v2, jx, jy) in enumerate(joins) if v2 == v and jy < y]
        south = [(jy, k) for k, (h2, v2, jx, jy) in enumerate(joins) if v2 == v and jy > y]
        out.append((max(west)[1] if west else -1, min(east)[1] if east else -1,
                    max(north)[1] if north else -1, min(south)[1] if south else -1))
    return out


# ---------------------------------------------------------------- checks

def buckets_of(rects, B=128):
    bk = {}
    for rc in rects:
        x, y, w, h = rc[:4]
        for by in range(y // B, (y + h) // B + 1):
            for bx in range(x // B, (x + w) // B + 1):
                bk.setdefault((bx, by), []).append(rc)
    return bk


def box_hits(m, x0, y0, x1, y1):
    key = (len(m.walls), len(m.props), tuple(getattr(m, 'plugs', ())))
    if getattr(m, '_bk_key', None) != key:
        m._bk = buckets_of(m.walls + m.props + list(getattr(m, 'plugs', ())))
        m._bk_key = key
    B = 128
    for by in range(y0 // B, (y1 - 1) // B + 1):
        for bx in range(x0 // B, (x1 - 1) // B + 1):
            for a, b, c, d in m._bk.get((bx, by), ()):
                if x1 > a and x0 < a + c and y1 > b and y0 < b + d:
                    return True
    return x0 < 0 or y0 < 0 or x1 > m.W or y1 > m.H


def connect(m):
    """the walkable grid, as the game builds it, and its pieces: the
    biggest is the map; anything cut off from it is a pocket the
    generator made (between a fence and a house, say). Harmless -- no
    one can get in -- as long as no pickup or lobby is in one"""
    W, H = m.W, m.H
    for r in m.walls + m.props:
        assert 0 <= r[0] and r[0] + r[2] <= W and 0 <= r[1] and r[1] + r[3] <= H, f"off the map: {r}"
    GW, GH = (W - SZ + CELL - 1) // CELL + 1, (H - SZ + CELL - 1) // CELL + 1
    rng = lambda k, hi: (max(CELL * k - 8, 0), min(CELL * k, hi))
    walk = bytearray(GW * GH)
    for cy in range(GH):
        y0, y1 = rng(cy, H - SZ)
        for cx in range(GW):
            x0, x1 = rng(cx, W - SZ)
            walk[cy * GW + cx] = not box_hits(m, x0, y0, x1 + SZ, y1 + SZ)
    piece = [0] * (GW * GH)
    pieces = []
    for s0 in range(GW * GH):
        if walk[s0] and not piece[s0]:
            pid = len(pieces) + 1
            piece[s0] = pid
            q, n = deque([s0]), 1
            while q:
                i = q.popleft()
                x, y = i % GW, i // GW
                for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    a, b = x + dx, y + dy
                    j = b * GW + a
                    if 0 <= a < GW and 0 <= b < GH and walk[j] and not piece[j]:
                        piece[j] = pid
                        q.append(j)
                        n += 1
            pieces.append((n, pid, s0))
    pieces.sort(reverse=True)
    m.grid = (GW, GH)
    m.piece, m.main = piece, pieces[0][1]
    m.walkable = pieces[0][0]
    m.pockets = [(s0 % GW * CELL, s0 // GW * CELL, n) for n, pid, s0 in pieces[1:]]


def in_main(m, x, y):
    """is corner position (x, y) in a cell of the main piece?"""
    GW, _ = m.grid
    cx, cy = (x + CELL - 1) // CELL, (y + CELL - 1) // CELL
    return m.piece[cy * GW + cx] == m.main


def check(m):
    GW, GH = m.grid
    left = cracks(m)
    assert not left, f"{len(left)} cracks left, e.g. {left[:3]}"
    # (each pair's lobbies are checked in pairs(): a closed site's isn't
    # meant to be reachable)
    # both lobbies pack 50 soldiers, 20 px apart
    rnd = random.Random(1)
    worst = 0
    for k, (ix, iy, iw, ih) in m.lobbies.items():
        x0, y0, x1, y1 = ix + 2, iy + 2, ix + iw - SZ - 2, iy + ih - SZ - 2
        for _ in range(300):
            placed = []
            for n in range(50):
                tries = 0
                while True:
                    tries += 1
                    x, y = rnd.randint(x0, x1), rnd.randint(y0, y1)
                    if all(abs(x - a) >= 20 or abs(y - b) >= 20 for a, b in placed):
                        break
                    assert tries < 100000, f"{k} lobby jams"
                placed.append((x, y))
                worst = max(worst, tries)
    return GW, GH, m.walkable, worst


def fill_pockets(m):
    """walkable ground nobody can reach (between a fence and a house,
    say) is filled in: a prop over each pocket's cells, so the flow
    fields never see it"""
    GW = (m.W - SZ + CELL - 1) // CELL + 1
    return


# ---------------------------------------------------------------- output

def fences_to_objs(m):
    for x, y, w, h, style in m.fence_px:
        if style == 'chain':
            m.objs.append((x, y, w, h, (150, 155, 160)))
            if w > h:
                for px in range(x, x + w, 2):
                    m.objs.append((px, y + (px // 2) % 2 * 2, 1, 2, (95, 100, 105)))
                for px in range(x - x % 24, x + w, 24):
                    if px >= x:
                        m.objs.append((px, y, 2, h, (80, 85, 90)))
            else:
                for py in range(y, y + h, 2):
                    m.objs.append((x + (py // 2) % 2 * 2, py, 2, 1, (95, 100, 105)))
                for py in range(y - y % 24, y + h, 24):
                    if py >= y:
                        m.objs.append((x, py, w, 2, (80, 85, 90)))
        else:
            m.objs.append((x, y, w, h, (140, 100, 60)))
            if w > h:
                for px in range(x - x % 16, x + w, 16):
                    if px >= x:
                        m.objs.append((px, y, 3, h, (100, 70, 40)))
            else:
                for py in range(y - y % 16, y + h, 16):
                    if py >= y:
                        m.objs.append((x, py, w, 3, (100, 70, 40)))


def image_rects(im):
    """the ground image as rectangles: runs of one colour in a row,
    stacked into one rectangle while the rows below repeat them"""
    W, H = im.size
    raw = im.tobytes()
    out = []
    open_ = {}
    for y in range(H):
        row = raw[y * W * 3:(y + 1) * W * 3]
        cur = {}
        x = 0
        while x < W:
            c = row[x * 3:x * 3 + 3]
            r = x + 1
            while r < W and row[r * 3:r * 3 + 3] == c:
                r += 1
            key = (x, r - x, c)
            if key in open_:
                i = open_[key]
                out[i][3] += 1
                cur[key] = i
            else:
                out.append([x, y, r - x, 1, c])
                cur[key] = len(out) - 1
            x = r
        open_ = cur
    return [(x, y, w, h, rgb(*c)) for x, y, w, h, c in out]


def write(m):
    fences_to_objs(m)
    ground = image_rects(m.ground)
    objs = [(x, y, w, h, rgb(*c) if isinstance(c, tuple) else c)
            for i, (x, y, w, h, c) in enumerate(m.objs) if i not in m.gone_objs]
    m.shadows = [r for i, r in enumerate(m.shadows) if i not in m.gone_shadows]
    blob = bytearray()
    offs = {}
    for name, rows, fmt in (("bg_ground", ground, '<iiiiI'), ("bg_shadows", m.shadows, '<iiii'),
                            ("bg_objects", objs, '<iiiiI')):
        offs[name] = (len(blob), len(rows), struct.calcsize(fmt))
        for t in rows:
            blob += struct.pack(fmt, *t)
    open(os.path.join(MAPS, MAP_FILE + "_bg.bin"), "wb").write(blob)
    out = [";; ---- MAP (generated by tools/gen_southside.py; don't edit by hand) ----",
           ";; the south side: real streets (OpenStreetMap, (c) OpenStreetMap",
           ";; contributors, ODbL), compressed about five times", "",
           f"MAP_W equ {m.W}", f"MAP_H equ {m.H}",
           f"NUM_SITES equ {len(m.complexes)}         ; complexes a gang can live in",
           f"NUM_PAIRS equ {len(m.pairs)}         ; pairs of them that play fair" +
           ("" if m.scores is not None else " (all candidates: no scores yet)"),
           f"PICKUPS_PER_PAIR equ {len(m.pair_pickups[0])}", "", "section .data"]
    out += ['    map_name db "South Side"', "    map_name_len equ $ - map_name"]
    def block(name, rows, comment):
        out.append(f"    ; {comment}")
        out.append(f"    {name}:")
        for row in rows:
            out.append("        dd " + ", ".join(str(v) for v in row))
        out.append(f"    {name}_count equ {len(rows)}")
    walls = m.walls
    block("map_walls", walls, "walls: x, y, w, h (buildings, houses, the complexes' walls)")
    block("map_props", m.props, "low cover: x, y, w, h (cars, fences, planes)")
    n = len(m.complexes)
    block("site_rects", m.complexes, "the sites (10.03): each complex's outside, x, y, w, h")
    block("site_lobbies", [m.lobbies[k] for k in range(n)], "... its lobby: x, y, w, h (spawn and respawn area)")
    walls, idx = [], []
    for k in range(n):
        idx.append((len(walls), len(m.cwalls[k])))
        walls += m.cwalls[k]
    block("site_walls", walls, "... its walls, drawn in the colour of the gang living there (or grey, closed)")
    block("site_wall_idx", idx, "... which of site_walls are its: first, count")
    doors, idx = [], []
    for k in range(n):
        idx.append((len(doors), len(m.site_doors[k])))
        doors += m.site_doors[k]
    block("site_doors", doors, "... its doorways: x, y, w, h (walled up when it's closed; lit when it's home)")
    block("site_door_idx", idx, "... which of site_doors are its: first, count")
    block("pair_sites", m.pairs, "the pairs a game can pick: site, site")
    block("pair_pickups", [p for pp in m.pair_pickups for p in pp],
          "each pair's weapon pickups, PICKUPS_PER_PAIR a pair: x, y, type")
    block("biz_points", m.biz_points, "deliveries (10.07): a business's door, where a package is picked up: x, y (a soldier corner)")
    block("house_points", m.house_points, "... a house's door, where one is dropped off: x, y")
    out.append(f"    MIN_JOB equ {MIN_JOB}")
    block("street_lamps", m.lamps, "streetlights: x, y (their 8x8 heads)")
    block("cop_routes", m.routes, "police routes: x, y, w, h, dx, dy (a lane, from off the map)")
    block("dog_walks", m.walks, "dog walks: start x, y, dx (along a sidewalk, from off the map)")
    m.runs, m.joins = road_net(m)
    block("road_runs", m.runs, "the road network (10.13): straight stretches with both lanes clear: axis (0 east-west, 1 north-south), centre line, from, to, lane offset, road half-width")
    block("road_joins", m.joins, "... where an east-west run meets a north-south one: run, run, x, y")
    block("road_join_nbrs", join_nbrs(m.joins), "... each crossing's neighbours (10.14): the next crossing west and east along its east-west run, north and south along its north-south one (-1: none)")
    out.append(f"    ; the background, in maps/{MAP_FILE}_bg.bin: ground (x, y, w, h, colour),")
    out.append("    ; shadows (x, y, w, h), objects (x, y, w, h, colour)")
    for name, (off, n, size) in offs.items():
        out.append(f"    {name}: incbin \"maps/{MAP_FILE}_bg.bin\", {off}, {n * size}")
        out.append(f"    {name}_count equ {n}")
    out.append(";; ---- END MAP ----")
    open(os.path.join(MAPS, MAP_FILE + ".inc"), "w").write("\n".join(out) + "\n")
    return len(ground), len(m.shadows), len(objs)


def preview(m, path, scale):
    fences_to_objs(m)
    m.objs = [o for i, o in enumerate(m.objs) if i not in m.gone_objs]
    m.shadows = [r for i, r in enumerate(m.shadows) if i not in m.gone_shadows]
    im = m.ground.copy()
    px = im.load()
    dr = ImageDraw.Draw(im)
    for x, y, w, h in m.shadows:
        for yy in range(max(y, 0), min(y + h, m.H)):
            for xx in range(max(x, 0), min(x + w, m.W)):
                r, g, b = px[xx, yy]
                px[xx, yy] = (r * 5 // 8, g * 5 // 8, b * 5 // 8)
    for x, y, w, h, c in m.objs:
        c = c if isinstance(c, tuple) else unrgb(c)
        dr.rectangle((x, y, x + w - 1, y + h - 1), fill=c)
    a, b = m.pairs[0]
    for k in range(len(m.complexes)):
        col = (60, 120, 220) if k == a else (220, 60, 60) if k == b else (130, 130, 130)
        for x, y, w, h in m.cwalls[k]:
            dr.rectangle((x, y, x + w - 1, y + h - 1), fill=col)
        dr.text((m.complexes[k][0] + 10, m.complexes[k][1] + 10), str(k), fill=(0, 0, 0))
    for x, y, t in m.pair_pickups[0]:
        dr.rectangle((x, y, x + 9, y + 9), fill=(230, 210, 40) if t == 1 else (170, 60, 200))
    if scale != 1:
        im = im.resize((m.W // scale, m.H // scale), Image.BOX)
    im.save(path)


if __name__ == "__main__":
    m = layout()
    GW, GH, n, worst = check(m)
    print(f"{m.W}x{m.H} ({m.k:.2f} px/m), grid {GW}x{GH}: {n} walkable cells connected (last pair), "
          f"{sum(p[2] for p in m.pockets)} in {len(m.pockets)} pockets; worst lobby spawn {worst} tries; "
          f"{len(m.walls)} walls, {len(m.props)} props, {len(m.complexes)} sites, {len(m.pairs)} pairs "
          f"{m.pairs}, {len(m.lamps)} lamps, "
          f"{len(m.routes)} police routes, {len(m.walks)} dog walks", file=sys.stderr)
    for p in m.pockets[:20]:
        print("  pocket at", p, file=sys.stderr)
    if len(sys.argv) > 2 and sys.argv[1] == "--preview":
        sc = int(sys.argv[sys.argv.index("--scale") + 1]) if "--scale" in sys.argv else 4
        preview(m, sys.argv[2], sc)
    else:
        g, s, o = write(m)
        print(f"background {g} + {s} + {o} rects", file=sys.stderr)
