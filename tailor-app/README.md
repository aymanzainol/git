# Tailor Orders / طلبات الخياط / درزی کے آرڈر

A one-file mobile web app for a tailor shop to keep track of thobe orders.

- Each order has: **customer name, mobile number, book number, invoice number**, status, due date and notes
- Statuses: **In progress → Thobe is ready → Delivered**
- **Arabic, English and Urdu** (Arabic and Urdu display right to left)
- When a thobe is ready, the **WhatsApp** button opens a ready-made message to the customer
  (the message language can be set in Settings)
- Search by name, mobile, book or invoice number; tap a counter to filter by status
- Works offline. Orders are saved on the phone itself. Use **Settings → Export backup** regularly.

## Use it
Open `index.html` in the phone's browser, then use **Add to Home Screen** so it works like an app.

## Online version (phone + computer, shared orders)
`online.html` is the same app, published as a private claude.ai page:
https://claude.ai/artifact/8Y6rM5AU4ZZBs73SoW3Cea

Orders are kept in an online database, so every phone and computer that opens the link
sees the same list and updates live. To let staff add or update orders, share the page
with them as **Contributor** (Viewers cannot see customer data).
If the database can't be reached, the page falls back to saving on the device.

When adding an order, the **📷 Scan** button opens the camera; Claude reads the invoice photo and fills in the
invoice number (and the invoice date, name, mobile and book number when they are written on it).
Each order also records an **invoice date** (defaults to today) and a **cleared date** (filled in automatically
when the order is marked Delivered).

## Report page
The **Report** tab (link ending `#report`) shows progress by day, week (starting Sunday) or month:
new orders (by invoice date), thobes marked ready, orders delivered (by cleared date) and the average
number of days from invoice to delivery. A chart and table compare the last 7 days / 8 weeks / 6 months,
and a "Right now" panel shows orders in progress, waiting for pickup and overdue (past their due date).

## Railway version
`server.js` serves the same page on Railway with its own storage:
- Orders are kept in `orders.json` on a Railway volume mounted at `/data`.
- Everyone signs in with one shop password (`APP_PASSWORD`). Sessions last 90 days.
- The **Scan** button works when `ANTHROPIC_API_KEY` is set (Claude reads the invoice photo).
- The page can be added to the phone's home screen (it has an app icon).

Variables: `APP_PASSWORD` (required), `ANTHROPIC_API_KEY` (optional), `DATA_DIR` (default `/data`).
Run locally: `cd tailor-app && npm install && APP_PASSWORD=test DATA_DIR=./data npm start`.
