// FreshCart API — mock quick-commerce backend for the ZG527 orchestration demo.
// Every behaviour the demo relies on is switched by environment variables, so the
// orchestrator (Swarm / Kubernetes), not a rebuilt image, changes how it runs.
//
//   PORT              3000
//   APP_VERSION       shown in /api/info (set by CI from the git tag)
//   DB_HOST/DB_PORT/DB_NAME/DB_USER, DB_PASSWORD or DB_PASSWORD_FILE
//   CART_STORE        memory | redis   (memory is deliberately wrong once replicas > 1)
//   REDIS_URL         redis://redis:6379
//   SALE_PERCENT      0..90            (the "festive sale" rollout)
//   CHAOS_ENABLED     true|false       (enables /api/chaos/* for demos ONLY)

const express = require("express");
const os = require("os");
const fs = require("fs");
const { Pool } = require("pg");

const PORT = Number(process.env.PORT || 3000);
const APP_VERSION = process.env.APP_VERSION || "dev";
const CART_STORE = (process.env.CART_STORE || "memory").toLowerCase();
const SALE_PERCENT = Math.min(Math.max(Number(process.env.SALE_PERCENT || 0), 0), 90);
const CHAOS_ENABLED = String(process.env.CHAOS_ENABLED || "false") === "true";
const HOSTNAME = os.hostname();
const STARTED_AT = new Date().toISOString();

function readSecret(name) {
  // Orchestrators mount secrets as files; *_FILE wins over the plain variable.
  const file = process.env[`${name}_FILE`];
  if (file) {
    try { return fs.readFileSync(file, "utf8").trim(); } catch (e) { console.error(`cannot read ${name}_FILE: ${e.message}`); }
  }
  return process.env[name];
}

// ---------- PostgreSQL ----------
const pool = new Pool({
  host: process.env.DB_HOST || "db",
  port: Number(process.env.DB_PORT || 5432),
  database: process.env.DB_NAME || "freshcart",
  user: process.env.DB_USER || "freshcart",
  password: readSecret("DB_PASSWORD") || "freshcart",
  max: 5,
  connectionTimeoutMillis: 3000,
});
pool.on("error", (e) => console.error("pg pool error:", e.message));
let dbReady = false;

async function waitForDb() {
  // Orchestrators do NOT guarantee start order (Swarm ignores depends_on).
  // The app must retry; readiness stays false until the DB answers.
  for (;;) {
    try {
      await pool.query("SELECT 1");
      if (!dbReady) console.log("database reachable");
      dbReady = true;
      return;
    } catch (e) {
      dbReady = false;
      console.log(`waiting for database at ${process.env.DB_HOST || "db"}: ${e.message}`);
      await new Promise((r) => setTimeout(r, 2000));
    }
  }
}
setInterval(async () => {
  try { await pool.query("SELECT 1"); dbReady = true; } catch { dbReady = false; }
}, 5000).unref();

// ---------- Cart store: the stateless-vs-stateful lesson ----------
let redis = null;
const memoryCarts = new Map(); // lives inside ONE replica's process memory

async function initCartStore() {
  if (CART_STORE !== "redis") {
    console.log("cart store: memory (each replica has its own carts!)");
    return;
  }
  const { createClient } = require("redis");
  redis = createClient({ url: process.env.REDIS_URL || "redis://redis:6379" });
  redis.on("error", (e) => console.error("redis error:", e.message));
  for (;;) {
    try { await redis.connect(); break; } catch (e) {
      console.log(`waiting for redis: ${e.message}`);
      await new Promise((r) => setTimeout(r, 2000));
    }
  }
  console.log("cart store: redis (shared by all replicas)");
}

async function getCart(id) {
  if (redis) {
    const h = await redis.hGetAll(`cart:${id}`);
    return Object.entries(h).map(([pid, qty]) => ({ productId: Number(pid), qty: Number(qty) }));
  }
  const c = memoryCarts.get(id) || {};
  return Object.entries(c).map(([pid, qty]) => ({ productId: Number(pid), qty }));
}
async function addToCart(id, productId, qty) {
  if (redis) {
    await redis.hIncrBy(`cart:${id}`, String(productId), qty);
    await redis.expire(`cart:${id}`, 60 * 60 * 24);
    return;
  }
  const c = memoryCarts.get(id) || {};
  c[productId] = (c[productId] || 0) + qty;
  memoryCarts.set(id, c);
}
async function clearCart(id) {
  if (redis) { await redis.del(`cart:${id}`); return; }
  memoryCarts.delete(id);
}

// ---------- HTTP ----------
const app = express();
app.use(express.json({ limit: "32kb" }));
app.use((req, res, next) => { res.set("X-Api-Replica", HOSTNAME); next(); });

const price = (paise) => Math.round(paise * (100 - SALE_PERCENT) / 100);
const cartId = (req) => String(req.get("X-Cart-Id") || "anonymous").slice(0, 64);

// Liveness: "is the process alive?" — never depends on the DB.
app.get("/api/healthz", (req, res) => res.json({ status: "alive", replica: HOSTNAME }));

// Readiness: "should this replica receive traffic?" — depends on the DB.
app.get("/api/ready", (req, res) => {
  if (dbReady) return res.json({ status: "ready", replica: HOSTNAME });
  res.status(503).json({ status: "not-ready", reason: "database unreachable", replica: HOSTNAME });
});

