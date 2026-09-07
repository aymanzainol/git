---
route: "/invoices/[number]"
page: Invoice
audience: Partner
access: The invoice's partner, or platform admin
forms: 0
fields: —
indexed: false
source: src/app/invoices/[number]/page.tsx
open_work: 1
tags:
  - route
  - audience/partner
---

# `/invoices/[number]` — Invoice

A settlement invoice with the events that made it, line by line.

| | |
|---|---|
| **Who can open it** | The invoice's partner, or platform admin |
| **Search engines** | Hidden |
| **Forms** | 0 |
| **Fields** | — |
| **Source** | `src/app/invoices/[number]/page.tsx` |

## APIs it calls

_None._

## Open work

- [[Commission & invoice calculation]]

> [!quote] As written on the route table
> change calculation

Back to [[Routes]] · [[RESERV]]
