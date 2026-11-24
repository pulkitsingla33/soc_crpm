"""Generate diagram/crpm_soc.svg: SoC block diagram with the CRPM controller.

Every wire follows a real connection in rtl/crpm_top.sv and rtl/soc_top.sv.
Clock and reset fan-out is drawn with net labels (coloured tags): a tag inside
a block names the CRPM output (or chip pin) that clocks / resets / drives it.

Run from the project root:  python diagram/gen_crpm_diagram.py
"""
from pathlib import Path

W, H = 1660, 772
FONT = "Segoe UI, Helvetica Neue, Helvetica, Arial, sans-serif"

# ---------------------------------------------------------------- palette
INK = "#1F2937"
MUTED = "#4B5563"
NAVY = "#1B1F5E"
CLK = "#1D5FB0"   # clocks
RST = "#C62828"   # resets
PWR = "#D96B00"   # power control: PMU <-> isolation / retention / power switch
DFT = "#7B3FA0"   # test_mode
IRQ = "#2E7D32"   # interrupts / wake
BUS = "#455A64"   # data buses
CTL = "#5F6B7A"   # CRPM-internal control

AON_FILL = "#F4F7FB"
CRPM_FILL = "#E6EFFA"
CORE_FILL = "#FFF1DE"
CORE_EDGE = "#D9822B"

HOP_R = 6
TAG_SIZE = 13

shapes, labels, wires = [], [], []


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def rect(x, y, w, h, fill, stroke=INK, sw=1.6, rx=8, dash=None, layer=None):
    d = f' stroke-dasharray="{dash}"' if dash else ""
    (layer if layer is not None else shapes).append(
        f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{rx}" '
        f'fill="{fill}" stroke="{stroke}" stroke-width="{sw}"{d}/>')


def text(x, y, s, size=17, weight="normal", anchor="start", color=INK,
         italic=False, layer=None, halo=False):
    st = ' font-style="italic"' if italic else ""
    h = ' stroke="#FFFFFF" stroke-width="5" stroke-linejoin="round" paint-order="stroke"' if halo else ""
    (layer if layer is not None else shapes).append(
        f'<text x="{x}" y="{y}" font-size="{size}" font-weight="{weight}" '
        f'text-anchor="{anchor}" fill="{color}"{st}{h}>{esc(s)}</text>')


def tw(s, size, bold=False):
    """rough text width estimate"""
    return len(s) * size * (0.60 if bold else 0.53)


def tag(x, y, s, color, size=TAG_SIZE, layer=None):
    """net-label tag (pill), x,y = top-left; returns width"""
    lay = layer if layer is not None else shapes
    w = tw(s, size, True) + 14
    h = size + 9
    lay.append(f'<rect x="{x}" y="{y}" width="{w:.0f}" height="{h}" rx="{h / 2:.1f}" fill="{color}"/>')
    text(x + w / 2, y + h - 6.5, s, size, "bold", "middle", "#FFFFFF", layer=lay)
    return w


def wire(pts, color, width=2.3, end=True, start=False):
    wires.append(dict(pts=pts, color=color, width=width, end=end, start=start))


def dot(x, y, color):
    labels.append(f'<circle cx="{x}" cy="{y}" r="4.5" fill="{color}"/>')


def lbl(x, y, s, color=CTL, anchor="start", size=14, weight="normal"):
    text(x, y, s, size, weight, anchor, color, layer=labels, halo=True)


def wires_svg():
    """horizontal segments hop over vertical segments of other wires"""
    verts = []
    for wi, w in enumerate(wires):
        p = w["pts"]
        for (x1, y1), (x2, y2) in zip(p, p[1:]):
            if x1 == x2:
                verts.append((wi, x1, min(y1, y2), max(y1, y2)))
    res = []
    for wi, w in enumerate(wires):
        p = w["pts"]
        d = f"M{p[0][0]},{p[0][1]}"
        for (x1, y1), (x2, y2) in zip(p, p[1:]):
            if y1 == y2:
                lo, hi = min(x1, x2), max(x1, x2)
                xs = sorted({vx for (vj, vx, vy1, vy2) in verts
                             if vj != wi and lo + HOP_R < vx < hi - HOP_R and vy1 + 1 < y1 < vy2 - 1},
                            reverse=(x2 < x1))
                sgn = 1 if x2 > x1 else -1
                for vx in xs:
                    d += f" L{vx - sgn * HOP_R},{y1} A{HOP_R},{HOP_R} 0 0 {1 if sgn > 0 else 0} {vx + sgn * HOP_R},{y1}"
            d += f" L{x2},{y2}"
        k = w["color"][1:]
        me = f' marker-end="url(#a-{k})"' if w["end"] else ""
        ms = f' marker-start="url(#s-{k})"' if w["start"] else ""
        res.append(f'<path d="{d}" fill="none" stroke="{w["color"]}" stroke-width="{w["width"]}" '
                   f'stroke-linejoin="round"{me}{ms}/>')
    return "".join(res)


