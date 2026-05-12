import type { JWTPayload } from "jose";
import {
  CognitoIdentityProviderClient,
  GetUserCommand,
} from "@aws-sdk/client-cognito-identity-provider";
import { getMongoDb } from "./mongo-client.ts";
import { logger } from "./logger.ts";
import { currentTrace } from "./trace-context.ts";

function asString(v: unknown): string | undefined {
  return typeof v === "string" && v.trim() ? v.trim() : undefined;
}

function asEmail(v: unknown): string | undefined {
  const s = asString(v);
  if (!s) return undefined;
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(s) ? s : undefined;
}

export async function buildAuthenticatedUserContext(
  userId: string | undefined,
  jwtPayload: JWTPayload | undefined,
  bearerToken?: string,
): Promise<string | undefined> {
  if (!userId || !jwtPayload) return undefined;

  const email =
    asEmail(jwtPayload.email) ??
    asEmail(jwtPayload.preferred_username) ??
    asEmail(jwtPayload["cognito:username"]) ??
    asEmail(jwtPayload.username);
  let resolvedEmail = email;
  const name = asString(jwtPayload.name);

  // Cognito access tokens usually do not contain `email`; fetch it when missing.
  if (!resolvedEmail && bearerToken) {
    try {
      const c = getCognitoClient();
      const out = await c.send(new GetUserCommand({ AccessToken: bearerToken }));
      const emailAttr = out.UserAttributes?.find((a) => a.Name === "email")?.Value;
      if (emailAttr && emailAttr.trim()) {
        resolvedEmail = emailAttr.trim();
      }
    } catch (err) {
      logger.warn("[auth-context] unable to resolve email from Cognito access token", {
        userId,
        error: err instanceof Error ? err.message : String(err),
      });
    }
  }

  let tier: string | undefined;
  let verified: string | undefined;
  let priorOrderSkus: string[] = [];
  let customersResolved = 0;
  let ordersResolved = 0;

  if (resolvedEmail) {
    try {
      const db = await getMongoDb();
      if (db) {
        const customer = await db.collection("customers").findOne({ email: resolvedEmail });
        if (customer) customersResolved = 1;
        tier = asString(customer?.tier);
        if (typeof customer?.verified === "boolean") {
          verified = customer.verified ? "true" : "false";
        }

        const orders = await db
          .collection("orders")
          .find({ customerEmail: resolvedEmail })
          .sort({ orderDate: -1 })
          .limit(10)
          .toArray();
        ordersResolved = orders.length;

        const skus = new Set<string>();
        for (const o of orders) {
          const items = Array.isArray(o.items) ? o.items : [];
          for (const item of items) {
            if (item && typeof item === "object" && typeof (item as { sku?: unknown }).sku === "string") {
              skus.add((item as { sku: string }).sku);
            }
          }
        }
        priorOrderSkus = [...skus].slice(0, 6);
      }
    } catch (err) {
      logger.warn("[auth-context] failed to enrich auth context from Mongo", {
        userId,
        email: resolvedEmail,
        error: err instanceof Error ? err.message : String(err),
      });
    }
  }

  currentTrace()?.event("auth.context_build", {
    userId,
    jwtClaims: {
      sub: asString(jwtPayload.sub),
      iss: asString(jwtPayload.iss),
      aud: typeof jwtPayload.aud === "string" ? jwtPayload.aud : undefined,
    },
    customersResolved,
    ordersResolved,
  });

  const lines: string[] = [
    "## Authenticated User Context",
    "- Treat this user as authenticated.",
    `- userId(sub): ${userId}`,
  ];
  if (resolvedEmail) lines.push(`- authenticatedEmail: ${resolvedEmail}`);
  if (name) lines.push(`- authenticatedName: ${name}`);
  if (tier) lines.push(`- customerTier: ${tier}`);
  if (verified) lines.push(`- customerVerified: ${verified}`);
  if (priorOrderSkus.length > 0) {
    lines.push(`- priorOrderedSkus: ${priorOrderSkus.join(", ")}`);
  }
  lines.push("- If the user asks 'my orders'/'my open tickets' and no email is provided, use authenticatedEmail.");

  return lines.join("\n");
}

let _cognitoClient: CognitoIdentityProviderClient | null = null;
function getCognitoClient(): CognitoIdentityProviderClient {
  if (!_cognitoClient) {
    _cognitoClient = new CognitoIdentityProviderClient({
      region: process.env.AWS_REGION ?? "us-east-1",
    });
  }
  return _cognitoClient;
}
