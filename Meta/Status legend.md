---
type: meta
tags:
  - reserv
---

# Status legend

Three colours, used the same way on the [[RESERV Map.canvas|map]], in the [[RESERV]] board, and in every note's frontmatter.

| | `status:` | Means | It is safe to say |
|---|---|---|---|
| 🟢 | `shipped` | Built, merged, and in use today. | "This works." |
| 🟡 | `in-progress` | Real work started, not finished. Usually one named blocker. | "This is moving." |
| 🔴 | `not-started` | Nothing built yet. | "This does not exist." |

Nothing sits between colours. A thing that is half-built is 🟡; a thing with a design doc and no code is 🔴.

## Frontmatter

Every note in `Items/` carries:

```yaml
area: Sell            # which branch of the map it hangs off
status: not-started   # shipped | in-progress | not-started
focus: true           # highlighted on the map
note: The gate to revenue
tags: [reserv/sell, status/not-started]
```

Which means you can pull any slice with search — `tag:#status/not-started`, `tag:#reserv/deliver` — or with Dataview if you install it:

````
```dataview
TABLE status, note AS "Blocker", area
FROM "Items"
WHERE status != "shipped"
SORT status ASC
```
````

## Keeping it honest

Change the status in the note's frontmatter **and** the node colour on the canvas — they are two files, and nothing syncs them for you. Canvas node colours are `1` red, `3` yellow, `4` green.
