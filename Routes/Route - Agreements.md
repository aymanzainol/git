---
route: "/admin/agreements"
page: Agreements
audience: Admin
access: Platform admin
forms: 1
fields: field (number), field (date), choice (select)
indexed: false
source: src/app/admin/agreements/page.tsx
open_work: 1
tags:
  - route
  - audience/admin
---

# `/admin/agreements` — Agreements

Commission and term per partner.

| | |
|---|---|
| **Who can open it** | Platform admin |
| **Search engines** | Hidden |
| **Forms** | 1 |
| **Fields** | field (number), field (date), choice (select) |
| **Source** | `src/app/admin/agreements/page.tsx` |

## APIs it calls

- `/api/admin/agreements`

## Open work

- [[Commission & invoice calculation]]

> [!quote] As written on the route table
> in agreement Platform commission % as well as by fixed unit
> need to recalate the invoice

Back to [[Routes]] · [[RESERV]]
