---
route: "/admin"
page: Admin dashboard
audience: Admin
access: Platform admin
forms: 0
fields: choice (select)
indexed: false
source: src/app/admin/page.tsx
open_work: 0
tags:
  - route
  - audience/admin
---

# `/admin` — Admin dashboard

Platform revenue, trend, billing tables, close a settlement period.

| | |
|---|---|
| **Who can open it** | Platform admin |
| **Search engines** | Hidden |
| **Forms** | 0 |
| **Fields** | choice (select) |
| **Source** | `src/app/admin/page.tsx` |

## APIs it calls

- `/api/admin/close-period`

## Open work

_Nothing outstanding._

Back to [[Routes]] · [[RESERV]]
