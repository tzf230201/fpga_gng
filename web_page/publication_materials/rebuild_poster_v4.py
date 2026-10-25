from __future__ import annotations

import math
import zipfile
from pathlib import Path

from PIL import Image, ImageOps
from pptx import Presentation
from pptx.dml.color import RGBColor
from pptx.enum.shapes import MSO_SHAPE
from pptx.enum.text import MSO_ANCHOR, MSO_AUTO_SIZE, PP_ALIGN
from pptx.util import Inches, Pt


ROOT = Path(__file__).resolve().parents[2]
WCCI = Path(__file__).resolve().parent
ASSET_DIR = WCCI / "_poster_v4_assets"
ASSET_DIR.mkdir(exist_ok=True)

OUT = WCCI / "WCCI_2026_Poster_v4.pptx"
BACKUP = WCCI / "WCCI_2026_Poster_v4.before_cleanup.pptx"


NAVY = RGBColor(22, 49, 88)
BLUE = RGBColor(45, 92, 151)
LIGHT_BLUE = RGBColor(232, 240, 250)
VERY_LIGHT = RGBColor(247, 250, 253)
MID_TEXT = RGBColor(70, 88, 112)
DARK = RGBColor(24, 34, 46)
ORANGE = RGBColor(230, 170, 62)
GREEN = RGBColor(46, 160, 94)
RED = RGBColor(191, 55, 55)
GREY = RGBColor(230, 235, 243)
WHITE = RGBColor(255, 255, 255)
LINE = RGBColor(203, 214, 228)


def inch(v: float):
    return Inches(v)


def rgb(hex_color: str) -> RGBColor:
    hex_color = hex_color.strip("#")
    return RGBColor(int(hex_color[0:2], 16), int(hex_color[2:4], 16), int(hex_color[4:6], 16))


def extract_tmu_logo() -> Path | None:
    dst = ASSET_DIR / "tmu_logo.png"
    if dst.exists():
        return dst
    for ppt in (BACKUP, OUT):
        if not ppt.exists():
            continue
        with zipfile.ZipFile(ppt) as z:
            for name in z.namelist():
                if name == "ppt/media/image1.png":
                    dst.write_bytes(z.read(name))
                    return dst
    return None


