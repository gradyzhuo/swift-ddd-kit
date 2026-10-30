"""Generate architecture diagram PNG for swift-ddd-kit (CA layers)."""
from PIL import Image, ImageDraw, ImageFont
import os

# ── Canvas ──────────────────────────────────────────────────────────
W, H = 1020, 630
BG = '#F8FAFC'
img = Image.new('RGB', (W, H), BG)
draw = ImageDraw.Draw(img)

# ── Fonts ────────────────────────────────────────────────────────────
def font(size, mono=False):
    mono_paths = ['/System/Library/Fonts/Menlo.ttc', '/System/Library/Fonts/Courier New.ttf']
    sans_paths = ['/System/Library/Fonts/Helvetica.ttc', '/Library/Fonts/Arial.ttf']
    for path in (mono_paths if mono else sans_paths):
        try:
            return ImageFont.truetype(path, size)
        except Exception:
            pass
    return ImageFont.load_default()

F_COL   = font(15)
F_LAYER = font(12)
F_BODY  = font(11, mono=True)
F_SMALL = font(10)
F_ARROW = font(10)

# ── Colours ──────────────────────────────────────────────────────────
LAYER_COLORS = {
    'ia':  ('#EEF2F7', '#64748B'),   # Interface Adapters — slate
    'uc':  ('#EBF4FF', '#2563EB'),   # Use Cases — blue
    'en':  ('#ECFDF5', '#059669'),   # Entities — green
}
FW_BG  = '#F5F0FF';  FW_BD = '#7C3AED'   # Frameworks & Drivers — purple
BORDER  = '#CBD5E1'
TEXT    = '#1E293B'
ARROW_C = '#64748B'
KDB_BG  = '#FEE2E2';  KDB_BD = '#DC2626'
PG_BG   = '#DBEAFE';  PG_BD  = '#1D4ED8'

# ── Layout ───────────────────────────────────────────────────────────
M    = 30
GAP  = 16
CW   = (W - 2*M - GAP) // 2
LX   = M
RX   = M + CW + GAP

TITLE_H = 32
HDR_H   = 26
R       = 6

# Frameworks & Drivers sits at the TOP (outermost CA layer)
FW_PAD   = 16
STORE_W  = 210
STORE_H  = 60
FW_BOX_H = STORE_H + FW_PAD * 2 + 20   # label (20) + padding + store box
FW_Y     = M + TITLE_H                  # starts just below column-title row

store_inner_y = FW_Y + 20 + FW_PAD     # below the "FRAMEWORKS & DRIVERS" label

ARROW_GAP = 30                          # gap between FW&D bottom and layer grid
GRID_TOP  = FW_Y + FW_BOX_H + ARROW_GAP

ROW_H = {'ia': 120, 'uc': 128, 'en': 130}

row_y = {}
y = GRID_TOP
for k in ('ia', 'uc', 'en'):
    row_y[k] = y
    y += ROW_H[k]

GRID_BOT = y

KDB_X = LX + CW//2 - STORE_W//2
PG_X  = RX + CW//2 - STORE_W//2

