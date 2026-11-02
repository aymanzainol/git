// Salar Tailoring – small server for Railway.
// Serves the app page, keeps orders in a JSON file on a volume, and reads invoice photos
// with the Claude API when ANTHROPIC_API_KEY is set. Customer data is only for signed-in
// people: staff (STAFF_PASSWORD) can view and enter orders; the owner (APP_PASSWORD) can also
// open the report and change shop settings.
//
// Environment:
//   APP_PASSWORD       required – the owner's password (everything, including the report)
//   STAFF_PASSWORD     required – the staff password (orders only, no report or settings)
//   DATA_DIR           where orders.json lives (default /data, mount a Railway volume there)
//   ANTHROPIC_API_KEY  optional – turns on the "Scan" invoice button
//   SESSION_SECRET     optional – signs login cookies (defaults to a value derived from APP_PASSWORD)
//   PORT               set by Railway

import http from "node:http";
import fs from "node:fs";
import fsp from "node:fs/promises";
import path from "node:path";
import crypto from "node:crypto";
import { fileURLToPath } from "node:url";
import zlib from "node:zlib";
import Anthropic from "@anthropic-ai/sdk";

const here = path.dirname(fileURLToPath(import.meta.url));
const PORT = Number(process.env.PORT) || 3000;
const DATA_DIR = process.env.DATA_DIR || "/data";
const DATA_FILE = path.join(DATA_DIR, "orders.json");
const PHOTO_DIR = path.join(DATA_DIR, "photos");
const PHOTO_EXT = { "image/jpeg": ".jpg", "image/png": ".png", "image/webp": ".webp" };
const PASSWORD = process.env.APP_PASSWORD || "";
const STAFF_PASSWORD = process.env.STAFF_PASSWORD || "";
const SECRET = process.env.SESSION_SECRET || crypto.createHash("sha256").update("salar:" + PASSWORD).digest("hex");
const COOKIE = "salar_session";
const SESSION_DAYS = 90;
const anthropic = process.env.ANTHROPIC_API_KEY ? new Anthropic() : null;

if (!PASSWORD) console.warn("APP_PASSWORD (owner) is not set – nobody can sign in as owner until it is.");
if (!STAFF_PASSWORD) console.warn("STAFF_PASSWORD is not set – staff cannot sign in until it is.");

// ---------- page ----------
const SKELETON_HEAD = `<!doctype html><html lang="ar" dir="rtl"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,viewport-fit=cover">
<meta name="theme-color" content="#1f2d58"><meta name="mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-capable" content="yes"><meta name="apple-mobile-web-app-title" content="Salar"><meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<link rel="manifest" href="manifest.webmanifest"><link rel="icon" href="icon-192.png"><link rel="apple-touch-icon" href="icon-192.png">
<style>:root{padding-top:env(safe-area-inset-top,0px);padding-bottom:env(safe-area-inset-bottom,0px)}body{margin:0;font-size:14px}img{max-width:100%}[hidden]{display:none!important}</style>
</head><body>`;
// The page is built once at start-up and kept compressed in memory.
const PAGE = SKELETON_HEAD + fs.readFileSync(path.join(here, "online.html"), "utf8") + "</body></html>";
const PAGE_GZ = zlib.gzipSync(PAGE, { level: 9 });
const PAGE_ETAG = '"' + crypto.createHash("sha1").update(PAGE).digest("base64url").slice(0, 16) + '"';
const STATIC = {
  "/manifest.webmanifest": ["manifest.webmanifest", "application/manifest+json"],
  "/icon-192.png": ["brand/icon-192.png", "image/png"],
  "/icon-512.png": ["brand/icon-512.png", "image/png"],
  "/sw.js": ["sw.js", "text/javascript; charset=utf-8"],
};

// ---------- storage ----------
let state = { orders: {}, config: { shop: "", code: "966" } };
try {
  const raw = JSON.parse(fs.readFileSync(DATA_FILE, "utf8"));
  state = { orders: raw.orders || {}, config: { ...state.config, ...(raw.config || {}) } };
  console.log(`Loaded ${Object.keys(state.orders).length} orders from ${DATA_FILE}`);
} catch (e) {
  if (e.code !== "ENOENT") console.error("Could not read data file:", e.message);
}
// ---------- live updates (Server-Sent Events) ----------
// Every change bumps the version and tells all open phones to fetch the new state.
let version = Date.now();
const listeners = new Set();
function broadcast() {
  version++;
  for (const r of listeners) { try { r.write(`data: ${version}\n\n`); } catch { listeners.delete(r); } }
}
setInterval(() => { for (const r of listeners) { try { r.write(": ping\n\n"); } catch { listeners.delete(r); } } }, 25000).unref();