def markers():
    m = []
    for c in {CLK, RST, PWR, DFT, IRQ, BUS, CTL}:
        k = c[1:]
        for mid, path, refx in ((f"a-{k}", "M0,0 L10,5 L0,10 z", 9), (f"s-{k}", "M10,0 L0,5 L10,10 z", 1)):
            m.append(f'<marker id="{mid}" viewBox="0 0 10 10" refX="{refx}" refY="5" markerWidth="11" '
                     f'markerHeight="11" orient="auto" markerUnits="userSpaceOnUse">'
                     f'<path d="{path}" fill="{c}"/></marker>')
    return "<defs>" + "".join(m) + "</defs>"


def block(box, title, lines=(), tsize=19, lsize=16, fill="#FFFFFF", pitch=22):
    x0, y0, x1, y1 = box
    rect(x0, y0, x1 - x0, y1 - y0, fill, INK)
    text(x0 + 13, y0 + 25, title, tsize, "bold", color=NAVY)
    for i, s in enumerate(lines):
        text(x0 + 13, y0 + 25 + pitch * (i + 1), s, lsize, color=MUTED)


# ================================================================ geometry
CHIP = (190, 34, 1452, 714)
CRPM = (300, 78, 872, 690)
PDC = (1150, 100, 1440, 584)

CLKB = (325, 120, 850, 206)
REGB = (325, 254, 800, 340)
PMUB = (505, 388, 800, 528)
RSTB = (325, 576, 850, 676)

IC = (878, 240, 1072, 324)
IBX = (1180, 138, 1418, 408)
RET = (1180, 436, 1418, 566)
PER = (1180, 596, 1418, 674)
SW = (1512, 506, 1652, 590)

# ---------------------------------------------------------------- frames
rect(CHIP[0], CHIP[1], CHIP[2] - CHIP[0], CHIP[3] - CHIP[1], AON_FILL, "#3B4A5A", 2.2, 14)
text(CHIP[0] + 16, CHIP[1] + 28, "SoC (soc_top)", 20, "bold")
text(CHIP[0] + 160, CHIP[1] + 28, "PD_AON: always-on supply", 17, color=MUTED)

rect(PDC[0], PDC[1], PDC[2] - PDC[0], PDC[3] - PDC[1], CORE_FILL, CORE_EDGE, 2.2, 12, "9 6")
text(PDC[0] + 14, PDC[1] + 26, "PD_CORE: switchable supply", 17, "bold", color="#9A4A00")

rect(CRPM[0], CRPM[1], CRPM[2] - CRPM[0], CRPM[3] - CRPM[1], CRPM_FILL, NAVY, 2.6, 12)
text(CRPM[0] + 16, CRPM[1] + 29, "CRPM controller (crpm_top)", 21, "bold", color=NAVY)
text(CRPM[2] - 16, CRPM[1] + 29, "all CRPM flops on clk_ref", 14, anchor="end", color=MUTED, italic=True)

# ---------------------------------------------------------------- blocks
block(CLKB, "Clock unit", ["÷1/2/4/8 dividers → latch clock gates (ICG)",
                           "aon_clk = clk_ref;  test_mode holds ICGs open"])
block(REGB, "Registers @ 0x1000_0000", ["CLK_CTRL · PM_CTRL · WAKE_MASK · RST_CAUSE",
                                        "watchdog · wake-up timer · wake control"])
block(PMUB, "PMU FSM", ["RUN · IDLE · SLEEP · DEEP", "sleep / wake sequencer,", "entered by PM_CTRL + WFI"])
block(RSTB, "Reset unit", ["POR sync + sequencer: sys → periph → core",
                           "sources: POR, ext pin, SW, watchdog"])

