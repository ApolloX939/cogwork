#!/usr/bin/env python3
"""Generates every texture of Cogwork and src/icons.lua.

    python3 tools/gen_textures.py

All art is drawn here (nothing is copied from lwscratch): block icons at 32x32
for the editor, 16x16 pixel art for the robot and items. Re-run after changing
a painter; commit the PNGs.
"""
import math
import os
import sys
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
MOD = os.path.dirname(HERE)
TEX = os.path.join(MOD, "textures")
os.makedirs(TEX, exist_ok=True)

FONT_BOLD = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
SS = 4  # supersampling for the 32px icons
SIZE = 32

COLORS = {          # tile background, edge
    "flow":      ("#e0852b", "#8a4a10"),
    "move":      ("#3d7bd6", "#1c3f7a"),
    "world":     ("#3d7bd6", "#1c3f7a"),
    "inventory": ("#3d7bd6", "#1c3f7a"),
    "var":       ("#8a55c9", "#4a2878"),
    "check":     ("#e3c12e", "#7d6a10"),
    "op":        ("#6a7094", "#363a54"),
    "dir":       ("#dfe4ec", "#7d8596"),
    "note":      ("#777777", "#3a3a3a"),
    "pkg":       ("#2e9c8c", "#12554b"),
}
INK = "#ffffff"
DARK = "#1a1a22"

TOKEN_FILES = {}     # token -> file name (for icons.lua)


def font(px):
    return ImageFont.truetype(FONT_BOLD, int(px * SS))


class Canvas:
    def __init__(self, kind):
        self.kind = kind
        self.im = Image.new("RGBA", (SIZE * SS, SIZE * SS), (0, 0, 0, 0))
        self.d = ImageDraw.Draw(self.im)
        bg, edge = COLORS[kind]
        self.ink = DARK if kind in ("dir", "check") else INK
        self.d.rounded_rectangle(self.r(1, 1, 31, 31), radius=5 * SS, fill=edge)
        self.d.rounded_rectangle(self.r(1, 1, 31, 29), radius=5 * SS, fill=bg)
        # light edge on top
        self.d.line(self.r(5, 2.5, 27, 2.5), fill=(255, 255, 255, 90), width=SS)

    def r(self, *v):
        return tuple(int(x * SS) for x in v)

    def line(self, pts, w=2.5, fill=None):
        pts = [(x * SS, y * SS) for x, y in pts]
        self.d.line(pts, fill=fill or self.ink, width=int(w * SS), joint="curve")

    def poly(self, pts, fill=None):
        self.d.polygon([(x * SS, y * SS) for x, y in pts], fill=fill or self.ink)

    def rect(self, x0, y0, x1, y1, fill=None, outline=None, w=1.5, rad=0):
        if rad:
            self.d.rounded_rectangle(self.r(x0, y0, x1, y1), radius=rad * SS,
                                     fill=fill, outline=outline, width=int(w * SS))
        else:
            self.d.rectangle(self.r(x0, y0, x1, y1), fill=fill, outline=outline,
                             width=int(w * SS))

    def ellipse(self, x0, y0, x1, y1, fill=None, outline=None, w=1.5):
        self.d.ellipse(self.r(x0, y0, x1, y1), fill=fill, outline=outline,
                       width=int(w * SS))

    def arc(self, box, a0, a1, w=2.5):
        self.d.arc(self.r(*box), a0, a1, fill=self.ink, width=int(w * SS))

    def text(self, s, cx, cy, px, fill=None):
        f = font(px)
        x0, y0, x1, y1 = self.d.textbbox((0, 0), s, font=f)
        w, h = x1 - x0, y1 - y0
        self.d.text((cx * SS - w / 2 - x0, cy * SS - h / 2 - y0), s, font=f,
                    fill=fill or self.ink)

    def arrow(self, cx, cy, ang, length=20, w=3.5, head=8, fill=None):
        """arrow centred on cx,cy pointing at angle ang (degrees, 0 = right,
        90 = up on screen)"""
        a = math.radians(ang)
        dx, dy = math.cos(a), -math.sin(a)
        px, py = -dy, dx
        tx, ty = cx + dx * length / 2, cy + dy * length / 2
        bx, by = cx - dx * length / 2, cy - dy * length / 2
        self.line([(bx, by), (tx - dx * head * 0.6, ty - dy * head * 0.6)], w, fill)
        self.poly([(tx, ty),
                   (tx - dx * head + px * head * 0.7, ty - dy * head + py * head * 0.7),
                   (tx - dx * head - px * head * 0.7, ty - dy * head - py * head * 0.7)],
                  fill)

    def save(self, name):
        out = self.im.resize((SIZE, SIZE), Image.LANCZOS)
        out.save(os.path.join(TEX, name))


# direction angles in the side view (robot looks to the right)
DIR_ANGLE = {
    "front": 0, "front_up": 45, "up": 90, "back_up": 135, "back": 180,
    "back_down": 225, "down": 270, "front_down": 315,
    "forward": 0,
}


def p_dir(c, name):
    c.arrow(16, 16, DIR_ANGLE[name], length=19, w=3.5, head=9)
    if name in ("front", "forward"):
        # a little robot on the left shows which way is front
        pass
    # base line hint for the horizontal plane
    c.line([(5, 27), (27, 27)], 1.2, fill="#9aa3b5")


def turn_arrow(c, mode):
    if mode == "left":
        c.arc((7, 8, 25, 26), 200, 340, 3)
        c.arc((7, 8, 25, 26), 340, 360, 3)
        c.poly([(5, 17), (13, 14), (12, 22)])
        c.line([(7, 17), (9, 15)], 1)
    elif mode == "right":
        c.arc((7, 8, 25, 26), 200, 340, 3)
        c.poly([(27, 17), (19, 14), (20, 22)])
    else:
        c.arc((8, 6, 24, 22), 180, 360, 3)
        c.line([(8, 14), (8, 22)], 3)
        c.line([(24, 14), (24, 22)], 3)
        c.poly([(3, 22), (13, 22), (8, 28)])


def p_turn(c, name):
    if name == "left":
        c.arc((6, 9, 26, 29), 180, 330, 3)
        c.poly([(3, 18), (12, 14), (11, 24)])
        c.line([(6, 18), (6, 14)], 3)
    elif name == "right":
        c.arc((6, 9, 26, 29), 210, 360, 3)
        c.poly([(29, 18), (20, 14), (21, 24)])
        c.line([(26, 18), (26, 14)], 3)
    else:
        turn_arrow(c, "around")


def robot_head(c, x=8, y=6, s=16):
    c.rect(x, y, x + s, y + s * 0.8, fill=c.ink, rad=2)
    c.rect(x + 3, y + 4, x + 6, y + 8, fill=COLORS[c.kind][0])
    c.rect(x + s - 6, y + 4, x + s - 3, y + 8, fill=COLORS[c.kind][0])


def chest(c, x, y, w=14, h=11):
    c.rect(x, y, x + w, y + h, outline=c.ink, w=2, rad=1.5)
    c.line([(x, y + 4), (x + w, y + 4)], 2)
    c.rect(x + w / 2 - 1.5, y + 3, x + w / 2 + 1.5, y + 7, fill=c.ink)


def stack_marks(c):
    c.rect(24, 5, 29, 10, outline=c.ink, w=1.5)
    c.rect(22, 7, 27, 12, fill=COLORS[c.kind][0], outline=c.ink, w=1.5)


def p_move(c):
    robot_head(c, 6, 5, 14)
    c.arrow(16, 24, 0, length=20, w=3, head=8)


def p_turn_cmd(c):
    turn_arrow2(c)


def turn_arrow2(c):
    c.arc((7, 6, 25, 24), 200, 340, 3)
    c.poly([(26, 14), (19, 12), (23, 20)])
    robot_head(c, 11, 18, 10)


def p_dig(c):
    # pickaxe
    c.line([(8, 26), (21, 10)], 3)
    c.arc((8, 4, 28, 20), 205, 335, 3.5)
    c.poly([(7, 13), (11, 9), (13, 12)])


def p_place(c):
    c.rect(10, 15, 22, 27, fill=c.ink, rad=1)
    c.rect(12, 17, 20, 25, fill=COLORS[c.kind][0])
    c.arrow(16, 8, 270, length=11, w=3, head=7)


def p_interact(c):
    c.poly([(11, 6), (11, 24), (16, 20), (20, 28), (23, 26), (19, 19), (25, 19)])