let writing = Promise.resolve();
function persist() {
  writing = writing.then(async () => {
    await fsp.mkdir(DATA_DIR, { recursive: true });
    const tmp = DATA_FILE + ".tmp";
    await fsp.writeFile(tmp, JSON.stringify(state));
    await fsp.rename(tmp, DATA_FILE);
  });
  writing.then(broadcast, () => {});
  return writing;
}

async function removePhoto(id) {
  for (const ext of Object.values(PHOTO_EXT)) await fsp.rm(path.join(PHOTO_DIR, id + ext), { force: true });
}

// ---------- auth ----------
const sign = (v) => crypto.createHmac("sha256", SECRET).update(v).digest("base64url");
const ROLES = ["staff", "owner"];
function makeToken(role) {
  const body = String(Date.now() + SESSION_DAYS * 864e5) + "." + role;
  return body + "." + sign(body);
}
// Returns "owner", "staff" or null.
function roleOf(req) {
  const tok = cookieOf(req, COOKIE);
  const [exp, role, sig] = (tok || "").split(".");
  if (!exp || !role || !sig || !ROLES.includes(role) || Number(exp) < Date.now()) return null;
  const a = Buffer.from(sig), b = Buffer.from(sign(exp + "." + role));
  return a.length === b.length && crypto.timingSafeEqual(a, b) ? role : null;
}
function samePassword(given, real) {
  if (!real) return false;
  const a = crypto.createHash("sha256").update(String(given || "")).digest();
  const b = crypto.createHash("sha256").update(real).digest();
  return crypto.timingSafeEqual(a, b);
}
const sessionCookie = (role) => `${COOKIE}=${makeToken(role)}; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=${SESSION_DAYS * 86400}`;
function cookieOf(req, name) {
  for (const part of (req.headers.cookie || "").split(";")) {
    const [k, ...v] = part.trim().split("=");
    if (k === name) return decodeURIComponent(v.join("="));
  }
  return "";
}
const attempts = new Map(); // ip -> [count, windowStart]
function tooMany(ip) {
  const now = Date.now(), a = attempts.get(ip);
  if (!a || now - a[1] > 15 * 60e3) { attempts.set(ip, [1, now]); return false; }
  a[0]++;
  return a[0] > 10;
}

// ---------- helpers ----------
const ID_RE = /^[A-Za-z0-9_.~:@+-]{1,64}$/;
const STATUSES = ["pending", "ready", "delivered"];
const str = (v, max = 500) => String(v ?? "").slice(0, max);
const date = (v) => (/^\d{4}-\d{2}-\d{2}$/.test(String(v || "")) ? String(v) : "");
function cleanOrder(id, o) {
  return {
    id,
    name: str(o.name, 120), mobile: str(o.mobile, 30), book: str(o.book, 30), invoice: str(o.invoice, 40),
    qty: Math.min(99, Math.max(1, parseInt(o.qty, 10) || 1)),
    status: STATUSES.includes(o.status) ? o.status : "pending",
    due: date(o.due), invDate: date(o.invDate), readyDate: date(o.readyDate), cleared: date(o.cleared),
    notes: str(o.notes, 1000),
    photo: Number(state.orders[id]?.photo) || 0,
    created: Number(o.created) || Date.now(), updated: Number(o.updated) || Date.now(),
  };
}
function send(res, code, body, headers = {}) {
  const isJson = typeof body !== "string" && !Buffer.isBuffer(body);
  res.writeHead(code, {
    "Content-Type": isJson ? "application/json; charset=utf-8" : "text/plain; charset=utf-8",
    "Cache-Control": "no-store",
    "X-Content-Type-Options": "nosniff",
    ...headers,
  });
  res.end(isJson ? JSON.stringify(body) : body);
}
function readBody(req, limit) {
  return new Promise((resolve, reject) => {
    let size = 0; const chunks = [];
    req.on("data", (c) => {
      size += c.length;
      if (size > limit) { reject(Object.assign(new Error("too large"), { status: 413 })); req.destroy(); return; }
      chunks.push(c);
    });
    req.on("end", () => {
      try { resolve(chunks.length ? JSON.parse(Buffer.concat(chunks).toString("utf8")) : {}); }
      catch { reject(Object.assign(new Error("bad json"), { status: 400 })); }
    });
    req.on("error", reject);
  });
}