block(IC, "Interconnect", ["+ SRAM 64 KB"], tsize=17, lsize=15, pitch=20)
tag(IC[0] + 10, IC[1] + 52, "core_clk", CLK)
tag(IC[0] + 94, IC[1] + 52, "core_rst_n", RST)

block(IBX, "Ibex RV32 core", ["lowRISC ibex_top, unmodified"])
tag(IBX[0] + 13, IBX[1] + 60, "core_clk", CLK)
tag(IBX[0] + 95, IBX[1] + 60, "core_rst_n", RST)
tag(IBX[0] + 13, IBX[1] + 90, "test_mode", DFT)
text(IBX[0] + 108, IBX[1] + 107, "→ test_en", 14, color=MUTED)

block(RET, "Retention regs", ["4 × 32-bit, AON shadow copy"])
tag(RET[0] + 13, RET[1] + 60, "core_clk", CLK)
tag(RET[0] + 95, RET[1] + 60, "sys_rst_n", RST)

block(PER, "Peripheral domain", [], tsize=17)
tag(PER[0] + 13, PER[1] + 47, "periph_clk", CLK)
tag(PER[0] + 113, PER[1] + 47, "periph_rst_n", RST)

# ---------------------------------------------------------------- pins
def pin(y, name, color, note=None, side="L"):
    x = CHIP[0] if side == "L" else CHIP[2]
    labels.append(f'<rect x="{x - 6}" y="{y - 6}" width="12" height="12" fill="{color}"/>')
    if side == "L":
        text(x - 14, y + 6, name, 17, "bold", "end", color, layer=labels)
        if note:
            text(x - 14, y + 24, note, 14, "normal", "end", MUTED, layer=labels)


Y_CLKREF, Y_TM = 146, 182
Y_IRQ, Y_WAKE = 284, 320
Y_TM_R, Y_POR, Y_EXTR = 600, 628, 656

pin(Y_CLKREF, "clk_ref", CLK, "100 MHz")
pin(Y_TM, "test_mode", DFT, "DFT")
pin(Y_IRQ, "ext_irq[15:0]", IRQ)
pin(Y_WAKE, "ext_wake", IRQ)
pin(Y_POR, "por_n", RST)
pin(Y_EXTR, "ext_rst_n", RST)

wire([(CHIP[0], Y_CLKREF), (CLKB[0], Y_CLKREF)], CLK, 2.8)
TRUNK_X = 232
wire([(CHIP[0], Y_TM), (CLKB[0], Y_TM)], DFT)
wire([(TRUNK_X, Y_TM), (TRUNK_X, Y_TM_R), (RSTB[0], Y_TM_R)], DFT)
dot(TRUNK_X, Y_TM, DFT)
# ext_irq: 2-FF synchronisers in soc_top (clk = aon_clk); ext_wake is synchronised inside the CRPM
SYNC = (254, Y_IRQ - 14, 302, Y_IRQ + 14)
wire([(CHIP[0], Y_IRQ), (SYNC[0], Y_IRQ)], IRQ)
rect(SYNC[0], SYNC[1], SYNC[2] - SYNC[0], SYNC[3] - SYNC[1], "#FFFFFF", IRQ, 1.5, 4, layer=labels)
text((SYNC[0] + SYNC[2]) / 2, Y_IRQ + 5, "sync", 12, "bold", "middle", IRQ, layer=labels)
wire([(SYNC[2], Y_IRQ), (REGB[0], Y_IRQ)], IRQ)
wire([(CHIP[0], Y_WAKE), (REGB[0], Y_WAKE)], IRQ)
wire([(CHIP[0], Y_POR), (RSTB[0], Y_POR)], RST, 2.5)
wire([(CHIP[0], Y_EXTR), (RSTB[0], Y_EXTR)], RST, 2.5)

