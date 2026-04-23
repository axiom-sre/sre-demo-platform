/**
 * load-test_250vusers.js — SRE Demo: 250 VU Stress Test
 * ──────────────────────────────────────────────────────
 * PURPOSE : Stepping stone between 100 VU and 1000 VU. Validates that
 *           HPA cascade handles sustained mid-tier load. All services
 *           should hit their scaled replica counts and hold them.
 * PASS    : <0.5% failures, p95 < 1500ms.
 * USAGE   : k6 run scripts/load-test_250vusers.js
 *
 * EXPECTED HPA AT PLATEAU (250 VU):
 *   currencyservice  → 10 pods  (maxed — this is expected and fine)
 *   frontend         → 4-6 pods
 *   productcatalog   → 3-4 pods
 *   recommendation   → 3-4 pods
 *   cartservice      → 3 pods
 *   checkoutservice  → 2-3 pods
 *
 * WHAT TO WATCH IN GRAFANA:
 *   - Platform & HPA:  all 6 services scaled, gauges in amber/green zone
 *   - Golden Signals:  0% errors, p95 stable under 500ms with pods scaled
 *   - Infra & Node:    node CPU 40-60% — confirms headroom exists for 1000 VU
 *   - SLO dashboard:   burn rate <1x — budget-neutral at this load level
 *
 * THINK TIMES: 1-2s — kept tight. At 250 VU with 2s think time each VU
 * generates ~0.4 req/s, so 250 VU = ~100 req/s baseline before bursts.
 * This is the realistic load profile for the HPA to respond to.
 *
 * NOTE: maxConnectionsPerHost added at this VU count. Docker Desktop's NAT
 * table starts showing contention above ~200 simultaneous connections.
 */

import http from 'k6/http';
import { sleep, check, group } from 'k6';

const BASE = __ENV.BASE_URL || 'http://localhost:8080';

const P = {
  timeout: '30s',
  tags: { test: '250vu' },
};

const PRODUCTS = [
  'OLJCESPC7Z', '66VCHSJNUP', '1YMWWN1N4O', '0PUK6V6EV0', '2ZYFJ3GM2N',
  'L9ECAV7KIM', 'LS4PSXUNUM', '9SIQT8TOJO', '6E92ZMYYFZ',
];

export const options = {
  stages: [
    { duration: '2m',  target: 500 },  // ramp — HPA cascade fires
    { duration: '5m',  target: 500 },  // sustain — stable plateau
    { duration: '2m',  target: 0   },  // ramp down — watch scaleDown hold
  ],
  thresholds: {
    http_req_failed:   ['rate<0.005'],
    http_req_duration: ['p(95)<1500'],
    'http_req_duration{expected_response:true}': ['p(99)<4000'],
  },
  // Prevent k6 from overwhelming Docker Desktop NAT table at 250+ VU.
  // Without this, connection resets appear as app errors — they're not.
  maxConnectionsPerHost: 50,
  summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(90)', 'p(95)', 'p(99)'],
};

function pick(arr) { return arr[Math.floor(Math.random() * arr.length)]; }
function think(lo, hi) { sleep(Math.random() * (hi - lo) + lo); }

export default function () {
  const persona = Math.random();

  group('session', () => {

    const home = http.get(`${BASE}/`, { ...P, tags: { ...P.tags, name: 'Home' } });
    check(home, { 'home: 200': r => r.status === 200 });
    think(1, 2);

    const numProds = persona < 0.1 ? 3 : Math.floor(Math.random() * 2) + 1;
    for (let i = 0; i < numProds; i++) {
      const prod = http.get(`${BASE}/product/${pick(PRODUCTS)}`,
        { ...P, tags: { ...P.tags, name: 'ProductPage' } });
      check(prod, {
        'product: 200':       r => r.status === 200,
        'product: has price': r => r.body && r.body.includes('$'),
      });
      think(1, 2);
    }

    if (persona >= 0.5) return;

    const add = http.post(`${BASE}/cart`, {
      product_id: pick(PRODUCTS),
      quantity:   String(Math.floor(Math.random() * 3) + 1),
    }, { ...P, tags: { ...P.tags, name: 'AddToCart' } });
    check(add, { 'addToCart: 200 or 302': r => r.status === 200 || r.status === 302 });

    const cart = http.get(`${BASE}/cart`, { ...P, tags: { ...P.tags, name: 'ViewCart' } });
    check(cart, { 'viewCart: 200': r => r.status === 200 });
    think(1, 2);

    if (persona >= 0.1) return;

    const co = http.post(`${BASE}/cart/checkout`, {
      email:                        'sre-250vu@example.com',
      street_address:               '250 Load Ave',
      zip_code:                     '10250',
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
    think(1, 2);
  });
}
