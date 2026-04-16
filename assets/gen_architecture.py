"""Generate architecture diagram PNG for swift-ddd-kit."""
from PIL import Image, ImageDraw, ImageFont
import os

# ── Canvas ──────────────────────────────────────────────────────────
W, H = 1020, 720
BG = '#F8FAFC'
img = Image.new('RGB', (W, H), BG)
draw = ImageDraw.Draw(img)

# ── Fonts ────────────────────────────────────────────────────────────
def font(size, mono=False):
    mono_paths = [
        '/System/Library/Fonts/Menlo.ttc',
        '/System/Library/Fonts/Courier New.ttf',
    ]
    sans_paths = [
        '/System/Library/Fonts/Helvetica.ttc',
        '/Library/Fonts/Arial.ttf',
        '/System/Library/Fonts/Geneva.dfont',
    ]
    for path in (mono_paths if mono else sans_paths):
        try:
            return ImageFont.truetype(path, size)
        except Exception:
            pass
    return ImageFont.load_default()

F_COL   = font(15)        # column title
F_LAYER = font(12)        # layer header
F_BODY  = font(11, mono=True)   # body text (mono for tree chars)
F_SMALL = font(10)        # small labels
F_ARROW = font(10)        # arrow labels

# ── Colours ──────────────────────────────────────────────────────────
LAYER_COLORS = {
    'if':   ('#EEF2F7', '#64748B'),   # bg, header
    'ap':   ('#EBF4FF', '#2563EB'),
    'dm':   ('#ECFDF5', '#059669'),
    'in':   ('#FFF7ED', '#C2410C'),
}
BORDER   = '#CBD5E1'
TEXT     = '#1E293B'
ARROW_C  = '#64748B'
KDB_BG   = '#FEE2E2';  KDB_BD = '#DC2626'
PG_BG    = '#DBEAFE';  PG_BD  = '#1D4ED8'

# ── Layout ───────────────────────────────────────────────────────────
M    = 30          # outer margin
GAP  = 16          # gap between columns
CW   = (W - 2*M - GAP) // 2   # ~487px
LX   = M
RX   = M + CW + GAP

TITLE_H = 32

ROW_H = {'if': 68, 'ap': 148, 'dm': 162, 'in': 108}

# compute row Y positions (below title)
row_y = {}
y = M + TITLE_H
for k in ('if', 'ap', 'dm', 'in'):
    row_y[k] = y
    y += ROW_H[k]

GRID_BOT = y          # bottom of the grid
ARROW_GAP = 20        # space between grid bottom and storage boxes
STORE_Y   = GRID_BOT + ARROW_GAP
STORE_W   = 210
STORE_H   = 60

# KurrentDB centred under left column, PostgreSQL under right column
KDB_X = LX + CW//2 - STORE_W//2
PG_X  = RX + CW//2 - STORE_W//2

HDR_H = 26   # header strip height within each layer box
R     = 6    # corner radius

