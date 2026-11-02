#!/usr/bin/env python3
"""
Find an iPhone in a given color (default: iPhone Duo, Night Sky) that is
available to buy from trusted vendors in Saudi Arabia.

How it works
------------
1. Apple Store Saudi Arabia (apple.com/sa-en) - checked LIVE.
   The script reads the official buy page, finds every model/storage
   option in the requested color, and asks Apple's delivery API
   (/shop/delivery-message, the same one the store page uses) whether each
   one can be bought, when it ships and which delivery options exist.
   All parts go in one batched request. Apple Saudi Arabia has no in-store
   pickup, so delivery is the only way to get it from Apple.

2. Authorised Saudi resellers (Jarir, eXtra, STC, Mobily, Zain, Amazon.sa,
   noon). Most of these sites load products with JavaScript or block bots,
   so the script does a normal page fetch. If the product name shows up,
   it reports "listed". Either way, it prints a direct search link so you
   can confirm the price and stock yourself.

Usage
-----
    pip install requests
    python3 find_iphone_ksa.py                       # iPhone Duo, Night Sky
    python3 find_iphone_ksa.py --model iphone-18-pro --color "Deep Blue"
    python3 find_iphone_ksa.py --list-models
    python3 find_iphone_ksa.py --json                # output for other tools
    python3 find_iphone_ksa.py --part MK294AH/A      # check exact part numbers
    python3 find_iphone_ksa.py --watch 15            # re-check every 15 minutes
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import time
from dataclasses import dataclass, field, asdict
from urllib.parse import quote_plus

try:
    import requests
except ImportError:  # pragma: no cover
    sys.exit("This script needs 'requests'. Install it with: pip install requests")

APPLE_BASE = "https://www.apple.com/sa-en"
HEADERS = {
    "User-Agent": (
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
        "(KHTML, like Gecko) Chrome/130.0 Safari/537.36"
    ),
    "Accept-Language": "en-SA,en;q=0.9",
}
TIMEOUT = 20

# Official Apple Store plus Apple Authorised Resellers / major carriers in KSA.
TRUSTED_RESELLERS = {
    "Jarir Bookstore": "https://www.jarir.com/sa-en/catalogsearch/result?q={q}",
    "eXtra": "https://www.extra.com/en-sa/search/?q={q}",
    "STC": "https://www.stc.com.sa/en/personal/devices.html?search={q}",
    "Mobily": "https://www.mobily.com.sa/?search={q}",
    "Zain KSA": "https://sa.zain.com/en/devices?search={q}",
    "Amazon.sa (sold by Amazon)": "https://www.amazon.sa/s?k={q}&emi=A2XPWB6MYN7ZDK",
    "noon (Apple official store)": "https://www.noon.com/saudi-en/search/?q={q}",
}


@dataclass
class Offer:
    vendor: str
    name: str
    status: str            # "available", "unavailable", "listed", "check link", "error"
    price_sar: float | None = None
    ships: str = ""
    url: str = ""
    notes: list[str] = field(default_factory=list)


def get(session: requests.Session, url: str) -> requests.Response:
    return session.get(url, headers=HEADERS, timeout=TIMEOUT, allow_redirects=True)


# --------------------------------------------------------------------------- #
# Apple Store Saudi Arabia
# --------------------------------------------------------------------------- #
def apple_models(session: requests.Session) -> list[str]:
    html = get(session, f"{APPLE_BASE}/shop/buy-iphone").text
    slugs = set(re.findall(r'/sa-en/shop/buy-iphone/(iphone-[a-z0-9-]+)', html))
    return sorted(slugs)


def apple_products(session: requests.Session, model: str) -> list[dict]:
    """Return [{'partNumber', 'name', 'price'}] from the Apple buy page."""
    url = f"{APPLE_BASE}/shop/buy-iphone/{model}"
    resp = get(session, url)
    resp.raise_for_status()
    products = {}
    pattern = re.compile(
        r'\{"sku":"[^"]*","partNumber":"(?P<part>[^"]+)",'
        r'"price":\{"fullPrice":(?P<price>[\d.]+)\},'
        r'"category":"iphone","name":"(?P<name>[^"]+)"\}'
    )
    for m in pattern.finditer(resp.text):
        products[m["part"]] = {
            "partNumber": m["part"],
            "name": m["name"],
            "price": float(m["price"]),
        }
    return list(products.values())


DELIVERY_BATCH = 10  # part numbers per delivery-message request


def apple_delivery(session: requests.Session, parts: list[str],
                   retries: int = 3) -> dict[str, dict]:
    """Ask Apple's delivery-message API about several part numbers at once.

    This is the same API the "Ships ..." text on apple.com/sa-en uses.
    Returns {partNumber: {buyable, reason, ships, options, subheader}}.
    Parts Apple doesn't know about are missing from the result.
    (Apple Saudi Arabia has no in-store pickup, and the ship date is the same
    nationwide, so no location parameter is needed.)
    """
    results: dict[str, dict] = {}
    for start in range(0, len(parts), DELIVERY_BATCH):
        chunk = parts[start:start + DELIVERY_BATCH]
        query = "&".join(f"parts.{i}={quote_plus(p)}" for i, p in enumerate(chunk))
        url = f"{APPLE_BASE}/shop/delivery-message?mt=regular&{query}"

        last_exc: Exception | None = None
        for attempt in range(retries):
            try:
                resp = get(session, url)
                resp.raise_for_status()
                content = resp.json()["body"]["content"]["deliveryMessage"]
                break
            except Exception as exc:  # timeout, 5xx, rate limit, bad JSON
                last_exc = exc
                time.sleep(2 ** attempt)
        else:
            raise RuntimeError(f"Apple delivery API failed: {last_exc}")

        for part in chunk:
            msg = (content.get(part) or {}).get("regular")
            if not msg:
                continue
            buy = msg.get("buyability") or {}
            results[part] = {
                "buyable": bool(buy.get("isBuyable", msg.get("isBuyable"))),
                "reason": buy.get("reason", ""),
                "ships": ", ".join(o.get("displayName", "")
                                   for o in msg.get("deliveryOptionMessages", [])),
                "options": [
                    " · ".join(x for x in (o.get("displayName"), o.get("date"),
                                           o.get("shippingCost")) if x)
                    for o in msg.get("deliveryOptions", [])
                ],
                "subheader": msg.get("subHeader", "").removeprefix("For "),
            }
    return results


def apple_offer(info: dict | None, name: str, price: float | None, page: str) -> Offer:
    if info is None:
        return Offer("Apple Store KSA", name, "unavailable", price, url=page,
                     notes=["Apple's delivery API doesn't list this part"])
    status = "available" if info["buyable"] else "unavailable"
    notes = list(info["options"])
    if not info["buyable"]:
        notes.append(f"Not buyable right now (reason: {info['reason'] or 'unknown'})")
    return Offer("Apple Store KSA", name, status, price, info["ships"], page, notes)


def check_apple_parts(session: requests.Session, parts: list[str]) -> list[Offer]:
    page = f"{APPLE_BASE}/shop/buy-iphone"
    try:
        info = apple_delivery(session, parts)
    except Exception as exc:
        return [Offer("Apple Store KSA", ", ".join(parts), "error", url=page, notes=[str(exc)])]
    return [apple_offer(info.get(p), (info.get(p) or {}).get("subheader") or p, None, page)
            for p in parts]


def check_apple(session: requests.Session, model: str, color: str) -> list[Offer]:
    page = f"{APPLE_BASE}/shop/buy-iphone/{model}"
    try:
        products = apple_products(session, model)
    except Exception as exc:  # network / layout change
        return [Offer("Apple Store KSA", model, "error", url=page, notes=[str(exc)])]
    if not products:
        return [Offer("Apple Store KSA", model, "error", url=page,
                      notes=["No products found on the page. Check --list-models for valid names"])]

    wanted = [p for p in products if color.lower() in p["name"].lower()]
    if not wanted:
        colors = sorted({re.sub(r"^.*?\d+\s?[GT]B\s+", "", p["name"]) for p in products})
        note = f"No '{color}' found. Colors on this page: {', '.join(colors) or 'none parsed'}"
        return [Offer("Apple Store KSA", model, "unavailable", url=page, notes=[note])]

    wanted.sort(key=lambda p: p["price"])
    try:
        info = apple_delivery(session, [p["partNumber"] for p in wanted])
    except Exception as exc:
        return [Offer("Apple Store KSA", p["name"], "error", p["price"], url=page,
                      notes=[str(exc)]) for p in wanted]
    return [apple_offer(info.get(p["partNumber"]), p["name"], p["price"], page)
            for p in wanted]


# --------------------------------------------------------------------------- #
# Authorised resellers (best effort)
# --------------------------------------------------------------------------- #
def check_reseller(session: requests.Session, vendor: str, template: str,
                   query: str) -> Offer:
    url = template.format(q=quote_plus(query))
    try:
        resp = get(session, url)
    except Exception as exc:
        return Offer(vendor, query, "check link", url=url,
                     notes=[f"Could not reach site ({type(exc).__name__})"])
    if resp.status_code != 200:
        return Offer(vendor, query, "check link", url=url,
                     notes=[f"Site returned HTTP {resp.status_code}; open the link to check"])

    text = resp.text.lower()
    # Ignore the search box / page title echoing our own query back.
    text = text.replace(query.lower(), "")
    words = query.lower().split()
    model_words = " ".join(words[:-2]) if len(words) > 2 else query.lower()
    hits = len(re.findall(re.escape(model_words), text))
    if hits >= 3:
        return Offer(vendor, query, "listed", url=url,
                     notes=["Product name appears on the results page; confirm price/stock"])
    return Offer(vendor, query, "check link", url=url,
                 notes=["Results load with JavaScript; open the link to see stock"])


# --------------------------------------------------------------------------- #
# Output
# --------------------------------------------------------------------------- #
ICONS = {"available": "✅", "unavailable": "❌", "listed": "🟡",
         "check link": "🔗", "error": "⚠️"}


def print_report(offers: list[Offer], target: str) -> None:
    print(f"\nSearching Saudi Arabia for: {target}\n")
    current = None
    for o in offers:
        if o.vendor != current:
            current = o.vendor
            print(f"── {o.vendor} " + "─" * max(0, 50 - len(o.vendor)))
        price = f"{o.price_sar:,.0f} SAR" if o.price_sar else ""
        line = f"  {ICONS.get(o.status, '?')} {o.name:<32} {price:>12}  {o.ships}"
        print(line.rstrip())
        for n in o.notes:
            if n:
                print(f"       {n}")
        if o.url and (o.status != "available" or o is offers[0]):
            print(f"       {o.url}")
    available = [o for o in offers if o.status == "available"]
    print()
    if available:
        best = min(available, key=lambda o: o.price_sar or 1e12)
        price = f" for {best.price_sar:,.0f} SAR" if best.price_sar else ""
        print(f"Cheapest confirmed option: {best.name} at {best.vendor}"
              f"{price} ({best.ships or 'see site'}).")
        print(f"Buy here: {best.url}")
    else:
        print("No confirmed stock right now. Try the 🔗 links above or run again later.")
    print("\nTip: only buy from the vendors above (Apple or Apple Authorised Resellers)\n"
          "to get the official Saudi warranty. Avoid third-party marketplace sellers.")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--model", default="iphone-duo",
                    help="Apple URL slug, e.g. iphone-duo, iphone-18-pro, iphone-air")
    ap.add_argument("--color", default="Night Sky")
    ap.add_argument("--apple-only", action="store_true", help="Skip resellers")
    ap.add_argument("--list-models", action="store_true",
                    help="List iPhone models on Apple's Saudi store and exit")
    ap.add_argument("--json", action="store_true", help="Print JSON instead of a table")
    ap.add_argument("--part", action="append", metavar="PART",
                    help="Check Apple part number(s) directly, e.g. MK294AH/A (repeatable)")
    ap.add_argument("--watch", type=float, metavar="MINUTES",
                    help="Keep checking Apple every N minutes until it's available")
    args = ap.parse_args()

    session = requests.Session()

    if args.list_models:
        for slug in apple_models(session):
            print(slug)
        return 0

    def apple_check() -> list[Offer]:
        if args.part:
            return check_apple_parts(session, [p.upper() for p in args.part])
        return check_apple(session, args.model, args.color)

    offers = apple_check()
    while args.watch and not any(o.status == "available" for o in offers):
        stamp = time.strftime("%H:%M")
        print(f"[{stamp}] Not available from Apple yet; checking again in {args.watch:g} min",
              file=sys.stderr)
        time.sleep(args.watch * 60)
        offers = apple_check()
    if args.watch:
        print("\a", end="", file=sys.stderr)  # terminal bell: it's in stock

    if not args.apple_only and not args.part:
        query = f"{args.model.replace('-', ' ').replace('iphone', 'iPhone')} {args.color}"
        for vendor, template in TRUSTED_RESELLERS.items():
            offers.append(check_reseller(session, vendor, template, query))

    if args.json:
        print(json.dumps([asdict(o) for o in offers], indent=2, ensure_ascii=False))
    else:
        if args.part:
            target = "Apple parts " + ", ".join(p.upper() for p in args.part)
        else:
            model = args.model.replace("-", " ").title().replace("Iphone", "iPhone")
            target = f"{model} in {args.color}"
        print_report(offers, target)
    return 0 if any(o.status == "available" for o in offers) else 1


if __name__ == "__main__":
    sys.exit(main())
