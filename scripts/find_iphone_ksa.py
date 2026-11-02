#!/usr/bin/env python3
"""
Find an iPhone in a given color (default: iPhone Duo, Night Sky) that is
available to buy from trusted vendors in Saudi Arabia.

How it works
------------
1. Apple Store Saudi Arabia (apple.com/sa-en) - checked LIVE.
   The script reads the official buy page, finds every model/storage
   option in the requested color, and asks Apple's own delivery service
   whether each one can be bought and when it ships.

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
"""

from __future__ import annotations

import argparse
import json
import re
import sys
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


def apple_delivery(session: requests.Session, part: str) -> dict:
    url = f"{APPLE_BASE}/shop/delivery-message?parts.0={quote_plus(part)}&mt=regular"
    data = get(session, url).json()
    msg = data["body"]["content"]["deliveryMessage"].get(part, {}).get("regular", {})
    ships = ", ".join(o.get("displayName", "") for o in msg.get("deliveryOptionMessages", []))
    return {
        "buyable": bool(msg.get("isBuyable")),
        "ships": ships,
        "reason": msg.get("buyability", {}).get("reason", ""),
    }


def check_apple(session: requests.Session, model: str, color: str) -> list[Offer]:
    page = f"{APPLE_BASE}/shop/buy-iphone/{model}"
    try:
        products = apple_products(session, model)
    except Exception as exc:  # network / layout change
        return [Offer("Apple Store KSA", model, "error", url=page, notes=[str(exc)])]

    wanted = [p for p in products if color.lower() in p["name"].lower()]
    if not wanted:
        colors = sorted({re.sub(r"^.*?\d+\s?[GT]B\s+", "", p["name"]) for p in products})
        note = f"No '{color}' found. Colors on this page: {', '.join(colors) or 'none parsed'}"
        return [Offer("Apple Store KSA", model, "unavailable", url=page, notes=[note])]

    offers = []
    for p in sorted(wanted, key=lambda p: p["price"]):
        try:
            d = apple_delivery(session, p["partNumber"])
            status = "available" if d["buyable"] else "unavailable"
            notes = [] if d["buyable"] else [d["reason"]]
            offers.append(Offer("Apple Store KSA", p["name"], status, p["price"],
                                d["ships"], page, notes))
        except Exception as exc:
            offers.append(Offer("Apple Store KSA", p["name"], "error", p["price"],
                                url=page, notes=[str(exc)]))
    return offers


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


def print_report(offers: list[Offer], model: str, color: str) -> None:
    print(f"\nSearching Saudi Arabia for: {model.replace('-', ' ').title().replace('Iphone', 'iPhone')} in {color}\n")
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
        print(f"Cheapest confirmed option: {best.name} at {best.vendor} "
              f"for {best.price_sar:,.0f} SAR ({best.ships or 'see site'}).")
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
    args = ap.parse_args()

    session = requests.Session()

    if args.list_models:
        for slug in apple_models(session):
            print(slug)
        return 0

    offers = check_apple(session, args.model, args.color)
    if not args.apple_only:
        query = f"{args.model.replace('-', ' ').replace('iphone', 'iPhone')} {args.color}"
        for vendor, template in TRUSTED_RESELLERS.items():
            offers.append(check_reseller(session, vendor, template, query))

    if args.json:
        print(json.dumps([asdict(o) for o in offers], indent=2, ensure_ascii=False))
    else:
        print_report(offers, args.model, args.color)
    return 0 if any(o.status == "available" for o in offers) else 1


if __name__ == "__main__":
    sys.exit(main())