app.get("/api/info", (req, res) => {
  res.json({ replica: HOSTNAME, version: APP_VERSION, cartStore: CART_STORE, salePercent: SALE_PERCENT, startedAt: STARTED_AT, chaosEnabled: CHAOS_ENABLED, dbReady });
});

app.get("/api/products", async (req, res) => {
  try {
    const { rows } = await pool.query("SELECT id, sku, name, category, emoji, price_paise, stock FROM products ORDER BY category, name");
    res.json({
      salePercent: SALE_PERCENT,
      products: rows.map((p) => ({ ...p, mrp_paise: p.price_paise, price_paise: price(p.price_paise) })),
    });
  } catch (e) {
    res.status(503).json({ error: "catalog unavailable", detail: e.message });
  }
});

app.get("/api/cart", async (req, res) => {
  try { res.json({ cartId: cartId(req), store: CART_STORE, items: await getCart(cartId(req)) }); }
  catch (e) { res.status(503).json({ error: "cart unavailable", detail: e.message }); }
});

app.post("/api/cart", async (req, res) => {
  const productId = Number(req.body?.productId);
  const qty = Number(req.body?.qty || 1);
  if (!Number.isInteger(productId) || !Number.isInteger(qty) || qty < 1 || qty > 20) {
    return res.status(400).json({ error: "productId and qty (1-20) required" });
  }
  try {
    await addToCart(cartId(req), productId, qty);
    res.status(201).json({ cartId: cartId(req), store: CART_STORE, items: await getCart(cartId(req)) });
  } catch (e) { res.status(503).json({ error: "cart unavailable", detail: e.message }); }
});

app.delete("/api/cart", async (req, res) => {
  try { await clearCart(cartId(req)); res.status(204).end(); }
  catch (e) { res.status(503).json({ error: "cart unavailable", detail: e.message }); }
});

app.post("/api/orders", async (req, res) => {
  const id = cartId(req);
  let client;
  try {
    const items = await getCart(id);
    if (items.length === 0) return res.status(409).json({ error: "cart is empty (on this replica?)", replica: HOSTNAME, store: CART_STORE });
    client = await pool.connect();
    await client.query("BEGIN");
    let total = 0;
    for (const it of items) {
      const { rows } = await client.query("UPDATE products SET stock = stock - $1 WHERE id = $2 AND stock >= $1 RETURNING price_paise", [it.qty, it.productId]);
      if (rows.length === 0) throw Object.assign(new Error(`product ${it.productId} out of stock`), { status: 409 });
      total += price(rows[0].price_paise) * it.qty;
    }
    const { rows: [order] } = await client.query(
      "INSERT INTO orders (cart_id, total_paise, served_by, sale_percent) VALUES ($1, $2, $3, $4) RETURNING id, created_at",
      [id, total, HOSTNAME, SALE_PERCENT]);
    for (const it of items) {
      await client.query("INSERT INTO order_items (order_id, product_id, qty) VALUES ($1, $2, $3)", [order.id, it.productId, it.qty]);
    }
    await client.query("COMMIT");
    await clearCart(id);
    res.status(201).json({ orderId: order.id, totalPaise: total, servedBy: HOSTNAME, createdAt: order.created_at });
  } catch (e) {
    if (client) await client.query("ROLLBACK").catch(() => {});
    res.status(e.status || 503).json({ error: e.message });
  } finally {
    if (client) client.release();
  }
});

app.get("/api/orders/recent", async (req, res) => {
  try {
    const { rows } = await pool.query("SELECT id, total_paise, served_by, sale_percent, created_at FROM orders ORDER BY id DESC LIMIT 10");
    res.json({ orders: rows });
  } catch (e) { res.status(503).json({ error: "orders unavailable", detail: e.message }); }
});

// ---------- Demo-only chaos endpoints ----------
if (CHAOS_ENABLED) {
  app.post("/api/chaos/crash", (req, res) => {
    res.json({ crashing: HOSTNAME });
    console.log("chaos: crashing on request");
    setTimeout(() => process.exit(1), 100);
  });
  app.get("/api/chaos/burn", (req, res) => {
    // Busy-loop CPU for ms milliseconds — drives the Kubernetes HPA demo.
    const ms = Math.min(Number(req.query.ms || 200), 2000);
    const end = Date.now() + ms;
    let x = 0; while (Date.now() < end) { x += Math.sqrt(x + 1); }
    res.json({ burnedMs: ms, replica: HOSTNAME });
  });
}

app.use("/api", (req, res) => res.status(404).json({ error: "not found" }));

// ---------- start + graceful shutdown ----------
const server = app.listen(PORT, () => console.log(`freshcart-api ${APP_VERSION} on :${PORT} replica=${HOSTNAME} cart=${CART_STORE} sale=${SALE_PERCENT}%`));
waitForDb();
initCartStore().catch((e) => console.error("cart store init failed:", e.message));

function shutdown(sig) {
  // docker stop / kubectl delete send SIGTERM; finish in-flight requests, then exit.
  console.log(`${sig} received — draining`);
  server.close(async () => {
    await pool.end().catch(() => {});
    if (redis) await redis.quit().catch(() => {});
    process.exit(0);
  });
  setTimeout(() => process.exit(0), 8000).unref();
}
process.on("SIGTERM", () => shutdown("SIGTERM"));
process.on("SIGINT", () => shutdown("SIGINT"));
