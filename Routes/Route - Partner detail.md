---
route: "/admin/partners/[slug]"
page: Partner detail
audience: Admin
access: Platform admin
forms: 1
fields: field (number), field (date), choice (select)
indexed: false
source: src/app/admin/partners/[slug]/page.tsx
open_work: 1
tags:
  - route
  - audience/admin
---

# `/admin/partners/[slug]` — Partner detail

One partner: performance, agreement, invoices, team.

| | |
|---|---|
| **Who can open it** | Platform admin |
| **Search engines** | Hidden |
| **Forms** | 1 |
| **Fields** | field (number), field (date), choice (select) |
| **Source** | `src/app/admin/partners/[slug]/page.tsx` |

## APIs it calls

- `/api/admin/impersonate`
- `/api/admin/accounts`
- `/api/admin/agreements`
- `/api/admin/partners`

## Open work

- [[Ratings]]

> [!quote] As written on the route table
> rating

Back to [[Routes]] · [[RESERV]]
