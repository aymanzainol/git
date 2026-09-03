---
type: board
project: RESERV
state: live today
shipped: 13
in_progress: 3
not_started: 6
tags:
  - reserv
---

# RESERV

> [!tip] live today
> 13 of 22 pieces are shipped. 3 are moving. 6 have not been started.

**Open the map:** [[RESERV Map.canvas|RESERV Map]] — the same picture, pannable, with every node linked to its note.

## Where it stands

| Area | 🟢 | 🟡 | 🔴 | |
|---|---|---|---|---|
| [[Sell]] | 3 | 0 | 2 | 🟢🟢🟢🔴🔴 |
| [[Admit]] | 3 | 0 | 0 | 🟢🟢🟢 |
| [[Hold up]] | 2 | 1 | 2 | 🟢🟢🟡🔴🔴 |
| [[Deliver]] | 2 | 2 | 0 | 🟢🟢🟡🟡 |
| [[Run]] | 3 | 0 | 2 | 🟢🟢🟢🔴🔴 |
| **Total** | **13** | **3** | **6** | |

## The map, as text

```mermaid
flowchart LR
  R(("RESERV<br/>live today")):::core
  R --> A1["Sell"]:::core
  A1 --> A1_0["Catalogue & storefronts"]:::done
  A1 --> A1_1["Seating & floor plans"]:::done
  A1 --> A1_2["Checkout & holds"]:::done
  A1 --> A1_3["Card payments<br/><small>The gate to revenue</small>"]:::todo
  A1 --> A1_4["Refunds"]:::todo
  R --> A2["Admit"]:::core
  A2 --> A2_0["Rotating signed QR"]:::done
  A2 --> A2_1["Offline-capable gate"]:::done
  A2 --> A2_2["One-use enforcement"]:::done
  R --> A3["Hold up"]:::core
  A3 --> A3_0["215 automated checks"]:::done
  A3 --> A3_1["Bilingual, true RTL"]:::done
  A3 --> A3_2["Design system<br/><small>Tokens in Figma, components next</small>"]:::doing
  A3 --> A3_3["Postgres & backups"]:::todo
  A3 --> A3_4["Security review"]:::todo
  R --> A4["Deliver"]:::core
  A4 --> A4_0["Email<br/><small>Live on Resend</small>"]:::done
  A4 --> A4_1["Printable pass"]:::done
  A4 --> A4_2["SMS<br/><small>Waiting on a CITC sender ID</small>"]:::doing
  A4 --> A4_3["Wallet passes<br/><small>Google needs a key, Apple a membership</small>"]:::doing
  R --> A5["Run"]:::core
  A5 --> A5_0["Partner console"]:::done
  A5 --> A5_1["Agreements & invoices"]:::done
  A5 --> A5_2["Roles & audited access"]:::done
  A5 --> A5_3["Partner payouts"]:::todo
  A5 --> A5_4["ZATCA e-invoicing"]:::todo
  classDef core stroke:#e8b93b,stroke-width:2px;
  classDef done stroke:#22c55e,stroke-width:2px;
  classDef doing stroke:#eab308,stroke-width:2px;
  classDef todo stroke:#ef4444,stroke-width:2px;
```

## 🔴 Not started

| Item | Area | Note |
|---|---|---|
| [[Card payments]] | [[Sell]] | The gate to revenue |
| [[Refunds]] | [[Sell]] |  |
| [[Postgres & backups]] | [[Hold up]] |  |
| [[Security review]] | [[Hold up]] |  |
| [[Partner payouts]] | [[Run]] |  |
| [[ZATCA e-invoicing]] | [[Run]] |  |

## 🟡 In progress

| Item | Area | Note |
|---|---|---|
| [[Design system]] | [[Hold up]] | Tokens in Figma, components next |
| [[SMS]] | [[Deliver]] | Waiting on a CITC sender ID |
| [[Wallet passes]] | [[Deliver]] | Google needs a key, Apple a membership |

## 🟢 Shipped

| Item | Area | Note |
|---|---|---|
| [[Catalogue & storefronts]] | [[Sell]] |  |
| [[Seating & floor plans]] | [[Sell]] |  |
| [[Checkout & holds]] | [[Sell]] |  |
| [[Rotating signed QR]] | [[Admit]] |  |
| [[Offline-capable gate]] | [[Admit]] |  |
| [[One-use enforcement]] | [[Admit]] |  |
| [[215 automated checks]] | [[Hold up]] |  |
| [[Bilingual, true RTL]] | [[Hold up]] |  |
| [[Email]] | [[Deliver]] | Live on Resend |
| [[Printable pass]] | [[Deliver]] |  |
| [[Partner console]] | [[Run]] |  |
| [[Agreements & invoices]] | [[Run]] |  |
| [[Roles & audited access]] | [[Run]] |  |

## Areas

[[Sell]] · [[Admit]] · [[Hold up]] · [[Deliver]] · [[Run]]

See [[Status legend]] for what each colour commits to.
