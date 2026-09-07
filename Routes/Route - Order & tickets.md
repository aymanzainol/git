---
route: "/orders/[code]"
page: Order & tickets
audience: Ticket holder
access: Anyone holding the order code
forms: 0
fields: —
indexed: false
source: src/app/orders/[code]/page.tsx
open_work: 1
tags:
  - route
  - audience/ticket-holder
---

# `/orders/[code]` — Order & tickets

The order after purchase, with every ticket and its QR. Three layouts.

| | |
|---|---|
| **Who can open it** | Anyone holding the order code |
| **Search engines** | Hidden |
| **Forms** | 0 |
| **Fields** | — |
| **Source** | `src/app/orders/[code]/page.tsx` |

## APIs it calls

- `/api/tickets/`
- `/api/orders/`

## Open work

- [[Waiting list]]

> [!quote] As written on the route table
> Add waiting list

Back to [[Routes]] · [[RESERV]]
