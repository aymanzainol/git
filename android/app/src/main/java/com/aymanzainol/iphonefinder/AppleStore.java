package com.aymanzainol.iphonefinder;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.TreeSet;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Talks to the Apple Store Saudi Arabia (apple.com/sa-en).
 * Same logic as scripts/find_iphone_ksa.py. All methods block, so call them off the UI thread.
 */
final class AppleStore {

    static final String BASE = "https://www.apple.com/sa-en";
    private static final String UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
            + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36";
    private static final int BATCH = 10;

    private static final Pattern MODEL_LINK =
            Pattern.compile("/sa-en/shop/buy-iphone/(iphone-[a-z0-9-]+)");
    private static final Pattern PRODUCT = Pattern.compile(
            "\\{\"sku\":\"[^\"]*\",\"partNumber\":\"([^\"]+)\","
                    + "\"price\":\\{\"fullPrice\":([\\d.]+)\\},"
                    + "\"category\":\"iphone\",\"name\":\"([^\"]+)\"\\}");
    private static final Pattern CAPACITY = Pattern.compile("^.*?\\d+\\s?[GT]B\\s+");

    static final class Product {
        final String part;
        final String name;
        final double price;

        Product(String part, String name, double price) {
            this.part = part;
            this.name = name;
            this.price = price;
        }

        String color() {
            return CAPACITY.matcher(name).replaceFirst("");
        }
    }

    static final class Delivery {
        boolean found;
        boolean buyable;
        String reason = "";
        String ships = "";
        final List<String> options = new ArrayList<>();
    }

    private AppleStore() {}

    static String modelPage(String slug) {
        return BASE + "/shop/buy-iphone/" + slug;
    }

    static String prettyModel(String slug) {
        StringBuilder sb = new StringBuilder();
        for (String w : slug.split("-")) {
            if (w.isEmpty()) continue;
            if (sb.length() > 0) sb.append(' ');
            if (w.equals("iphone")) sb.append("iPhone");
            else sb.append(Character.toUpperCase(w.charAt(0))).append(w.substring(1));
        }
        return sb.toString();
    }

    /** iPhone model slugs on the Saudi store, e.g. "iphone-duo". */
    static List<String> models() throws IOException {
        TreeSet<String> slugs = new TreeSet<>();
        Matcher m = MODEL_LINK.matcher(fetch(BASE + "/shop/buy-iphone"));
        while (m.find()) slugs.add(m.group(1));
        return new ArrayList<>(slugs);
    }

    /** Every model/storage/color option on a model's buy page, cheapest first. */
    static List<Product> products(String slug) throws IOException {
        Map<String, Product> byPart = new LinkedHashMap<>();
        Matcher m = PRODUCT.matcher(fetch(modelPage(slug)));
        while (m.find()) {
            byPart.put(m.group(1),
                    new Product(m.group(1), m.group(3), Double.parseDouble(m.group(2))));
        }
        List<Product> list = new ArrayList<>(byPart.values());
        list.sort((a, b) -> Double.compare(a.price, b.price));
        return list;
    }

    static List<String> colors(List<Product> products) {
        LinkedHashSet<String> colors = new LinkedHashSet<>();
        for (Product p : products) colors.add(p.color());
        return new ArrayList<>(colors);
    }

    /**
     * Apple's delivery API (/shop/delivery-message): buyability, ship date and
     * delivery options for each part number. Batched, with retries.
     */
    static Map<String, Delivery> delivery(List<String> parts) throws IOException {
        Map<String, Delivery> out = new LinkedHashMap<>();
        for (int start = 0; start < parts.size(); start += BATCH) {
            List<String> chunk = parts.subList(start, Math.min(parts.size(), start + BATCH));
            StringBuilder url = new StringBuilder(BASE + "/shop/delivery-message?mt=regular");
            for (int i = 0; i < chunk.size(); i++) {
                url.append("&parts.").append(i).append('=')
                        .append(URLEncoder.encode(chunk.get(i), "UTF-8"));
            }

            JSONObject content = null;
            IOException last = null;
            for (int attempt = 0; attempt < 3 && content == null; attempt++) {
                try {
                    content = new JSONObject(fetch(url.toString()))
                            .getJSONObject("body").getJSONObject("content")
                            .getJSONObject("deliveryMessage");
                } catch (Exception e) {
                    last = e instanceof IOException ? (IOException) e : new IOException(e);
                    sleep(1000L << attempt);
                }
            }
            if (content == null) throw new IOException("Apple delivery API failed: " + last);

            for (String part : chunk) {
                Delivery d = new Delivery();
                JSONObject entry = content.optJSONObject(part);
                JSONObject msg = entry == null ? null : entry.optJSONObject("regular");
                if (msg != null) {
                    d.found = true;
                    JSONObject buy = msg.optJSONObject("buyability");
                    d.buyable = buy != null ? buy.optBoolean("isBuyable") : msg.optBoolean("isBuyable");
                    d.reason = buy != null ? buy.optString("reason") : "";
                    d.ships = joinField(msg.optJSONArray("deliveryOptionMessages"));
                    JSONArray opts = msg.optJSONArray("deliveryOptions");
                    if (opts != null) {
                        for (int i = 0; i < opts.length(); i++) {
                            JSONObject o = opts.optJSONObject(i);
                            if (o == null) continue;
                            StringBuilder sb = new StringBuilder();
                            for (String k : new String[]{"displayName", "date", "shippingCost"}) {
                                String v = o.optString(k);
                                if (v.isEmpty() || v.equals("null")) continue;
                                if (sb.length() > 0) sb.append(" · ");
                                sb.append(v);
                            }
                            d.options.add(sb.toString());
                        }
                    }
                }
                out.put(part, d);
            }
        }
        return out;
    }

    private static String joinField(JSONArray arr) {
        if (arr == null) return "";
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < arr.length(); i++) {
            JSONObject o = arr.optJSONObject(i);
            if (o == null) continue;
            if (sb.length() > 0) sb.append(", ");
            sb.append(o.optString("displayName"));
        }
        return sb.toString();
    }

    private static String fetch(String url) throws IOException {
        HttpURLConnection c = (HttpURLConnection) new URL(url).openConnection();
        c.setConnectTimeout(20000);
        c.setReadTimeout(20000);
        c.setRequestProperty("User-Agent", UA);
        c.setRequestProperty("Accept-Language", "en-SA,en;q=0.9");
        try {
            int code = c.getResponseCode();
            if (code != 200) throw new IOException("HTTP " + code + " from " + url);
            try (InputStream in = c.getInputStream()) {
                ByteArrayOutputStream buf = new ByteArrayOutputStream();
                byte[] b = new byte[16384];
                int n;
                while ((n = in.read(b)) > 0) buf.write(b, 0, n);
                return buf.toString(StandardCharsets.UTF_8.name());
            }
        } finally {
            c.disconnect();
        }
    }

    private static void sleep(long ms) {
        try {
            Thread.sleep(ms);
        } catch (InterruptedException ignored) {
            Thread.currentThread().interrupt();
        }
    }
}
