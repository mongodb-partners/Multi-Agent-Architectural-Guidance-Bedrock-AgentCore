/**
 * Seed: orders collection
 *
 * Upserts demo orders covering all status variants.
 * Safe to re-run (idempotent on `orderId`).
 * Run:  MONGODB_URI=... bun db-seeding/seed-orders.ts
 */

import { connect } from "./connect.ts";

const ORDERS = [
  // ── Alex Rivera ───────────────────────────────────────────────────────────
  {
    orderId: "ORD-1001",
    status: "shipped",
    customerEmail: "alex@example.com",
    orderDate: new Date("2024-11-01"),
    estimatedDelivery: new Date("2024-11-07"),
    items: [{ sku: "SKU-1", title: "Compact Widget", qty: 1, unitPrice: 29.99 }],
    total: 29.99,
    trackingNumber: "TRK-9001-US",
    trackingUrl: "https://carriers.example/track/TRK-9001-US",
    shippingAddress: { line1: "123 Main St", city: "Austin", state: "TX", zip: "78701" },
  },
  {
    orderId: "ORD-1003",
    status: "delivered",
    customerEmail: "alex@example.com",
    orderDate: new Date("2024-10-15"),
    deliveredAt: new Date("2024-10-21"),
    items: [{ sku: "SKU-1", title: "Compact Widget", qty: 1, unitPrice: 29.99, returnEligible: true }],
    total: 29.99,
    notes: "Customer reported unit stopped working after 2 weeks — replacement eligible. Suggest SKU-4 or SKU-5.",
    shippingAddress: { line1: "123 Main St", city: "Austin", state: "TX", zip: "78701" },
  },
  {
    orderId: "ORD-1005",
    status: "shipped",
    customerEmail: "alex@example.com",
    orderDate: new Date("2024-11-05"),
    estimatedDelivery: new Date("2024-11-11"),
    items: [{ sku: "SKU-2", title: "Pro Gadget", qty: 1, unitPrice: 89.99 }],
    total: 89.99,
    trackingNumber: "TRK-9005-US",
    trackingUrl: "https://carriers.example/track/TRK-9005-US",
    shippingAddress: { line1: "123 Main St", city: "Austin", state: "TX", zip: "78701" },
  },
  {
    orderId: "ORD-1009",
    status: "delivered",
    customerEmail: "alex@example.com",
    orderDate: new Date("2024-09-20"),
    deliveredAt: new Date("2024-09-26"),
    items: [
      { sku: "SKU-5", title: "Smart Widget Hub", qty: 1, unitPrice: 49.99 },
      { sku: "SKU-6", title: "Office Lamp LED", qty: 1, unitPrice: 39.99 },
    ],
    total: 89.98,
    shippingAddress: { line1: "123 Main St", city: "Austin", state: "TX", zip: "78701" },
  },

  // ── Blake Chen ────────────────────────────────────────────────────────────
  {
    orderId: "ORD-1002",
    status: "processing",
    customerEmail: "blake@example.com",
    orderDate: new Date("2024-11-06"),
    estimatedDelivery: new Date("2024-11-12"),
    items: [{ sku: "SKU-2", title: "Pro Gadget", qty: 2, unitPrice: 89.99 }],
    total: 179.98,
    shippingAddress: { line1: "456 Oak Ave", city: "Seattle", state: "WA", zip: "98101" },
  },
  {
    orderId: "ORD-1004",
    status: "cancelled",
    customerEmail: "blake@example.com",
    orderDate: new Date("2024-10-28"),
    cancelledAt: new Date("2024-10-29"),
    items: [{ sku: "SKU-3", title: "Travel Widget Mini", qty: 1, unitPrice: 24.99 }],
    total: 24.99,
    notes: "Cancelled at customer request before ship.",
    shippingAddress: { line1: "456 Oak Ave", city: "Seattle", state: "WA", zip: "98101" },
  },
  {
    orderId: "ORD-1006",
    status: "return_requested",
    customerEmail: "blake@example.com",
    orderDate: new Date("2024-10-10"),
    deliveredAt: new Date("2024-10-16"),
    items: [{ sku: "SKU-2", title: "Pro Gadget", qty: 1, unitPrice: 89.99, returnEligible: true }],
    total: 89.99,
    notes: "Return label pending — reported intermittent NET-204 error after firmware update.",
    shippingAddress: { line1: "456 Oak Ave", city: "Seattle", state: "WA", zip: "98101" },
  },
  {
    orderId: "ORD-1010",
    status: "shipped",
    customerEmail: "blake@example.com",
    orderDate: new Date("2024-11-04"),
    estimatedDelivery: new Date("2024-11-10"),
    items: [{ sku: "SKU-4", title: "Compact Widget Plus", qty: 1, unitPrice: 34.99 }],
    total: 34.99,
    trackingNumber: "TRK-9010-US",
    trackingUrl: "https://carriers.example/track/TRK-9010-US",
    shippingAddress: { line1: "456 Oak Ave", city: "Seattle", state: "WA", zip: "98101" },
  },

  // ── Casey Morgan (premium) ────────────────────────────────────────────────
  {
    orderId: "ORD-2001",
    status: "delivered",
    customerEmail: "casey@example.com",
    orderDate: new Date("2024-10-01"),
    deliveredAt: new Date("2024-10-05"),
    items: [
      { sku: "SKU-4", title: "Compact Widget Plus", qty: 2, unitPrice: 34.99 },
      { sku: "SKU-5", title: "Smart Widget Hub", qty: 1, unitPrice: 49.99 },
    ],
    total: 119.97,
    shippingAddress: { line1: "789 Elm St", city: "Chicago", state: "IL", zip: "60601" },
  },
  {
    orderId: "ORD-2002",
    status: "shipped",
    customerEmail: "casey@example.com",
    orderDate: new Date("2024-11-03"),
    estimatedDelivery: new Date("2024-11-08"),
    items: [{ sku: "SKU-2", title: "Pro Gadget", qty: 1, unitPrice: 89.99 }],
    total: 89.99,
    trackingNumber: "TRK-2002-US",
    trackingUrl: "https://carriers.example/track/TRK-2002-US",
    shippingAddress: { line1: "789 Elm St", city: "Chicago", state: "IL", zip: "60601" },
  },

  // ── Dana Patel (premium) ──────────────────────────────────────────────────
  {
    orderId: "ORD-3001",
    status: "delivered",
    customerEmail: "dana@example.com",
    orderDate: new Date("2024-09-15"),
    deliveredAt: new Date("2024-09-19"),
    items: [{ sku: "SKU-6", title: "Office Lamp LED", qty: 3, unitPrice: 39.99 }],
    total: 119.97,
    shippingAddress: { line1: "321 Pine Rd", city: "Boston", state: "MA", zip: "02101" },
  },
  {
    orderId: "ORD-3002",
    status: "return_requested",
    customerEmail: "dana@example.com",
    orderDate: new Date("2024-10-20"),
    deliveredAt: new Date("2024-10-25"),
    items: [{ sku: "SKU-1", title: "Compact Widget", qty: 1, unitPrice: 29.99, returnEligible: true }],
    total: 29.99,
    notes: "Unit shows HW-900 error code — hardware fault. Escalation required.",
    shippingAddress: { line1: "321 Pine Rd", city: "Boston", state: "MA", zip: "02101" },
  },
];

const { client, db } = await connect();
const col = db.collection("orders");
let upserted = 0;

for (const o of ORDERS) {
  const res = await col.updateOne(
    { orderId: o.orderId },
    { $set: o },
    { upsert: true },
  );
  if (res.upsertedCount || res.modifiedCount) upserted++;
}

console.log(`✅  orders: ${upserted} upserted / ${ORDERS.length} total`);
await client.close();
