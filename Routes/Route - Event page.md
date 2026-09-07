---
route: "/events/[slug]"
page: Event page
audience: Public
access: Anyone
forms: 1
fields: field (text)
indexed: true
source: src/app/events/[slug]/page.tsx
open_work: 2
tags:
  - route
  - audience/public
---

# `/events/[slug]` — Event page

One event: poster, date, venue, ticket tiers, floor plan, buy.

| | |
|---|---|
| **Who can open it** | Anyone |
| **Search engines** | Indexed |
| **Forms** | 1 |
| **Fields** | field (text) |
| **Source** | `src/app/events/[slug]/page.tsx` |

## APIs it calls

- `/api/checkout/hold`
- `/api/concierge`

## Open work

- [[Waiting list]]
- [[Ratings]]

> [!quote] As written on the route table
> add wait list and rating

Back to [[Routes]] · [[RESERV]]
