import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import * as jose from "jose";
import { createApp } from "../../src/app.ts";
import { _setJwksResolverForTests } from "../../src/lib/jwt-verify.ts";

const ISS = "https://cognito-idp.us-east-1.amazonaws.com/us-east-1_demo_prompts";
const KID = "demo-prompts-test-kid";

let signingKey: CryptoKey;

async function authHeaders(): Promise<Record<string, string>> {
  const jwt = await new jose.SignJWT({ token_use: "access", client_id: "test-client" })
    .setProtectedHeader({ alg: "ES256", kid: KID })
    .setIssuer(ISS)
    .setSubject("demo-user")
    .setExpirationTime("1h")
    .sign(signingKey);
  return { Authorization: `Bearer ${jwt}` };
}

describe("GET /demo-prompts", () => {
  const saved = { ...process.env };

  beforeAll(async () => {
    process.env.RATE_LIMIT_DISABLED = "1";
    process.env.AUTH_JWKS_URI = "https://example.invalid/jwks.json";
    process.env.AUTH_ISSUER = ISS;

    const { privateKey, publicKey } = await jose.generateKeyPair("ES256", {
      extractable: true,
    });
    const pub = await jose.exportJWK(publicKey);
    pub.kid = KID;
    pub.alg = "ES256";
    _setJwksResolverForTests(jose.createLocalJWKSet({ keys: [pub] }));
    signingKey = privateKey;
  });

  afterAll(() => {
    _setJwksResolverForTests(null);
    process.env = { ...saved };
  });

  test("requires auth", async () => {
    const app = createApp();
    const r = await app.request("http://localhost/demo-prompts");
    expect(r.status).toBe(401);
  });

  test("returns groups from config/demo-prompts.yaml with auth", async () => {
    const app = createApp();
    const r = await app.request("http://localhost/demo-prompts", {
      headers: await authHeaders(),
    });
    expect(r.status).toBe(200);
    const body = (await r.json()) as { groups: Array<{ title: string; prompts: unknown[] }> };
    expect(Array.isArray(body.groups)).toBe(true);
    expect(body.groups.length).toBeGreaterThan(0);
    for (const g of body.groups) {
      expect(typeof g.title).toBe("string");
      expect(g.title.length).toBeGreaterThan(0);
      expect(Array.isArray(g.prompts)).toBe(true);
      expect(g.prompts.length).toBeGreaterThan(0);
      for (const p of g.prompts as Array<{ label: string; text: string }>) {
        expect(typeof p.label).toBe("string");
        expect(typeof p.text).toBe("string");
        expect(p.text.length).toBeGreaterThan(0);
      }
    }
  });
});