def p_pull(c, stack=False):
    chest(c, 3, 14, 15, 12)
    c.arrow(21, 11, 180, length=15, w=3, head=7)
    c.line([(24, 12), (29, 12)], 3)
    if stack:
        stack_marks(c)


def p_put(c, stack=False):
    chest(c, 14, 14, 15, 12)
    c.arrow(11, 11, 0, length=15, w=3, head=7)
    c.line([(3, 12), (8, 12)], 3)
    if stack:
        stack_marks(c)


def p_drop(c, stack=False):
    c.arrow(16, 12, 270, length=16, w=3, head=8)
    c.ellipse(11, 22, 14, 25, fill=c.ink)
    c.ellipse(18, 22, 21, 25, fill=c.ink)
    c.ellipse(14.5, 26, 17.5, 29, fill=c.ink)
    if stack:
        stack_marks(c)


def p_trash(c, stack=False):
    c.rect(10, 11, 22, 27, outline=c.ink, w=2, rad=2)
    c.line([(8, 9), (24, 9)], 3)
    c.line([(13, 6), (19, 6)], 2.5)
    c.line([(14, 14), (14, 24)], 1.5)
    c.line([(18, 14), (18, 24)], 1.5)
    if stack:
        stack_marks(c)


def p_craft(c):
    for i in range(3):
        for j in range(3):
            c.rect(6 + i * 7, 6 + j * 7, 11 + i * 7, 11 + j * 7,
                   fill=c.ink if (i + j) % 2 == 0 else None, outline=c.ink, w=1.2)


def p_wait(c):
    c.ellipse(6, 6, 26, 26, outline=c.ink, w=2.5)
    c.line([(16, 16), (16, 9)], 2.5)
    c.line([(16, 16), (21, 19)], 2.5)


def p_stop(c):
    c.rect(8, 8, 24, 24, fill=c.ink, rad=2)


def p_chat(c):
    c.rect(5, 6, 27, 21, fill=c.ink, rad=4)
    c.poly([(10, 20), (10, 28), (17, 21)])
    for x in (11, 16, 21):
        c.ellipse(x - 1.3, 12, x + 1.3, 14.6, fill=COLORS[c.kind][0])


def p_if(c):
    c.poly([(16, 4), (28, 16), (16, 28), (4, 16)])
    c.text("?", 16, 16, 15, fill=COLORS["flow"][0])


def p_else(c):
    c.line([(16, 6), (16, 14)], 3)
    c.line([(16, 14), (8, 24)], 3)
    c.line([(16, 14), (24, 24)], 3)
    c.poly([(4, 22), (12, 22), (7, 29)])
    c.poly([(20, 22), (28, 22), (25, 29)])


def p_loop(c):
    c.arc((6, 6, 26, 26), 40, 330, 3)
    c.poly([(21, 3), (27, 12), (16, 11)])


def p_repeat(c):
    c.arc((5, 5, 27, 27), 40, 330, 2.5)
    c.poly([(22, 2), (28, 11), (17, 10)])
    c.text("N", 16, 16, 12)


def p_forever(c):
    c.text("∞", 16, 16, 27)


def p_break(c):
    c.rect(5, 8, 17, 24, outline=c.ink, w=2.5, rad=2)
    c.arrow(20, 16, 0, length=14, w=3, head=8)


def p_continue(c):
    c.arrow(10, 16, 0, length=14, w=3, head=8)
    c.line([(21, 8), (21, 24)], 3)
    c.line([(26, 8), (26, 24)], 3)


def p_fn(c):
    c.text("f(x)", 16, 16, 12)


def p_call(c):
    c.text("f()", 16, 11, 12)
    c.arrow(16, 24, 270, length=9, w=2.5, head=6)


def p_return(c):
    c.line([(24, 8), (24, 20), (9, 20)], 3)
    c.poly([(5, 20), (13, 14), (13, 26)])


def p_use(c):
    c.rect(6, 11, 26, 27, fill=c.ink, rad=2)
    c.rect(6, 7, 15, 13, fill=c.ink, rad=1)
    c.text("pkg", 16, 19.5, 8, fill=COLORS["flow"][0])


def p_note(c):
    c.text("#", 16, 16, 24)


def text_painter(s, px):
    def paint(c, *_):
        c.text(s, 16, 16, px)
    return paint


def p_query_counter(c):
    c.text("#", 16, 16, 24, fill=DARK)


def p_ok(c):
    c.line([(7, 17), (13, 24), (25, 8)], 4, fill=DARK)


def p_detect(c):
    c.ellipse(5, 10, 27, 22, outline=DARK, w=2.5)
    c.ellipse(12, 12, 20, 20, fill=DARK)


def p_node(c):
    c.poly([(16, 5), (27, 11), (16, 17), (5, 11)], fill=DARK)
    c.poly([(5, 13), (15, 19), (15, 28), (5, 22)], fill="#5a4d12")
    c.poly([(17, 19), (27, 13), (27, 22), (17, 28)], fill="#8d7a1a")


def p_contains(c):
    chest(c, 5, 12, 22, 16)
    for p in c.d, :
        pass
    c.line([(10, 8), (15, 4), (22, 9)], 2, fill=DARK)


def p_fits(c):
    chest(c, 4, 13, 18, 15)
    c.line([(24, 7), (24, 15)], 3)
    c.line([(20, 11), (28, 11)], 3)


def p_count(c):
    chest(c, 4, 15, 16, 13)
    c.text("n", 24, 9, 14, fill=DARK)


def p_axis(letter):
    def paint(c, *_):
        c.text(letter, 16, 16, 20)
    return paint


def p_facing(c):
    c.ellipse(5, 5, 27, 27, outline=DARK, w=2.5)
    c.poly([(16, 6), (20, 16), (12, 16)], fill="#c0392b")
    c.poly([(16, 26), (20, 16), (12, 16)], fill=DARK)


def p_random(c):
    c.rect(6, 6, 26, 26, outline=DARK, w=2.5, rad=4)
    for x, y in ((11, 11), (21, 11), (16, 16), (11, 21), (21, 21)):
        c.ellipse(x - 1.8, y - 1.8, x + 1.8, y + 1.8, fill=DARK)


def p_length(c):
    c.rect(4, 11, 28, 21, outline=DARK, w=2.2, rad=1)
    for x in (9, 14, 19, 24):
        c.line([(x, 11), (x, 16)], 1.8, fill=DARK)


PAINTERS = {}


def reg(token, kind, painter, *args):
    PAINTERS[token] = (kind, painter, args)


for d in ("front", "front_up", "front_down", "up", "down", "back", "back_up", "back_down",
          "forward"):
    reg(d, "dir", p_dir, d)
for t in ("left", "right", "around"):
    reg(t, "dir", p_turn, t)

reg("move", "move", p_move)
reg("turn", "move", turn_arrow2)
reg("dig", "world", p_dig)
reg("place", "world", p_place)
reg("interact", "world", p_interact)
reg("pull", "inventory", p_pull, False)
reg("pull_stack", "inventory", p_pull, True)
reg("put", "inventory", p_put, False)
reg("put_stack", "inventory", p_put, True)
reg("drop", "inventory", p_drop, False)
reg("drop_stack", "inventory", p_drop, True)
reg("trash", "inventory", p_trash, False)
reg("trash_stack", "inventory", p_trash, True)
reg("craft", "inventory", p_craft)
reg("wait", "flow", p_wait)
reg("stop", "flow", p_stop)
reg("chat", "flow", p_chat)
reg("if", "flow", p_if)
reg("else", "flow", p_else)
reg("loop", "flow", p_loop)
reg("repeat", "flow", p_repeat)
reg("forever", "flow", p_forever)
reg("break", "flow", p_break)
reg("continue", "flow", p_continue)
reg("fn", "flow", p_fn)
reg("call", "flow", p_call)
reg("return", "flow", p_return)
reg("use", "flow", p_use)
reg("#", "note", p_note)

for tok, label, px in (("set", "=", 24), ("add", "+=", 16), ("sub", "-=", 16),
                       ("mul", "×=", 16), ("div", "÷=", 16), ("mod", "%=", 16),
                       ("join", "ab", 18)):
    reg(tok, "var", text_painter(label, px))

reg("counter", "check", p_query_counter)
reg("ok", "check", p_ok)
reg("detect", "check", p_detect)
reg("node", "check", p_node)
reg("contains", "check", p_contains)
reg("fits", "check", p_fits)
reg("count", "check", p_count)
reg("pos_x", "check", p_axis("X"))
reg("pos_y", "check", p_axis("Y"))
reg("pos_z", "check", p_axis("Z"))
reg("facing", "check", p_facing)
reg("random", "check", p_random)
reg("length", "check", p_length)
for tok, label, px in (("even", "2n", 17), ("odd", "2n+1", 11), ("floor", "⌊x⌋", 16)):
    reg(tok, "check", text_painter(label, px))