# ── Helpers ──────────────────────────────────────────────────────────
def layer_box(x, y, w, h, key, title, lines):
    bg, hdr = LAYER_COLORS[key]
    # background
    draw.rounded_rectangle([x, y, x+w, y+h], radius=R, fill=bg, outline=BORDER, width=1)
    # header strip (flat bottom so it connects to body cleanly)
    draw.rectangle([x+1, y+1, x+w-1, y+HDR_H], fill=hdr)
    draw.rectangle([x+1, y+1, x+R, y+HDR_H], fill=bg)    # restore top-left corner bg
    draw.rectangle([x+w-R, y+1, x+w-1, y+HDR_H], fill=bg)  # top-right
    draw.rounded_rectangle([x, y, x+w, y+HDR_H], radius=R, fill=hdr, outline=BORDER, width=1)
    # title centred in header
    draw.text((x + w//2, y + HDR_H//2), title, fill='white', font=F_LAYER, anchor='mm')
    # body lines
    ty = y + HDR_H + 10
    for line in lines:
        draw.text((x + 14, ty), line, fill=TEXT, font=F_BODY)
        ty += 17

def store_box(x, y, w, h, bg, border, name, sub):
    draw.rounded_rectangle([x, y, x+w, y+h], radius=8, fill=bg, outline=border, width=2)
    draw.text((x+w//2, y+h//2 - 9), name, fill=border, font=F_LAYER, anchor='mm')
    draw.text((x+w//2, y+h//2 + 9), sub,  fill=border, font=F_SMALL, anchor='mm')

def arrow_v(x, y1, y2, color, label='', label_side='right'):
    """Vertical arrow from y1 down to y2."""
    tip = y2
    draw.line([(x, y1), (x, tip-7)], fill=color, width=2)
    draw.polygon([(x-5, tip-7), (x+5, tip-7), (x, tip)], fill=color)
    if label:
        lx = x + 6 if label_side == 'right' else x - 6
        anchor = 'lm' if label_side == 'right' else 'rm'
        draw.text((lx, (y1+y2)//2), label, fill=color, font=F_ARROW, anchor=anchor)

def arrow_up(x, y_from, y_to, color, label=''):
    """Vertical arrow pointing upward (y_to < y_from)."""
    tip = y_to
    draw.line([(x, y_from), (x, tip+7)], fill=color, width=2)
    draw.polygon([(x-5, tip+7), (x+5, tip+7), (x, tip)], fill=color)
    if label:
        draw.text((x + 6, (y_from+y_to)//2), label, fill=color, font=F_ARROW, anchor='lm')

# ── Column titles ────────────────────────────────────────────────────
draw.text((LX + CW//2, M + TITLE_H//2), 'WRITE SIDE  (Command)',
          fill='#1E293B', font=F_COL, anchor='mm')
draw.text((RX + CW//2, M + TITLE_H//2), 'READ SIDE  (Query)',
          fill='#1E293B', font=F_COL, anchor='mm')

# Vertical divider line between titles
div_x = M + CW + GAP//2
draw.line([(div_x, M), (div_x, GRID_BOT)], fill=BORDER, width=1)

# ── INTERFACE ────────────────────────────────────────────────────────
layer_box(LX, row_y['if'], CW, ROW_H['if'], 'if', 'INTERFACE',
          ['Command Handler'])
layer_box(RX, row_y['if'], CW, ROW_H['if'], 'if', 'INTERFACE',
          ['Query Handler'])

# ── APPLICATION ──────────────────────────────────────────────────────
layer_box(LX, row_y['ap'], CW, ROW_H['ap'], 'ap', 'APPLICATION',
          ['Usecase',
           'EventSourcingRepository'])
layer_box(RX, row_y['ap'], CW, ROW_H['ap'], 'ap', 'APPLICATION',
          ['EventSourcingProjector',
           '  ├─  buildReadModel(input:)',
           '  └─  apply(readModel:events:)',
           'StatefulProjector'])

# ── DOMAIN ───────────────────────────────────────────────────────────
layer_box(LX, row_y['dm'], CW, ROW_H['dm'], 'dm', 'DOMAIN  (DDDCore)',
          ['AggregateRoot',
           '  ├─  when(happened:)',
           '  ├─  apply(event:)',
           '  └─  ensureInvariant()',
           'DomainEvent'])
layer_box(RX, row_y['dm'], CW, ROW_H['dm'], 'dm', 'DOMAIN  (DDDCore)',
          ['ReadModel',
           '  └─  id  (Codable)'])

# ── INFRASTRUCTURE ───────────────────────────────────────────────────
layer_box(LX, row_y['in'], CW, ROW_H['in'], 'in', 'INFRASTRUCTURE  (KurrentSupport)',
          ['KurrentStorageCoordinator',
           'EventTypeMapper'])
layer_box(RX, row_y['in'], CW, ROW_H['in'], 'in', 'INFRASTRUCTURE  (ReadModelPersistence)',
          ['KurrentStorageCoordinator',
           'EventTypeMapper',
           'ReadModelStore'])

# ── Storage boxes ────────────────────────────────────────────────────
store_box(KDB_X, STORE_Y, STORE_W, STORE_H, KDB_BG, KDB_BD, 'KurrentDB', '(Event Store)')
store_box(PG_X,  STORE_Y, STORE_W, STORE_H, PG_BG,  PG_BD,  'PostgreSQL / Memory', '(Read Store)')

# ── Arrows ───────────────────────────────────────────────────────────
in_bot_l = row_y['in'] + ROW_H['in']
in_bot_r = row_y['in'] + ROW_H['in']

# Write: appends events  ↓  (left INFRA → KurrentDB top)
kdb_cx = KDB_X + STORE_W//2
arrow_v(kdb_cx, in_bot_l, STORE_Y, KDB_BD, 'appends events', label_side='left')

# Read: persists snapshot  ↓  (right INFRA → PostgreSQL top)
pg_cx = PG_X + STORE_W//2
arrow_v(pg_cx, in_bot_r, STORE_Y, PG_BD, 'persists snapshot', label_side='right')

# Read: reads events  ↑  (KurrentDB → right INFRA)
# Path: KurrentDB right edge → horizontal to bend_x → up to right INFRA bottom
kdb_right = KDB_X + STORE_W
reads_y   = STORE_Y + STORE_H//2          # mid-height of KurrentDB box
bend_x    = RX + 45                        # inside right column

draw.line([(kdb_right, reads_y), (bend_x, reads_y)], fill=ARROW_C, width=2)
arrow_up(bend_x, reads_y, in_bot_r, ARROW_C)

# label "reads events" above the horizontal segment
mid_rx = (kdb_right + bend_x) // 2
draw.text((mid_rx, reads_y - 14), 'reads events', fill=ARROW_C, font=F_ARROW, anchor='mm')

# ── Save ─────────────────────────────────────────────────────────────
out = os.path.join(os.path.dirname(__file__), 'architecture.png')
img.save(out, 'PNG')
print(f'Saved: {out}  ({W}×{H}px)')
