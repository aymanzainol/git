---
route: "/scan"
page: Entry gate scanner
audience: Gate
access: Gate operator, partner admin or platform admin
forms: 2
fields: field (text), choice (select)
indexed: false
source: src/app/scan/page.tsx
open_work: 1
tags:
  - route
  - audience/gate
---

# `/scan` — Entry gate scanner

The gate. Camera or manual code, one-word verdict, recent scans.

| | |
|---|---|
| **Who can open it** | Gate operator, partner admin or platform admin |
| **Search engines** | Hidden |
| **Forms** | 2 |
| **Fields** | field (text), choice (select) |
| **Source** | `src/app/scan/page.tsx` |

## APIs it calls

- `/api/scan`

## Open work

- [[Waiting list]]

> [!quote] As written on the route table
> add wahting list

Back to [[Routes]] · [[RESERV]]