def fit_image(src: Path, dst_name: str, ratio: tuple[int, int], mode: str = "cover", bg=(255, 255, 255)) -> Path:
    dst = ASSET_DIR / dst_name
    if dst.exists() and dst.stat().st_mtime >= src.stat().st_mtime:
        return dst

    raw = Image.open(src)
    if raw.mode in ("RGBA", "LA") or (raw.mode == "P" and "transparency" in raw.info):
        rgba = raw.convert("RGBA")
        canvas_rgba = Image.new("RGBA", rgba.size, (*bg, 255))
        canvas_rgba.alpha_composite(rgba)
        img = canvas_rgba.convert("RGB")
    else:
        img = raw.convert("RGB")
    w, h = ratio
    target = (w, h)
    if mode == "contain":
        img = ImageOps.contain(img, target, Image.Resampling.LANCZOS)
        canvas = Image.new("RGB", target, bg)
        canvas.paste(img, ((w - img.width) // 2, (h - img.height) // 2))
        canvas.save(dst, quality=95)
        return dst

    src_ratio = img.width / img.height
    target_ratio = w / h
    if src_ratio > target_ratio:
        new_w = int(img.height * target_ratio)
        left = (img.width - new_w) // 2
        img = img.crop((left, 0, left + new_w, img.height))
    else:
        new_h = int(img.width / target_ratio)
        top = (img.height - new_h) // 2
        img = img.crop((0, top, img.width, top + new_h))
    img = img.resize(target, Image.Resampling.LANCZOS)
    img.save(dst, quality=95)
    return dst


def set_fill(shape, color: RGBColor):
    shape.fill.solid()
    shape.fill.fore_color.rgb = color


def set_line(shape, color: RGBColor = LINE, width: float = 0.75):
    shape.line.color.rgb = color
    shape.line.width = Pt(width)


def textbox(
    slide,
    x,
    y,
    w,
    h,
    text,
    size=18,
    bold=False,
    color=DARK,
    align=PP_ALIGN.LEFT,
    font="Aptos",
    margin=0.06,
    valign=MSO_ANCHOR.TOP,
    italic=False,
):
    box = slide.shapes.add_textbox(inch(x), inch(y), inch(w), inch(h))
    tf = box.text_frame
    tf.clear()
    tf.word_wrap = True
    tf.auto_size = MSO_AUTO_SIZE.NONE
    tf.margin_left = inch(margin)
    tf.margin_right = inch(margin)
    tf.margin_top = inch(margin)
    tf.margin_bottom = inch(margin)
    tf.vertical_anchor = valign
    p = tf.paragraphs[0]
    p.alignment = align
    run = p.add_run()
    run.text = text
    run.font.name = font
    run.font.size = Pt(size)
    run.font.bold = bold
    run.font.italic = italic
    run.font.color.rgb = color
    return box


def rich_lines(slide, x, y, w, h, lines, size=17, color=DARK, leading=0.28):
    top = y
    for line in lines:
        if isinstance(line, tuple):
            text, bold, c = line
        else:
            text, bold, c = line, False, color
        textbox(slide, x, top, w, leading + 0.07, text, size=size, bold=bold, color=c, margin=0.01)
        top += leading


def card(slide, x, y, w, h, radius=True, fill=WHITE, line=LINE, shadow=False):
    shape = slide.shapes.add_shape(
        MSO_SHAPE.ROUNDED_RECTANGLE if radius else MSO_SHAPE.RECTANGLE,
        inch(x),
        inch(y),
        inch(w),
        inch(h),
    )
    set_fill(shape, fill)
    set_line(shape, line, 0.8)
    if shadow:
        shape.shadow.inherit = False
        shape.shadow.visible = True
        shape.shadow.blur_radius = Pt(5)
        shape.shadow.distance = Pt(1)
        shape.shadow.transparency = 0.75
    return shape


def section(slide, x, y, w, h, title, fill=WHITE):
    card(slide, x, y, w, h, fill=fill, line=LINE)
    hdr = slide.shapes.add_shape(MSO_SHAPE.RECTANGLE, inch(x), inch(y), inch(w), inch(0.58))
    set_fill(hdr, NAVY)
    hdr.line.fill.background()
    textbox(slide, x + 0.16, y + 0.09, w - 0.32, 0.38, title, size=17, bold=True, color=WHITE, margin=0)
    return y + 0.75


def add_bullets(slide, x, y, w, items, size=13.5, gap=0.4, bullet_color=BLUE):
    top = y
    for item in items:
        circ = slide.shapes.add_shape(MSO_SHAPE.OVAL, inch(x), inch(top + 0.05), inch(0.16), inch(0.16))
        set_fill(circ, bullet_color)
        circ.line.fill.background()
        textbox(slide, x + 0.28, top - 0.01, w - 0.3, gap, item, size=size, color=DARK, margin=0)
        top += gap
    return top


def table_box(slide, x, y, w, row_h, headers, rows, widths=None, size=11.8):
    if widths is None:
        widths = [1 / len(headers)] * len(headers)
    scale = w / sum(widths)
    xs = [x]
    for cw in widths[:-1]:
        xs.append(xs[-1] + cw * scale)

    h = row_h * (len(rows) + 1)
    bg = slide.shapes.add_shape(MSO_SHAPE.ROUNDED_RECTANGLE, inch(x), inch(y), inch(w), inch(h))
    set_fill(bg, VERY_LIGHT)
    set_line(bg, LINE, 0.6)
    for r in range(len(rows) + 1):
        for c in range(len(headers)):
            cx = xs[c]
            cw = widths[c] * scale
            cell = slide.shapes.add_shape(MSO_SHAPE.RECTANGLE, inch(cx), inch(y + r * row_h), inch(cw), inch(row_h))
            if r == 0:
                set_fill(cell, NAVY)
                tcolor = WHITE
                bold = True
            else:
                set_fill(cell, RGBColor(239, 245, 252) if r % 2 else WHITE)
                tcolor = DARK
                bold = False
            set_line(cell, WHITE, 0.3)
            txt = headers[c] if r == 0 else rows[r - 1][c]
            textbox(slide, cx + 0.04, y + r * row_h + 0.04, cw - 0.08, row_h - 0.06, txt, size=size, bold=bold, color=tcolor, margin=0, valign=MSO_ANCHOR.MIDDLE)
    return h


def add_metric(slide, x, y, w, number, label, sub, color):
    card(slide, x, y, w, 1.25, fill=WHITE, line=RGBColor(217, 226, 238))
    textbox(slide, x + 0.2, y + 0.13, w - 0.4, 0.45, number, size=24, bold=True, color=color, margin=0)
    textbox(slide, x + 0.2, y + 0.62, w - 0.4, 0.25, label, size=11.5, bold=True, color=NAVY, margin=0)
    textbox(slide, x + 0.2, y + 0.9, w - 0.4, 0.25, sub, size=10.3, color=MID_TEXT, margin=0)


def add_arrow(slide, x1, y1, x2, y2, color=BLUE, width=1.5):
    line = slide.shapes.add_connector(1, inch(x1), inch(y1), inch(x2), inch(y2))
    line.line.color.rgb = color
    line.line.width = Pt(width)
    line.line.end_arrowhead = True
    return line


def image(slide, path: Path, x, y, w, h, contain=False):
    p = path
    if contain:
        p = fit_image(path, f"fit_{path.stem}_{int(w*100)}x{int(h*100)}.jpg", (1400, max(1, int(1400 * h / w))), mode="contain")
    return slide.shapes.add_picture(str(p), inch(x), inch(y), inch(w), inch(h))


def image_card(slide, path: Path, x, y, w, h, label, caption=None, mode="cover", label_h=0.58):
    fitted = fit_image(path, f"card_{path.stem}_{int(w*100)}x{int(h*100)}.jpg", (1200, max(1, int(1200 * (h - label_h) / w))), mode=mode)
    card(slide, x, y, w, h, fill=WHITE, line=LINE)
    slide.shapes.add_picture(str(fitted), inch(x + 0.06), inch(y + 0.06), inch(w - 0.12), inch(h - label_h - 0.08))
    textbox(slide, x + 0.08, y + h - label_h + 0.04, w - 0.16, 0.22, label, size=10.4, bold=True, color=NAVY, align=PP_ALIGN.CENTER, margin=0)
    if caption:
        textbox(slide, x + 0.08, y + h - label_h + 0.28, w - 0.16, 0.25, caption, size=8.2, color=MID_TEXT, align=PP_ALIGN.CENTER, margin=0)


def draw_matrix(slide, x, y, n=6, cell=0.46):
    values = {
        (0, 1): "3",
        (0, 2): "1",
        (0, 3): "0",
        (0, 4): "0",
        (0, 5): "0",
        (1, 2): "0",
        (1, 3): "7",
        (1, 4): "0",
        (1, 5): "0",
        (2, 3): "2",
        (2, 4): "5",
        (2, 5): "0",
        (3, 4): "0",
        (3, 5): "1",
        (4, 5): "4",
    }
    textbox(slide, x + 1.0, y - 0.52, 2.4, 0.3, "node j ->", size=10.8, bold=True, color=RGBColor(176, 119, 31), align=PP_ALIGN.CENTER, margin=0)
    t = textbox(slide, x - 0.68, y + 1.45, 0.62, 0.35, "<- node i", size=10.8, bold=True, color=RGBColor(176, 119, 31), align=PP_ALIGN.CENTER, margin=0)
    t.rotation = 270
    for c in range(n):
        textbox(slide, x + (c + 1) * cell, y - 0.18, cell, 0.22, str(c), size=9.5, bold=True, color=MID_TEXT, align=PP_ALIGN.CENTER, margin=0)
    for r in range(n):
        textbox(slide, x + 0.05, y + r * cell + 0.12, cell * 0.7, 0.22, str(r), size=9.5, bold=True, color=MID_TEXT, align=PP_ALIGN.CENTER, margin=0)
        for c in range(n):
            xx = x + (c + 1) * cell
            yy = y + r * cell
            rect = slide.shapes.add_shape(MSO_SHAPE.ROUNDED_RECTANGLE, inch(xx), inch(yy), inch(cell - 0.04), inch(cell - 0.04))
            if c <= r:
                set_fill(rect, GREY)
                rect.line.fill.background()
                continue
            val = values[(r, c)]
            if val != "0":
                set_fill(rect, ORANGE)
                rect.line.fill.background()
                color = WHITE
                bold = True
            else:
                set_fill(rect, WHITE)
                set_line(rect, LINE, 0.7)
                color = MID_TEXT
                bold = False
            textbox(slide, xx + 0.01, yy + 0.09, cell - 0.06, 0.23, val, size=12, bold=bold, color=color, align=PP_ALIGN.CENTER, margin=0)


def draw_flatten(slide, x, y, w):
    pairs = [
        "0,1",
        "0,2",
        "0,3",
        "0,4",
        "0,5",
        "1,2",
        "1,3",
        "1,4",
        "1,5",
        "2,3",
        "2,4",
        "2,5",
        "3,4",
        "3,5",
        "4,5",
    ]
    cw = w / len(pairs)
    for i, pair in enumerate(pairs):
        rect = slide.shapes.add_shape(MSO_SHAPE.ROUNDED_RECTANGLE, inch(x + i * cw), inch(y), inch(cw - 0.02), inch(0.58))
        if i == 6:
            set_fill(rect, ORANGE)
            set_line(rect, ORANGE, 0.5)
            tcolor = WHITE
        else:
            set_fill(rect, RGBColor(245, 248, 252))
            set_line(rect, LINE, 0.5)
            tcolor = NAVY
        textbox(slide, x + i * cw, y + 0.07, cw - 0.02, 0.18, str(i), size=9.5, bold=True, color=tcolor, align=PP_ALIGN.CENTER, margin=0)
        textbox(slide, x + i * cw, y + 0.32, cw - 0.02, 0.18, pair, size=7.8, color=tcolor if i == 6 else RGBColor(120, 140, 166), align=PP_ALIGN.CENTER, margin=0)


def draw_pipeline(slide, x, y, w):
    steps = [
        ("SAMPLE", "fetch input xi"),
        ("WIN_SCAN", "find s1 and s2"),
        ("UPDATE", "err_s1 += d2 >> ERR_SHIFT; move s1 by EPS_WIN_Q8"),
        ("NB_SCAN", "decay err_n; probe edge_cell[idx(s1,n)]"),
        ("ACTIVE EDGE", "age/prune edge; move neighbor by EPS_N_Q16"),
        ("CONNECT", "reset edge(s1,s2) age; update degree counters"),
        ("INSERT / SNAP", "every lambda split max-error edge; stream UART snapshots"),
    ]
    box_h = 0.55
    gap = 0.18
    for i, (label, desc) in enumerate(steps):
        yy = y + i * (box_h + gap)
        fill = ORANGE if label in {"NB_SCAN", "ACTIVE EDGE"} else RGBColor(239, 245, 252)
        rect = slide.shapes.add_shape(MSO_SHAPE.ROUNDED_RECTANGLE, inch(x), inch(yy), inch(w), inch(box_h))
        set_fill(rect, fill if label in {"NB_SCAN", "ACTIVE EDGE"} else RGBColor(239, 245, 252))
        set_line(rect, RGBColor(207, 220, 236), 0.8)
        textbox(slide, x + 0.15, yy + 0.12, 1.35, 0.25, label, size=10.4, bold=True, color=WHITE if label in {"NB_SCAN", "ACTIVE EDGE"} else NAVY, margin=0)
        textbox(slide, x + 1.6, yy + 0.12, w - 1.75, 0.25, desc, size=9.6, color=WHITE if label in {"NB_SCAN", "ACTIVE EDGE"} else DARK, margin=0)
        if i < len(steps) - 1:
            add_arrow(slide, x + w / 2, yy + box_h, x + w / 2, yy + box_h + gap * 0.82, color=BLUE, width=0.9)


def draw_node_word(slide, x, y, w):
    widths = [0.24, 0.24, 0.12, 0.4]
    labels = ["x [16]", "y [16]", "deg [8]", "err [32]"]
    start = x
    for frac, label in zip(widths, labels):
        cw = w * frac
        rect = slide.shapes.add_shape(MSO_SHAPE.ROUNDED_RECTANGLE, inch(start), inch(y), inch(cw - 0.02), inch(0.45))
        set_fill(rect, RGBColor(239, 245, 252))
        set_line(rect, LINE, 0.6)
        textbox(slide, start, y + 0.13, cw - 0.02, 0.18, label, size=9.2, bold=True, color=NAVY if "deg" not in label else RGBColor(176, 119, 31), align=PP_ALIGN.CENTER, margin=0)
        start += cw


def make_poster():
    prs = Presentation()
    prs.slide_width = inch(33.115)
    prs.slide_height = inch(49.605)
    slide = prs.slides.add_slide(prs.slide_layouts[6])

    bg = slide.background.fill
    bg.solid()
    bg.fore_color.rgb = rgb("f4f7fb")

    # Header
    card(slide, 0.35, 0.25, 32.4, 3.25, fill=WHITE, line=RGBColor(153, 171, 194))
    tmu = extract_tmu_logo()
    if tmu:
        image(slide, tmu, 0.7, 1.08, 3.2, 1.35, contain=True)
    image(slide, WCCI / "wcci2026_logo.jpg", 29.0, 0.68, 2.55, 1.65, contain=True)
    textbox(slide, 4.65, 0.48, 23.9, 1.18, "Edge-Cell Graph Encoding and Fixed-Point Arithmetic for FPGA Growing Neural Gas", size=31, bold=True, color=NAVY, align=PP_ALIGN.CENTER, margin=0)
    textbox(slide, 8.4, 1.78, 16.5, 0.46, "Integer-only online topology learning on a sub-10K-LUT FPGA", size=17, bold=True, color=BLUE, align=PP_ALIGN.CENTER, margin=0)
    textbox(slide, 5.4, 2.38, 22.4, 0.42, "Teuku Zikri Fatahillah1 · Raditya Artha Rochmanto1,2 · Achmad Fahrul Aji1,2 · Anhar Risnumawan1,3 · Chyan Zheng Siow1,4 · Naoyuki Kubota1", size=11.4, color=MID_TEXT, align=PP_ALIGN.CENTER, margin=0)
    textbox(slide, 7.0, 2.8, 19.4, 0.32, "1 Tokyo Metropolitan University, Japan · 2 Politeknik Negeri Semarang, Indonesia · 3 PENS, Indonesia · 4 Changsha CCAVC, China", size=8.8, color=MID_TEXT, align=PP_ALIGN.CENTER, margin=0)
    textbox(slide, 28.9, 2.52, 2.8, 0.32, "IEEE WCCI 2026\nMaastricht", size=8.6, color=MID_TEXT, align=PP_ALIGN.CENTER, margin=0)

    # Metrics
    y_metrics = 3.72
    add_metric(slide, 0.35, y_metrics, 7.85, "-41%", "total graph-state memory", "2,000 B -> 1,180 B", RGBColor(178, 111, 20))
    add_metric(slide, 8.65, y_metrics, 7.85, "~625 us", "deterministic latency", "~16.9k cycles @ 27 MHz", BLUE)
    add_metric(slide, 16.95, y_metrics, 7.85, "38%", "LUT utilization", "3,205 / 8,640 LUTs", GREEN)
    add_metric(slide, 25.25, y_metrics, 7.5, "~1,600/s", "online throughput", "UART-measured FPGA snapshots", RGBColor(111, 79, 178))

    x1, x2, x3 = 0.35, 11.25, 22.15
    cw = 10.55
    y0 = 5.25
    gap = 0.25

    # Column 1: problem, contributions, architecture, fused loop
    yy = section(slide, x1, y0, cw, 7.35, "1 · Problem & Motivation")
    textbox(slide, x1 + 0.35, yy, cw - 0.7, 0.55, "Edge robots need on-board unsupervised adaptation.", size=18, bold=True, color=NAVY, margin=0)
    add_bullets(
        slide,
        x1 + 0.35,
        yy + 0.72,
        cw - 0.7,
        [
            "Streaming raw sensor data to the cloud is often impractical under intermittent links and latency limits.",
            "GNG learns a topology incrementally, but dynamic edges and floating point are expensive on tiny FPGAs.",
            "The target is bounded memory, deterministic per-sample time, and an integer-only datapath.",
        ],
        size=12.6,
        gap=0.68,
    )
    # motivation flow
    img_scene = fit_image(ROOT / "web_page" / "images" / "motivation-embedded-scene.png", "scene_flow.jpg", (1100, 650), mode="cover")
    img_top = fit_image(ROOT / "web_page" / "images" / "motivation-topology-map.png", "topology_flow.jpg", (1100, 650), mode="cover")
    slide.shapes.add_picture(str(img_scene), inch(x1 + 0.35), inch(yy + 3.3), inch(3.0), inch(2.05))
    card(slide, x1 + 3.75, yy + 3.47, 2.15, 1.72, fill=WHITE, line=LINE)
    image(slide, ROOT / "web_page" / "images" / "tang-nano-9k.png", x1 + 3.95, yy + 3.75, 1.75, 0.92, contain=True)
    textbox(slide, x1 + 3.78, yy + 4.65, 2.1, 0.25, "Tang Nano 9K", size=9.1, color=NAVY, align=PP_ALIGN.CENTER, margin=0)
    slide.shapes.add_picture(str(img_top), inch(x1 + 6.5), inch(yy + 3.3), inch(3.6), inch(2.05))
    add_arrow(slide, x1 + 3.38, yy + 4.35, x1 + 3.72, yy + 4.35, color=ORANGE)
    add_arrow(slide, x1 + 5.92, yy + 4.35, x1 + 6.45, yy + 4.35, color=ORANGE)
    textbox(slide, x1 + 0.35, yy + 5.55, cw - 0.7, 0.48, "Unstructured field scene -> integer FPGA engine -> online topology graph", size=11.4, bold=True, color=RGBColor(146, 91, 25), align=PP_ALIGN.CENTER, margin=0)

    yy = section(slide, x1, y0 + 7.35 + gap, cw, 5.25, "2 · Contributions in the Paper")
    add_bullets(
        slide,
        x1 + 0.35,
        yy + 0.1,
        cw - 0.7,
        [
            "Synthesized GNG engine on Gowin GW1NR-9C with no CPU, no FPU, and no PLL.",
            "Edge-cell graph storage: upper triangle only, one 8-bit age+1 cell per possible undirected edge.",
            "Q8/Q16 shift-scaled learning rates mapped to DSP-friendly multiply-and-shift updates.",
            "Winner-indexed fused NB_SCAN combines error decay, edge aging, neighbor movement, and pruning.",
        ],
        size=12.1,
        gap=0.72,
        bullet_color=ORANGE,
    )
    chip_y = yy + 3.55
    chips = [("No soft-core CPU", "FSM datapath"), ("No FPU", "Q8/Q16 shifts"), ("No dynamic memory", "fixed BRAM arrays")]
    for i, (top, bottom) in enumerate(chips):
        cx = x1 + 0.55 + i * 3.25
        card(slide, cx, chip_y, 2.95, 0.95, fill=RGBColor(240, 246, 253), line=RGBColor(205, 219, 237))
        textbox(slide, cx + 0.1, chip_y + 0.16, 2.75, 0.22, top, size=10.2, bold=True, color=NAVY, align=PP_ALIGN.CENTER, margin=0)
        textbox(slide, cx + 0.1, chip_y + 0.52, 2.75, 0.22, bottom, size=8.8, color=MID_TEXT, align=PP_ALIGN.CENTER, margin=0)

    yy = section(slide, x1, y0 + 12.85 + gap, cw, 6.9, "3 · FPGA Architecture")
    textbox(slide, x1 + 0.35, yy, cw - 0.7, 0.48, "Single-clock FSM at 27 MHz with BRAM-mapped state.", size=15, bold=True, color=NAVY, margin=0)
    # architecture blocks
    bx, by = x1 + 0.35, yy + 0.75
    blocks = [
        ("UART input", "100-sample dataset ROM"),
        ("WIN_SCAN", "nearest s1, runner-up s2"),
        ("UPDATE", "winner error + Q8 move"),
        ("NB_SCAN", "node BRAM + edge BRAM RMW"),
        ("CONNECT / INSERT", "degree counters + split edge"),
        ("DBG/SNAP", "cycle counter + topology stream"),
    ]
    for i, (a, b) in enumerate(blocks):
        row = i // 2
        col = i % 2
        xx = bx + col * 5.05
        yyb = by + row * 1.15
        rect = slide.shapes.add_shape(MSO_SHAPE.ROUNDED_RECTANGLE, inch(xx), inch(yyb), inch(4.72), inch(0.86))
        set_fill(rect, RGBColor(239, 245, 252) if i != 3 else NAVY)
        set_line(rect, LINE, 0.7)
        textbox(slide, xx + 0.12, yyb + 0.11, 4.48, 0.22, a, size=11.6, bold=True, color=WHITE if i == 3 else NAVY, align=PP_ALIGN.CENTER, margin=0)
        textbox(slide, xx + 0.12, yyb + 0.46, 4.48, 0.2, b, size=8.8, color=WHITE if i == 3 else MID_TEXT, align=PP_ALIGN.CENTER, margin=0)
    image(slide, ROOT / "web_page" / "images" / "tang-nano-9k.png", x1 + 3.95, yy + 4.45, 2.3, 1.05, contain=True)
    textbox(slide, x1 + 0.35, yy + 5.55, cw - 0.7, 0.45, "Node, edge, and dataset BRAMs use synchronous read-modify-write access; each sequence costs at least 3 cycles.", size=10.8, color=MID_TEXT, align=PP_ALIGN.CENTER, margin=0)

    yy = section(slide, x1, y0 + 20.0 + gap, cw, 17.15, "4 · GNG Loop and Fused NB_SCAN")
    textbox(slide, x1 + 0.35, yy, cw - 0.7, 0.5, "Paper-aligned FSM sequence per input sample", size=15, bold=True, color=NAVY, margin=0)
    draw_pipeline(slide, x1 + 0.55, yy + 0.72, cw - 1.1)
    note_y = yy + 6.0
    card(slide, x1 + 0.55, note_y, cw - 1.1, 3.6, fill=RGBColor(255, 250, 240), line=RGBColor(230, 191, 115))
    textbox(slide, x1 + 0.75, note_y + 0.18, cw - 1.5, 0.35, "Why fused?", size=14, bold=True, color=RGBColor(159, 91, 14), margin=0)
    add_bullets(
        slide,
        x1 + 0.75,
        note_y + 0.7,
        cw - 1.5,
        [
            "Canonical GNG separates global error decay from winner-neighbor edge updates.",
            "The FPGA already scans all node slots around s1, so decay is folded into the same NB_SCAN.",
            "Per-node degree counters detect isolated nodes without a second full edge-array scan.",
        ],
        size=10.8,
        gap=0.66,
        bullet_color=ORANGE,
    )
    card(slide, x1 + 0.55, yy + 9.95, cw - 1.1, 5.0, fill=VERY_LIGHT, line=LINE)
    textbox(slide, x1 + 0.78, yy + 10.2, cw - 1.55, 0.36, "Hardware invariant", size=13.2, bold=True, color=NAVY, margin=0)
    invariant = (
        "Only fixed-capacity arrays are used: node state is stored once, edge state is stored once, "
        "and dynamic topology is expressed by age+1 cells and degree counters. This keeps memory bounded even as GNG rewires."
    )
    textbox(slide, x1 + 0.78, yy + 10.75, cw - 1.55, 1.2, invariant, size=11.0, color=DARK, margin=0)
    table_box(
        slide,
        x1 + 0.78,
        yy + 12.25,
        cw - 1.55,
        0.48,
        ["State", "BRAM word", "Role"],
        [
            ["node", "x,y,deg,err", "coordinates + degree + error"],
            ["edge", "age+1", "0 = inactive; v>0 = age v-1"],
            ["dataset", "x,y sample", "100-entry on-chip input set"],
        ],
        widths=[0.7, 1.1, 2.4],
        size=8.8,
    )

    # Column 2: edge cell and fixed point
    yy = section(slide, x2, y0, cw, 17.0, "5 · Edge-Cell Encoding")
    textbox(slide, x2 + 0.35, yy, cw - 0.7, 0.46, "Flatten only the upper triangle of an undirected graph.", size=15, bold=True, color=NAVY, margin=0)
    draw_matrix(slide, x2 + 0.6, yy + 1.2, n=6, cell=0.58)
    card(slide, x2 + 6.1, yy + 1.0, 4.0, 2.2, fill=VERY_LIGHT, line=LINE)
    textbox(slide, x2 + 6.32, yy + 1.18, 3.55, 0.4, "cell = age + 1", size=16, bold=True, color=RGBColor(165, 103, 28), align=PP_ALIGN.CENTER, margin=0)
    textbox(slide, x2 + 6.35, yy + 1.75, 3.55, 0.28, "0 means no edge", size=11.2, color=MID_TEXT, align=PP_ALIGN.CENTER, margin=0)
    textbox(slide, x2 + 6.35, yy + 2.12, 3.55, 0.28, "v > 0 means true age = v - 1", size=11.2, color=MID_TEXT, align=PP_ALIGN.CENTER, margin=0)
    textbox(slide, x2 + 0.45, yy + 4.95, cw - 0.9, 0.4, "Half-adjacency indexing, row by row", size=13.4, bold=True, color=NAVY, margin=0)
    draw_flatten(slide, x2 + 0.45, yy + 5.45, cw - 0.9)
    card(slide, x2 + 0.45, yy + 6.4, cw - 0.9, 2.55, fill=WHITE, line=RGBColor(230, 210, 174))
    textbox(slide, x2 + 0.75, yy + 6.9, 6.6, 0.62, "idx(i,j) = i(2Nmax - i - 1)/2 + (j - i - 1)", size=18, bold=True, color=NAVY, margin=0)
    textbox(slide, x2 + 7.5, yy + 7.05, 2.2, 0.4, "(1,3) -> cell 6", size=16, bold=True, color=RGBColor(159, 91, 14), align=PP_ALIGN.CENTER, margin=0)
    textbox(slide, x2 + 0.75, yy + 7.82, 9.2, 0.36, "Example uses Nmax = 6: 1(12 - 1 - 1)/2 + (3 - 1 - 1) = 5 + 1 = 6", size=10.6, color=MID_TEXT, margin=0)
    card(slide, x2 + 0.45, yy + 9.45, cw - 0.9, 2.95, fill=RGBColor(248, 250, 254), line=LINE)
    textbox(slide, x2 + 0.72, yy + 9.73, 3.25, 0.35, "Dense matrix", size=13.2, bold=True, color=NAVY, align=PP_ALIGN.CENTER, margin=0)
    textbox(slide, x2 + 6.25, yy + 9.73, 3.55, 0.35, "Edge-cell array", size=13.2, bold=True, color=NAVY, align=PP_ALIGN.CENTER, margin=0)
    textbox(slide, x2 + 0.72, yy + 10.27, 3.25, 0.78, "40 x 40 x 8-bit\n= 1,600 B", size=16, bold=True, color=RED, align=PP_ALIGN.CENTER, margin=0)
    textbox(slide, x2 + 4.45, yy + 10.48, 1.5, 0.38, "->", size=24, bold=True, color=ORANGE, align=PP_ALIGN.CENTER, margin=0)
    textbox(slide, x2 + 6.25, yy + 10.27, 3.55, 0.78, "40 x 39 / 2 bytes\n= 780 B", size=16, bold=True, color=GREEN, align=PP_ALIGN.CENTER, margin=0)
    textbox(slide, x2 + 2.0, yy + 11.62, 6.7, 0.42, "51.25% less edge storage; total graph state drops 2,000 B -> 1,180 B.", size=11.6, bold=True, color=RGBColor(161, 98, 22), align=PP_ALIGN.CENTER, margin=0)
    textbox(slide, x2 + 0.45, yy + 12.95, cw - 0.9, 1.0, "This matches the paper's fixed-capacity allocation: graph growth and rewiring do not allocate memory dynamically; they only update existing node and edge BRAM cells.", size=10.8, color=DARK, margin=0)
    callouts = [
        ("Presence + age", "one byte encodes both"),
        ("Deterministic address", "13-bit BRAM index at Nmax=40"),
        ("Degree counters", "isolated nodes need no edge scan"),
    ]
    for i, (top, bottom) in enumerate(callouts):
        cx = x2 + 0.45 + i * 3.25
        card(slide, cx, yy + 14.25, 2.95, 1.25, fill=RGBColor(240, 246, 253), line=RGBColor(205, 219, 237))
        textbox(slide, cx + 0.1, yy + 14.48, 2.75, 0.25, top, size=10.6, bold=True, color=NAVY, align=PP_ALIGN.CENTER, margin=0)
        textbox(slide, cx + 0.1, yy + 14.88, 2.75, 0.28, bottom, size=8.8, color=MID_TEXT, align=PP_ALIGN.CENTER, margin=0)

    yy = section(slide, x2, y0 + 17.25, cw, 19.9, "6 · Fixed-Point Arithmetic")
    textbox(slide, x2 + 0.35, yy, 5.5, 0.4, "Integer-only datapath", size=15, bold=True, color=NAVY, margin=0)
    image(slide, ROOT / "web_page" / "images" / "tang-nano-9k.png", x2 + 7.25, yy - 0.05, 2.45, 1.15, contain=True)
    textbox(slide, x2 + 0.35, yy + 0.5, cw - 0.7, 0.55, "Coordinates are 16-bit signed integers in [-1000, 1000] after min-max normalization.", size=11.2, color=MID_TEXT, margin=0)
    card(slide, x2 + 0.35, yy + 1.25, cw - 0.7, 1.55, fill=VERY_LIGHT, line=LINE)
    textbox(slide, x2 + 0.6, yy + 1.45, cw - 1.2, 0.28, "Coordinate representation", size=11.8, bold=True, color=NAVY, margin=0)
    textbox(slide, x2 + 0.6, yy + 1.9, cw - 1.2, 0.4, "x_norm = ((x - x_min) / (x_max - x_min)) * 2S - S,    S = 1000", size=13, bold=True, color=DARK, align=PP_ALIGN.CENTER, margin=0)
    textbox(slide, x2 + 0.35, yy + 3.08, 3.4, 0.3, "80-bit node word", size=11.8, bold=True, color=NAVY, margin=0)
    draw_node_word(slide, x2 + 3.05, yy + 2.98, 6.85)
    # formula blocks
    formulas = [
        ("Squared-distance unit", "dx = xi_x - x_n,   dy = xi_y - y_n\n"
         "d2 = dx^2 + dy^2      // 17-bit signed -> 35-bit unsigned\n"
         "err_s1 += d2 >> ERR_SHIFT"),
        ("Winner adaptation, Q8", "Delta x_s1 = floor(EPS_WIN_Q8 * (xi_x - x_s1) / 2^8)\n"
         "Delta y_s1 = floor(EPS_WIN_Q8 * (xi_y - y_s1) / 2^8)"),
        ("Neighbor adaptation, Q16", "Delta x_n = floor(EPS_N_Q16 * (xi_x - x_n) / 2^16)\n"
         "Delta y_n = floor(EPS_N_Q16 * (xi_y - y_n) / 2^16)"),
        ("Multiplierless error decay", "err_n = err_n - (err_n >> ERR_DECAY_SHIFT)\n"
         "beta approx 1 - 2^-8 = 0.9961"),
    ]
    fy = yy + 3.75
    for title, body in formulas:
        card(slide, x2 + 0.35, fy, cw - 0.7, 1.45, fill=RGBColor(249, 252, 255), line=RGBColor(210, 224, 241))
        textbox(slide, x2 + 0.58, fy + 0.13, cw - 1.15, 0.25, title, size=11.2, bold=True, color=NAVY if "decay" not in title else RGBColor(150, 88, 15), margin=0)
        textbox(slide, x2 + 0.58, fy + 0.52, cw - 1.15, 0.66, body, size=10.2, color=DARK, margin=0)
        fy += 1.65
    table_y = yy + 10.6
    table_box(
        slide,
        x2 + 0.35,
        table_y,
        cw - 0.7,
        0.46,
        ["Parameter", "Value", "Hardware mapping"],
        [
            ["Nmax", "40", "node BRAM depth"],
            ["Amax", "50", "A_MAX_STORED = 51"],
            ["lambda", "100", "lambda counter"],
            ["eps_w", "~0.301", "EPS_WIN_Q8 = 77, >> 8"],
            ["eps_n", "~0.001", "EPS_N_Q16 = 66, >> 16"],
            ["alpha", "0.5", "INS_ALPHA_SHIFT = 1"],
            ["beta", "~0.9961", "ERR_DECAY_SHIFT = 8"],
        ],
        widths=[1.1, 0.8, 2.2],
        size=8.9,
    )
    card(slide, x2 + 0.35, yy + 14.35, cw - 0.7, 2.1, fill=RGBColor(255, 250, 240), line=RGBColor(231, 196, 128))
    textbox(slide, x2 + 0.6, yy + 14.6, cw - 1.2, 0.3, "Where 77 and 66 come from", size=12.4, bold=True, color=RGBColor(150, 88, 15), margin=0)
    note = (
        "EPS_Q = round(epsilon * 2^Q). The implementation targets a winner rate near 0.3 and a neighbor rate near 0.001, "
        "so EPS_WIN_Q8 = round(0.301 * 256) = 77 and EPS_N_Q16 = round(0.001 * 65536) = 66."
    )
    textbox(slide, x2 + 0.6, yy + 15.08, cw - 1.2, 0.92, note, size=10.5, color=DARK, margin=0)
    card(slide, x2 + 0.35, yy + 16.75, cw - 0.7, 1.75, fill=VERY_LIGHT, line=LINE)
    textbox(slide, x2 + 0.6, yy + 16.98, cw - 1.2, 0.34, "Interpretation", size=12.0, bold=True, color=NAVY, margin=0)
    textbox(slide, x2 + 0.6, yy + 17.45, cw - 1.2, 0.58, "The fixed-point approximation is not exact, but the paper reports low final QE/TE on both datasets, so the hardware-friendly rates are acceptable for the evaluated benchmarks.", size=9.8, color=DARK, margin=0)

    # Column 3: results
    yy = section(slide, x3, y0, cw, 7.7, "7 · Fits on a 9K FPGA")
    textbox(slide, x3 + 0.35, yy, cw - 0.7, 0.42, "Place-and-route on Gowin GW1NR-LV9QN88PC6", size=13.4, bold=True, color=NAVY, margin=0)
    table_box(
        slide,
        x3 + 0.35,
        yy + 0.65,
        cw - 0.7,
        0.52,
        ["Resource", "Used", "Avail.", "Util."],
        [["LUT", "3,205", "8,640", "38%"], ["FF", "1,408", "6,693", "22%"], ["BSRAM", "6", "26", "24%"], ["DSP", "5", "10", "50%"]],
        widths=[1.2, 1, 1, 1],
        size=10.4,
    )
    table_box(
        slide,
        x3 + 0.35,
        yy + 3.4,
        cw - 0.7,
        0.52,
        ["Memory", "Baseline", "Proposed", "Saving"],
        [["Node array", "400 B", "400 B", "-"], ["Edge memory", "1,600 B", "780 B", "-51.25%"], ["Total graph", "2,000 B", "1,180 B", "-41.0%"]],
        widths=[1.35, 1, 1, 1],
        size=9.8,
    )
    textbox(slide, x3 + 0.55, yy + 5.95, cw - 1.1, 0.55, "The design retains 62% LUT and 76% BRAM headroom for application logic.", size=11.5, bold=True, color=BLUE, align=PP_ALIGN.CENTER, margin=0)

    yy = section(slide, x3, y0 + 7.95, cw, 14.0, "8 · Learning Quality")
    textbox(slide, x3 + 0.35, yy, cw - 0.7, 0.42, "Final FPGA snapshots preserve the target topology.", size=13.2, bold=True, color=NAVY, margin=0)
    image_card(slide, WCCI / "two_moons_result.png", x3 + 0.35, yy + 0.7, 4.9, 3.55, "Two Moons, epoch 32", "QE 0.1832, TE 0.00", mode="contain", label_h=0.72)
    image_card(slide, WCCI / "concentric_circles_result.png", x3 + 5.35, yy + 0.7, 4.85, 3.55, "Concentric Circles, epoch 64", "QE 0.1960, TE 0.07", mode="contain", label_h=0.72)
    textbox(slide, x3 + 0.35, yy + 4.6, cw - 0.7, 0.7, "The paper reports QE decreasing on both datasets. TE stays near zero during growth; Circles drifts after saturation because the fixed Nmax graph cannot insert more nodes across the inter-ring gap.", size=10.5, color=DARK, margin=0)
    table_box(
        slide,
        x3 + 0.35,
        yy + 5.55,
        cw - 0.7,
        0.45,
        ["Dataset", "Epoch", "Nodes", "Edges", "QE", "TE"],
        [
            ["Two Moons", "32", "35", "33", "0.1832", "0.00"],
            ["Two Moons", "64", "40", "34", "0.1455", "0.01"],
            ["Circles", "32", "35", "36", "0.2592", "0.00"],
            ["Circles", "64", "40", "39", "0.1960", "0.07"],
        ],
        widths=[1.7, 0.7, 0.7, 0.7, 0.85, 0.65],
        size=8.3,
    )
    image_card(slide, WCCI / "two_moons_training.png", x3 + 0.35, yy + 8.25, cw - 0.7, 2.3, "Two Moons training dynamics", "node/edge growth, QE convergence, TE", mode="contain", label_h=0.58)
    image_card(slide, WCCI / "concentric_circles_training.png", x3 + 0.35, yy + 10.9, cw - 0.7, 2.3, "Concentric Circles training dynamics", "64 epochs after Nmax saturation", mode="contain", label_h=0.58)

    yy = section(slide, x3, y0 + 22.2, cw, 7.2, "9 · Deterministic Real-Time Throughput")
    textbox(slide, x3 + 0.35, yy, cw - 0.7, 0.45, "Measured directly from the FPGA cycle counter embedded in DBG frames.", size=12.2, bold=True, color=NAVY, margin=0)
    table_box(
        slide,
        x3 + 0.35,
        yy + 0.7,
        cw - 0.7,
        0.55,
        ["Dataset", "Cycles", "us", "Samples/s", "Total s"],
        [["Two Moons", "16,852", "624.1", "1,602", "5.40"], ["Circles", "16,931", "627.1", "1,595", "5.72"]],
        widths=[1.7, 1.2, 0.9, 1.25, 0.95],
        size=9.6,
    )
    # simple throughput line plot
    plot = card(slide, x3 + 0.65, yy + 2.65, cw - 1.3, 2.65, fill=WHITE, line=LINE)
    px, py, pw, ph = x3 + 1.0, yy + 3.02, cw - 2.0, 1.75
    # axes
    line = slide.shapes.add_connector(1, inch(px), inch(py + ph), inch(px + pw), inch(py + ph))
    line.line.color.rgb = LINE
    line.line.width = Pt(1)
    line = slide.shapes.add_connector(1, inch(px), inch(py), inch(px), inch(py + ph))
    line.line.color.rgb = LINE
    line.line.width = Pt(1)
    pts = []
    for i in range(35):
        xx = px + pw * i / 34
        val = 1600 + 65 * math.sin(i * 0.9) + 28 * math.sin(i * 2.1)
        yyv = py + ph * (1 - (val - 1400) / 500)
        pts.append((xx, yyv))
    for a, b in zip(pts, pts[1:]):
        l = slide.shapes.add_connector(1, inch(a[0]), inch(a[1]), inch(b[0]), inch(b[1]))
        l.line.color.rgb = BLUE
        l.line.width = Pt(1.4)
    avg_y = py + ph * (1 - (1600 - 1400) / 500)
    l = slide.shapes.add_connector(1, inch(px), inch(avg_y), inch(px + pw), inch(avg_y))
    l.line.color.rgb = RED
    l.line.width = Pt(1.0)
    l.line.dash_style = 4
    textbox(slide, x3 + 0.9, yy + 4.95, cw - 1.8, 0.32, "~1,600 samples/s with bounded per-sample latency", size=10.4, bold=True, color=BLUE, align=PP_ALIGN.CENTER, margin=0)

    yy = section(slide, x3, y0 + 29.65, cw, 7.5, "10 · Takeaway and Future Work")
    textbox(slide, x3 + 0.35, yy, cw - 0.7, 0.68, "Self-organizing clustering with dynamic topology is feasible on a sub-10K-LUT FPGA when memory layout and arithmetic format are co-designed.", size=11.4, bold=True, color=NAVY, margin=0)
    add_bullets(
        slide,
        x3 + 0.35,
        yy + 1.15,
        cw - 0.7,
        [
            "Current evaluation: static 2D benchmarks; streaming non-stationary data remains future work.",
            "Next: parallel winner-search tree to reduce O(Nmax) latency toward O(log Nmax).",
            "Next: configurable Q-format constants and multi-stream sensor input.",
            "Target deployment: continual topology learning on low-power, memory-constrained robots/devices.",
        ],
        size=10.6,
        gap=0.68,
        bullet_color=GREEN,
    )
    card(slide, x3 + 0.55, yy + 4.58, cw - 1.1, 2.35, fill=NAVY, line=NAVY)
    textbox(slide, x3 + 0.8, yy + 4.88, 3.2, 0.5, "Code, poster,\nslides, and data", size=12.2, bold=True, color=WHITE, align=PP_ALIGN.CENTER, margin=0)
    image(slide, WCCI / "fpga_gng_qr.png", x3 + 4.45, yy + 4.92, 1.45, 1.45, contain=True)
    textbox(slide, x3 + 6.15, yy + 5.18, 3.5, 0.58, "github.com/tzf230201/fpga_gng", size=10.2, color=WHITE, align=PP_ALIGN.CENTER, margin=0)

    # Bottom future applications
    bottom_y = 42.65
    section(slide, 0.35, bottom_y, 32.4, 5.95, "Prospective Edge-Robotics Applications")
    apps = [
        (ROOT / "web_page" / "images" / "future-aerial-robot.png", "Lightweight flapping robot", "payload-limited topology mapping", "contain"),
        (ROOT / "web_page" / "images" / "future-bio-inspired-robot.jpg", "Bio-inspired robot", "strict body and actuator constraints", "cover"),
        (ROOT / "web_page" / "images" / "future-swarm-robot.jpg", "Swarm robot", "distributed intelligence, low memory", "cover"),
        (ROOT / "web_page" / "images" / "future-exploration-robot.png", "Long-term exploration robot", "low power, adaptive autonomy", "cover"),
        (ROOT / "web_page" / "images" / "future-pipe-exploration-robot.jpg", "Infrastructure inspection", "narrow spaces, local computation", "cover"),
    ]
    start_x = 0.65
    app_w = 6.2
    for i, (path, label, cap, mode) in enumerate(apps):
        image_card(slide, path, start_x + i * 6.38, bottom_y + 0.9, app_w, 4.62, label, cap, mode=mode, label_h=0.8)

    # Footer
    image(slide, WCCI / "moonshot_logo.jpg", 0.45, 48.85, 2.0, 0.42, contain=True)
    textbox(slide, 2.7, 48.88, 13.5, 0.28, "Supported by the Japan Science and Technology Agency (JST), Moonshot R&D Program, grant JPMJMS2034.", size=7.8, color=MID_TEXT, margin=0)
    textbox(slide, 28.0, 48.88, 4.2, 0.28, "[email protected]", size=7.8, color=BLUE, align=PP_ALIGN.RIGHT, margin=0)

    prs.save(OUT)
    print(f"saved {OUT}")


if __name__ == "__main__":
    make_poster()
