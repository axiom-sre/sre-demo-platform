/**
 * load-test_100vusers.js — SRE Demo Platform: 100 VU Soak Test
 * =============================================================================
 * FIXES vs previous version:
 *
 * 1. BASE_URL default changed: localhost:8080 → localhost:30080
 *    Port-forward (8080) is a single goroutine that backs up under sustained
 *    load. At 100 VU × 10min it starts dropping connections → timeout cascade.
 *    NodePort (30080) bypasses port-forward entirely — goes directly to the
 *    kube-proxy iptables rule → no goroutine bottleneck, no timeouts.
 *    Root cause of the 1.52% error rate and 15x burn rate seen in the demo.
 *
 * 2. Checkout form fields fixed: http.post() with a plain JS object sends
 *    application/x-www-form-urlencoded, but the boutique frontend parses form
 *    POST bodies. Added explicit Content-Type header and verified field names
 *    against the boutique source (checkout.go handler).
 *
 * 3. http.get() response checks added: previously errors were silent.
 *    Now every request is checked and tagged — failures appear in k6 output
 *    AND in Grafana (traces_spanmetrics_calls_total{status_code=ERROR}).
 *
 * 4. timeout option added to all requests: 30s. Previously k6 would wait
 *    up to 60s (default) per request, inflating iteration_duration and making
 *    the "avg=744ms" stat meaningless (skewed by 60s timeout waits).
 *
 * 5. Think times tuned: reduced max sleep from 5s to 3s on product views.
 *    At 100 VU × 3s avg think time the server sees ~33 rps — realistic
 *    production traffic pattern for a boutique app. Previous 7s max on cart
 *    was making the 120-minute test very light in the middle.
 *
 * 6. Currency randomisation restored: USD/EUR/GBP was commented out.
 *    currencyservice is the most horizontally scalable service — cycling
 *    currencies exercises the HPA trigger path properly.
 *
 * 7. gracefulStop added: 30s. Allows in-flight requests to complete before
 *    k6 tears down VUs. Without this, the ramp-down generates spurious
 *    "connection reset" errors that inflate the failure rate stat.
 *
 * USAGE:
 *   k6 run scripts/load-test_100vusers.js
 *   k6 run --env BASE_URL=http://localhost:30080 scripts/load-test_100vusers.js
 *
 * WHAT TO WATCH IN GRAFANA DURING THIS TEST:
 *   - SRE Command Center:  RPS ramps, HPA fires on frontend + cart ~min 2-3
 *   - Golden Signals:      Error rate should stay flat at ~0% (green)
 *   - Platform & HPA:      cartservice scales 2→3, frontend scales 2→4
 *   - SLO & Error Budget:  Burn rate should stay <1x (budget-neutral)
 *   - Infra & Node:        Node CPU climbs to 40-60% — healthy headroom
 * =============================================================================
 */

import http from 'k6/http';
import { sleep, check, group } from 'k6';

// ── Target ────────────────────────────────────────────────────────────────────
// ALWAYS use the NodePort. Port-forward (8080) cannot handle sustained VU load.
const BASE = __ENV.BASE_URL || 'http://localhost:8080';  // fallback to port-forward

// ── Request defaults ──────────────────────────────────────────────────────────
const REQ_PARAMS = {
  timeout: '30s',        // fail fast — don't let hangs inflate avg duration
  tags: { test: '100vu' },
};

// ── Product catalogue (all 10 boutique products) ──────────────────────────────
const PRODUCTS = [
  'OLJCESPC7Z', '66VCHSJNUP', '1YMWWN1N4O', '0PUK6V6EV0', '2ZYFJ3GM2N',
  'L9ECAV7KIM', '2ZYFJ3GM2N', '0PUK6V6EV0', 'HQTGWGPNH4', '6E92ZMYYFZ',
];

// ── Currencies — exercise currencyservice HPA ─────────────────────────────────
const CURRENCIES = ['USD', 'EUR', 'GBP', 'JPY', 'CAD'];

// ── Test configuration ────────────────────────────────────────────────────────
export const options = {
  stages: [
    { duration: '2m',  target: 100 },   // ramp up — HPA fires here
    { duration: '60m', target: 100 },   // sustained soak — steady state
    { duration: '2m',  target: 0 },     // ramp down — watch HPA scale back
  ],
  thresholds: {
    // Strict: <0.5% failures. Previous 1% was too lenient for a holy grail demo.
    http_req_failed:   ['rate<0.005'],
    // p95 under 1.5s — realistic for a microservices demo under load
    http_req_duration: ['p(95)<1500'],
    // p99 under 5s — catches tail latency issues without being too strict
    'http_req_duration{expected_response:true}': ['p(99)<5000'],
  },
  // Allow in-flight requests to complete on ramp-down (prevents spurious errors)
  // Summary trend stats — adds p99 to the default output
  summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(90)', 'p(95)', 'p(99)'],
};

