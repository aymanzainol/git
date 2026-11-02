package com.aymanzainol.iphonefinder;

import android.app.Activity;
import android.content.Intent;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.net.Uri;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.AdapterView;
import android.widget.ArrayAdapter;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.ScrollView;
import android.widget.Spinner;
import android.widget.TextView;

import java.net.URLEncoder;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public class MainActivity extends Activity {

    private static final String DEFAULT_MODEL = "iphone-duo";
    private static final String DEFAULT_COLOR = "Night Sky";

    /** Apple Authorised Resellers and carriers in Saudi Arabia. {q} = search text. */
    private static final String[][] RESELLERS = {
            {"Jarir Bookstore", "https://www.jarir.com/sa-en/catalogsearch/result?q={q}"},
            {"eXtra", "https://www.extra.com/en-sa/search/?q={q}"},
            {"STC", "https://www.stc.com.sa/en/personal/devices.html?search={q}"},
            {"Mobily", "https://www.mobily.com.sa/?search={q}"},
            {"Zain KSA", "https://sa.zain.com/en/devices?search={q}"},
            {"Amazon.sa (sold by Amazon)", "https://www.amazon.sa/s?k={q}&emi=A2XPWB6MYN7ZDK"},
            {"noon (Apple official store)", "https://www.noon.com/saudi-en/search/?q={q}"},
    };

    private static final int NAVY = Color.parseColor("#1C2A4A");
    private static final int BLUE = Color.parseColor("#2F5BD3");
    private static final int GREEN = Color.parseColor("#1E8E3E");
    private static final int RED = Color.parseColor("#C5221F");
    private static final int MUTED = Color.parseColor("#5F6368");

    private final ExecutorService io = Executors.newSingleThreadExecutor();
    private final Handler ui = new Handler(Looper.getMainLooper());

    private Spinner modelSpinner;
    private Spinner colorSpinner;
    private Button checkButton;
    private ProgressBar progress;
    private TextView status;
    private LinearLayout results;
    private LinearLayout resellers;

    private List<String> models = new ArrayList<>(Arrays.asList(DEFAULT_MODEL));
    private List<AppleStore.Product> products = new ArrayList<>();
    private String currentSlug;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(buildUi());
        loadModels();
    }

    @Override
    protected void onDestroy() {
        io.shutdownNow();
        super.onDestroy();
    }

    // ------------------------------------------------------------------ UI --

    private View buildUi() {
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setBackgroundColor(Color.parseColor("#F4F5F8"));

        // Header (also fills the status-bar area on edge-to-edge Android 15+)
        LinearLayout header = new LinearLayout(this);
        header.setOrientation(LinearLayout.VERTICAL);
        header.setBackgroundColor(NAVY);
        int pad = dp(20);
        header.setPadding(pad, pad, pad, dp(16));
        TextView title = text("iPhone Finder KSA", 24, Color.WHITE, true);
        TextView sub = text("Live stock from Apple Store Saudi Arabia + trusted resellers",
                14, Color.parseColor("#C9D3EA"), false);
        header.addView(title);
        header.addView(sub);
        root.addView(header);

        root.setOnApplyWindowInsetsListener((v, insets) -> {
            header.setPadding(pad, pad + insets.getSystemWindowInsetTop(), pad, dp(16));
            v.setPadding(insets.getSystemWindowInsetLeft(), 0,
                    insets.getSystemWindowInsetRight(), insets.getSystemWindowInsetBottom());
            return insets.consumeSystemWindowInsets();
        });

        ScrollView scroll = new ScrollView(this);
        LinearLayout body = new LinearLayout(this);
        body.setOrientation(LinearLayout.VERTICAL);
        body.setPadding(dp(16), dp(16), dp(16), dp(24));
        scroll.addView(body);
        root.addView(scroll, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f));

        // Search card
        LinearLayout search = card();
        search.addView(label("Model"));
        modelSpinner = new Spinner(this);
        search.addView(modelSpinner);
        search.addView(label("Color"));
        colorSpinner = new Spinner(this);
        search.addView(colorSpinner);

        checkButton = new Button(this);
        checkButton.setText("Check availability");
        checkButton.setAllCaps(false);
        checkButton.setTextColor(Color.WHITE);
        checkButton.setTextSize(TypedValue.COMPLEX_UNIT_SP, 16);
        checkButton.setBackground(rounded(BLUE, 12));
        LinearLayout.LayoutParams blp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, dp(52));
        blp.topMargin = dp(16);
        search.addView(checkButton, blp);
        checkButton.setOnClickListener(v -> checkAvailability());

        LinearLayout statusRow = new LinearLayout(this);
        statusRow.setGravity(Gravity.CENTER_VERTICAL);
        statusRow.setPadding(0, dp(12), 0, 0);
        progress = new ProgressBar(this);
        progress.setVisibility(View.GONE);
        statusRow.addView(progress, new LinearLayout.LayoutParams(dp(24), dp(24)));
        status = text("", 14, MUTED, false);
        status.setPadding(dp(8), 0, 0, 0);
        statusRow.addView(status);
        search.addView(statusRow);
        body.addView(search);

        body.addView(section("Apple Store Saudi Arabia"));
        results = new LinearLayout(this);
        results.setOrientation(LinearLayout.VERTICAL);
        body.addView(results);

        body.addView(section("Trusted resellers (tap to open)"));
        resellers = new LinearLayout(this);
        resellers.setOrientation(LinearLayout.VERTICAL);
        body.addView(resellers);

        TextView tip = text("Buy only from Apple or Apple Authorised Resellers to get the "
                + "official Saudi warranty. Avoid third-party marketplace sellers.", 13, MUTED, false);
        tip.setPadding(dp(4), dp(16), dp(4), 0);
        body.addView(tip);

        modelSpinner.setOnItemSelectedListener(new AdapterView.OnItemSelectedListener() {
            @Override
            public void onItemSelected(AdapterView<?> parent, View view, int pos, long id) {
                String slug = models.get(pos);
                if (!slug.equals(currentSlug)) loadColors(slug);
            }

            @Override
            public void onNothingSelected(AdapterView<?> parent) {}
        });
        colorSpinner.setOnItemSelectedListener(new AdapterView.OnItemSelectedListener() {
            @Override
            public void onItemSelected(AdapterView<?> parent, View view, int pos, long id) {
                showResellers();
            }

            @Override
            public void onNothingSelected(AdapterView<?> parent) {}
        });
        return root;
    }

    // -------------------------------------------------------------- Actions --

    private void loadModels() {
        busy(true, "Loading models from Apple…");
        io.execute(() -> {
            try {
                List<String> found = AppleStore.models();
                ui.post(() -> {
                    if (!found.isEmpty()) models = found;
                    int idx = Math.max(0, models.indexOf(DEFAULT_MODEL));
                    loadColors(models.get(idx));
                    modelSpinner.setAdapter(adapter(prettyModels()));
                    modelSpinner.setSelection(idx, false);
                });
            } catch (Exception e) {
                ui.post(() -> {
                    modelSpinner.setAdapter(adapter(prettyModels()));
                    busy(false, "Couldn't reach Apple: " + e.getMessage()
                            + "\nCheck your internet connection and tap the button to retry.");
                });
            }
        });
    }

    private void loadColors(String slug) {
        currentSlug = slug;
        products = new ArrayList<>();
        busy(true, "Loading colors for " + AppleStore.prettyModel(slug) + "…");
        results.removeAllViews();
        io.execute(() -> {
            try {
                List<AppleStore.Product> found = AppleStore.products(slug);
                ui.post(() -> {
                    if (!slug.equals(currentSlug)) return;  // user picked another model meanwhile
                    products = found;
                    List<String> colors = AppleStore.colors(found);
                    colorSpinner.setAdapter(adapter(colors));
                    int idx = indexIgnoreCase(colors, DEFAULT_COLOR);
                    if (idx >= 0) colorSpinner.setSelection(idx, false);
                    showResellers();
                    if (found.isEmpty()) {
                        busy(false, "No products found on Apple's page for this model.");
                    } else {
                        // Check straight away so the answer is on screen without an extra tap.
                        checkAvailability();
                    }
                });
            } catch (Exception e) {
                ui.post(() -> {
                    if (slug.equals(currentSlug)) {
                        currentSlug = null;  // let the button retry
                        busy(false, "Couldn't load colors: " + e.getMessage());
                    }
                });
            }
        });
    }

    private void checkAvailability() {
        if (products.isEmpty()) {
            int pos = modelSpinner.getSelectedItemPosition();
            loadColors(models.get(Math.max(0, pos)));
            return;
        }
        String color = selectedColor();
        String slug = selectedModel();
        List<AppleStore.Product> wanted = new ArrayList<>();
        for (AppleStore.Product p : products) {
            if (p.color().equalsIgnoreCase(color)) wanted.add(p);
        }
        if (wanted.isEmpty()) return;

        busy(true, "Asking Apple's delivery service…");
        io.execute(() -> {
            try {
                List<String> parts = new ArrayList<>();
                for (AppleStore.Product p : wanted) parts.add(p.part);
                Map<String, AppleStore.Delivery> info = AppleStore.delivery(parts);
                ui.post(() -> showResults(slug, wanted, info));
            } catch (Exception e) {
                ui.post(() -> busy(false, "Apple check failed: " + e.getMessage()));
            }
        });
    }

    private void showResults(String slug, List<AppleStore.Product> wanted,
                             Map<String, AppleStore.Delivery> info) {
        results.removeAllViews();
        int available = 0;
        AppleStore.Product cheapest = null;
        for (AppleStore.Product p : wanted) {
            AppleStore.Delivery d = info.get(p.part);
            boolean ok = d != null && d.found && d.buyable;
            if (ok) {
                available++;
                if (cheapest == null) cheapest = p;
            }

            LinearLayout c = card();
            LinearLayout top = new LinearLayout(this);
            top.setGravity(Gravity.CENTER_VERTICAL);
            TextView name = text((ok ? "✅  " : "❌  ") + p.name, 16, NAVY, true);
            top.addView(name, new LinearLayout.LayoutParams(0,
                    ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
            top.addView(text(String.format(Locale.US, "%,.0f SAR", p.price), 16, NAVY, true));
            c.addView(top);

            if (d == null || !d.found) {
                c.addView(detail("Apple's delivery service doesn't list this option", RED));
            } else {
                if (!d.ships.isEmpty()) c.addView(detail(d.ships, ok ? GREEN : RED));
                for (String o : d.options) c.addView(detail(o, MUTED));
                if (!d.buyable) {
                    c.addView(detail("Not buyable right now (" +
                            (d.reason.isEmpty() ? "unknown" : d.reason) + ")", RED));
                }
            }
            TextView buy = text(ok ? "Buy on apple.com/sa →" : "Open on apple.com/sa →",
                    14, BLUE, true);
            buy.setPadding(0, dp(8), 0, 0);
            c.addView(buy);
            String page = AppleStore.modelPage(slug);
            c.setOnClickListener(v -> open(page));
            results.addView(c);
        }

        String summary;
        if (cheapest != null) {
            summary = available + " of " + wanted.size() + " in stock. Cheapest: "
                    + cheapest.name + String.format(Locale.US, " (%,.0f SAR)", cheapest.price);
        } else {
            summary = "Not available from Apple right now. Try the resellers below.";
        }
        busy(false, summary);
    }

    private void showResellers() {
        resellers.removeAllViews();
        String query = AppleStore.prettyModel(selectedModel()) + " " + selectedColor();
        String q;
        try {
            q = URLEncoder.encode(query.trim(), "UTF-8");
        } catch (Exception e) {
            q = query.trim().replace(' ', '+');
        }
        for (String[] r : RESELLERS) {
            String url = r[1].replace("{q}", q);
            LinearLayout c = card();
            LinearLayout row = new LinearLayout(this);
            row.setGravity(Gravity.CENTER_VERTICAL);
            row.addView(text("🔗  " + r[0], 15, NAVY, true), new LinearLayout.LayoutParams(0,
                    ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
            row.addView(text("Search →", 14, BLUE, true));
            c.addView(row);
            c.setOnClickListener(v -> open(url));
            resellers.addView(c);
        }
    }

    // ------------------------------------------------------------- Helpers --

    private String selectedModel() {
        int pos = modelSpinner.getSelectedItemPosition();
        return models.get(pos < 0 || pos >= models.size() ? 0 : pos);
    }

    private String selectedColor() {
        Object item = colorSpinner.getSelectedItem();
        return item == null ? DEFAULT_COLOR : item.toString();
    }

    private List<String> prettyModels() {
        List<String> names = new ArrayList<>();
        for (String m : models) names.add(AppleStore.prettyModel(m));
        return names;
    }

    private static int indexIgnoreCase(List<String> list, String value) {
        for (int i = 0; i < list.size(); i++) {
            if (list.get(i).equalsIgnoreCase(value)) return i;
        }
        return -1;
    }

    private void busy(boolean on, String message) {
        progress.setVisibility(on ? View.VISIBLE : View.GONE);
        checkButton.setEnabled(!on);
        checkButton.setAlpha(on ? 0.6f : 1f);
        status.setText(message);
    }

    private void open(String url) {
        try {
            startActivity(new Intent(Intent.ACTION_VIEW, Uri.parse(url)));
        } catch (Exception e) {
            status.setText("No browser found to open " + url);
        }
    }

    private ArrayAdapter<String> adapter(List<String> items) {
        ArrayAdapter<String> a = new ArrayAdapter<>(this,
                android.R.layout.simple_spinner_item, items);
        a.setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item);
        return a;
    }

    private LinearLayout card() {
        LinearLayout c = new LinearLayout(this);
        c.setOrientation(LinearLayout.VERTICAL);
        c.setBackground(rounded(Color.WHITE, 14));
        c.setPadding(dp(16), dp(14), dp(16), dp(14));
        c.setElevation(dp(1));
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        lp.bottomMargin = dp(10);
        c.setLayoutParams(lp);
        return c;
    }

    private TextView section(String s) {
        TextView t = text(s, 13, MUTED, true);
        t.setAllCaps(true);
        t.setPadding(dp(4), dp(18), 0, dp(8));
        return t;
    }

    private TextView label(String s) {
        TextView t = text(s, 13, MUTED, true);
        t.setPadding(0, dp(8), 0, dp(2));
        return t;
    }

    private TextView detail(String s, int color) {
        TextView t = text(s, 14, color, false);
        t.setPadding(0, dp(4), 0, 0);
        return t;
    }

    private TextView text(String s, int sp, int color, boolean bold) {
        TextView t = new TextView(this);
        t.setText(s);
        t.setTextSize(TypedValue.COMPLEX_UNIT_SP, sp);
        t.setTextColor(color);
        if (bold) t.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        return t;
    }

    private GradientDrawable rounded(int color, int radiusDp) {
        GradientDrawable g = new GradientDrawable();
        g.setColor(color);
        g.setCornerRadius(dp(radiusDp));
        return g;
    }

    private int dp(int v) {
        return Math.round(v * getResources().getDisplayMetrics().density);
    }
}
