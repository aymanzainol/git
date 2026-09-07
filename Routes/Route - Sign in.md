---
route: "/login"
page: Sign in
audience: Public
access: Anyone — redirects away if already signed in
forms: 2
fields: field (text)
indexed: true
source: src/app/login/page.tsx
open_work: 0
tags:
  - route
  - audience/public
---

# `/login` — Sign in

Request a code by phone or email, then enter it.

| | |
|---|---|
| **Who can open it** | Anyone — redirects away if already signed in |
| **Search engines** | Indexed |
| **Forms** | 2 |
| **Fields** | field (text) |
| **Source** | `src/app/login/page.tsx` |

## APIs it calls

- `/api/auth/otp/request`
- `/api/auth/otp/verify`

## Open work

_Nothing outstanding._

Back to [[Routes]] · [[RESERV]]
