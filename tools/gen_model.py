#!/usr/bin/env python3
"""Writes models/cogwork_robot.obj (a small robot), cogwork_hover.obj (the same
robot hovering, for when there is nothing under it) and cogwork_drone.obj (with a
Flight Upgrade), all built from boxes.

    python3 tools/gen_model.py

Materials, in tile order: 1 metal, 2 face, 3 tread, 4 accent, 5 grille.
The robot's front is -Z in the file, like a node's front tile.
"""
import math
import os

HERE = os.path.dirname(os.path.abspath(__file__))
MODELS = os.path.join(os.path.dirname(HERE), "models")

MATERIALS = ["metal", "face", "tread", "accent", "grille"]

verts, norms, uvs, faces = [], [], [], {m: [] for m in MATERIALS}


def idx(lst, v):
    lst.append(v)
    return len(lst)


# face: normal, 4 corners as (sx, sy, sz) selectors of (min=0|max=1), CCW from outside
FACES = {
    "+x": ((1, 0, 0), [(1, 0, 1), (1, 0, 0), (1, 1, 0), (1, 1, 1)]),
    "-x": ((-1, 0, 0), [(0, 0, 0), (0, 0, 1), (0, 1, 1), (0, 1, 0)]),
    "+y": ((0, 1, 0), [(0, 1, 1), (1, 1, 1), (1, 1, 0), (0, 1, 0)]),
    "-y": ((0, -1, 0), [(0, 0, 0), (1, 0, 0), (1, 0, 1), (0, 0, 1)]),
    "+z": ((0, 0, 1), [(0, 0, 1), (1, 0, 1), (1, 1, 1), (0, 1, 1)]),
    "-z": ((0, 0, -1), [(1, 0, 0), (0, 0, 0), (0, 1, 0), (1, 1, 0)]),
}
UV = [(0, 0), (1, 0), (1, 1), (0, 1)]


def spin(v, yaw):
    """turn a point or direction around the up axis by yaw degrees"""
    a = math.radians(yaw)
    c, s = math.cos(a), math.sin(a)
    return (v[0] * c - v[2] * s, v[1], v[0] * s + v[2] * c)


def box(x0, y0, z0, x1, y1, z1, material="metal", yaw=0, **per_face):
    lo, hi = (x0, y0, z0), (x1, y1, z1)
    for name, (n, corners) in FACES.items():
        mat = per_face.get(name.replace("+", "p").replace("-", "m"), material)
        ni = idx(norms, spin(n, yaw) if yaw else n)
        ids = []
        for (cx, cy, cz), uv in zip(corners, UV):
            p = tuple(hi[a] if s else lo[a] for a, s in enumerate((cx, cy, cz)))
            if yaw:
                p = spin(p, yaw)
            ids.append((idx(verts, p), idx(uvs, uv), ni))
        faces[mat].append(ids)


def robot():
    # treads
    box(-0.50, -0.50, -0.46, -0.30, -0.22, 0.46, "tread", py="metal", my="tread")
    box(0.30, -0.50, -0.46, 0.50, -0.22, 0.46, "tread", py="metal", my="tread")
    # axle between the treads
    box(-0.30, -0.42, -0.30, 0.30, -0.30, 0.30, "metal")
    # body
    box(-0.32, -0.30, -0.30, 0.32, 0.10, 0.30, "metal", pz="grille", py="accent")
    # chest panel on the front
    box(-0.20, -0.22, -0.32, 0.20, -0.02, -0.30, "accent")
    # arms
    box(-0.46, -0.20, -0.08, -0.32, 0.02, 0.08, "metal")
    box(0.32, -0.20, -0.08, 0.46, 0.02, 0.08, "metal")
    # neck
    box(-0.08, 0.10, -0.08, 0.08, 0.14, 0.08, "tread")
    # head with the face on the front
    box(-0.26, 0.14, -0.24, 0.26, 0.40, 0.24, "metal", mz="face", pz="grille")
    # antenna
    box(-0.025, 0.40, -0.025, 0.025, 0.46, 0.025, "tread")
    box(-0.055, 0.44, -0.055, 0.055, 0.50, 0.055, "accent")



