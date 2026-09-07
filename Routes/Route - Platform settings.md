---
route: "/admin/settings"
page: Platform settings
audience: Admin
access: Platform admin
forms: 1
fields: field (text), text (textarea), choice (select)
indexed: false
source: src/app/admin/settings/page.tsx
open_work: 1
tags:
  - route
  - audience/admin
---

# `/admin/settings` — Platform settings

Email provider, sender, support details, test send.

| | |
|---|---|
| **Who can open it** | Platform admin |
| **Search engines** | Hidden |
| **Forms** | 1 |
| **Fields** | field (text), text (textarea), choice (select) |
| **Source** | `src/app/admin/settings/page.tsx` |

## APIs it calls

- `/api/admin/settings`
- `/api/admin/settings/test-mail`

## Open work

- [[Page & menu visibility]]

> [!quote] As written on the route table
> need to toggel pages hide pages   add catoagry  hide menue

Back to [[Routes]] · [[RESERV]]
