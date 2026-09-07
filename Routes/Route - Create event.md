---
route: "/console/events/new"
page: Create event
audience: Partner
access: Partner admin
forms: 1
fields: field (checkbox), field (text), text (textarea), choice (select)
indexed: false
source: src/app/console/events/new/page.tsx
open_work: 2
tags:
  - route
  - audience/partner
---

# `/console/events/new` — Create event

Create an event in both languages with tiers, poster and floor plan.

| | |
|---|---|
| **Who can open it** | Partner admin |
| **Search engines** | Hidden |
| **Forms** | 1 |
| **Fields** | field (checkbox), field (text), text (textarea), choice (select) |
| **Source** | `src/app/console/events/new/page.tsx` |

## APIs it calls

- `/api/console/events`

## Open work

- [[Floor plan & seat selection]]
- [[Event location]]

> [!quote] As written on the route table
> add locarion removing venue and as well add a place for link floot plan

Back to [[Routes]] · [[RESERV]]
