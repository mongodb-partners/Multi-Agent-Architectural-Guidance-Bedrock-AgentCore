/**
 * Seed: products collection
 *
 * Upserts the product catalog. Safe to re-run (idempotent on `sku`).
 *
 * NOTE: Atlas vector search requires an embedding field (e.g. `embedding`).
 * This script seeds the text fields only. To add embeddings:
 *   1. Run seed-embeddings.ts (requires a live embedding model endpoint), OR
 *   2. Use an Atlas trigger / scheduled function to backfill embeddings after insert.
 *
 * Run:  MONGODB_URI=... bun db-seeding/seed-products.ts
 */

import { connect } from "./connect.ts";

const PRODUCTS = [
  {
    sku: "SKU-1",
    title: "Compact Widget",
    description: "A compact widget ideal for small spaces and daily use. Lightweight, plug-and-play, 1-year warranty.",
    category: "home",
    tags: ["widget", "home", "compact", "beginner"],
    price: 29.99,
    stock: 142,
    rating: 4.3,
    specs: { weight: "120g", dimensions: "8x5x3cm", warranty: "12 months" },
    replacedBy: ["SKU-4", "SKU-5"],
  },
  {
    sku: "SKU-2",
    title: "Pro Gadget",
    description: "Pro-grade gadget with extended battery life for power users. 48-hour battery, fast-charge, IP54 water resistance.",
    category: "electronics",
    tags: ["gadget", "pro", "battery", "waterproof", "power-user"],
    price: 89.99,
    stock: 58,
    rating: 4.7,
    specs: { battery: "48h", charging: "fast-charge 30min to 80%", ipRating: "IP54", warranty: "24 months" },
  },
  {
    sku: "SKU-3",
    title: "Travel Widget Mini",
    description: "Portable mini widget for travel. Foldable, TSA-approved, fits in carry-on. Similar functionality to Compact Widget.",
    category: "home",
    tags: ["widget", "travel", "compact", "portable", "mini"],
    price: 24.99,
    stock: 210,
    rating: 4.1,
    specs: { weight: "75g", foldable: true, tsaApproved: true, warranty: "12 months" },
    similarTo: ["SKU-1"],
  },
  {
    sku: "SKU-4",
    title: "Compact Widget Plus",
    description: "Upgraded compact widget with metal body and improved internals. Direct replacement for SKU-1; 30% faster, 2-year warranty.",
    category: "home",
    tags: ["widget", "home", "replacement", "upgraded", "metal"],
    price: 34.99,
    stock: 95,
    rating: 4.6,
    specs: { weight: "145g", dimensions: "8x5x3cm", material: "aluminium", warranty: "24 months" },
    replacesSkus: ["SKU-1"],
  },
  {
    sku: "SKU-5",
    title: "Smart Widget Hub",
    description: "Connected hub variant with app control, scheduling, and voice assistant support. Upgrade path from SKU-1 for smart home users.",
    category: "home",
    tags: ["widget", "smart", "iot", "voice", "hub", "connected"],
    price: 49.99,
    stock: 73,
    rating: 4.5,
    specs: { connectivity: "Wi-Fi 6 + Bluetooth 5.2", voiceAssistants: ["Alexa", "Google"], warranty: "24 months" },
    replacesSkus: ["SKU-1"],
  },
  {
    sku: "SKU-6",
    title: "Office Lamp LED",
    description: "Adjustable LED desk lamp with warm and cool modes, USB-C charging port, and motion-activated auto-off for home office use.",
    category: "home",
    tags: ["lamp", "office", "lighting", "desk", "led", "usb-c"],
    price: 39.99,
    stock: 187,
    rating: 4.4,
    specs: { brightness: "800 lm", colorTemp: "2700K–6500K", usbC: true, warranty: "12 months" },
  },
  {
    sku: "SKU-7",
    title: "Outdoor Widget Rugged",
    description: "Heavy-duty rugged outdoor widget with IP67 waterproof and dustproof rating. Weatherproof and weather-resistant design for harsh conditions, extreme temperatures (-20°C to 60°C), rain, dust, and UV exposure. Ideal for garages, workshops, construction sites, and outdoor environments.",
    category: "outdoor",
    tags: ["widget", "outdoor", "rugged", "waterproof", "weatherproof", "heavy-duty", "IP67", "harsh-conditions", "garage", "workshop"],
    price: 59.99,
    stock: 41,
    rating: 4.2,
    specs: { ipRating: "IP67", tempRange: "-20°C to 60°C", uvResistant: true, warranty: "36 months" },
  },
  {
    sku: "SKU-8",
    title: "Pro Gadget Lite",
    description: "Lighter version of the Pro Gadget for everyday carry. 24-hour battery, same sensors, 20% lighter body.",
    category: "electronics",
    tags: ["gadget", "lite", "everyday", "battery", "lightweight"],
    price: 64.99,
    stock: 120,
    rating: 4.4,
    specs: { battery: "24h", weight: "180g", warranty: "18 months" },
    similarTo: ["SKU-2"],
  },
  {
    sku: "SKU-9",
    title: "Widget Starter Bundle",
    description: "Value bundle combo kit: includes one Compact Widget for home use and one Travel Widget Mini for travel. Perfect for customers who want both a home widget and a travel widget in one affordable package. Best value two-in-one bundle for home and travel coverage.",
    category: "home",
    tags: ["bundle", "widget", "starter", "value", "compact", "travel", "home-and-travel", "combo", "kit", "two-in-one", "affordable"],
    price: 49.99,
    stock: 34,
    rating: 4.5,
    bundleSkus: ["SKU-1", "SKU-3"],
  },
];

const { client, db } = await connect();
const col = db.collection("products");
let upserted = 0;

for (const p of PRODUCTS) {
  const res = await col.updateOne(
    { sku: p.sku },
    { $set: p },
    { upsert: true },
  );
  if (res.upsertedCount || res.modifiedCount) upserted++;
}

console.log(`✅  products: ${upserted} upserted / ${PRODUCTS.length} total`);
console.log("ℹ️   Embeddings not seeded — run seed-embeddings.ts once your embedding endpoint is live.");
await client.close();