# ------------------------------------------------- CRPM internal control
wire([(420, REGB[1]), (420, CLKB[3])], CTL)                      # regs -> clock
lbl(430, 236, "div_sel, clk_en")
CH_X = 826
wire([(PMUB[2], 398), (CH_X, 398), (CH_X, CLKB[3])], CTL)       # pmu -> clock
lbl(CH_X - 9, 236, "pm clk_en", anchor="end")
wire([(590, REGB[3]), (590, PMUB[1])], CTL)                      # regs -> pmu
lbl(598, 370, "lp_mode, wake")
wire([(770, PMUB[1]), (770, REGB[3])], CTL)                      # pmu -> regs
lbl(762, 370, "state", anchor="end")
wire([(350, REGB[3]), (350, RSTB[1])], CTL)                      # regs -> reset
lbl(358, 420, "SW / WDT")
lbl(358, 437, "reset req")
wire([(470, RSTB[1]), (470, REGB[3])], CTL)                      # reset -> regs
lbl(462, 500, "rst_cause", anchor="end")
wire([(640, PMUB[3]), (640, RSTB[1])], CTL)                      # pmu -> reset
lbl(648, 558, "core_rst_hold")

# ------------------------------------------------ CRPM clock/reset outputs
TAG_X = 884
for y, n in zip((134, 163, 192), ("core_clk", "periph_clk", "aon_clk")):
    wire([(CLKB[2], y), (TAG_X - 2, y)], CLK)
    tag(TAG_X, y - 11, n, CLK, layer=labels)
for y, n in zip((598, 627, 656), ("sys_rst_n", "periph_rst_n", "core_rst_n")):
    wire([(RSTB[2], y), (TAG_X - 2, y)], RST)
    tag(TAG_X, y - 11, n, RST, layer=labels)

# ---------------------------------------------------------------- buses
Y_REGBUS = 282
wire([(REGB[2], Y_REGBUS), (IC[0], Y_REGBUS)], BUS, 4.2, end=True, start=True)

Y_RESP, Y_REQ = 258, 300
ISO_X0, ISO_X1 = 1086, 1134
ISO_MID = (ISO_X0 + ISO_X1) // 2
wire([(IC[2], Y_RESP), (IBX[0], Y_RESP)], BUS, 4.2)                    # gnt / rvalid / rdata
wire([(IBX[0], Y_REQ), (ISO_X1 + 1, Y_REQ)], BUS, 4.2, end=False)      # req / addr / wdata
wire([(ISO_X0 - 1, Y_REQ), (IC[2], Y_REQ)], BUS, 4.2)
lbl(IBX[0] - 6, Y_RESP - 10, "instr + data bus", BUS, "end", 13, "bold")

# ext bus port (0x2000_0000) and the retention registers' bus port
wire([(1000, IC[1]), (1000, CHIP[1] - 1)], BUS, 4.2, end=True, start=True)
text(1010, CHIP[1] - 12, "ext bus port (0x2000_0000)", 15, "bold", color=BUS, layer=labels)
Y_TOPCH, RAIL_X, Y_RETBUS = 84, 1430, 500
wire([(1040, IC[1]), (1040, Y_TOPCH), (RAIL_X, Y_TOPCH), (RAIL_X, Y_RETBUS), (RET[2] + 1, Y_RETBUS)], BUS, 4.2, start=True)
lbl(1182, Y_TOPCH - 9, "retention regs bus (0x1001_0000)", BUS, size=13, weight="bold")

# ------------------------------------------------------- isolation cells
Y_WIRQ, Y_SLEEP = 344, 380
for yc in (Y_REQ, Y_SLEEP):
    rect(ISO_X0, yc - 13, ISO_X1 - ISO_X0, 26, "#FFFFFF", PWR, 2, 5, layer=labels)
    text(ISO_MID, yc + 5, "ISO", 13, "bold", "middle", PWR, layer=labels)

# wake interrupt to Ibex irq_fast[0]
wire([(REGB[2], Y_WIRQ), (IBX[0], Y_WIRQ)], IRQ, 2.5)
lbl(884, Y_WIRQ - 8, "wake_irq → irq_fast[0]", IRQ, size=14)

# core_sleep from Ibex through isolation to the PMU
X_SLP = 846
Y_SLP_PMU = 422
wire([(IBX[0], Y_SLEEP), (ISO_X1 + 1, Y_SLEEP)], PWR, 2.5, end=False)
wire([(ISO_X0 - 1, Y_SLEEP), (X_SLP, Y_SLEEP), (X_SLP, Y_SLP_PMU), (PMUB[2], Y_SLP_PMU)], PWR, 2.5)
lbl(884, Y_SLEEP - 8, "core_sleep (WFI)", PWR)