// ---------- invoice scan ----------
const SCAN_PROMPT =
  "The image is a photo of a tailor shop invoice or receipt (it may be in Arabic, English or Urdu, handwritten or printed). " +
  "Read it and return ONLY a JSON object with these keys: " +
  '{"invoice": the invoice/receipt number as a string of digits (look for labels like Invoice No, رقم الفاتورة, فاتورة رقم, No., انوائس نمبر), ' +
  '"date": the invoice date as YYYY-MM-DD (convert Hijri to Gregorian only if you are sure, otherwise empty), ' +
  '"name": the customer name if written, "mobile": the customer mobile number if written, "book": a book/booklet number if written, ' +
  '"qty": the number of thobes ordered as a whole number if written (for example from a quantity column), else empty}. ' +
  "The shop's own phone numbers (056 391 8278, 056 071 6819) are never the customer's mobile. " +
  "Use Western digits 0-9. Use an empty string for anything you cannot read clearly. Do not guess.";
const IMAGE_TYPES = ["image/jpeg", "image/png", "image/webp", "image/gif"];

async function scanInvoice(image, mediaType) {
  const response = await anthropic.beta.messages.create({
    model: "claude-opus-5-5",
    max_tokens: 4000,
    output_config: { effort: "low" },
    betas: ["server-side-fallback-2026-07-01"],
    fallbacks: "default",
    messages: [{
      role: "user",
      content: [
        { type: "image", source: { type: "base64", media_type: mediaType, data: image } },
        { type: "text", text: SCAN_PROMPT },
      ],
    }],
  });
  if (response.stop_reason === "refusal") return {};
  const text = response.content.filter((b) => b.type === "text").map((b) => b.text).join("");
  const m = text.match(/\{[\s\S]*\}/);
  if (!m) return {};
  try {
    const r = JSON.parse(m[0]);
    return { invoice: str(r.invoice, 40), date: str(r.date, 10), name: str(r.name, 120), mobile: str(r.mobile, 30), book: str(r.book, 30), qty: str(r.qty, 3) };
  } catch { return {}; }
}