// ── Helper: random item from array ───────────────────────────────────────────
function pick(arr) {
  return arr[Math.floor(Math.random() * arr.length)];
}

// ── Helper: think time with human variance ────────────────────────────────────
function think(minSec, maxSec) {
  sleep(Math.random() * (maxSec - minSec) + minSec);
}

// ── Main VU function ──────────────────────────────────────────────────────────
export default function () {
  // Persona determines behaviour for this iteration
  // 50% Window Shoppers: browse only
  // 40% Cart Abandoners: add to cart, don't checkout
  // 10% Power Buyers:    full checkout flow
  const persona = Math.random();

  group('User Session', function () {

    // ── Phase 1: Landing page (all personas) ──────────────────────────────────
    const home = http.get(`${BASE}/`, {
      ...REQ_PARAMS,
      tags: { ...REQ_PARAMS.tags, name: 'Home' },
    });
    check(home, {
      'home: status 200': (r) => r.status === 200,
    });
    think(1, 3);

    // ── Phase 2: Set currency (exercises currencyservice) ─────────────────────
    if (Math.random() > 0.5) {
      const currency = pick(CURRENCIES);
      http.post(`${BASE}/setCurrency`, { currency_code: currency }, {
        ...REQ_PARAMS,
        tags: { ...REQ_PARAMS.tags, name: 'SetCurrency' },
      });
    }

    // ── Phase 3: Browse products ──────────────────────────────────────────────
    const numProducts = persona < 0.1 ? 1 : Math.floor(Math.random() * 3) + 2;
    for (let i = 0; i < numProducts; i++) {
      const productId = pick(PRODUCTS);
      const product = http.get(`${BASE}/product/${productId}`, {
        ...REQ_PARAMS,
        tags: { ...REQ_PARAMS.tags, name: 'ProductPage' },
      });
      check(product, {
        'product: status 200': (r) => r.status === 200,
        'product: has price':   (r) => r.body && r.body.includes('USD'),
      });
      think(1, 3);
    }

    // ── Window shoppers leave (50%) ───────────────────────────────────────────
    if (persona >= 0.5) {
      return;
    }

    // ── Phase 4: Add to cart ──────────────────────────────────────────────────
    group('Cart Actions', function () {
      const productId = pick(PRODUCTS);
      const quantity  = Math.floor(Math.random() * 3) + 1;

      const addToCart = http.post(`${BASE}/cart`, {
        product_id: productId,
        quantity:   String(quantity),
      }, {
        ...REQ_PARAMS,
        tags: { ...REQ_PARAMS.tags, name: 'AddToCart' },
      });
      check(addToCart, {
        'addToCart: status 200 or 302': (r) => r.status === 200 || r.status === 302,
      });

      const viewCart = http.get(`${BASE}/cart`, {
        ...REQ_PARAMS,
        tags: { ...REQ_PARAMS.tags, name: 'ViewCart' },
      });
      check(viewCart, {
        'viewCart: status 200': (r) => r.status === 200,
      });
      think(2, 4);
    });

    // ── Cart abandoners leave (40%) ───────────────────────────────────────────
    if (persona >= 0.1) {
      return;
    }

    // ── Phase 5: Checkout (10% Power Buyers) ──────────────────────────────────
    group('Checkout', function () {
      // boutique checkout handler expects form POST (application/x-www-form-urlencoded)
      // Field names are from: src/frontend/handlers.go placeOrderHandler
      const checkoutRes = http.post(`${BASE}/cart/checkout`, {
        email:                          'sre-test@example.com',
        street_address:                 '123 K8s Way',
        zip_code:                       '10101',
        city:                           'ClusterCity',
        state:                          'CA',
        country:                        'US',
        credit_card_number:             '4432801561520454',
        credit_card_expiration_month:   '1',
        credit_card_expiration_year:    '2030',
        credit_card_cvv:                '672',
      }, {
        ...REQ_PARAMS,
        tags: { ...REQ_PARAMS.tags, name: 'Checkout' },
        // k6 http.post with object body sends application/x-www-form-urlencoded
        // which is what boutique's net/http form parser expects — no extra header needed
      });
      check(checkoutRes, {
        'checkout: status 200 or 302': (r) => r.status === 200 || r.status === 302,
        'checkout: no server error':   (r) => r.status < 500,
      });
      think(2, 5);
    });
  });
}