OPS = {"=": "eq", "!=": "ne", "<": "lt", ">": "gt", "<=": "le", ">=": "ge",
       "+": "plus", "-": "minus", "*": "star", "/": "slash", "%": "pct",
       "(": "lp", ")": "rp", "and": "and", "or": "or", "not": "not",
       "matches": "matches", "true": "true", "false": "false"}
OP_LABEL = {"=": ("=", 26), "!=": ("≠", 26), "<": ("<", 26), ">": (">", 26),
            "<=": ("≤", 26), ">=": ("≥", 26), "+": ("+", 28), "-": ("−", 28),
            "*": ("×", 26), "/": ("÷", 26), "%": ("%", 22), "(": ("(", 28), ")": (")", 28),
            "and": ("and", 13), "or": ("or", 16), "not": ("not", 14),
            "matches": ("~", 28), "true": ("T", 22), "false": ("F", 22)}
for tok in OPS:
    label, px = OP_LABEL[tok]
    reg(tok, "op", text_painter(label, px))


# ------------------------- icons for punching, chat, events, structure, machines, paths


def bg_of(c):
    return COLORS[c.kind][0]


def g_bolt(c, ox=0, oy=0, s=1.0):
    pts = [(18, 4), (8, 18), (15, 18), (13, 28), (24, 13), (17, 13)]
    c.poly([(ox + x * s, oy + y * s) for x, y in pts])


def g_battery(c, level=0.6, y=11):
    c.rect(4, y, 25, y + 12, outline=c.ink, w=2.2, rad=2)
    c.rect(25, y + 3.5, 28.5, y + 8.5, fill=c.ink)
    if level > 0:
        c.rect(6.5, y + 2.5, 6.5 + 16 * level, y + 9.5, fill=c.ink)


def g_shield(c):
    c.poly([(16, 4), (26, 8), (25, 18), (16, 28), (7, 18), (6, 8)])
    c.poly([(16, 8), (22, 10.5), (21.5, 17), (16, 23.5), (10.5, 17), (10, 10.5)], fill=bg_of(c))


def g_bubble(c, w=24, h=16, mark=None):
    c.rect(4, 5, 4 + w, 5 + h, fill=c.ink, rad=4)
    c.poly([(9, 4 + h), (9, 28), (16, 5 + h)])
    if mark:
        c.text(mark, 4 + w / 2, 5 + h / 2, 13, fill=bg_of(c))


def g_whisper(c):
    c.rect(5, 9, 23, 22, fill=c.ink, rad=4)
    c.poly([(9, 21), (8, 28), (15, 22)])
    for x in (10, 14, 18):
        c.ellipse(x - 1.2, 14.3, x + 1.2, 16.7, fill=bg_of(c))
    c.arc((17, 3, 30, 16), 280, 360, 2)
    c.arc((20, 1, 34, 15), 280, 360, 2)


def g_bell(c, ox=0, oy=0):
    c.ellipse(11 + ox, 6 + oy, 21 + ox, 16 + oy)
    c.poly([(8 + ox, 22 + oy), (24 + ox, 22 + oy), (21 + ox, 17 + oy), (21 + ox, 11 + oy),
            (11 + ox, 11 + oy), (11 + ox, 17 + oy)])
    c.ellipse(14 + ox, 23 + oy, 18 + ox, 27 + oy)


def g_loop(c):
    c.arc((6, 6, 26, 26), 200, 340, 3)
    c.poly([(25, 11), (27, 19), (19, 15)])
    c.arc((6, 6, 26, 26), 20, 160, 3)
    c.poly([(7, 21), (5, 13), (13, 17)])


def g_exit(c):
    c.line([(18, 6), (6, 6), (6, 26), (18, 26)], 2.5)
    c.arrow(19, 16, 0, length=16, w=3, head=7)


def g_chip(c, y=17):
    c.rect(7, y, 25, y + 10, outline=c.ink, w=2.2, rad=1.5)
    for x in (11, 16, 21):
        c.line([(x, y + 10), (x, y + 13)], 1.8)


def g_pin(c, ox=0, oy=0):
    c.ellipse(10 + ox, 4 + oy, 22 + ox, 16 + oy, outline=c.ink, w=2.6)
    c.poly([(11.5 + ox, 14 + oy), (20.5 + ox, 14 + oy), (16 + ox, 27 + oy)])
    c.ellipse(14 + ox, 8 + oy, 18 + ox, 12 + oy, fill=c.ink)


def g_person(c, ox=0, oy=0):
    c.ellipse(12 + ox, 4 + oy, 20 + ox, 12 + oy)
    c.poly([(9 + ox, 27 + oy), (11 + ox, 15 + oy), (21 + ox, 15 + oy), (23 + ox, 27 + oy)])


def g_foot(c):
    c.ellipse(8, 5, 15, 16)
    c.ellipse(17, 15, 24, 27)
    c.ellipse(8, 18, 12, 22)
    c.ellipse(20, 6, 24, 10)


def g_x(c, ox=0, oy=0, s=1.0):
    c.line([(ox + 4 * s, oy + 4 * s), (ox + 14 * s, oy + 14 * s)], 3 * s)
    c.line([(ox + 14 * s, oy + 4 * s), (ox + 4 * s, oy + 14 * s)], 3 * s)


def g_gauge(c):
    c.arc((4, 7, 28, 31), 180, 360, 3)
    c.line([(16, 19), (22, 11)], 2.8)
    c.ellipse(13.5, 16.5, 18.5, 21.5, fill=c.ink)
    c.line([(5, 25), (27, 25)], 2)


def g_hourglass(c):
    c.line([(7, 5), (25, 5)], 2.5)
    c.line([(7, 27), (25, 27)], 2.5)
    c.poly([(9, 7), (23, 7), (16, 16)])
    c.poly([(9, 25), (23, 25), (16, 17)], fill=None)
    c.line([(9, 25), (16, 17), (23, 25), (9, 25)], 1.8)


def g_waves(c, both=True):
    c.ellipse(13, 13, 19, 19)
    c.arc((7, 7, 25, 25), 320, 40, 2.4)
    c.arc((3, 3, 29, 29), 320, 40, 2.4)
    if both:
        c.arc((7, 7, 25, 25), 140, 220, 2.4)
        c.arc((3, 3, 29, 29), 140, 220, 2.4)


def g_cube(c):
    c.line([(16, 5), (27, 11), (27, 22), (16, 28), (5, 22), (5, 11), (16, 5)], 2.4)
    c.line([(5, 11), (16, 17), (27, 11)], 2.4)
    c.line([(16, 17), (16, 28)], 2.4)


def g_gem(c):
    c.poly([(16, 5), (26, 13), (16, 28), (6, 13)])
    c.line([(6, 13), (26, 13)], 1.6, fill=bg_of(c))


def p_punch(c):
    c.rect(7, 13, 19, 25, fill=c.ink, rad=3)
    for y in (17, 21):
        c.line([(7, y), (19, y)], 1.4, fill=bg_of(c))
    c.line([(22, 11), (27, 6)], 2.5)
    c.line([(23, 16), (29, 16)], 2.5)
    c.line([(22, 21), (27, 26)], 2.5)


def p_say(c):
    g_bubble(c, mark="!")


def p_tell_bot(c):
    robot_head(c, 3, 8, 14)
    c.arrow(24, 17, 0, length=11, w=2.8, head=6)


def p_tell_bots(c):
    robot_head(c, 2, 3, 12)
    robot_head(c, 2, 17, 12)
    c.arrow(23, 16, 0, length=12, w=2.8, head=6)


def p_event_register(c):
    g_bell(c, -2, 1)
    c.line([(25, 4), (25, 12)], 2.6)
    c.line([(21, 8), (29, 8)], 2.6)


def p_machine_switch(c):
    c.rect(4, 10, 28, 22, outline=c.ink, w=2.4, rad=6)
    c.ellipse(16, 12, 26, 20, fill=c.ink)


def p_install(c):
    c.arrow(16, 9, 270, length=12, w=2.8, head=7)
    g_chip(c, 17)


def p_uninstall(c):
    c.arrow(16, 9, 90, length=12, w=2.8, head=7)
    g_chip(c, 17)


def p_path_cancel(c):
    c.line([(4, 26), (11, 17), (18, 21)], 2.4)
    g_x(c, 15, 4, 1.15)


