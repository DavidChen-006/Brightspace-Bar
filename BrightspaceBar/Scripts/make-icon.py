#!/usr/bin/env python3
"""Regenerate Modules/BrightspaceBar/Resources/MotionP.pdf from the logo SVG.

    ./Scripts/make-icon.py motionp.svg MotionP.pdf 12 1 letterform

No dependencies, because there is no SVG converter on a stock macOS box: SVG
path data and PDF content streams share the same curve model, so this parses the
handful of commands the logo uses (relative m/l/h/c/z) into absolute points and
re-emits them as PDF operators.

The source SVG stacks three copies of the mark - a black keyline, a grey shim,
and the gold letterform on top. `letterform` takes the gold layer, which is the
real shape and already pairs its outer contour with the P's counter; `keyline`
takes the outermost outline instead, which at menu-bar size closes the counter
up into a blob. The height argument is the glyph, excluding padding.
"""
import re, sys

NUM = re.compile(r'[-+]?(?:\d*\.\d+|\d+)(?:[eE][-+]?\d+)?')


def parse(d):
    """SVG path data -> [subpath], subpath = [('m'|'l'|'c', pts...)] absolute."""
    toks = re.findall(r'[A-Za-z]|[-+]?(?:\d*\.\d+|\d+)(?:[eE][-+]?\d+)?', d)
    i, cx, cy, sx, sy = 0, 0.0, 0.0, 0.0, 0.0
    subs, cur, cmd = [], None, None
    def num():
        nonlocal i
        v = float(toks[i]); i += 1; return v
    while i < len(toks):
        if re.match(r'[A-Za-z]', toks[i]):
            cmd = toks[i]; i += 1
        if cmd == 'm':
            if cur: subs.append(cur)
            cx += num(); cy += num(); sx, sy = cx, cy
            cur = [('m', (cx, cy))]
            cmd = 'l'                      # extra pairs after m are lineto
        elif cmd == 'l':
            cx += num(); cy += num(); cur.append(('l', (cx, cy)))
        elif cmd == 'h':
            cx += num(); cur.append(('l', (cx, cy)))
        elif cmd == 'v':
            cy += num(); cur.append(('l', (cx, cy)))
        elif cmd == 'c':
            p1 = (cx + num(), cy + num()); p2 = (cx + num(), cy + num())
            cx += num(); cy += num()
            cur.append(('c', p1, p2, (cx, cy)))
        elif cmd == 'z':
            cur.append(('z',)); cx, cy = sx, sy; i += 0
        else:
            raise SystemExit('unhandled command %r' % cmd)
    if cur: subs.append(cur)
    return subs


def bezier_pts(p0, p1, p2, p3, n=24):
    for k in range(n + 1):
        t = k / n; u = 1 - t
        yield (u*u*u*p0[0] + 3*u*u*t*p1[0] + 3*u*t*t*p2[0] + t*t*t*p3[0],
               u*u*u*p0[1] + 3*u*u*t*p1[1] + 3*u*t*t*p2[1] + t*t*t*p3[1])


def bbox(subs):
    xs, ys, cur = [], [], (0, 0)
    for sub in subs:
        for seg in sub:
            if seg[0] == 'z': continue
            if seg[0] == 'c':
                for p in bezier_pts(cur, seg[1], seg[2], seg[3]):
                    xs.append(p[0]); ys.append(p[1])
                cur = seg[3]
            else:
                xs.append(seg[1][0]); ys.append(seg[1][1]); cur = seg[1]
    return min(xs), min(ys), max(xs), max(ys)


def main():
    svg = open(sys.argv[1]).read()
    out = sys.argv[2]
    height = float(sys.argv[3])          # target height in points
    pad = float(sys.argv[4]) if len(sys.argv) > 4 else 0.0

    paths = re.findall(r'<path d="([^"]+)"', svg)
    m = re.search(r'matrix\(([^)]+)\)', svg)
    a, b, c, d, e, f = [float(x) for x in NUM.findall(m.group(1))]

    variant = sys.argv[5] if len(sys.argv) > 5 else 'keyline'
    if variant == 'keyline':
        # Outer black outline (path 0) + the counter from path 2, even-odd.
        subs = parse(paths[0]) + parse(paths[2])[1:]
    else:
        # The gold layer: the true letterform, outer + counter already paired.
        subs = parse(paths[2])

    # SVG user space -> logo space
    def tx(p): return (a*p[0] + c*p[1] + e, b*p[0] + d*p[1] + f)
    subs = [[(s[0],) if s[0] == 'z' else (s[0],) + tuple(tx(p) for p in s[1:])
             for s in sub] for sub in subs]

    x0, y0, x1, y1 = bbox(subs)
    s = height / (y1 - y0)
    w = (x1 - x0) * s + 2 * pad
    h = height + 2 * pad

    # ...and into PDF space: y flips, origin at the padded bottom-left.
    def to_pdf(p):
        return (pad + (p[0] - x0) * s, pad + (y1 - p[1]) * s)

    ops = []
    for sub in subs:
        for seg in sub:
            if seg[0] == 'z':
                ops.append('h')
            elif seg[0] == 'c':
                q = [to_pdf(p) for p in seg[1:]]
                ops.append('%.4f %.4f %.4f %.4f %.4f %.4f c' % (*q[0], *q[1], *q[2]))
            else:
                ops.append('%.4f %.4f %s' % (*to_pdf(seg[1]), 'm' if seg[0] == 'm' else 'l'))
    stream = '0 g\n' + '\n'.join(ops) + '\nf*\n'

    objs = [
        '<< /Type /Catalog /Pages 2 0 R >>',
        '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
        '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 %.4f %.4f] /Contents 4 0 R '
        '/Resources << >> >>' % (w, h),
        '<< /Length %d >>\nstream\n%s\nendstream' % (len(stream), stream),
    ]
    pdf, offsets = '%PDF-1.4\n', []
    for n, o in enumerate(objs, 1):
        offsets.append(len(pdf))
        pdf += '%d 0 obj\n%s\nendobj\n' % (n, o)
    start = len(pdf)
    pdf += 'xref\n0 %d\n0000000000 65535 f \n' % (len(objs) + 1)
    pdf += ''.join('%010d 00000 n \n' % o for o in offsets)
    pdf += ('trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n'
            % (len(objs) + 1, start))
    open(out, 'wb').write(pdf.encode('latin-1'))
    print('%s  %.2f x %.2f pt' % (out, w, h))


main()