def hover():
    # the robot without treads: a hover pad with four glowing nozzles under the body
    box(-0.34, -0.40, -0.34, 0.34, -0.30, 0.34, "tread", my="accent")
    for cx, cz in ((-0.24, -0.24), (0.24, -0.24), (-0.24, 0.24), (0.24, 0.24)):
        box(cx - 0.06, -0.50, cz - 0.06, cx + 0.06, -0.40, cz + 0.06, "accent", my="metal")
    # body
    box(-0.32, -0.30, -0.30, 0.32, 0.10, 0.30, "metal", pz="grille", py="accent")
    # chest panel on the front
    box(-0.20, -0.22, -0.32, 0.20, -0.02, -0.30, "accent")
    # arms
    box(-0.46, -0.20, -0.08, -0.32, 0.02, 0.08, "metal")
    box(0.32, -0.20, -0.08, 0.46, 0.02, 0.08, "metal")
    # neck
    box(-0.08, 0.10, -0.08, 0.08, 0.14, 0.08, "tread")
    # head with the face on the front
    box(-0.26, 0.14, -0.24, 0.26, 0.40, 0.24, "metal", mz="face", pz="grille")
    # antenna
    box(-0.025, 0.40, -0.025, 0.025, 0.46, 0.025, "tread")
    box(-0.055, 0.44, -0.055, 0.055, 0.50, 0.055, "accent")


def rotor():
    # two crossed blades, centred: it spins around its own middle
    box(-0.14, -0.01, -0.025, 0.14, 0.01, 0.025, "tread")
    box(-0.025, -0.01, -0.14, 0.025, 0.01, 0.14, "tread")


def drone():
    # skids
    box(-0.26, -0.50, -0.30, -0.20, -0.36, 0.30, "tread")
    box(0.20, -0.50, -0.30, 0.26, -0.36, 0.30, "tread")
    box(-0.26, -0.40, -0.30, 0.26, -0.36, -0.24, "tread")
    box(-0.26, -0.40, 0.24, 0.26, -0.36, 0.30, "tread")
    # body with the face on the front and a grille behind
    box(-0.24, -0.36, -0.24, 0.24, -0.04, 0.24, "metal", mz="face", pz="grille", py="accent")
    # four arms in an X, like a quadcopter: two long bars across the corners
    box(-0.62, -0.22, -0.04, 0.62, -0.14, 0.04, "metal", yaw=45)
    box(-0.62, -0.22, -0.04, 0.62, -0.14, 0.04, "metal", yaw=-45)
    # a motor at the end of each arm; the rotor blades are a model of their own
    # (rotor.obj, an entity that spins) set on top of each motor
    for cx, cz in ((-0.38, -0.38), (0.38, -0.38), (-0.38, 0.38), (0.38, 0.38)):
        box(cx - 0.05, -0.14, cz - 0.05, cx + 0.05, -0.04, cz + 0.05, "accent")
    # antenna on the back
    box(-0.02, -0.04, 0.12, 0.02, 0.16, 0.16, "tread")
    box(-0.05, 0.12, 0.10, 0.05, 0.20, 0.18, "accent")


def write(name, comment):
    for v in verts:
        assert all(-0.5 <= c <= 0.5 for c in v), v

    os.makedirs(MODELS, exist_ok=True)
    out = os.path.join(MODELS, name)
    with open(out, "w") as f:
        f.write("# %s, generated by tools/gen_model.py\n" % comment)
        # entity models are 10 units to the node (the robots are entities now)
        for v in verts:
            f.write("v %.4f %.4f %.4f\n" % tuple(c * 10 for c in v))
        for u in uvs:
            f.write("vt %.4f %.4f\n" % u)
        for n in norms:
            f.write("vn " + " ".join(("%d" % c) if float(c).is_integer() else ("%.4f" % c) for c in n) + "\n")
        for m in MATERIALS:
            if not faces[m]:
                continue
            # a "g" line is what makes Irrlicht start a separate buffer (and tile)
            f.write("g %s\nusemtl %s\n" % (m, m))
            for ids in faces[m]:
                f.write("f " + " ".join("%d/%d/%d" % t for t in ids) + "\n")
    print("wrote", out, len(verts), "vertices")


def build(fn, name, comment):
    verts.clear(); norms.clear(); uvs.clear()
    for m in MATERIALS:
        faces[m].clear()
    fn()
    write(name, comment)


build(robot, "cogwork_robot.obj", "Cogwork robot")
build(hover, "cogwork_hover.obj", "Cogwork hover robot (nothing under it)")
build(rotor, "cogwork_rotor.obj", "Cogwork drone rotor (spins)")
build(drone, "cogwork_drone.obj", "Cogwork drone (a robot with a Flight Upgrade)")
