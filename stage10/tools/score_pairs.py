#!/usr/bin/env python3
"""Score each pair of home sites for fairness (10.03).

Plays PAIR=n headless games of a build (through batch.sh, 4 at a time)
and counts, for each pair, how often its first site's gang wins. The
side swap stays random, so the gangs themselves are balanced; what's
left is the sites. Two rounds: FIRST games each, then the pairs that
look fair enough (within ROUND2 of 50%) play on to TOTAL games.
The results go to maps/pair_scores.json, keyed by the two lobbies'
corners (so they survive renumbering), and gen_southside.py keeps the
pairs within FAIR (its constant) of 50% over at least FAIR_GAMES.

    python3 tools/score_pairs.py build/03_fair_homes [first=96] [total=480]

Run it on a build whose map has every candidate pair (gen_southside.py
without a scores file), then regenerate the map with the scores.
"""
import json, os, re, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..")
MAPS = os.path.join(ROOT, "maps")
ROUND2 = 0.15


def lobbies_and_pairs():
    inc = open(os.path.join(MAPS, "southside2.inc")).read()
    def rows(name):
        body = inc.split(f"    {name}:\n", 1)[1].split(f"    {name}_count", 1)[0]
        return [tuple(int(v) for v in l.split("dd", 1)[1].split(",")) for l in body.strip().split("\n")]
    return rows("site_lobbies"), rows("pair_sites")


def play(binary, pair, games):
    env = dict(os.environ, PAIR=str(pair), STAGGER="0")
    r = subprocess.run(["./batch.sh", str(games), binary, "180"], cwd=ROOT, env=env,
                       capture_output=True, text=True)
    lines = [l for l in r.stderr.split("\n") if l.startswith(("Team", "Stalemate", "STUCK", "CRASH"))]
    first = done = bad = 0
    for l in lines:
        m = re.search(r"homes (\d+)-(\d+); crips home (\d+)", l)
        if not m or not l.startswith("Team"):
            bad += 1
            continue
        a, b, crips = map(int, m.groups())
        winner_site = crips if l.startswith("Team 0") else (b if crips == a else a)
        first += winner_site == a
        done += 1
    return first, done, bad


def main():
    binary = sys.argv[1]
    first_n = int(sys.argv[2]) if len(sys.argv) > 2 else 96
    total = int(sys.argv[3]) if len(sys.argv) > 3 else 480
    lob, pairs = lobbies_and_pairs()
    scores = {}
    for p, (a, b) in enumerate(pairs):
        key = "%d,%d-%d,%d" % (lob[a][:2] + lob[b][:2])
        w, n, bad = play(binary, p, first_n)
        print(f"pair {p} ({a}-{b}): site {a} won {w}/{n} ({100 * w / max(n, 1):.0f}%), {bad} not finished",
              flush=True)
        if n and abs(w / n - 0.5) <= ROUND2 and total > first_n:
            w2, n2, bad2 = play(binary, p, total - first_n)
            w, n, bad = w + w2, n + n2, bad + bad2
            print(f"    to {n}: site {a} won {w} ({100 * w / n:.1f}%), {bad} not finished", flush=True)
        scores[key] = dict(sites=[a, b], games=n, first_wins=w, unfinished=bad)
        json.dump(scores, open(os.path.join(MAPS, "pair_scores.json"), "w"), indent=1)


if __name__ == "__main__":
    main()
