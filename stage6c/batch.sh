#!/usr/bin/env bash
# Run N headless games in parallel and count who wins.
#
#   ./batch.sh [games=20] [binary=build/01_scale_up] [timeout_s=120]
#
# Every fairness bug in 6a/6b was invisible in a single game and only
# showed up by counting wins over 10-20+ runs -- this does that counting
# without needing a window per game. SDL's "dummy" video driver plus
# the software renderer let the unmodified binary run with no display.
# The game keeps running after someone wins (it waits for the window to
# close), so each run is stopped as soon as it prints its win line.
# A run that never prints one within the timeout is reported as STUCK
# -- a stalemate or a freeze, worth tracing tick by tick -- and one that
# exits without printing is reported as CRASH.

games=${1:-20}
bin=${2:-build/01_scale_up}
limit=${3:-120}

[ -x "$bin" ] || { echo "no binary at $bin -- run make first" >&2; exit 1; }

run_one() {
    local start end line tmp pid
    tmp=$(mktemp)
    start=$(date +%s.%N)
    SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software \
        timeout "$limit" "$bin" > "$tmp" &
    pid=$!
    # the win line is the only thing the game ever prints; stop it there
    while kill -0 "$pid" 2>/dev/null && [ ! -s "$tmp" ]; do sleep 0.2; done
    end=$(date +%s.%N)
    local status=0
    if [ -s "$tmp" ]; then
        kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    else
        wait "$pid" 2>/dev/null; status=$?
    fi
    line=$(head -n 1 "$tmp"); rm -f "$tmp"
    # no win line: timeout exits 124 when time ran out, anything else
    # means the game itself died (a segfault shows up as 139)
    if [ -z "$line" ]; then
        if [ "$status" -eq 124 ]; then line="STUCK"; else line="CRASH ($status)"; fi
    fi
    printf '%-22s %5.1fs\n' "$line" "$(echo "$end - $start" | bc)"
}

# The game seeds rand() with srand(time(NULL)) -- one-second resolution.
# Launch every game in the same second and they all get the SAME seed
# and play the SAME game, so a 16-0 result means nothing (this harness's
# first version did exactly that). Start each game in its own second.
for i in $(seq "$games"); do
    run_one &
    [ "$i" -lt "$games" ] && sleep 1.05
done | tee /dev/stderr | {
    t0=0; t1=0; stuck=0; crash=0
    while read -r l; do
        case "$l" in
            "Team 0"*) t0=$((t0 + 1)) ;;
            "Team 1"*) t1=$((t1 + 1)) ;;
            CRASH*) crash=$((crash + 1)) ;;
            *) stuck=$((stuck + 1)) ;;
        esac
    done
    echo "---"
    echo "team 0: $t0   team 1: $t1   stuck: $stuck   crashed: $crash   (of $games)"
}
