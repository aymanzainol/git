# Tailor Orders / طلبات الخياط / درزی کے آرڈر

A one-file mobile web app for a tailor shop to keep track of thobe orders.

- Each order has: **customer name, mobile number, book number, invoice number**, status, due date and notes
- Statuses: **In progress → Thobe is ready → Delivered**
- **Arabic and English** (Arabic displays right to left)
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
- Customer data is private: everyone signs in with a **username and password**. Staff accounts can
  view and enter orders; owner accounts can also open the report, change shop settings and manage
  accounts (Settings → Accounts: add, set a new password, delete). Passwords are stored as scrypt
  hashes. Changing a password or deleting an account signs that person out everywhere. Each order
  records who added it and who changed it last. **Lock** in the report drops an owner back to staff.
- The **📷 Photo** button takes a picture of the invoice. The photo is saved with the order (in
  `/data/photos`) and can be opened from the order card with **Invoice photo**.
- The photo is also read automatically (OCR) to fill in the invoice number, date and mobile:
  with `ANTHROPIC_API_KEY` set, Claude reads it (best, handles handwriting); without a key, a
  free built-in reader (Tesseract) runs on the phone, which works well on printed numbers.
  The shop's own phone numbers are never taken as the customer's mobile.
- The page can be added to the phone's home screen (it has an app icon).

Variables (only used to create the first accounts when none exist): `OWNER_USERNAME` (default `admin`) + `APP_PASSWORD`, and `STAFF_PASSWORD` for a first `staff` account, `ANTHROPIC_API_KEY` (optional), `DATA_DIR` (default `/data`).
Run locally: `cd tailor-app && npm install && APP_PASSWORD=test DATA_DIR=./data npm start`.
