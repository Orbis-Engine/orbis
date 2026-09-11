#!/usr/bin/env python3
"""Writes a Gaussian splat capture with real view-dependent colour in it.

A trained capture is hundreds of megabytes of somebody else's photographs, and
the repository carries none. This writes one from nothing instead — the same
binary little-endian `.ply` the reference trainer writes, `f_rest_*` bands and
all — so that a change to how Orbis reads or draws spherical harmonics can be
looked at rather than reasoned about. A hundred and twenty thousand splats is
twenty megabytes and a couple of seconds.

The cloud is a ring of flattened discs lying on a torus, which is the shape the
gallery's own splats example generates, so the two can be put side by side.
What differs is the colour. Each disc's degree-zero colour is a flat cool grey,
and its higher bands carry a lobe pointed along the disc's own normal:

    c_lm = amplitude_l * Y_lm(normal)

which by the addition theorem sums to amplitude_l * (2l+1)/(4 pi) * P_l(cos a),
where a is the angle between the direction the disc is being looked along and
its normal. So a disc's colour swings as the camera goes round it, and the
sheen slides around the ring — which is what a shiny surface does in a real
capture, and is the thing degree-zero colour cannot do at all.

It is also a check on the basis rather than only a picture of one. The table
below is written out from the normalisations, the same way splat.mat writes it
out; if a sign in either disagreed with the other, the sheen would land on the
wrong side of the ring instead of merely looking a bit different.

    tool/make_splat_capture.py ring.ply [--degree 0..3] [--count N]

Then, with the gallery built:

    ORBIS_EXAMPLE="Gaussian splats" ORBIS_SPLAT=<path> ORBIS_YAW=0.6 \
      ORBIS_SECONDS=3 ORBIS_DUMP_FRAME=60 <the app's binary>

Note that a sandboxed macOS build can only read the file from inside its own
container, so put it under
~/Library/Containers/dev.orbis.orbisGallery/Data/tmp.
"""

import argparse
import math
import random
import struct

# The real-valued spherical harmonics in Cartesian form, on a unit vector.
# Orthonormal over the sphere, with the Condon-Shortley phase, which is the
# convention every 3D Gaussian splatting trainer writes f_rest in. The
# constants are the normalisations: sqrt(3/4pi) for the first band;
# sqrt(15/4pi), sqrt(5/16pi) and sqrt(15/16pi) for the second; sqrt(35/32pi),
# sqrt(105/4pi), sqrt(21/32pi), sqrt(7/16pi) and sqrt(105/16pi) for the third.
C1 = 0.4886025119029199
C2_XY = 1.0925484305920792
C2_Z2 = 0.31539156525252005
C2_X2 = 0.5462742152960396
C3_A = 0.5900435899266435
C3_B = 2.890611442640554
C3_C = 0.4570457994644658
C3_D = 0.3731763325901154
C3_E = 1.445305721320277

# What the degree-zero coefficient is multiplied by to become colour, which is
# how the renderer reads f_dc: colour = 0.5 + Y00 * f_dc.
Y00 = 0.28209479177387814


def basis(x, y, z, degree):
    """Y_lm for l = 1..degree, in the order f_rest stores them."""
    values = []
    if degree >= 1:
        values += [-C1 * y, C1 * z, -C1 * x]
    if degree >= 2:
        xx, yy, zz = x * x, y * y, z * z
        values += [
            C2_XY * x * y,
            -C2_XY * y * z,
            C2_Z2 * (2.0 * zz - xx - yy),
            -C2_XY * x * z,
            C2_X2 * (xx - yy),
        ]
    if degree >= 3:
        xx, yy, zz = x * x, y * y, z * z
        values += [
            -C3_A * y * (3.0 * xx - yy),
            C3_B * x * y * z,
            -C3_C * y * (4.0 * zz - xx - yy),
            C3_D * z * (2.0 * zz - 3.0 * xx - 3.0 * yy),
            -C3_C * x * (4.0 * zz - xx - yy),
            C3_E * z * (xx - yy),
            -C3_A * x * (xx - 3.0 * yy),
        ]
    return values


def logit(p):
    """Opacity as a trainer stores it, so it can be fitted without a clamp."""
    p = min(max(p, 1e-6), 1.0 - 1e-6)
    return math.log(p / (1.0 - p))


def quaternion_from_axes(a, b, c):
    """A unit quaternion (w, x, y, z) from three orthonormal columns."""
    m = [[a[0], b[0], c[0]], [a[1], b[1], c[1]], [a[2], b[2], c[2]]]
    trace = m[0][0] + m[1][1] + m[2][2]
    if trace > 0:
        s = math.sqrt(trace + 1.0) * 2
        q = (0.25 * s, (m[2][1] - m[1][2]) / s, (m[0][2] - m[2][0]) / s,
             (m[1][0] - m[0][1]) / s)
    elif m[0][0] > m[1][1] and m[0][0] > m[2][2]:
        s = math.sqrt(1.0 + m[0][0] - m[1][1] - m[2][2]) * 2
        q = ((m[2][1] - m[1][2]) / s, 0.25 * s, (m[0][1] + m[1][0]) / s,
             (m[0][2] + m[2][0]) / s)
    elif m[1][1] > m[2][2]:
        s = math.sqrt(1.0 + m[1][1] - m[0][0] - m[2][2]) * 2
        q = ((m[0][2] - m[2][0]) / s, (m[0][1] + m[1][0]) / s, 0.25 * s,
             (m[1][2] + m[2][1]) / s)
    else:
        s = math.sqrt(1.0 + m[2][2] - m[0][0] - m[1][1]) * 2
        q = ((m[1][0] - m[0][1]) / s, (m[0][2] + m[2][0]) / s,
             (m[1][2] + m[2][1]) / s, 0.25 * s)
    length = math.sqrt(sum(component * component for component in q)) or 1.0
    return tuple(component / length for component in q)