def p_armor_level(c):
    g_shield(c)


def p_battery_level(c):
    g_battery(c, 0.6)


def p_cell_count(c):
    g_battery(c, 0.9, y=5)
    c.text("n", 16, 24, 12, fill=DARK)


def p_structure_item(c):
    c.rect(6, 6, 26, 26, outline=DARK, w=2.6, rad=2)
    c.text("?", 16, 16, 18, fill=DARK)


def p_entity(c):
    g_person(c)


def p_height_limit(c):
    c.line([(4, 27), (28, 27)], 3)
    c.line([(8, 5), (24, 5)], 3)
    c.arrow(16, 16, 90, length=20, w=2.6, head=7)


def p_listeners(c):
    g_waves(c, True)


def p_listener(c):
    g_waves(c, False)


def p_machine_state(c):
    c.arc((6, 9, 26, 29), -50, 230, 3)
    c.line([(16, 4), (16, 16)], 3)


def p_machine_power(c):
    g_bolt(c)


def p_machine_capacity(c):
    g_battery(c, 1.0)


def p_machine_level(c):
    g_gauge(c)


def p_machine_supply(c):
    g_bolt(c, 0, 5, 0.8)
    c.arrow(24, 9, 45, length=10, w=2.4, head=5)


def p_machine_demand(c):
    g_bolt(c, 6, 0, 0.8)
    c.arrow(8, 12, 225, length=10, w=2.4, head=5)


def p_network_level(c):
    for (x0, y0), (x1, y1) in (((16, 8), (6, 23)), ((16, 8), (26, 23)), ((6, 23), (26, 23))):
        c.line([(x0, y0), (x1, y1)], 2)
    for x, y in ((16, 8), (6, 23), (26, 23)):
        c.ellipse(x - 4, y - 4, x + 4, y + 4)


def p_node_stock(c):
    chest(c, 5, 13, 22, 14)
    c.text("#", 16, 7, 10, fill=DARK)


def p_node_timer(c):
    g_hourglass(c)


def p_path_plan(c):
    g_pin(c)


def p_path_plan_entity(c):
    g_person(c, -3, 0)
    c.ellipse(21, 20, 27, 26, outline=DARK, w=2)


def p_path_step(c):
    g_foot(c)


def p_path_left(c):
    for x, w in ((5, 6), (13, 4), (21, 3)):
        c.ellipse(x, 18 - w / 2, x + w, 18 + w / 2)
    c.line([(5, 24), (27, 24)], 1.6)
    c.line([(27, 24), (27, 6)], 2.4)
    c.poly([(27, 5), (22, 8), (27, 11)])


reg("punch", "world", p_punch)
reg("say", "flow", p_say)
reg("whisper", "flow", lambda c: g_whisper(c))
reg("tell_bot", "flow", p_tell_bot)
reg("tell_bots", "flow", p_tell_bots)
reg("event_register", "flow", p_event_register)
reg("event_process", "flow", lambda c: g_loop(c))
reg("event_leave", "flow", lambda c: g_exit(c))
reg("path_cancel", "flow", p_path_cancel)
reg("machine_switch", "world", p_machine_switch)
reg("install", "inventory", p_install)
reg("uninstall", "inventory", p_uninstall)
for _tok, _p in (("armor_level", p_armor_level), ("battery_level", p_battery_level),
                 ("cell_count", p_cell_count), ("structure_item", p_structure_item),
                 ("entity", p_entity), ("height_limit", p_height_limit),
                 ("listeners", p_listeners), ("listener", p_listener),
                 ("machine_state", p_machine_state), ("machine_power", p_machine_power),
                 ("machine_capacity", p_machine_capacity), ("machine_level", p_machine_level),
                 ("machine_supply", p_machine_supply), ("machine_demand", p_machine_demand),
                 ("network_level", p_network_level), ("node_stock", p_node_stock),
                 ("node_timer", p_node_timer), ("path_plan", p_path_plan),
                 ("path_plan_entity", p_path_plan_entity), ("path_step", p_path_step),
                 ("path_left", p_path_left)):
    reg(_tok, "check", _p)


def file_for(token):
    if token in OPS:
        return "cogwork_t_%s.png" % OPS[token]
    if token == "#":
        return "cogwork_t_note.png"
    return "cogwork_t_%s.png" % token


for token, (kind, painter, args) in PAINTERS.items():
    c = Canvas(kind)
    painter(c, *args)
    name = file_for(token)
    c.save(name)
    TOKEN_FILES[token] = name

# ------------------------------------------------- packages and functions

FN_FILES = {}    # "pkg.fn" -> file
PKG_FILES = {}   # package -> file


def boxes(c, cells, size=5.5, gap=1.2, x0=4, y0=4, fill=None):
    for (i, j) in cells:
        c.rect(x0 + i * (size + gap), y0 + j * (size + gap),
               x0 + i * (size + gap) + size, y0 + j * (size + gap) + size,
               fill=fill or c.ink)


def g_boot(c):
    c.poly([(8, 8), (15, 8), (15, 17), (25, 20), (25, 26), (8, 26)])


def g_pick(c):
    p_dig(c)


def g_brick(c):
    for y in (6, 13, 20):
        c.rect(4, y, 28, y + 6, outline=c.ink, w=1.5)
    for x, y in ((12, 6), (20, 13), (12, 20)):
        c.line([(x, y), (x, y + 6)], 1.5)


def g_sprout(c, cx=16, base=27, h=14):
    c.line([(cx, base), (cx, base - h)], 2.5)
    c.poly([(cx, base - h + 3), (cx - 9, base - h - 3), (cx - 7, base - h + 5)])
    c.poly([(cx, base - h + 6), (cx + 9, base - h), (cx + 7, base - h + 8)])


def g_chest(c):
    chest(c, 4, 9, 24, 17)


def g_pi(c):
    c.text("π", 16, 16, 24)


def fn_icon(pkg, name, painter, *args):
    FN_FILES[pkg + "." + name] = ("cogwork_fn_%s_%s.png" % (pkg, name), painter, args)


def fp_arrow(c, ang, shaft=True):
    c.arrow(16, 16, ang, length=20, w=3.5, head=9)


def fp_walk(c):
    g_boot(c)
    c.arrow(23, 10, 0, length=9, w=2, head=5)


def fp_retreat(c):
    c.arrow(16, 16, 180, length=20, w=3.5, head=9)
    c.line([(5, 25), (27, 25)], 1.5)


def fp_rise(c):
    c.arrow(16, 14, 90, length=17, w=3.5, head=9)
    c.line([(6, 27), (26, 27)], 2.5)


def fp_sink(c):
    c.arrow(16, 18, 270, length=17, w=3.5, head=9)
    c.line([(6, 5), (26, 5)], 2.5)


def fp_about(c):
    turn_arrow(c, "around")


def fp_bore(c):
    c.rect(18, 6, 28, 26, fill=c.ink)
    c.arrow(11, 16, 0, length=17, w=3.5, head=8)


def fp_patrol(c):
    c.rect(7, 7, 25, 25, outline=c.ink, w=2.5, rad=2)
    c.poly([(16, 3), (22, 9), (10, 9)])


def fp_tunnel(c):
    c.rect(4, 6, 28, 28, fill=c.ink, rad=1)
    c.d.pieslice(c.r(9, 11, 23, 31), 180, 360, fill=COLORS["pkg"][0])
    c.rect(9, 21, 23, 28, fill=COLORS["pkg"][0])


def fp_shaft(c):
    c.rect(5, 4, 11, 28, fill=c.ink)
    c.rect(21, 4, 27, 28, fill=c.ink)
    c.arrow(16, 16, 270, length=18, w=3, head=8)


def fp_climb(c):
    c.rect(5, 4, 11, 28, fill=c.ink)
    c.rect(21, 4, 27, 28, fill=c.ink)
    c.arrow(16, 16, 90, length=18, w=3, head=8)


def fp_layer(c):
    boxes(c, [(i, j) for i in range(3) for j in range(3)], size=6, gap=1.5, x0=3.5, y0=3.5)


def fp_quarry(c):
    c.poly([(4, 6), (28, 6), (22, 26), (10, 26)])
    c.poly([(8, 8), (24, 8), (20, 22), (12, 22)], fill=COLORS["pkg"][0])
    c.arrow(16, 12, 270, length=9, w=2.5, head=6)


def fp_line(c):
    boxes(c, [(0, 1), (1, 1), (2, 1), (3, 1)], size=5, gap=1.2, x0=3, y0=12)


