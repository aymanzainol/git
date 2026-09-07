---
route: "/checkout/[slug]"
page: Checkout
audience: Public
access: Anyone — no account needed to start
forms: 0
fields: field (text), field (email)
indexed: false
source: src/app/checkout/[slug]/page.tsx
open_work: 2
tags:
  - route
  - audience/public
---

# `/checkout/[slug]` — Checkout

Pick tickets or a table, hold them, prove a phone or email, pay.

| | |
|---|---|
| **Who can open it** | Anyone — no account needed to start |
| **Search engines** | Hidden |
| **Forms** | 0 |
| **Fields** | field (text), field (email) |
| **Source** | `src/app/checkout/[slug]/page.tsx` |

## APIs it calls

- `/api/checkout/quote`
- `/api/auth/otp/request`
- `/api/auth/otp/verify`
- `/api/checkout/pay`
- `/api/checkout/tables`
- `/api/checkout/tables?eventId=`

## Open work

- [[Waiting list]]
- [[Floor plan & seat selection]]

> [!quote] As written on the route table
> how to add the floor plan
> add wait list

Back to [[Routes]] · [[RESERV]]
