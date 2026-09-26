#!/usr/bin/env python3
"""Verificacion visual de chaetop: renderiza con stdscr falso y detecta colisiones.

Uso: python3 test_chaetop_frame.py [--show]
Sale con rc=1 si encuentra texto pisado o cortado sin puntos suspensivos.
"""
import os
import re
import sys
import threading
import time
from importlib.machinery import SourceFileLoader

CHAETOP = os.path.join(os.path.dirname(os.path.abspath(__file__)), "chaetop")

SIZES = [(24, 80), (24, 100), (24, 120), (30, 80), (30, 100), (30, 120),
         (30, 160), (40, 100), (40, 120), (40, 160)]

GLUE_PATTERNS = [
    (r"libre\S", "palabra 'libre' pegada al texto siguiente (bug de discos)"),
    (r"(MiB|GiB|KiB|B)\d", "unidad de memoria pegada a un digito"),
    (r"[0-9]▼", "gauge pegado al indicador de red"),
    (r"%[0-9A-Za-z]", "porcentaje pegado al valor siguiente"),
    (r"caído\S", "estado pegado a la siguiente columna"),
]


class FakeScr:
    def __init__(self, H, W):
        self.H, self.W = H, W
        self.erase()

    def getmaxyx(self):
        return (self.H, self.W)

    def erase(self):
        self.g = [[" "] * self.W for _ in range(self.H)]
        self.owner = [[None] * self.W for _ in range(self.H)]
        self.writes = 0
        self.collisions = []
        self.clipped = []

    def refresh(self):
        pass

    def addnstr(self, y, x, text, n=200, attr=0):
        if y < 0 or y >= self.H or x < 0 or x >= self.W:
            return
        self.writes += 1
        wid = self.writes
        s = str(text)
        if len(s) > n:
            self.clipped.append((y, x, s[max(0, n - 12):n + 8], n))
            s = s[:n]
        for i, ch in enumerate(s):
            xx = x + i
            if xx >= self.W:
                self.clipped.append((y, x, s[max(0, self.W - x - 12):], self.W - x))
                break
            prev = self.g[y][xx]
            if prev != " " and ch != " " and self.owner[y][xx] not in (None, wid):
                self.collisions.append(
                    (y, xx, prev, ch, self.owner[y][xx], wid))
            self.g[y][xx] = ch
            self.owner[y][xx] = wid

    def addstr(self, y, x, text, attr=0):
        self.addnstr(y, x, text, 200, attr)

    def lines(self):
        return ["".join(r).rstrip() for r in self.g]


def load_chaetop():
    return SourceFileLoader("chaetop_under_test", CHAETOP).load_module()


def build_app(m, scr):
    class App(m.Chaetop):
        def colors(self):
            self.R = self.G = self.Y = self.C = self.M = self.W = self.D = 0

        def pct_color(self, p, hi=90, mid=70):
            return 0
    return App(scr)


def start_collectors(m):
    for fn in (m.docker_collect, m.stats_collect, m.disk_collect,
               m.repair_collect, m.media_collect):
        threading.Thread(target=fn, daemon=True).start()
    time.sleep(3)


def check_frame(H, W, lines, collisions, clipped):
    problems = []
    for y, line in enumerate(lines):
        for pat, desc in GLUE_PATTERNS:
            if re.search(pat, line):
                problems.append(f"  L{y:02d} {desc}: {line.strip()[:70]}")
    for (y, x, frag, n) in clipped:
        if re.search(r"[A-Za-z0-9]", frag[-3:] if frag else ""):
            problems.append(f"  L{y:02d}x{x:03d} cortado a {n} sin '…': …{frag!r}")
    for (y, x, old, new, _, _) in collisions:
        problems.append(f"  L{y:02d}x{x:03d} pisado {old!r}→{new!r}")
    return problems


def main():
    show = "--show" in sys.argv
    m = load_chaetop()
    m.ENV = m.load_env(m.ENV_PATH) or {}
    start_collectors(m)
    fail = 0
    for H, W in SIZES:
        scr = FakeScr(H, W)
        app = build_app(m, scr)
        scr.erase()
        app.draw()
        lines = scr.lines()
        problems = check_frame(H, W, lines, scr.collisions, scr.clipped)
        tag = "OK " if not problems else "FAIL"
        print(f"[{tag}] {W}x{H}  (writes={scr.writes}, collisions={len(scr.collisions)}, clipped={len(scr.clipped)})")
        if problems:
            fail += 1
            for p in problems[:12]:
                print(p)
        if show or problems:
            print(f"  --- frame {W}x{H} ---")
            for i, ln in enumerate(lines):
                print(f"  {i:2d}|{ln}")
            print()
    print(f"\n{'TODO OK' if not fail else f'{fail}/{len(SIZES)} tamanos con problemas'}")
    sys.exit(0 if not fail else 1)


if __name__ == "__main__":
    main()