def fp_pave(c):
    boxes(c, [(i, j) for i in range(3) for j in range(2)], size=7, gap=1.5, x0=3.5, y0=8)


def fp_wall(c):
    g_brick(c)


def fp_plant_row(c):
    g_sprout(c, 9, 27, 11)
    g_sprout(c, 23, 27, 11)


def fp_harvest(c):
    c.line([(16, 27), (16, 8)], 2)
    for k in range(4):
        y = 8 + k * 4.5
        c.poly([(16, y + 3), (9, y - 1), (10, y + 3)])
        c.poly([(16, y + 3), (23, y - 1), (22, y + 3)])


def fp_field(c):
    for x, y in ((9, 15), (23, 15), (9, 28), (23, 28)):
        g_sprout(c, x, y, 8)


def fp_unload(c):
    chest(c, 15, 12, 14, 12)
    c.arrow(10, 16, 0, length=14, w=3, head=7)


def fp_load(c):
    chest(c, 3, 12, 14, 12)
    c.arrow(22, 16, 180, length=14, w=3, head=7)


def fp_take(c):
    chest(c, 3, 14, 15, 12)
    c.arrow(21, 11, 180, length=15, w=3, head=7)
    c.text("n", 24, 22, 12)


def fp_give(c):
    chest(c, 14, 14, 15, 12)
    c.arrow(11, 11, 0, length=15, w=3, head=7)
    c.text("n", 8, 22, 12)


def fp_text(label, px):
    return lambda c: c.text(label, 16, 16, px)


for n, f in (("walk", fp_walk), ("retreat", fp_retreat), ("rise", fp_rise),
             ("sink", fp_sink), ("about_face", fp_about), ("bore", fp_bore),
             ("patrol", fp_patrol)):
    fn_icon("movement", n, f)
for n, f in (("tunnel", fp_tunnel), ("shaft", fp_shaft), ("climb", fp_climb),
             ("layer", fp_layer), ("quarry", fp_quarry)):
    fn_icon("mining", n, f)
for n, f in (("line", fp_line), ("pave", fp_pave), ("wall", fp_wall)):
    fn_icon("building", n, f)
for n, f in (("plant_row", fp_plant_row), ("harvest_row", fp_harvest),
             ("plant_field", fp_field)):
    fn_icon("farming", n, f)
for n, f in (("unload", fp_unload), ("load", fp_load), ("take", fp_take), ("give", fp_give)):
    fn_icon("storage", n, f)
for n, f in (("abs", fp_text("|x|", 15)), ("min", fp_text("min", 11)),
             ("max", fp_text("max", 11)), ("sign", fp_text("±", 24)),
             ("clamp", fp_text("[x]", 17)), ("power", fp_text("xⁿ", 18))):
    fn_icon("math", n, f)

# events and pathfind functions
for n, f in (("register", lambda c: (g_bell(c, -2, 1), c.line([(25, 4), (25, 12)], 2.6), c.line([(21, 8), (29, 8)], 2.6))),
             ("register_nodes", g_cube), ("register_entities", g_person), ("register_items", g_gem),
             ("register_chat", lambda c: g_bubble(c)), ("register_whisper", g_whisper),
             ("register_bot", lambda c: robot_head(c, 7, 8, 18)),
             ("process", g_loop), ("leave", g_exit)):
    fn_icon("events", n, f)
for n, f in (("start", g_pin), ("start_entity", lambda c: (g_person(c, -3, 0), c.ellipse(21, 20, 27, 26, outline=c.ink, w=2))),
             ("step", g_foot), ("left", lambda c: p_path_left(c)),
             ("cancel", lambda c: p_path_cancel(c)),
             ("goto", lambda c: (g_pin(c, -3, -1), c.arrow(24, 24, 0, length=9, w=2.4, head=5))),
             ("goto_entity", lambda c: (g_person(c, -4, -1), c.arrow(25, 23, 0, length=9, w=2.4, head=5)))):
    fn_icon("pathfind", n, f)


PKG_PAINTERS = {"movement": g_boot, "mining": g_pick, "building": g_brick,
                "farming": g_sprout, "storage": g_chest, "math": g_pi,
                "events": g_bell, "pathfind": g_pin,
                "default": lambda c: (c.rect(6, 12, 26, 28, fill=c.ink, rad=2),
                                      c.rect(6, 8, 15, 14, fill=c.ink, rad=1),
                                      c.text("pkg", 16, 21, 8, fill=COLORS["pkg"][0]))}


def package_tab(c):
    # folder tab so packages read differently from functions
    c.rect(2, 1, 14, 5, fill=COLORS["pkg"][1], rad=1.5)


for key, (fname, painter, args) in FN_FILES.items():
    c = Canvas("pkg")
    painter(c, *args)
    c.save(fname)
for pkg, painter in PKG_PAINTERS.items():
    c = Canvas("pkg")
    package_tab(c)
    painter(c)
    c.save("cogwork_pkg_%s.png" % pkg)
    PKG_FILES[pkg] = "cogwork_pkg_%s.png" % pkg

# ----------------------------------------------------------------- editor UI

UI_BG = ("#3b3f4e", "#1b1d26")


def ui_canvas():
    c = Canvas("op")
    c.d.rounded_rectangle(c.r(1, 1, 31, 31), radius=5 * SS, fill=UI_BG[1])
    c.d.rounded_rectangle(c.r(1, 1, 31, 29), radius=5 * SS, fill=UI_BG[0])
    c.ink = "#e8ecf4"
    return c


def ui(name, painter):
    c = ui_canvas()
    painter(c)
    c.save("cogwork_ui_%s.png" % name)


def u_insert(c):
    c.rect(6, 7, 26, 13, outline=c.ink, w=1.8)
    c.rect(6, 19, 26, 25, outline=c.ink, w=1.8)
    c.line([(16, 13), (16, 19)], 0.1)
    c.line([(12, 16), (20, 16)], 2.5, fill="#7fdf7f")
    c.line([(16, 12.5), (16, 19.5)], 2.5, fill="#7fdf7f")


def u_delete(c):
    c.rect(6, 7, 26, 13, outline=c.ink, w=1.8)
    c.rect(6, 19, 26, 25, outline=c.ink, w=1.8)
    c.line([(10, 12), (22, 20)], 3, fill="#ff6060")
    c.line([(22, 12), (10, 20)], 3, fill="#ff6060")


def u_duplicate(c):
    c.rect(5, 6, 21, 16, outline=c.ink, w=1.8)
    c.rect(11, 16, 27, 26, fill=UI_BG[0], outline=c.ink, w=1.8)


def u_indent(c):
    c.line([(6, 8), (26, 8)], 2)
    c.line([(14, 16), (26, 16)], 2)
    c.line([(6, 24), (26, 24)], 2)
    c.poly([(5, 12), (11, 16), (5, 20)])


def u_unindent(c):
    c.line([(6, 8), (26, 8)], 2)
    c.line([(14, 16), (26, 16)], 2)
    c.line([(6, 24), (26, 24)], 2)
    c.poly([(11, 12), (5, 16), (11, 20)])


def u_up(c):
    c.arrow(16, 16, 90, length=18, w=3.5, head=10, fill=c.ink)


def u_down(c):
    c.arrow(16, 16, 270, length=18, w=3.5, head=10, fill=c.ink)


def u_left(c):
    c.arrow(16, 16, 180, length=18, w=3.5, head=10, fill=c.ink)
    c.rect(24, 9, 27, 23, fill=c.ink)


def u_right(c):
    c.arrow(16, 16, 0, length=18, w=3.5, head=10, fill=c.ink)
    c.rect(5, 9, 8, 23, fill=c.ink)


def u_cell_delete(c):
    c.rect(6, 9, 26, 23, outline=c.ink, w=2, rad=3)
    c.line([(12, 13), (20, 19)], 2.5, fill="#ff6060")
    c.line([(20, 13), (12, 19)], 2.5, fill="#ff6060")


def u_clear(c):
    c.line([(8, 9), (24, 25)], 3.5, fill="#ff6060")
    c.line([(24, 9), (8, 25)], 3.5, fill="#ff6060")


def u_power(on):
    def paint(c):
        col = "#58e06b" if on else "#9aa0b4"
        c.arc((6, 7, 26, 27), 125, 415 - 360 + 360 - 0, 3.5)
        # redraw ring in colour
        c.d.arc(c.r(6, 7, 26, 27), 300, 240 + 360, fill=col, width=int(3.5 * SS))
        c.line([(16, 4), (16, 16)], 3.5, fill=col)
    return paint


