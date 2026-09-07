---
route: "/console/events/[id]"
page: Edit event
audience: Partner
access: Partner admin — own events only
forms: 1
fields: field (checkbox), field (text), text (textarea), choice (select)
indexed: false
source: src/app/console/events/[id]/page.tsx
open_work: 1
tags:
  - route
  - audience/partner
---

# `/console/events/[id]` — Edit event

Edit an event, its tiers and its gate team.

| | |
|---|---|
| **Who can open it** | Partner admin — own events only |
| **Search engines** | Hidden |
| **Forms** | 1 |
| **Fields** | field (checkbox), field (text), text (textarea), choice (select) |
| **Source** | `src/app/console/events/[id]/page.tsx` |

## APIs it calls

- `/api/console/events`

## Open work

- [[Floor plan & seat selection]]

> [!quote] As written on the route table
> what to pick searts in the floor plan layou

Back to [[Routes]] · [[RESERV]]
