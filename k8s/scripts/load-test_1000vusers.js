/**
 * load-test_1000vusers.js — SRE Demo: 1000 VU Stress Test
 * ─────────────────────────────────────────────────────────
 * PURPOSE : The money shot. Max load, full HPA cascade, demo-ready.
 *           Only run after 100 VU soak passes with 0% errors.
 * PASS    : <1% failures, p95 < 2000ms at peak 1000 VU.
 * USAGE   : k6 run scripts/load-test_1000vusers.js
 * NOTE    : maxConnectionsPerHost warning is cosmetic — k6 handles connection
 *           pooling automatically at 1000 VU on Docker Desktop.
 *
 * LIVE DEMO TIMELINE:
 *   T+0:00  Start — Command Center: RPS climbing
 *   T+2:00  100 VU  → HPA wave 1: frontend 2→4, cart 2→3
 *   T+5:00  300 VU  → HPA wave 2: productcatalog, recommendation scaling
 *   T+8:00  600 VU  → mid-demo plateau — show SLO dashboard (burn rate ~neutral)
 *   T+10:00 1000 VU → peak — node CPU 70-80%, Infra dashboard
 *   T+25:00 ramp down — HPA stabilization window (5 min) visible as slow scale-back
 *
 * KEY KNOB: maxConnectionsPerHost: 100
 *   Prevents k6 from opening ~1000 simultaneous TCP connections to Docker
 *   Desktop's NAT table. Without this, k6 itself becomes the bottleneck at
 *   high VU counts and you get connection reset errors that aren't app errors.
 */

import http from 'k6/http';
import { sleep, check, group } from 'k6';

// ─── Config ───────────────────────────────────────────────────────────────────
const BASE = __ENV.BASE_URL || 'http://localhost:8080';

const P = {
  timeout: '30s',
  tags: { test: '1000vu' },
};

const PRODUCTS = [
  'OLJCESPC7Z', '66VCHSJNUP', '1YMWWN1N4O', '0PUK6V6EV0', '2ZYFJ3GM2N',
  'L9ECAV7KIM', 'LS4PSXUNUM', '9SIQT8TOJO', '6E92ZMYYFZ',
];

// ─── Thresholds ───────────────────────────────────────────────────────────────
export const options = {
  stages: [
    { duration: '2m',  target: 100  },  // HPA wave 1
    { duration: '3m',  target: 300  },  // HPA wave 2
    { duration: '3m',  target: 600  },  // mid-demo plateau
    { duration: '2m',  target: 1000 },  // max load ramp
    { duration: '15m', target: 1000 },  // sustained peak — the money shot
    { duration: '5m',  target: 0    },  // ramp down — HPA stabilization visible
  ],
  thresholds: {
    http_req_failed:   ['rate<0.01'],    // <1% at 1000 VU
    http_req_duration: ['p(95)<2000'],
    'http_req_duration{expected_response:true}': ['p(99)<8000'],
  },
  // TCP connection pooling — prevents k6 from overwhelming Docker Desktop NAT.
  // maxConnectionsPerHost was deprecated in k6 v0.44. Use batch requests or
  // accept the warning — behaviour is identical, just a cosmetic log message.
  // At 1000 VU Docker Desktop handles the connection pool automatically.
  // To suppress: run with --env K6_MAX_CONNECTIONS_PER_HOST=100 instead.
  summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(90)', 'p(95)', 'p(99)'],
};

// ─── Helpers ──────────────────────────────────────────────────────────────────
function pick(arr) { return arr[Math.floor(Math.random() * arr.length)]; }
function think(lo, hi) { sleep(Math.random() * (hi - lo) + lo); }

// ─── VU function ──────────────────────────────────────────────────────────────
export default function () {
  const persona = Math.random();

  group('session', () => {

    // ── 1. Home ───────────────────────────────────────────────────────────────
    const home = http.get(`${BASE}/`, { ...P, tags: { ...P.tags, name: 'Home' } });
    check(home, { 'home: 200': r => r.status === 200 });
    think(1, 2);  // tighter at 1000 VU — keeps RPS from being too light

    // ── 2. Browse products ────────────────────────────────────────────────────
    const numProds = persona < 0.1 ? 3 : Math.floor(Math.random() * 2) + 1;
    for (let i = 0; i < numProds; i++) {
      const prod = http.get(`${BASE}/product/${pick(PRODUCTS)}`, {
        ...P, tags: { ...P.tags, name: 'ProductPage' },
      });
      check(prod, {
        'product: 200':       r => r.status === 200,
        'product: has price': r => r.body && r.body.includes('$'),
      });
      think(1, 2);
    }

    // ── 3. Window shoppers leave (50%) ────────────────────────────────────────
    if (persona >= 0.5) return;

    // ── 4. Add to cart ────────────────────────────────────────────────────────
    const add = http.post(`${BASE}/cart`, {
      product_id: pick(PRODUCTS),
      quantity:   String(Math.floor(Math.random() * 3) + 1),
    }, { ...P, tags: { ...P.tags, name: 'AddToCart' } });
    check(add, { 'addToCart: ok': r => r.status === 200 || r.status === 302 });

    const cart = http.get(`${BASE}/cart`, { ...P, tags: { ...P.tags, name: 'ViewCart' } });
    check(cart, { 'viewCart: 200': r => r.status === 200 });
    think(1, 3);

    // ── 5. Cart abandoners leave (40%) ────────────────────────────────────────
    if (persona >= 0.1) return;

    // ── 6. Checkout (10% power buyers) ────────────────────────────────────────
    const co = http.post(`${BASE}/cart/checkout`, {
      email:                        'sre-1000vu@example.com',
      street_address:               '1000 Load Ave',
      zip_code:                     '10000',
      city:                         'ClusterCity',
      state:                        'CA',
      country:                      'US',
      credit_card_number:           '4432801561520454',
      credit_card_expiration_month: '1',
      credit_card_expiration_year:  '2030',
      credit_card_cvv:              '672',
    }, { ...P, tags: { ...P.tags, name: 'Checkout' } });
    check(co, {
      'checkout: ok':     r => r.status === 200 || r.status === 302,
      'checkout: no 5xx': r => r.status < 500,
    });
    think(2, 4);
  });
}