# PMU control outputs
Y_ISO, Y_RET, Y_ACK, Y_PEN = 446, 470, 494, 518
wire([(PMUB[2], Y_ISO), (ISO_MID, Y_ISO), (ISO_MID, Y_SLEEP + 14)], PWR, 2.5)
wire([(ISO_MID, Y_SLEEP - 14), (ISO_MID, Y_REQ + 14)], PWR, 2.5)
lbl(856, Y_ISO - 6, "iso_en", PWR)
wire([(PMUB[2], Y_RET), (RET[0], Y_RET)], PWR, 2.5)
lbl(856, Y_RET - 6, "ret_save / ret_restore", PWR)

# power switch (off-chip) with acknowledge
X_PEN, X_ACK = 1036, 1074
Y_PEN_B, Y_ACK_B = 700, 688
X_PEN_R, X_ACK_R = 1616, 1556
wire([(PMUB[2], Y_PEN), (X_PEN, Y_PEN), (X_PEN, Y_PEN_B), (X_PEN_R, Y_PEN_B), (X_PEN_R, SW[3])], PWR, 2.5)
wire([(X_ACK_R, SW[3]), (X_ACK_R, Y_ACK_B), (X_ACK, Y_ACK_B), (X_ACK, Y_ACK), (PMUB[2], Y_ACK)], PWR, 2.5)
lbl(856, Y_ACK - 6, "pwr_ack", PWR)
lbl(856, Y_PEN - 6, "pwr_en", PWR)
Y_OK = 548
wire([(X_ACK, Y_OK), (RET[0], Y_OK)], PWR, 2.5)
dot(X_ACK, Y_OK, PWR)
lbl(1084, Y_OK - 7, "pwr_ok", PWR)
for y in (Y_ACK_B, Y_PEN_B):
    labels.append(f'<rect x="{CHIP[2] - 6}" y="{y - 5}" width="12" height="10" fill="{PWR}"/>')
rect(SW[0], SW[1], SW[2] - SW[0], SW[3] - SW[1], "#FFFFFF", PWR, 2, 8, layer=labels)
text((SW[0] + SW[2]) / 2, SW[1] + 26, "Power switch", 17, "bold", "middle", NAVY, layer=labels)
text((SW[0] + SW[2]) / 2, SW[1] + 48, "off-chip", 14, "normal", "middle", MUTED, layer=labels)
text((SW[0] + SW[2]) / 2, SW[1] + 68, "pwr_switch_model", 13, "normal", "middle", MUTED, layer=labels)
wire([(SW[0], 548), (PDC[2] + 1, 548)], PWR, 3.4)
text((PDC[2] + SW[0]) / 2, 539, "VDD_CORE", 12, "bold", "middle", PWR, layer=labels)

# ---------------------------------------------------------------- legend
LY = 748
x = CHIP[0]
for c, s, wdt in [(CLK, "clock", 3), (RST, "reset", 3), (PWR, "power control", 3), (IRQ, "interrupt / wake", 3),
                  (DFT, "test mode", 3), (CTL, "CRPM internal", 3), (BUS, "bus", 4.5)]:
    labels.append(f'<line x1="{x}" y1="{LY}" x2="{x + 28}" y2="{LY}" stroke="{c}" stroke-width="{wdt}"/>')
    text(x + 35, LY + 5, s, 14, color=MUTED, layer=labels)
    x += 50 + tw(s, 14)
x += 10
wa = tag(x, LY - 11, "core_clk", CLK, layer=labels)
wb = tag(x + wa + 6, LY - 11, "core_rst_n", RST, layer=labels)
text(x + wa + wb + 16, LY + 5, "= clock / reset net driving that block (same name as the CRPM output)",
     14, color=MUTED, layer=labels)

# ---------------------------------------------------------------- write
svg = (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" '
       f'font-family="{FONT}">'
       f'<rect width="{W}" height="{H}" fill="#FFFFFF"/>' + markers()
       + "".join(shapes) + wires_svg() + "".join(labels) + "</svg>")
dst = Path(__file__).with_name("crpm_soc.svg")
dst.write_text(svg, encoding="utf-8")
print("wrote", dst)
