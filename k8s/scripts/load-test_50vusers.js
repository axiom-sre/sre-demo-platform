/**
 * load-test_50vusers.js — SRE Demo: Light Load / First HPA Trigger (50 VU)
 * ──────────────────────────────────────────────────────────────────────────
 * PURPOSE : Confirm baseline is clean. First HPA trigger test.
 *           Currency should scale 2→3. Frontend may scale 2→3 near end.
 * PASS    : <0.5% failures, p95 < 1000ms.
 * USAGE   : k6 run scripts/load-test_50vusers.js
 *
 * WHAT TO WATCH IN GRAFANA:
 *   - Platform & HPA: currencyservice 2→3 around minute 1
 *   - Platform & HPA: frontend 2→3 around minute 2-3
 *   - Golden Signals: error rate flat at 0%
 *   - SLO dashboard:  burn rate <1x
 *
 * THINK TIMES:
 *   1-2s browse, 1-3s cart — kept tight so 50 VU generates enough RPS
 *   to actually trigger HPA. Too much sleep = VUs idle = no scaling signal.
 */

import http from 'k6/http';
import { sleep, check, group } from 'k6';

const BASE = __ENV.BASE_URL || 'http://localhost:8080';

const P = {
  timeout: '30s',
  tags: { test: '50vu' },
};

const PRODUCTS = [
  'OLJCESPC7Z', '66VCHSJNUP', '1YMWWN1N4O', '0PUK6V6EV0', '2ZYFJ3GM2N',
  'L9ECAV7KIM', 'LS4PSXUNUM', '9SIQT8TOJO', '6E92ZMYYFZ',
];

export const options = {
  stages: [
    { duration: '1m', target: 50 },   // ramp — HPA fires here
    { duration: '7m', target: 50 },   // sustain — watch cascade complete
    { duration: '1m', target: 0  },   // ramp down — watch scaleDown hold 5min
  ],
  thresholds: {
    http_req_failed:   ['rate<0.005'],
    http_req_duration: ['p(95)<1000'],
    'http_req_duration{expected_response:true}': ['p(99)<3000'],
  },
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
    think(1, 3);

    if (persona >= 0.1) return;

    const co = http.post(`${BASE}/cart/checkout`, {
      email:                        'sre-50vu@example.com',
      street_address:               '50 Load Ave',
      zip_code:                     '10050',
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
    think(1, 3);
  });
}
