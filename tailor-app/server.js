// Salar Tailoring – small server for Railway.
// Serves the app page, keeps orders in a JSON file on a volume, protects them with a
// shop password, and reads invoice photos with the Claude API when ANTHROPIC_API_KEY is set.
//
// Environment:
//   APP_PASSWORD       required – the password staff type to open the app
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
import Anthropic from "@anthropic-ai/sdk";

const here = path.dirname(fileURLToPath(import.meta.url));
const PORT = Number(process.env.PORT) || 3000;
const DATA_DIR = process.env.DATA_DIR || "/data";
const DATA_FILE = path.join(DATA_DIR, "orders.json");
const PASSWORD = process.env.APP_PASSWORD || "";
const SECRET = process.env.SESSION_SECRET || crypto.createHash("sha256").update("salar:" + PASSWORD).digest("hex");
const COOKIE = "salar_session";
const SESSION_DAYS = 90;
const anthropic = process.env.ANTHROPIC_API_KEY ? new Anthropic() : null;

if (!PASSWORD) console.warn("APP_PASSWORD is not set – the app will refuse all logins until it is.");

// ---------- page ----------
const SKELETON_HEAD = `<!doctype html><html lang="ar" dir="rtl"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="theme-color" content="#1f2d58"><meta name="mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-capable" content="yes"><meta name="apple-mobile-web-app-title" content="Salar">
<link rel="manifest" href="manifest.webmanifest"><link rel="icon" href="icon-192.png"><link rel="apple-touch-icon" href="icon-192.png">
<style>:root{padding-top:env(safe-area-inset-top,0px);padding-bottom:env(safe-area-inset-bottom,0px)}body{margin:0;font-size:14px}img{max-width:100%}[hidden]{display:none!important}</style>
</head><body>`;
function pageHtml() {
  return SKELETON_HEAD + fs.readFileSync(path.join(here, "online.html"), "utf8") + "</body></html>";
}
const STATIC = {
  "/manifest.webmanifest": ["manifest.webmanifest", "application/manifest+json"],
  "/icon-192.png": ["brand/icon-192.png", "image/png"],
  "/icon-512.png": ["brand/icon-512.png", "image/png"],
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
let writing = Promise.resolve();
function persist() {
  writing = writing.then(async () => {
    await fsp.mkdir(DATA_DIR, { recursive: true });
    const tmp = DATA_FILE + ".tmp";
    await fsp.writeFile(tmp, JSON.stringify(state));
    await fsp.rename(tmp, DATA_FILE);
  });
  return writing;
}

// ---------- auth ----------
const sign = (v) => crypto.createHmac("sha256", SECRET).update(v).digest("base64url");
function makeToken() {
  const exp = String(Date.now() + SESSION_DAYS * 864e5);
  return exp + "." + sign(exp);
}
function validToken(tok) {
  if (!tok || !PASSWORD) return false;
  const [exp, sig] = tok.split(".");
  if (!exp || !sig || Number(exp) < Date.now()) return false;
  const a = Buffer.from(sig), b = Buffer.from(sign(exp));
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}
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
    status: STATUSES.includes(o.status) ? o.status : "pending",
    due: date(o.due), invDate: date(o.invDate), readyDate: date(o.readyDate), cleared: date(o.cleared),
    notes: str(o.notes, 1000),
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
  '"name": the customer name if written, "mobile": the customer mobile number if written, "book": a book/booklet number if written}. ' +
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
    return { invoice: str(r.invoice, 40), date: str(r.date, 10), name: str(r.name, 120), mobile: str(r.mobile, 30), book: str(r.book, 30) };
  } catch { return {}; }
}

// ---------- server ----------
const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, "http://x");
  const p = url.pathname;
  try {
    if (req.method === "GET" && (p === "/" || p === "/index.html")) {
      return send(res, 200, pageHtml(), {
        "Content-Type": "text/html; charset=utf-8",
        "Content-Security-Policy": "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; font-src https://fonts.gstatic.com; img-src 'self' data: blob:; connect-src 'self'; frame-ancestors 'none'",
        "Referrer-Policy": "no-referrer",
      });
    }
    if (req.method === "GET" && STATIC[p]) {
      const [file, type] = STATIC[p];
      return send(res, 200, fs.readFileSync(path.join(here, file)), { "Content-Type": type, "Cache-Control": "public, max-age=86400" });
    }
    if (p === "/health") return send(res, 200, { ok: true });

    if (!p.startsWith("/api/")) return send(res, 404, "Not found");

    if (p === "/api/login" && req.method === "POST") {
      const ip = (req.headers["x-forwarded-for"] || req.socket.remoteAddress || "").split(",")[0].trim();
      if (tooMany(ip)) return send(res, 429, { error: "too_many_attempts" });
      const { password } = await readBody(req, 4096);
      const a = crypto.createHash("sha256").update(String(password || "")).digest();
      const b = crypto.createHash("sha256").update(PASSWORD).digest();
      if (!PASSWORD || !crypto.timingSafeEqual(a, b)) return send(res, 401, { error: "wrong_password" });
      attempts.delete(ip);
      return send(res, 200, { ok: true }, {
        "Set-Cookie": `${COOKIE}=${makeToken()}; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=${SESSION_DAYS * 86400}`,
      });
    }
    if (p === "/api/logout" && req.method === "POST") {
      return send(res, 200, { ok: true }, { "Set-Cookie": `${COOKIE}=; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=0` });
    }

    if (!validToken(cookieOf(req, COOKIE))) return send(res, 401, { error: "login_required" });
    // Same-origin check for writes (cookie is SameSite=Strict as well).
    if (req.method !== "GET" && req.headers.origin && new URL(req.headers.origin).host !== req.headers.host) {
      return send(res, 403, { error: "bad_origin" });
    }

    if (p === "/api/state" && req.method === "GET") {
      return send(res, 200, { orders: Object.values(state.orders), config: state.config, scan: !!anthropic });
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
        return send(res, 200, { ok: true });
      }
    }
    if (p === "/api/config" && req.method === "PUT") {
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
