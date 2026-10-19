// Thin client for the FreshCart API. Relative URLs only: the same build runs
// under Vite (dev proxy), Docker Compose, Swarm and Kubernetes unchanged.

function cartId() {
  let id = localStorage.getItem("freshcart-cart-id");
  if (!id) {
    id = "c-" + Math.random().toString(36).slice(2, 10);
    localStorage.setItem("freshcart-cart-id", id);
  }
  return id;
}

async function call(path, options = {}) {
  const res = await fetch(path, {
    ...options,
    headers: { "Content-Type": "application/json", "X-Cart-Id": cartId(), ...(options.headers || {}) },
  });
  const meta = {
    status: res.status,
    webReplica: res.headers.get("X-Served-By") || "vite-dev",
    apiReplica: res.headers.get("X-Api-Replica") || "?",
  };
  let body = null;
  if (res.status !== 204) {
    try { body = await res.json(); } catch { body = { error: `non-JSON response (${res.status})` }; }
  }
  return { ok: res.ok, body, meta };
}

export const api = {
  cartId,
  info: () => call("/api/info"),
  products: () => call("/api/products"),
  cart: () => call("/api/cart"),
  add: (productId, qty = 1) => call("/api/cart", { method: "POST", body: JSON.stringify({ productId, qty }) }),
  clear: () => call("/api/cart", { method: "DELETE" }),
  order: () => call("/api/orders", { method: "POST" }),
  recentOrders: () => call("/api/orders/recent"),
  crash: () => call("/api/chaos/crash", { method: "POST" }),
};

export const rupees = (paise) => {
  const d = paise % 100 === 0 ? 0 : 2;
  return "₹" + (paise / 100).toLocaleString("en-IN", { minimumFractionDigits: d, maximumFractionDigits: d });
};
