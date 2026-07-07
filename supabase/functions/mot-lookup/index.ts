// Supabase Edge Function: registration -> { make, model, manufactureYear } via the DVSA
// MOT History API. The three DVSA secrets NEVER reach the client app — this function is the
// only holder. Token is cached in module scope across warm invocations (valid 60 min).
//
// Secrets (set via `supabase secrets set`):
//   MOT_CLIENT_ID, MOT_CLIENT_SECRET, MOT_TENANT_ID, MOT_API_KEY
//
// NOTE: the DVSA API key expires after 90 days of NON-USE — shipping this function and
// calling it occasionally is what keeps the credential alive.

const TOKEN_URL = (tenant: string) => `https://login.microsoftonline.com/${tenant}/oauth2/v2.0/token`;
const SCOPE = "https://tapi.dvsa.gov.uk/.default";
const VEHICLE_URL = (reg: string) => `https://history.mot.api.gov.uk/v1/trade/vehicles/registration/${encodeURIComponent(reg)}`;

let cachedToken: { value: string; expiresAt: number } | null = null;

async function getToken(): Promise<string> {
  if (cachedToken && Date.now() < cachedToken.expiresAt - 60_000) return cachedToken.value;
  const body = new URLSearchParams({
    grant_type: "client_credentials",
    client_id: Deno.env.get("MOT_CLIENT_ID")!,
    client_secret: Deno.env.get("MOT_CLIENT_SECRET")!,
    scope: SCOPE,
  });
  const res = await fetch(TOKEN_URL(Deno.env.get("MOT_TENANT_ID")!), {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body,
  });
  if (!res.ok) throw new Error(`token endpoint ${res.status}`);
  const json = await res.json();
  cachedToken = { value: json.access_token, expiresAt: Date.now() + (json.expires_in ?? 1200) * 1000 };
  return cachedToken.value;
}

Deno.serve(async (req) => {
  const headers = { "Content-Type": "application/json" };
  try {
    if (req.method !== "POST") return new Response(JSON.stringify({ error: "POST only" }), { status: 405, headers });
    const { registration } = await req.json();
    const reg = String(registration ?? "").replace(/\s+/g, "").toUpperCase();
    if (!/^[A-Z0-9]{2,8}$/.test(reg)) {
      return new Response(JSON.stringify({ error: "invalid registration" }), { status: 400, headers });
    }
    const token = await getToken();
    const res = await fetch(VEHICLE_URL(reg), {
      headers: { Authorization: `Bearer ${token}`, "X-API-Key": Deno.env.get("MOT_API_KEY")! },
    });
    if (res.status === 404) {
      // Expected case, not an error: coachbuilts registered under the converter's make,
      // brand-new vehicles, NI pre-2017, etc. Client falls back to the manual list.
      return new Response(JSON.stringify({ found: false }), { headers });
    }
    if (!res.ok) throw new Error(`MOT API ${res.status}`);
    const v = await res.json();
    const record = Array.isArray(v) ? v[0] : v;
    return new Response(JSON.stringify({
      found: true,
      make: record.make ?? null,
      model: record.model ?? null,
      manufactureYear: record.manufactureYear ? Number(record.manufactureYear) : null,
      fuelType: record.fuelType ?? null,
    }), { headers });
  } catch (e) {
    // The Setup screen already carries "this lookup is occasionally unavailable" copy —
    // a 503 here lands on that path, never a spinner.
    return new Response(JSON.stringify({ error: "lookup unavailable", detail: String(e) }), { status: 503, headers });
  }
});
