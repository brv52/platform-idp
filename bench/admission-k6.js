// Admission latency under load: VUs create pods through the Kubernetes API
// with dryRun=All, so every request goes through the full admission chain
// (Kyverno mutating webhook with image signature + SLSA provenance
// verification and digest pinning, Kyverno validating webhook, the CEL
// ValidatingAdmissionPolicy) without anything being persisted.
//
// Run through bench/admission.sh, which creates the namespace, a
// ServiceAccount allowed to create pods there and a short-lived token.
//
// Env: API_URL, TOKEN, NAMESPACE, IMAGE, VUS (500), HOLD (60s), THINK (1 s
// between requests per VU), OUT (summary JSON path), P99_MS (650).
import http from 'k6/http';
import { check, sleep } from 'k6';
import { Counter } from 'k6/metrics';

const VUS = parseInt(__ENV.VUS || '500', 10);
const THINK = parseFloat(__ENV.THINK || '1');
const P99_MS = parseInt(__ENV.P99_MS || '650', 10);
const denied = new Counter('admission_denied');

export const options = {
  // kind's API server certificate is signed by a cluster-local CA.
  insecureSkipTLSVerify: true,
  discardResponseBodies: false,
  scenarios: {
    admission: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: '30s', target: VUS },
        { duration: __ENV.HOLD || '60s', target: VUS },
        { duration: '10s', target: 0 },
      ],
      gracefulRampDown: '10s',
    },
  },
  thresholds: {
    'http_req_duration{phase:admission}': [`p(99)<${P99_MS}`],
    checks: ['rate==1'],
  },
  summaryTrendStats: ['avg', 'min', 'med', 'p(90)', 'p(95)', 'p(99)', 'max'],
};

const url = `${__ENV.API_URL}/api/v1/namespaces/${__ENV.NAMESPACE}/pods?dryRun=All`;
const params = {
  headers: {
    Authorization: `Bearer ${__ENV.TOKEN}`,
    'Content-Type': 'application/json',
  },
  tags: { phase: 'admission' },
  timeout: '30s',
};
const body = JSON.stringify({
  apiVersion: 'v1',
  kind: 'Pod',
  metadata: { generateName: 'k6-', namespace: __ENV.NAMESPACE },
  spec: {
    automountServiceAccountToken: false,
    securityContext: { runAsNonRoot: true, runAsUser: 65532, seccompProfile: { type: 'RuntimeDefault' } },
    containers: [{
      name: 'app',
      image: __ENV.IMAGE,
      args: ['serve'],
      securityContext: { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: ['ALL'] } },
    }],
  },
});

export default function () {
  const res = http.post(url, body, params);
  const ok = check(res, {
    'admitted (201)': (r) => r.status === 201,
    'image pinned to digest': (r) => r.status === 201 && r.json('spec.containers.0.image').includes('@sha256:'),
  });
  if (!ok) denied.add(1);
  sleep(THINK);
}

export function handleSummary(data) {
  const d = data.metrics['http_req_duration{phase:admission}'] || data.metrics.http_req_duration;
  const reqs = data.metrics.http_reqs;
  const out = {
    bench: 'admission-k6',
    generated_at: new Date().toISOString(),
    vus: VUS,
    think_s: THINK,
    requests: reqs.values.count,
    rps: Math.round(reqs.values.rate * 10) / 10,
    failed: data.metrics.admission_denied ? data.metrics.admission_denied.values.count : 0,
    latency_ms: {
      p50: d.values.med, p90: d.values['p(90)'], p95: d.values['p(95)'],
      p99: d.values['p(99)'], max: d.values.max, avg: d.values.avg,
    },
    threshold_p99_ms: P99_MS,
    threshold_ok: !Object.values(data.metrics).some((m) => m.thresholds && Object.values(m.thresholds).some((t) => !t.ok)),
  };
  const res = { stdout: JSON.stringify(out, null, 2) + '\n' };
  if (__ENV.OUT) res[__ENV.OUT] = JSON.stringify(out, null, 2);
  return res;
}