def u_power2(on):
    def paint(c):
        col = "#58e06b" if on else "#9aa0b4"
        c.d.arc(c.r(6, 8, 26, 28), 120, 420, fill=col, width=int(3.5 * SS))
        c.line([(16, 3), (16, 16)], 3.5, fill=col)
    return paint


def u_persist(on):
    def paint(c):
        col = "#58c8ff" if on else "#9aa0b4"
        c.rect(7, 7, 25, 25, outline=col, w=2.5, rad=2)
        c.line([(7, 16), (25, 16)], 1.5, fill=col)
        c.line([(16, 7), (16, 25)], 1.5, fill=col)
        c.ellipse(13, 13, 19, 19, fill=col)
        if not on:
            c.line([(5, 27), (27, 5)], 3, fill="#ff6060")
    return paint


def u_check(c):
    c.rect(7, 5, 25, 27, outline=c.ink, w=2, rad=2)
    c.line([(11, 11), (21, 11)], 1.5)
    c.line([(11, 16), (17, 16)], 1.5)
    c.line([(12, 22), (16, 26), (25, 14)], 3.5, fill="#58e06b")


def u_run_bg(c):
    # a window with a play triangle, and a tray arrow: runs on while closed
    c.rect(5, 5, 27, 22, outline=c.ink, w=2, rad=2)
    c.line([(5, 9), (27, 9)], 1.5)
    c.poly([(13, 12), (13, 20), (20, 16)], fill="#58e06b")
    c.arrow(16, 27, 270, length=8, w=2, head=5)


for name, fn in (("run_bg", u_run_bg), ("check", u_check), ("insert", u_insert), ("delete", u_delete), ("duplicate", u_duplicate),
                 ("indent", u_indent), ("unindent", u_unindent), ("line_up", u_up),
                 ("line_down", u_down), ("cell_left", u_left), ("cell_right", u_right),
                 ("cell_delete", u_cell_delete), ("clear", u_clear)):
    ui(name, fn)
ui("power_on", u_power2(True))
ui("power_off", u_power2(False))
ui("persist_on", u_persist(True))
ui("persist_off", u_persist(False))

# --------------------------------------------------------- robot (16x16 art)

P = {
    "." : None,
    "k": (28, 30, 38, 255),     # dark
    "d": (58, 64, 78, 255),     # dark steel
    "m": (96, 106, 126, 255),   # steel
    "l": (150, 162, 184, 255),  # light steel
    "w": (214, 222, 236, 255),  # highlight
    "o": (224, 133, 43, 255),   # orange accent
    "O": (150, 82, 20, 255),
    "g": (88, 224, 107, 255),   # screen green
    "G": (32, 110, 50, 255),
    "b": (60, 140, 230, 255),
    "r": (210, 70, 60, 255),
    "y": (240, 210, 60, 255),
}


def sprite(rows, name):
    im = Image.new("RGBA", (16, 16), (0, 0, 0, 0))
    for y, row in enumerate(rows):
        for x, ch in enumerate(row):
            col = P[ch]
            if col:
                im.putpixel((x, y), col)
    im.save(os.path.join(TEX, name))


def panel(base="m", edge="d", hi="l"):
    rows = []
    for y in range(16):
        row = ""
        for x in range(16):
            if x in (0, 15) or y in (0, 15):
                row += edge
            elif x in (1,) or y in (1,):
                row += hi
            elif x == 14 or y == 14:
                row += "d"
            else:
                row += base
        rows.append(row)
    return [list(r) for r in rows]


def put(rows, x, y, ch):
    rows[y][x] = ch


def finish(rows):
    return ["".join(r) for r in rows]


# top: steel plate with an arrow towards the front (down the texture = -Z)
t = panel()
for (x, y) in ((3, 3), (12, 3), (3, 12), (12, 12)):
    put(t, x, y, "d")
    put(t, x + 0, y - 0, "d")
for y in range(4, 10):
    put(t, 7, y, "o")
    put(t, 8, y, "o")
# head, narrowing towards the bottom edge (the robot's front)
for row, half in enumerate((4, 3, 2, 1)):
    for x in range(8 - half, 8 + half):
        put(t, x, 10 + row, "o")
sprite(finish(t), "cogwork_top.png")

# bottom
b = panel("d", "k", "m")
for y in range(4, 12):
    for x in range(4, 12):
        if (x + y) % 2 == 0:
            put(b, x, y, "k")
sprite(finish(b), "cogwork_bottom.png")


def side(left):
    s = panel()
    # panel seam and a hatch
    for x in range(3, 13):
        put(s, x, 8, "d")
    for y in range(3, 8):
        put(s, 3, y, "d")
        put(s, 12, y, "d")
    for x in range(3, 13):
        put(s, x, 3, "d")
    for (x, y) in ((4, 4), (11, 4), (4, 6), (11, 6)):
        put(s, x, y, "w")
    # status stripe
    for x in range(3, 13):
        put(s, x, 11, "O")
        put(s, x, 12, "o")
    if left:
        put(s, 7, 5, "b")
        put(s, 8, 5, "b")
    else:
        put(s, 7, 5, "r")
        put(s, 8, 5, "r")
    return finish(s)


sprite(side(False), "cogwork_right.png")
sprite(side(True), "cogwork_left.png")

# back: grille and a cable socket
bk = panel()
for y in range(4, 11):
    for x in range(3, 13):
        put(bk, x, y, "k" if y % 2 == 0 else "d")
for x in range(6, 10):
    for y in range(11, 13):
        put(bk, x, y, "k")
put(bk, 7, 11, "y")
sprite(finish(bk), "cogwork_back.png")


def face(on):
    f = panel()
    # screen
    for y in range(3, 13):
        for x in range(2, 14):
            put(f, x, y, "k")
    for x in range(2, 14):
        put(f, x, 3, "d")
    eye = "g" if on else "G"
    for (x, y) in ((4, 5), (5, 5), (4, 6), (5, 6), (10, 5), (11, 5), (10, 6), (11, 6)):
        put(f, x, y, eye)
    if on:
        # smile
        for (x, y) in ((4, 9), (5, 10), (6, 10), (7, 10), (8, 10), (9, 10), (10, 10), (11, 9)):
            put(f, x, y, "g")
    else:
        for x in range(5, 11):
            put(f, x, 10, "G")
    return finish(f)


sprite(face(False), "cogwork_face.png")
sprite(face(True), "cogwork_face_on.png")

# model materials: plain metal, tread, accent; and the inventory picture
metal = panel()
for y in range(3, 13):
    for x in range(3, 13):
        if x in (3, 12) or y in (3, 12):
            put(metal, x, y, "d")
for (x, y) in ((4, 4), (11, 4), (4, 11), (11, 11)):
    put(metal, x, y, "w")
sprite(finish(metal), "cogwork_metal.png")

tread = panel("d", "k", "m")
for y in range(0, 16):
    for x in range(0, 16):
        if y % 4 == 0:
            put(tread, x, y, "k")
        elif y % 4 == 2 and x % 4 in (1, 2):
            put(tread, x, y, "m")
sprite(finish(tread), "cogwork_tread.png")

accent = panel("o", "O", "y")
for y in range(3, 13):
    for x in range(3, 13):
        if (x + y) % 5 == 0:
            put(accent, x, y, "O")
sprite(finish(accent), "cogwork_accent.png")

icon = [
    "......O..O......",
    ".......oo.......",
    "....kkkkkkkk....",
    "...kmllllllmk...",
    "...kmkkkkkkmk...",
    "...kmkggkkgkmk..",
    "...kmkggkkgkmk..",
    "...kmkkkkkkmk...",
    "...kmkgggggkmk..",
    "....kmmmmmmk....",
    "..kkkkkkkkkkkk..",
    ".kmmllllllllmmk.",
    ".kmkoooooooomkk.",
    ".kmkddddddddkmk.",
    ".kkkkkkkkkkkkkk.",
    "..dkkdkkdkkdkk..",
]
sprite(icon, "cogwork_robot_inv.png")

# ----------------------------------------------------------------- items

cas = [
    "................",
    "................",
    ".kkkkkkkkkkkkk..",
    ".kddddddddddddk.",
    ".kdwwwwwwwwwwdk.",
    ".kdwkkwwwwkkwdk.",
    ".kdwkkwwwwkkwdk.",
    ".kdwwwwwwwwwwdk.",
    ".kdoooooooooodk.",
    ".kdddddddddddk..",
    ".kdkkdkkdkkdkk..",
    ".kddddddddddk...",
    ".kkkkkkkkkkkk...",
    "................",
    "................",
    "................",
]
sprite(cas, "cogwork_cassette.png")

