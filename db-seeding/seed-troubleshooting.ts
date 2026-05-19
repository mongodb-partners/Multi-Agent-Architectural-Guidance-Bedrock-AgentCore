/**
 * Seed: troubleshooting_docs collection
 *
 * Upserts diagnostic articles keyed by `docId`.
 * Safe to re-run (idempotent on `docId`).
 *
 * Run:  MONGODB_URI=... bun db-seeding/seed-troubleshooting.ts
 */

import { connect } from "./connect.ts";

const DOCS = [
  // ── Power / boot ─────────────────────────────────────────────────────────
  {
    docId: "ts-1",
    title: "Device will not power on",
    category: "power",
    errorCodes: ["PWR-001", "BOOT-010"],
    affectedSkus: ["SKU-1", "SKU-2", "SKU-4", "SKU-5", "SKU-7"],
    symptoms: ["no power", "dead unit", "won't turn on", "no LED", "blank screen"],
    body: `Check the power cable and outlet first — try a different cable and wall socket.
Hold the power button for 10 seconds to force a hard reset.
If the unit is still unresponsive (PWR-001), try a known-good USB-C cable at 5V/2A minimum.
If BOOT-010 appears (unit partially powers then restarts), perform a factory reset:
  hold Power + Volume-Down for 15 seconds until the LED blinks twice.
If the issue persists after two resets, escalate to hardware replacement.`,
    escalateTo: "ts-3",
    updatedAt: new Date("2024-10-01"),
  },
  {
    docId: "ts-1b",
    title: "Device restarts randomly or freezes",
    category: "power",
    errorCodes: ["BOOT-010"],
    affectedSkus: ["SKU-2", "SKU-8"],
    symptoms: ["random restart", "freezes", "crashes", "boot loop", "reboot"],
    body: `Random restarts often indicate a firmware or memory issue.
Step 1: Check firmware version — update to the latest via the companion app.
Step 2: Disable background sync and location services temporarily to isolate the cause.
Step 3: If on battery, calibrate by fully discharging then charging to 100% without interruption.
Step 4: Factory reset if the problem persists after firmware update (BOOT-010 recovery procedure).
Escalate if restarts continue after a clean firmware install — may indicate hardware fault.`,
    updatedAt: new Date("2024-10-15"),
  },

  // ── Connectivity ─────────────────────────────────────────────────────────
  {
    docId: "ts-2",
    title: "Intermittent Wi-Fi / connectivity drops",
    category: "connectivity",
    errorCodes: ["NET-204"],
    affectedSkus: ["SKU-2", "SKU-5", "SKU-8"],
    symptoms: ["wifi drops", "disconnects", "offline", "connectivity", "NET-204", "network"],
    body: `NET-204 indicates intermittent network loss. Common causes and fixes:
1. Distance — move within 5 metres of the router for the initial setup.
2. VPN interference — temporarily disable VPN; some split-tunnel configurations block device traffic.
3. 2.4GHz / 5GHz band — the device defaults to 2.4GHz; if your router is 5GHz-only, enable band steering.
4. Firmware — ensure firmware is on the latest version (companion app > Settings > Updates).
5. Factory network reset — hold Network-Reset button for 5 seconds (LED blinks amber x3).
If NET-204 persists after all five steps, open a return request referencing error code NET-204.`,
    escalateTo: "ts-4-policy",
    updatedAt: new Date("2024-09-20"),
  },
  {
    docId: "ts-2b",
    title: "Bluetooth pairing fails or drops",
    category: "connectivity",
    errorCodes: [],
    affectedSkus: ["SKU-2", "SKU-5", "SKU-8"],
    symptoms: ["bluetooth", "pairing", "won't connect", "BT drops", "can't pair"],
    body: `Bluetooth pairing issues:
1. Clear existing pairings — on the device, hold BT button for 8 seconds until LED blinks white.
2. Forget the device on your phone and re-pair from scratch.
3. Ensure no more than 3 devices are paired simultaneously (firmware limit).
4. Interference — microwave ovens and other 2.4GHz devices can disrupt BT; move away and retry.
5. Update companion app and device firmware to the latest version before re-pairing.`,
    updatedAt: new Date("2024-08-12"),
  },

  // ── Hardware fault / escalation ──────────────────────────────────────────
  {
    docId: "ts-3",
    title: "Hardware fault — LED blink pattern or HW-900",
    category: "hardware",
    errorCodes: ["HW-900"],
    affectedSkus: ["SKU-1", "SKU-2", "SKU-4", "SKU-5", "SKU-7", "SKU-8"],
    symptoms: ["red blink", "blinks three times", "HW-900", "hardware error", "replacement"],
    body: `HW-900 and a three-blink red LED pattern indicate a non-recoverable hardware fault.
Do NOT continue troubleshooting — further resets will not resolve the issue.
Action required:
  1. Note the serial number (printed on the underside or in Settings > About).
  2. Capture a short video of the blink pattern if possible.
  3. Gather proof of purchase (order ID or receipt).
  4. Open a replacement ticket via the Order Management agent — reference HW-900.
The standard replacement window is 24 months from the date of purchase for Pro series,
12 months for standard widgets. Premium-tier customers have an extended 36-month window.`,
    updatedAt: new Date("2024-11-01"),
  },

  // ── Return / replacement policy ──────────────────────────────────────────
  {
    docId: "ts-4",
    title: "Replacement after delivery — policy and process",
    category: "returns",
    errorCodes: ["RET-010"],
    affectedSkus: [],
    symptoms: ["replacement", "return", "refund", "broken after delivery", "swap"],
    body: `For delivered orders, use the Order Management agent to confirm return eligibility before promising an exchange.
Policy summary:
  - Eligibility window: 30 days from delivery for standard returns; 90 days for defective units.
  - Pro series defect: 24-month hardware warranty (see ts-3 for HW-900 procedure).
  - Escalation: if the order notes mention HW-900 or repeated failures, escalate immediately.
Process:
  1. Look up the order with mongodb_query (field: orderId or customerEmail).
  2. Run validate-return.mjs via run_skill_script to get the eligibility verdict.
  3. Summarize verdict and next steps for the customer — never approve from memory alone.`,
    updatedAt: new Date("2024-10-05"),
  },

  // ── Smart home / app issues ───────────────────────────────────────────────
  {
    docId: "ts-5",
    title: "Smart Widget Hub — app not detecting device",
    category: "smart-home",
    errorCodes: [],
    affectedSkus: ["SKU-5"],
    symptoms: ["app not finding", "device offline in app", "hub not detected", "smart widget", "pairing"],
    body: `If the companion app shows SKU-5 as offline or cannot discover it:
1. Ensure phone and hub are on the same Wi-Fi SSID (not a guest network).
2. Force-close and reopen the companion app.
3. Pull the hub's power for 30 seconds then reconnect.
4. Revoke and re-grant the app's local network permission in phone settings.
5. Delete the hub from the app and re-add as a new device.
If the hub never appears in discovery after step 5, perform a full factory reset (ts-1 procedure)
and re-add — some firmware versions require this after a network change.`,
    updatedAt: new Date("2024-09-10"),
  },
  {
    docId: "ts-6",
    title: "Firmware update fails or gets stuck",
    category: "firmware",
    errorCodes: [],
    affectedSkus: ["SKU-2", "SKU-5", "SKU-8"],
    symptoms: ["update stuck", "update failed", "firmware error", "won't update", "update loop"],
    body: `Stuck firmware updates:
1. Do not power off during an update — wait at least 10 minutes before intervening.
2. If the LED has been solid amber for more than 15 minutes, force a recovery:
   - Disconnect power.
   - Hold the recovery button (pin-hole on base) while reconnecting power.
   - LED will blink white rapidly — release after 3 blinks.
   - The device boots into recovery mode; trigger the update again from the app.
3. Ensure the phone has a stable internet connection during the OTA download.
4. If recovery mode update also fails, escalate to hardware replacement (HW-900 procedure).`,
    updatedAt: new Date("2024-10-22"),
  },
];

const { client, db } = await connect();
const col = db.collection("troubleshooting_docs");
let upserted = 0;

for (const doc of DOCS) {
  const res = await col.updateOne(
    { docId: doc.docId },
    { $set: doc },
    { upsert: true },
  );
  if (res.upsertedCount || res.modifiedCount) upserted++;
}

console.log(`✅  troubleshooting_docs: ${upserted} upserted / ${DOCS.length} total`);
await client.close();
