# RESERV — Obsidian vault

The RESERV status mind map, as an Obsidian vault: one canvas you can pan and edit, and one note per piece of the system behind it.

## Open it

1. Clone this repo.
2. Obsidian → **Open folder as vault** → pick the cloned folder.
3. Open **`RESERV Map.canvas`** for the map, or **`RESERV.md`** for the board view.

Nothing here needs a community plugin. Canvas, graph, and search are all core Obsidian. Dataview queries are suggested in [Status legend](Meta/Status%20legend.md) but everything works without it.

## What's in here

| | |
|---|---|
| `RESERV Map.canvas` | The mind map. Five branches off a centre node, 22 leaves, colour-coded by status. Every leaf is a live link to its note. |
| `RESERV.md` | The board: roll-up counts, the same map as a Mermaid diagram, and the work bucketed by status. |
| `Areas/` | One note per branch — Sell, Admit, Hold up, Deliver, Run — each with its items and a count. |
| `Items/` | One note per leaf, with `status`, `area`, and any blocker in frontmatter. |
| `Meta/Status legend.md` | What the three colours commit to, and the frontmatter schema. |

## Status at a glance

🟢 13 shipped · 🟡 3 in progress · 🔴 6 not started

| Area | 🟢 | 🟡 | 🔴 |
|---|---|---|---|
| Sell | 3 | 0 | 2 |
| Admit | 3 | 0 | 0 |
| Hold up | 2 | 1 | 2 |
| Deliver | 2 | 2 | 0 |
| Run | 3 | 0 | 2 |

## Editing

Drag nodes, recolour them, and add branches directly in the canvas — it is plain JSON, so the diffs stay readable. When you change a node's colour, change `status:` in the matching note too; nothing syncs the two for you.