disk = [
    "................",
    "..kkkkkkkkkkk...",
    ".kbbbbbbmmmmkk..",
    ".kbbbbbbmkkmbk..",
    ".kbbbbbbmkkmbk..",
    ".kbbbbbbmmmmbk..",
    ".kbbbbbbbbbbbk..",
    ".kbwwwwwwwwwbk..",
    ".kbwooowwwwwbk..",
    ".kbwwwwwwwwwbk..",
    ".kbwooooowwwbk..",
    ".kbwwwwwwwwwbk..",
    ".kbbbbbbbbbbbk..",
    ".kkkkkkkkkkkkk..",
    "................",
    "................",
]
sprite(disk, "cogwork_disk.png")

hover = [
    "................",
    ".kkkkkkkkkkkkkk.",
    ".kddddddddddddk.",
    ".kdmmmmmmmmmmdk.",
    ".kdmmmmooommmdk.",
    ".kdmmmmmoommmdk.",
    ".kdmmmmmmmmmmdk.",
    ".kdmbbmmmmbbmdk.",
    ".kdmbwmmmmwbmdk.",
    ".kdmbbmmmmbbmdk.",
    ".kdmmbmmmmbmmdk.",
    ".kdmmmmmmmmmmdk.",
    ".kddddddddddddk.",
    ".kkkkkkkkkkkkkk.",
    "................",
    "................",
]
sprite(hover, "cogwork_upgrade_hover.png")

flight = [
    "................",
    "................",
    "..l..........l..",
    ".ll..kkkkkk..ll.",
    ".lwl.kddddk.lwl.",
    ".lmml.kmmk.lmml.",
    ".lmmmlkoookmmml.",
    "..lmmmkooklmml..",
    "...lmmkmmkmml...",
    "....lmkddkml....",
    ".....lkbbkl.....",
    "......kbbk......",
    ".......bb.......",
    "................",
    "................",
    "................",
]
sprite(flight, "cogwork_upgrade_flight.png")

# ----------------------------------------------------------------- structure items


def sprite_x(rows, name, extra):
    """sprite() with extra palette letters"""
    saved = dict(P)
    P.update(extra)
    try:
        sprite(rows, name)
    finally:
        P.clear()
        P.update(saved)


CELL_COLORS = {
    "small": ((88, 224, 107, 255), (32, 110, 50, 255)),
    "medium": ((240, 210, 60, 255), (150, 120, 20, 255)),
    "large": ((224, 133, 43, 255), (150, 82, 20, 255)),
    "huge": ((210, 70, 60, 255), (120, 30, 30, 255)),
    "colossal": ((170, 90, 230, 255), (90, 40, 140, 255)),
}


def cell_rows():
    rows = ["................", ".....kkkkkk.....", ".....kllllk.....", "....kkkkkkkk...."]
    for patt in ["CccccC", "cccyyc", "ccyycc", "cyyyyc", "cccyyc", "ccyycc", "cccccc", "cccccc", "CccccC"]:
        rows.append("...kd" + patt + "dk...")
    rows.append("...kkkkkkkkkk...")
    rows.append("................")
    return rows


for tier, (c, cd) in CELL_COLORS.items():
    extra = {"c": c, "C": cd}
    if tier == "medium":
        extra["y"] = (40, 44, 60, 255)   # the bolt would vanish into the yellow
    sprite_x(cell_rows(), "cogwork_cell_%s.png" % tier, extra)

ARMOR_COLORS = {
    "basic": ((150, 162, 184, 255), (96, 106, 126, 255)),
    "reinforced": ((88, 150, 230, 255), (50, 90, 160, 255)),
    "heavy": ((224, 133, 43, 255), (150, 82, 20, 255)),
}


def shield_rows():
    widths = {1: 12, 2: 12, 3: 12, 4: 12, 5: 12, 6: 12, 7: 12, 8: 12, 9: 10, 10: 8, 11: 6, 12: 4, 13: 2}
    fill = set()
    for y, w in widths.items():
        x0 = 8 - w // 2
        for x in range(x0, x0 + w):
            fill.add((x, y))
    grid = [["."] * 16 for _ in range(16)]
    for (x, y) in fill:
        edge = any((x + dx, y + dy) not in fill for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)))
        inner = not edge and any((x + dx, y + dy) in fill and any(
            (x + dx + ex, y + dy + ey) not in fill for ex, ey in ((1, 0), (-1, 0), (0, 1), (0, -1)))
            for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)))
        grid[y][x] = "k" if edge else ("C" if inner else "c")
    for x, y in ((4, 3), (5, 3), (4, 4), (5, 4), (4, 5)):
        grid[y][x] = "w"
    for y in range(4, 9):
        grid[y][8] = "d"
    return ["".join(r) for r in grid]


for tier, (c, cd) in ARMOR_COLORS.items():
    sprite_x(shield_rows(), "cogwork_armor_%s.png" % tier, {"c": c, "C": cd})


def chip(interior):
    rows = ["................", ".kkkkkkkkkkkkkk.", ".kddddddddddddk."]
    for patt in interior:
        rows.append(".kd" + patt + "dk.")
    rows += [".kddddddddddddk.", ".kkkkkkkkkkkkkk.", "................", "................"]
    return rows


sprite(chip(["mmmmmmmmmm", "mmmmggmmmm", "mmmmggmmmm", "mggggggggm", "mggggggggm",
             "mmmmggmmmm", "mmmmggmmmm", "mmmmmmmmmm", "mmmmmmmmmm"]), "cogwork_armor_mod_repair.png")

sprite_x(chip(["mmmmmmmmmm", "mmoooooomm", "mmoooooomm", "mmddyyddmm", "mmoooooomm",
               "mmoooooomm", "mmmmmmmmmm", "mmmmmmmmmm", "mmmmmmmmmm"]), "cogwork_upgrade_storage.png", {})

sprite(chip(["mmmmmmmmmm", "mmmmrrmmmm", "mmmmrrmmmm", "mmmmmmmmmm", "rrrmmmmrrr",
             "rrrmmmmrrr", "mmmmmmmmmm", "mmmmrrmmmm", "mmmmrrmmmm"][:9]), "cogwork_upgrade_combat.png")

sprite(chip(["mmmmmmmmmm", "mmoooooomm", "mooOOOOoom", "moOkkkkOom", "moOkkkkOom",
             "mooOOOOoom", "mmoooooomm", "mmmmmmmmmm", "mmmmmmmmmm"]), "cogwork_augment_generator.png")

capacitor = [
    "................",
    ".....kkkkkk.....",
    "....kvvvvvvk....",
    "...kvppppppvk...",
    "...kpppyyyppk...",
    "...kppyyyyppk...",
    "...kpppyyyppk...",
    "...kppppyyppk...",
    "...kppyyppppk...",
    "...kpppppppPk...",
    "...kPPPPPPPPk...",
    "....kkkkkkkk....",
    ".....kmmmmk.....",
    ".....kkkkkk.....",
    "................",
    "................",
]
sprite_x(capacitor, "cogwork_augment_capacitor.png",
         {"p": (170, 90, 230, 255), "P": (90, 40, 140, 255), "v": (220, 170, 255, 255)})

# ----------------------------------------------------------------- charger

CHARGER_COLORS = {
    "base": (80, 200, 230, 255),
    "lv": (240, 210, 60, 255),
    "mv": (224, 133, 43, 255),
    "techage": (60, 140, 230, 255),
    "sbz": (170, 90, 230, 255),
}


def charger_textures(variant, accent):
    from PIL import Image
    dark, steel, light = P["d"], P["m"], P["l"]
    # side: steel panel with a band in the accent colour
    side = Image.new("RGBA", (16, 16), steel)
    for x in range(16):
        for y in range(16):
            if x in (0, 15) or y in (0, 15):
                side.putpixel((x, y), dark)
    for x in range(1, 15):
        for y in (6, 7, 8, 9):
            side.putpixel((x, y), accent)
    for x, y in ((2, 2), (13, 2), (2, 13), (13, 13)):
        side.putpixel((x, y), light)
    side.save(os.path.join(TEX, "cogwork_charger_side_%s.png" % variant))

    # top: a pad with a lightning bolt where the robot stands
    top = Image.new("RGBA", (16, 16), steel)
    for x in range(16):
        for y in range(16):
            if x in (0, 15) or y in (0, 15):
                top.putpixel((x, y), dark)
            elif x in (1, 14) or y in (1, 14):
                top.putpixel((x, y), accent)
            elif 2 <= x <= 13 and 2 <= y <= 13:
                top.putpixel((x, y), P["d"] if (x + y) % 2 == 0 else (66, 72, 88, 255))
    bolt = [(9, 3), (8, 4), (8, 5), (7, 6), (7, 7), (8, 7), (6, 8), (6, 9), (7, 9), (5, 10), (6, 11), (6, 12),
            (9, 4), (8, 6), (9, 7), (7, 8), (8, 9), (7, 10), (7, 11)]
    for x, y in bolt:
        top.putpixel((x, y), P["y"])
    top.save(os.path.join(TEX, "cogwork_charger_top_%s.png" % variant))