# ── Helpers ──────────────────────────────────────────────────────────
def layer_box(x, y, w, h, key, title, lines):
    bg, hdr = LAYER_COLORS[key]
    draw.rounded_rectangle([x, y, x+w, y+h], radius=R, fill=bg, outline=BORDER, width=1)
    draw.rectangle([x+1, y+1, x+w-1, y+HDR_H], fill=hdr)
    draw.rectangle([x+1, y+1, x+R,   y+HDR_H], fill=bg)
    draw.rectangle([x+w-R, y+1, x+w-1, y+HDR_H], fill=bg)
    draw.rounded_rectangle([x, y, x+w, y+HDR_H], radius=R, fill=hdr, outline=BORDER, width=1)
    draw.text((x + w//2, y + HDR_H//2), title, fill='white', font=F_LAYER, anchor='mm')
    ty = y + HDR_H + 10
    for line in lines:
        draw.text((x + 14, ty), line, fill=TEXT, font=F_BODY)
        ty += 17

def store_box(x, y, w, h, bg, border, name, sub):
    draw.rounded_rectangle([x, y, x+w, y+h], radius=8, fill=bg, outline=border, width=2)
    draw.text((x+w//2, y+h//2 - 9), name, fill=border, font=F_LAYER, anchor='mm')
    draw.text((x+w//2, y+h//2 + 9), sub,  fill=border, font=F_SMALL, anchor='mm')

def arrow_v(x, y1, y2, color, label='', label_side='right'):
    """Downward arrow from y1 to y2."""
    draw.line([(x, y1), (x, y2-7)], fill=color, width=2)
    draw.polygon([(x-5, y2-7), (x+5, y2-7), (x, y2)], fill=color)
    if label:
        lx     = x + 6 if label_side == 'right' else x - 6
        anchor = 'lm' if label_side == 'right' else 'rm'
        draw.text((lx, (y1+y2)//2), label, fill=color, font=F_ARROW, anchor=anchor)

def arrow_up(x, y_from, y_to, color, label='', label_side='right'):
    """Upward arrow from y_from to y_to."""
    draw.line([(x, y_from), (x, y_to+7)], fill=color, width=2)
    draw.polygon([(x-5, y_to+7), (x+5, y_to+7), (x, y_to)], fill=color)
    if label:
        lx     = x + 6 if label_side == 'right' else x - 6
        anchor = 'lm' if label_side == 'right' else 'rm'
        draw.text((lx, (y_from+y_to)//2), label, fill=color, font=F_ARROW, anchor=anchor)

# ── Column titles ────────────────────────────────────────────────────
draw.text((LX + CW//2, M + TITLE_H//2), 'WRITE SIDE  (Command)',
          fill='#1E293B', font=F_COL, anchor='mm')
draw.text((RX + CW//2, M + TITLE_H//2), 'READ SIDE  (Query)',
          fill='#1E293B', font=F_COL, anchor='mm')

# ── FRAMEWORKS & DRIVERS wrapper (TOP, outermost layer) ──────────────
fw_left  = M
fw_right = W - M

draw.rounded_rectangle([fw_left, FW_Y, fw_right, FW_Y + FW_BOX_H],
    radius=10, fill=FW_BG, outline=FW_BD, width=2)
draw.text(((fw_left + fw_right)//2, FW_Y + 10),
          'FRAMEWORKS & DRIVERS',
          fill=FW_BD, font=F_LAYER, anchor='mm')

store_box(KDB_X, store_inner_y, STORE_W, STORE_H, KDB_BG, KDB_BD, 'KurrentDB / Local Files', '(Event Store)')
store_box(PG_X,  store_inner_y, STORE_W, STORE_H, PG_BG,  PG_BD,  'PostgreSQL / In-Memory', '(Read Store)')

# ── Divider between Write and Read columns (layer grid only) ─────────
div_x = M + CW + GAP//2
draw.line([(div_x, GRID_TOP), (div_x, GRID_BOT)], fill=BORDER, width=1)

# ── INTERFACE ADAPTERS ───────────────────────────────────────────────
layer_box(LX, row_y['ia'], CW, ROW_H['ia'], 'ia', 'INTERFACE ADAPTERS',
          ['Command Handler  (Controller)',
           'KurrentStorageCoordinator  (Gateway)',
           'PersistentEventStore / InMemoryEventStore',
           'EventTypeMapper  (Adapter)'])
layer_box(RX, row_y['ia'], CW, ROW_H['ia'], 'ia', 'INTERFACE ADAPTERS',
          ['KurrentProjection.*SubscriptionRunner',
           'KurrentStorageCoordinator  (Gateway)',
           '(Transactional)ReadModelStore  (Gateway)',
           'EventTypeMapper  (Adapter)'])

# ── USE CASES ────────────────────────────────────────────────────────
layer_box(LX, row_y['uc'], CW, ROW_H['uc'], 'uc', 'USE CASES',
          ['Usecase',
           'EventSourcingRepository',
           'EventStore  (Port)',
           'EventMetadataContext'])
layer_box(RX, row_y['uc'], CW, ROW_H['uc'], 'uc', 'USE CASES',
          ['EventSourcingProjector',
           '  ├─  buildReadModel(input:)',
           '  └─  apply(readModel:events:)',
           'StatefulEventSourcingProjector',
           'EventStore  (Port)'])

# ── ENTITIES ─────────────────────────────────────────────────────────
layer_box(LX, row_y['en'], CW, ROW_H['en'], 'en', 'ENTITIES  (DDDCore)',
          ['AggregateRoot',
           '  ├─  when(happened:)',
           '  ├─  apply(event:)',
           '  └─  ensureInvariant()',
           'DomainEvent / DeletedEvent'])
layer_box(RX, row_y['en'], CW, ROW_H['en'], 'en', 'ENTITIES  (EventSourcing)',
          ['ReadModel  (Codable)',
           '  ├─  id',
           '  └─  readModelTypeName'])

# ── Arrows ───────────────────────────────────────────────────────────
kdb_cx    = KDB_X + STORE_W//2
pg_cx     = PG_X  + STORE_W//2
store_bot = store_inner_y + STORE_H

# Write: appends events ↑  (Write side → KurrentDB)
arrow_up(kdb_cx, GRID_TOP, store_bot, KDB_BD, 'appends events', label_side='left')

# Read: persists snapshot ↑  (Read side → PostgreSQL)
arrow_up(pg_cx, GRID_TOP, store_bot, PG_BD, 'persists snapshot', label_side='right')

# Read: reads events ↓  (KurrentDB → Read side, bent path)
kdb_right = KDB_X + STORE_W
reads_y   = store_inner_y + STORE_H//2
bend_x    = RX + 50

draw.line([(kdb_right, reads_y), (bend_x, reads_y)], fill=ARROW_C, width=2)
arrow_v(bend_x, reads_y, GRID_TOP, ARROW_C)
mid_rx = (kdb_right + bend_x) // 2
draw.text((mid_rx, reads_y - 14), 'persistent subscription', fill=ARROW_C, font=F_ARROW, anchor='mm')

# ── Save ─────────────────────────────────────────────────────────────
out = os.path.join(os.path.dirname(__file__), 'architecture.png')
img.save(out, 'PNG')
print(f'Saved: {out}  ({W}×{H}px)')