// ---------- server ----------
const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, "http://x");
  const p = url.pathname;
  try {
    if (req.method === "GET" && (p === "/" || p === "/index.html")) {
      if (req.headers["if-none-match"] === PAGE_ETAG) { res.writeHead(304, { ETag: PAGE_ETAG }); return res.end(); }
      const gz = /\bgzip\b/.test(req.headers["accept-encoding"] || "");
      return send(res, 200, gz ? PAGE_GZ : PAGE, {
        ...(gz ? { "Content-Encoding": "gzip" } : {}),
        "Vary": "Accept-Encoding",
        "ETag": PAGE_ETAG,
        "Cache-Control": "no-cache",
        "Content-Type": "text/html; charset=utf-8",
        "Content-Security-Policy": "default-src 'self'; script-src 'self' 'unsafe-inline' 'wasm-unsafe-eval' https://cdn.jsdelivr.net; worker-src 'self' blob: https://cdn.jsdelivr.net; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; font-src https://fonts.gstatic.com; img-src 'self' data: blob:; connect-src 'self' blob: data: https://cdn.jsdelivr.net https://tessdata.projectnaptha.com; frame-ancestors 'none'",
        "Referrer-Policy": "no-referrer",
      });
    }
    if (req.method === "GET" && STATIC[p]) {
      const [file, type] = STATIC[p];
      return send(res, 200, fs.readFileSync(path.join(here, file)), { "Content-Type": type, "Cache-Control": p === "/sw.js" ? "no-cache" : "public, max-age=86400" });
    }
    if (p === "/health") return send(res, 200, { ok: true });
    const ph = req.method === "GET" && p.match(/^\/photos\/([^/]+)$/);
    if (ph) {
      if (!roleOf(req)) return send(res, 401, "Sign in first");
      const id = decodeURIComponent(ph[1]);
      if (!ID_RE.test(id)) return send(res, 404, "Not found");
      for (const [type, ext] of Object.entries(PHOTO_EXT)) {
        const f = path.join(PHOTO_DIR, id + ext);
        if (fs.existsSync(f)) return send(res, 200, fs.readFileSync(f), { "Content-Type": type, "Cache-Control": "private, max-age=31536000" });
      }
      return send(res, 404, "Not found");
    }

    if (!p.startsWith("/api/")) return send(res, 404, "Not found");

    if (p === "/api/login" && req.method === "POST") {
      const ip = (req.headers["x-forwarded-for"] || req.socket.remoteAddress || "").split(",")[0].trim();
      if (tooMany(ip)) return send(res, 429, { error: "too_many_attempts" });
      const { password } = await readBody(req, 4096);
      const role = samePassword(password, PASSWORD) ? "owner" : samePassword(password, STAFF_PASSWORD) ? "staff" : null;
      if (!role) return send(res, 401, { error: "wrong_password" });
      attempts.delete(ip);
      return send(res, 200, { ok: true, role }, { "Set-Cookie": sessionCookie(role) });
    }
    // Owner locks the report again on a shared phone: stay signed in, as staff.
    if (p === "/api/lock" && req.method === "POST") {
      if (!roleOf(req)) return send(res, 401, { error: "login_required" });
      return send(res, 200, { ok: true, role: "staff" }, { "Set-Cookie": sessionCookie("staff") });
    }
    if (p === "/api/logout" && req.method === "POST") {
      return send(res, 200, { ok: true }, { "Set-Cookie": `${COOKIE}=; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=0` });
    }

    // Everything below needs a signed-in owner or staff member.
    const role = roleOf(req);
    if (!role) return send(res, 401, { error: "login_required" });

    // Same-origin check for writes.
    if (req.method !== "GET" && req.headers.origin && new URL(req.headers.origin).host !== req.headers.host) {
      return send(res, 403, { error: "bad_origin" });
    }

    if (p === "/api/state" && req.method === "GET") {
      return send(res, 200, { orders: Object.values(state.orders), config: state.config, scan: !!anthropic, role, report: role === "owner", version });
    }
    if (p === "/api/events" && req.method === "GET") {
      res.writeHead(200, { "Content-Type": "text/event-stream; charset=utf-8", "Cache-Control": "no-store", "Connection": "keep-alive", "X-Accel-Buffering": "no" });
      res.write(`retry: 3000\ndata: ${version}\n\n`);
      listeners.add(res);
      req.on("close", () => listeners.delete(res));
      return;
    }
    const om = p.match(/^\/api\/orders\/([^/]+)$/);
    if (om) {
      const id = decodeURIComponent(om[1]);
      if (!ID_RE.test(id)) return send(res, 400, { error: "bad_id" });
      if (req.method === "PUT") {
        state.orders[id] = cleanOrder(id, await readBody(req, 64 * 1024));
        await persist();
        return send(res, 200, state.orders[id]);
      }
      if (req.method === "DELETE") {
        delete state.orders[id];
        await persist();
        await removePhoto(id);
        return send(res, 200, { ok: true });
      }
    }
    const pm = p.match(/^\/api\/photos\/([^/]+)$/);
    if (pm && req.method === "PUT") {
      const id = decodeURIComponent(pm[1]);
      if (!ID_RE.test(id) || !state.orders[id]) return send(res, 404, { error: "no_such_order" });
      const b = await readBody(req, 12 * 1024 * 1024);
      const ext = PHOTO_EXT[b.type];
      if (!ext || typeof b.image !== "string" || !b.image) return send(res, 400, { error: "bad_image" });
      const buf = Buffer.from(b.image, "base64");
      if (!buf.length || buf.length > 8 * 1024 * 1024) return send(res, 400, { error: "bad_image" });
      await fsp.mkdir(PHOTO_DIR, { recursive: true });
      await removePhoto(id);
      await fsp.writeFile(path.join(PHOTO_DIR, id + ext), buf);
      state.orders[id] = { ...state.orders[id], photo: Date.now() };
      await persist();
      return send(res, 200, state.orders[id]);
    }
    if (p === "/api/config" && req.method === "PUT") {
      if (role !== "owner") return send(res, 403, { error: "owner_only" });
      const b = await readBody(req, 4096);
      state.config = { shop: str(b.shop, 120), code: String(b.code || "966").replace(/\D/g, "").slice(0, 4) || "966" };
      await persist();
      return send(res, 200, state.config);
    }
    if (p === "/api/scan" && req.method === "POST") {
      if (!anthropic) return send(res, 503, { error: "scan_not_configured" });
      const b = await readBody(req, 8 * 1024 * 1024);
      const type = IMAGE_TYPES.includes(b.type) ? b.type : null;
      if (!type || typeof b.image !== "string" || !b.image) return send(res, 400, { error: "bad_image" });
      try {
        return send(res, 200, await scanInvoice(b.image, type));
      } catch (e) {
        console.error("scan failed:", e.status || "", e.message);
        return send(res, 502, { error: "scan_failed" });
      }
    }
    return send(res, 404, { error: "not_found" });
  } catch (e) {
    const status = e.status && e.status < 500 ? e.status : 500;
    if (status === 500) console.error(e);
    return send(res, status, { error: status === 500 ? "server_error" : e.message });
  }
});

server.listen(PORT, () => console.log(`Salar Tailoring listening on :${PORT}`));
