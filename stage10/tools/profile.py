# A sampling profiler for the game, run inside gdb (9.03). perf needs
# perf_event_paranoid lowered, and gdb can't attach to a running game
# (ptrace_scope 1), but gdb can stop a game it started itself: a shell
# loop sends the game SIGINT every 20 ms, gdb stops on each one, and
# this notes which function it was in.
#
#   HEADLESS=1 SEED=21 gdb -batch -x tools/profile.py ./build/03_bfs
#   SAMPLES=1000 HEADLESS=1 ... (default 500, or until the game ends)
#
# A name like ".@151[skip]" is a label inside a macro (BFS_VISIT's
# %%skip): count it with the function that uses the macro.
import collections, os, subprocess

import gdb

gdb.execute("set pagination off")
gdb.execute("set confirm off")
gdb.execute("handle SIGINT stop print nopass")   # (noprint would mean nostop)
gdb.execute("break main")
gdb.execute("run")
gdb.execute("delete")
pid = gdb.selected_inferior().pid
# gdb's Python holds its lock while the game runs, so the ticking has
# to come from outside
ticker = subprocess.Popen(["sh", "-c", "while kill -INT %d 2>/dev/null; do sleep 0.02; done" % pid])
here, pairs = collections.Counter(), collections.Counter()
for _ in range(int(os.environ.get("SAMPLES", "500"))):
    try:
        gdb.execute("continue", to_string=True)
        f = gdb.selected_frame()
    except gdb.error:
        break                                      # the game ended
    name = f.name() or "?"
    here[name] += 1
    up = f.older()
    pairs[((up.name() if up else None) or "?") + " > " + name] += 1
ticker.kill()
n = sum(here.values()) or 1
print("samples", n)
for k, v in here.most_common(15):
    print("%5.1f%%  %s" % (100 * v / n, k))
print("--- with callers")
for k, v in pairs.most_common(10):
    print("%5.1f%%  %s" % (100 * v / n, k))
try:
    gdb.execute("kill")
except gdb.error:
    pass