for _variant, _accent in CHARGER_COLORS.items():
    charger_textures(_variant, _accent)

bottom = Image.new("RGBA", (16, 16), P["d"]) if "Image" in globals() else None
if bottom is not None:
    bottom.save(os.path.join(TEX, "cogwork_charger_bottom.png"))

# thruster particle: a soft blue-white spark
spark = Image.new("RGBA", (8, 8), (0, 0, 0, 0))
for _x in range(8):
    for _y in range(8):
        _d = math.hypot(_x - 3.5, _y - 3.5)
        if _d < 4:
            _a = int(255 * max(0.0, 1 - _d / 4) ** 1.5)
            spark.putpixel((_x, _y), (170, 215, 255, _a))
spark.save(os.path.join(TEX, "cogwork_particle.png"))

# ----------------------------------------------------------------- the robot's room


def room_tex(name, painter):
    im = Image.new("RGBA", (16, 16), P["m"])
    painter(im, im.load())
    im.save(os.path.join(TEX, "cogwork_room_%s.png" % name))


def r_border(px, col=None):
    for i in range(16):
        for pos in ((i, 0), (i, 15), (0, i), (15, i)):
            px[pos] = col or P["d"]


def r_rivets(px):
    for pos in ((2, 2), (13, 2), (2, 13), (13, 13)):
        px[pos] = P["l"]


def r_rect(px, x0, y0, x1, y1, col):
    for x in range(x0, x1 + 1):
        for y in range(y0, y1 + 1):
            px[x, y] = col


def p_wall(im, px):
    r_border(px)
    for y in range(1, 15):
        px[8, y] = P["d"]
    r_rivets(px)


def p_floor(im, px):
    for x in range(16):
        for y in range(16):
            px[x, y] = P["d"] if (x % 4 and y % 4) else P["m"]


def p_light(im, px):
    for x in range(16):
        for y in range(16):
            px[x, y] = (255, 250, 220, 255)
    r_border(px, (205, 200, 160, 255))


def p_frame(im, px):
    for x in range(16):
        for y in range(16):
            px[x, y] = (40, 44, 58, 255)
    r_border(px, P["o"])


def p_screen(im, px):
    for x in range(16):
        for y in range(16):
            px[x, y] = (16, 18, 26, 255) if y % 2 else (12, 14, 20, 255)


def p_console(im, px):
    r_border(px)
    r_rect(px, 3, 4, 12, 8, P["d"])
    for x, col in ((4, P["g"]), (7, P["y"]), (10, P["r"])):
        r_rect(px, x, 11, x + 1, 12, col)


def p_console_top(im, px):
    r_border(px)
    for i in range(2, 14, 3):
        r_rect(px, i, 2, i + 1, 13, P["d"])


def p_exit(im, px):
    for x in range(16):
        for y in range(16):
            px[x, y] = P["d"]
    for i in range(16):
        for pos in ((i, 0), (i, 1), (i, 14), (i, 15), (0, i), (1, i), (14, i), (15, i)):
            px[pos] = P["o"] if (i // 2) % 2 == 0 else P["k"]
    # an arrow pointing out
    for y in range(7, 9):
        for x in range(4, 11):
            px[x, y] = P["w"]
    for k in range(4):
        px[10 + 0, 4 + k] = P["w"] if k < 4 else P["d"]
        px[10, 11 - k] = P["w"]
        px[11 + (k // 2), 6 - k // 2 + 1] = P["w"]


def p_chest(im, px):
    r_border(px)
    r_rect(px, 1, 6, 14, 6, P["d"])
    r_rect(px, 6, 5, 9, 9, P["y"])
    r_rect(px, 7, 7, 8, 8, P["k"])


def p_chest_top(im, px):
    r_border(px)
    r_rect(px, 3, 3, 12, 12, P["l"])


def p_bay(im, px):
    r_border(px)
    for x in range(2, 14, 3):
        r_rect(px, x, 4, x + 1, 11, P["d"])
        px[x, 13] = P["g"]


def p_terminal(im, px):
    r_border(px)
    r_rect(px, 2, 2, 13, 10, P["k"])
    for y in (4, 6, 8):
        r_rect(px, 3, y, 3 + (y % 5) + 4, y, P["g"])
    r_rect(px, 4, 12, 11, 13, P["d"])


def p_terminal_top(im, px):
    r_border(px)
    r_rect(px, 4, 4, 11, 11, P["d"])


def p_settings(im, px):
    r_border(px)
    for y, knob in ((4, 5), (7, 10), (10, 7)):
        r_rect(px, 3, y, 12, y, P["d"])
        r_rect(px, knob, y - 1, knob + 1, y + 1, P["o"])
    r_rect(px, 4, 13, 11, 13, P["d"])


def p_settings_top(im, px):
    r_border(px)
    r_rect(px, 5, 5, 10, 10, P["d"])
    r_rect(px, 7, 7, 8, 8, P["o"])


def p_cam(im, px):
    r_border(px)
    r_rect(px, 3, 3, 12, 11, P["d"])
    r_rect(px, 5, 4, 10, 10, P["k"])
    r_rect(px, 6, 5, 9, 9, P["b"])
    px[7, 6] = px[8, 6] = P["w"]
    r_rect(px, 4, 13, 11, 13, P["d"])


def p_cam_top(im, px):
    r_border(px)
    r_rect(px, 4, 4, 11, 11, P["d"])
    r_rect(px, 6, 6, 9, 9, P["b"])


def p_ctl(im, px):
    r_border(px)
    px[7, 4] = px[8, 4] = px[7, 5] = px[8, 5] = P["r"]
    r_rect(px, 7, 6, 8, 9, P["d"])
    for x, col in ((3, P["g"]), (6, P["y"]), (9, P["b"]), (12, P["o"])):
        r_rect(px, x, 12, x + 1, 13, col)


def p_ctl_top(im, px):
    r_border(px)
    r_rect(px, 7, 3, 8, 12, P["d"])
    r_rect(px, 3, 7, 12, 8, P["d"])
    r_rect(px, 7, 7, 8, 8, P["r"])


for _name, _p in (("wall", p_wall), ("floor", p_floor), ("light", p_light), ("frame", p_frame),
                  ("screen", p_screen), ("console", p_console), ("console_top", p_console_top),
                  ("exit", p_exit), ("chest", p_chest), ("chest_top", p_chest_top), ("bay", p_bay),
                  ("terminal", p_terminal), ("terminal_top", p_terminal_top), ("settings", p_settings),
                  ("settings_top", p_settings_top), ("cam", p_cam), ("cam_top", p_cam_top), ("ctl", p_ctl),
                  ("ctl_top", p_ctl_top)):
    room_tex(_name, _p)

# ----------------------------------------------------------------- icons.lua

with open(os.path.join(MOD, "src", "icons.lua"), "w") as f:
    f.write("-- Generated by tools/gen_textures.py\n")
    f.write("-- Returns tokens, functions (\"pkg.fn\") and packages -> texture\n")
    f.write("local tokens = {\n")
    for token in sorted(TOKEN_FILES):
        key = token.replace("\\", "\\\\").replace('"', '\\"')
        f.write('\t["%s"] = "%s",\n' % (key, TOKEN_FILES[token]))
    f.write("}\nlocal functions = {\n")
    for k in sorted(FN_FILES):
        f.write('\t["%s"] = "%s",\n' % (k, FN_FILES[k][0]))
    f.write("}\nlocal packages = {\n")
    for k in sorted(PKG_FILES):
        f.write('\t["%s"] = "%s",\n' % (k, PKG_FILES[k]))
    f.write("}\nreturn tokens, functions, packages\n")

print("wrote %d token icons, %d function icons, %d package icons" % (
    len(TOKEN_FILES), len(FN_FILES), len(PKG_FILES)))