def ring(count, degree, seed=7):
    """Discs on a torus, each with a lobe along its own normal."""
    random.seed(seed)
    major, minor, tilt = 1.6, 0.55, 0.5
    ct, st = math.cos(tilt), math.sin(tilt)
    # How strong each band's lobe is, per colour channel: warm, so the sheen
    # reads against the cool flat colour under it.
    amplitudes = [(1.9, 1.35, 0.55), (0.9, 0.6, 0.25), (0.35, 0.22, 0.10)]
    amplitudes = amplitudes[:max(degree, 0)]

    out = []
    for i in range(count):
        # In order round the ring, jittered, as the example generates it.
        u = (i + random.random()) / count * 2 * math.pi
        v = random.random() * 2 * math.pi
        cu, su, cv, sv = math.cos(u), math.sin(u), math.cos(v), math.sin(v)

        radius = major + minor * cv
        position = [radius * cu, minor * sv, radius * su]
        along = [-su, 0.0, cu]
        around = [-sv * cu, cv, -sv * su]
        normal = [cv * cu, sv, cv * su]

        def tilted(a):
            return [a[0], a[1] * ct - a[2] * st, a[1] * st + a[2] * ct]

        position = tilted(position)
        position[1] += 1.0
        along, around, normal = tilted(along), tilted(around), tilted(normal)

        # Written upside down, the way structure-from-motion leaves a capture:
        # y points down, because that is where the first photograph's camera
        # had it. Anything showing a capture turns it back with a half turn
        # about x, so writing it the right way up would show it below the
        # floor.
        def flip(a):
            return [a[0], -a[1], -a[2]]

        position, along, around, normal = (
            flip(position), flip(along), flip(around), flip(normal)
        )

        size = 0.018 + random.random() * 0.02
        scale = [size, size * (0.6 + random.random() * 0.4), 0.003]
        rotation = quaternion_from_axes(along, around, normal)

        shade = 0.88 + random.random() * 0.12
        colour = [0.26 * shade, 0.30 * shade, 0.38 * shade]
        dc = [(channel - 0.5) / Y00 for channel in colour]

        # The lobe, coefficient by coefficient. Kept per channel, because the
        # file stores all of red's before any of green's.
        rest = [[], [], []]
        if amplitudes:
            values = basis(normal[0], normal[1], normal[2], degree)
            at = 0
            for band, amplitude in enumerate(amplitudes, start=1):
                width = 2 * band + 1
                for k in range(width):
                    for channel in range(3):
                        rest[channel].append(amplitude[channel] * values[at + k])
                at += width

        out.append((position, dc, rest, 0.55, scale, rotation))
    return out


def write_ply(path, splats, degree):
    per_channel = {0: 0, 1: 3, 2: 8, 3: 15}[degree]
    names = ["x", "y", "z", "nx", "ny", "nz", "f_dc_0", "f_dc_1", "f_dc_2"]
    names += [f"f_rest_{i}" for i in range(per_channel * 3)]
    names += ["opacity", "scale_0", "scale_1", "scale_2"]
    names += [f"rot_{i}" for i in range(4)]

    header = ["ply", "format binary_little_endian 1.0",
              f"element vertex {len(splats)}"]
    header += [f"property float {name}" for name in names]
    header += ["end_header", ""]

    with open(path, "wb") as file:
        file.write("\n".join(header).encode("ascii"))
        for position, dc, rest, opacity, scale, rotation in splats:
            # Normals are nought, as a trainer writes them: nothing reads them.
            row = list(position) + [0.0, 0.0, 0.0] + list(dc)
            for channel in range(3):
                row += rest[channel]
            row.append(logit(opacity))
            row += [math.log(s) for s in scale]
            row += list(rotation)
            file.write(struct.pack(f"<{len(row)}f", *row))
    return len(names)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("out", help="where to write the .ply")
    parser.add_argument("--degree", type=int, default=2, choices=[0, 1, 2, 3],
                        help="how many spherical-harmonic bands to write")
    parser.add_argument("--count", type=int, default=120000,
                        help="how many splats")
    arguments = parser.parse_args()

    splats = ring(arguments.count, arguments.degree)
    properties = write_ply(arguments.out, splats, arguments.degree)
    print(f"{arguments.out}: {len(splats)} splats, degree {arguments.degree}, "
          f"{properties} properties a vertex")


if __name__ == "__main__":
    main()
