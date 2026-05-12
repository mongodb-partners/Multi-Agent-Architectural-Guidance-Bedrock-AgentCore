import { describe, expect, test } from "bun:test";
import * as jose from "jose";
import { verifyJwtWithJwksResolver } from "../../src/lib/jwt-verify.ts";

const ISS = "https://cognito-idp.us-east-1.amazonaws.com/us-east-1_testpool";

async function makeLocalJwks(alg: "ES256" = "ES256") {
  const { privateKey, publicKey } = await jose.generateKeyPair(alg, { extractable: true });
  const pub = await jose.exportJWK(publicKey);
  pub.kid = "unit-test-kid";
  pub.alg = alg;
  const local = jose.createLocalJWKSet({ keys: [pub] });
  return { privateKey, local };
}

describe("jwt-verify (local JWKS)", () => {
  test("accepts valid token with issuer and client_id", async () => {
    const { privateKey, local } = await makeLocalJwks();
    const jwt = await new jose.SignJWT({ token_use: "access", client_id: "app-client-1" })
      .setProtectedHeader({ alg: "ES256", kid: "unit-test-kid" })
      .setIssuer(ISS)
      .setSubject("user-1")
      .setExpirationTime("1h")
      .sign(privateKey);

    const payload = await verifyJwtWithJwksResolver(jwt, local, ISS, {
      appClientId: "app-client-1",
      tokenUse: "access",
    });
    expect(payload.sub).toBe("user-1");
  });

  test("rejects wrong app client id", async () => {
    const { privateKey, local } = await makeLocalJwks();
    const jwt = await new jose.SignJWT({ token_use: "access", client_id: "app-client-1" })
      .setProtectedHeader({ alg: "ES256", kid: "unit-test-kid" })
      .setIssuer(ISS)
      .setExpirationTime("1h")
      .sign(privateKey);

    await expect(
      verifyJwtWithJwksResolver(jwt, local, ISS, {
        appClientId: "other-client",
        tokenUse: "access",
      }),
    ).rejects.toThrow();
  });

  test("rejects wrong token_use when enforced", async () => {
    const { privateKey, local } = await makeLocalJwks();
    const jwt = await new jose.SignJWT({ token_use: "id", client_id: "app-client-1" })
      .setProtectedHeader({ alg: "ES256", kid: "unit-test-kid" })
      .setIssuer(ISS)
      .setExpirationTime("1h")
      .sign(privateKey);

    await expect(
      verifyJwtWithJwksResolver(jwt, local, ISS, {
        appClientId: "app-client-1",
        tokenUse: "access",
      }),
    ).rejects.toThrow();
  });

  test("accepts aud instead of client_id when appClientId matches", async () => {
    const { privateKey, local } = await makeLocalJwks();
    const jwt = await new jose.SignJWT({ token_use: "id" })
      .setProtectedHeader({ alg: "ES256", kid: "unit-test-kid" })
      .setIssuer(ISS)
      .setAudience("app-client-1")
      .setExpirationTime("1h")
      .sign(privateKey);

    const payload = await verifyJwtWithJwksResolver(jwt, local, ISS, {
      appClientId: "app-client-1",
      tokenUse: "id",
    });
    expect(payload.aud).toBe("app-client-1");
  });
});
