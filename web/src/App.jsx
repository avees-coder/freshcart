import { useCallback, useEffect, useMemo, useState } from "react";
import { api, rupees } from "./api.js";

const WEB_VERSION = import.meta.env.VITE_APP_VERSION || "dev";

export default function App() {
  const [products, setProducts] = useState([]);
  const [sale, setSale] = useState(0);
  const [category, setCategory] = useState("All");
  const [cart, setCart] = useState({ items: [], from: "", store: "" });
  const [info, setInfo] = useState(null);
  const [lastWeb, setLastWeb] = useState("");
  const [toast, setToast] = useState("");
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);

  const flash = (msg) => { setToast(msg); setTimeout(() => setToast(""), 3500); };

  const loadCatalog = useCallback(async () => {
    const r = await api.products();
    setLastWeb(r.meta.webReplica);
    if (!r.ok) { setError(r.body?.error || "Catalog unavailable"); return; }
    setError("");
    setProducts(r.body.products);
    setSale(r.body.salePercent);
  }, []);

  const loadCart = useCallback(async () => {
    const r = await api.cart();
    if (r.ok) setCart({ items: r.body.items, from: r.meta.apiReplica, store: r.body.store });
  }, []);

  const loadInfo = useCallback(async () => {
    const r = await api.info();
    if (r.ok) setInfo(r.body);
  }, []);

  useEffect(() => { loadCatalog(); loadCart(); loadInfo(); }, [loadCatalog, loadCart, loadInfo]);

  const categories = useMemo(() => ["All", ...new Set(products.map((p) => p.category))], [products]);
  const byId = useMemo(() => Object.fromEntries(products.map((p) => [p.id, p])), [products]);
  const shown = category === "All" ? products : products.filter((p) => p.category === category);

  const cartLines = cart.items.filter((i) => byId[i.productId]);
  const total = cartLines.reduce((s, i) => s + byId[i.productId].price_paise * i.qty, 0);
  const count = cartLines.reduce((s, i) => s + i.qty, 0);

  async function add(p) {
    const r = await api.add(p.id, 1);
    if (!r.ok) { flash(r.body?.error || "Could not add"); return; }
    flash(`Added ${p.name} — saved on API replica ${r.meta.apiReplica}`);
    // Re-read the cart with a NEW request. With CART_STORE=memory and >1 replica,
    // this request may land on a different replica — and the cart looks empty.
    await loadCart();
  }

  async function placeOrder() {
    setBusy(true);
    const r = await api.order();
    setBusy(false);
    if (!r.ok) { flash(`Order failed: ${r.body?.error} (replica ${r.meta.apiReplica})`); await loadCart(); return; }
    flash(`Order #${r.body.orderId} placed — ${rupees(r.body.totalPaise)} via replica ${r.body.servedBy}`);
    await Promise.all([loadCart(), loadCatalog()]);
  }

  return (
    <div className="page">
      <header className="topbar">
        <div className="brand"><span className="logo">🛒</span> FreshCart</div>
        <div className="eta">Delivery in <b>10 minutes</b></div>
        <div className="cart-pill">{count} items · {rupees(total)}</div>
      </header>

      {sale > 0 && <div className="sale">🎉 Festive Sale — {sale}% off everything, today only</div>}
      {error && <div className="error">⚠️ {error}. The API may still be waiting for its database — refresh in a few seconds.</div>}

      <main className="layout">
        <section>
          <nav className="chips">
            {categories.map((c) => (
              <button key={c} className={c === category ? "chip on" : "chip"} onClick={() => setCategory(c)}>{c}</button>
            ))}
          </nav>
          <div className="grid">
            {shown.map((p) => (
              <article key={p.id} className="card">
                <div className="emoji">{p.emoji}</div>
                <div className="name">{p.name}</div>
                <div className="price">
                  {rupees(p.price_paise)}
                  {p.mrp_paise !== p.price_paise && <s>{rupees(p.mrp_paise)}</s>}
                </div>
                <div className="stock">{p.stock > 0 ? `${p.stock} in stock` : "Out of stock"}</div>
                <button disabled={p.stock <= 0} onClick={() => add(p)}>Add</button>
              </article>
            ))}
          </div>
        </section>

        <aside className="cart">
          <h2>Your cart</h2>
          <div className="muted">Loaded from API replica <code>{cart.from || "…"}</code> · store: <code>{cart.store || "…"}</code></div>
          {cartLines.length === 0 && <p className="muted">Cart is empty.</p>}
          {cartLines.map((i) => (
            <div key={i.productId} className="line">
              <span>{byId[i.productId].emoji} {byId[i.productId].name} × {i.qty}</span>
              <span>{rupees(byId[i.productId].price_paise * i.qty)}</span>
            </div>
          ))}
          <div className="line total"><span>Total</span><span>{rupees(total)}</span></div>
          <button className="primary" disabled={busy || cartLines.length === 0} onClick={placeOrder}>{busy ? "Placing…" : "Place order"}</button>
          <button className="link" onClick={async () => { await api.clear(); loadCart(); }}>Clear cart</button>
          <button className="link" onClick={loadCart}>Reload cart</button>
        </aside>
      </main>

      <OpsPanel info={info} lastWeb={lastWeb} refreshInfo={loadInfo} />

      {toast && <div className="toast">{toast}</div>}
    </div>
  );
}

// ---------------------------------------------------------------------------
// The classroom panel: makes the orchestrator's work visible in the browser.
function OpsPanel({ info, lastWeb, refreshInfo }) {
  const [open, setOpen] = useState(true);
  const [tally, setTally] = useState(null);
  const [orders, setOrders] = useState([]);
  const [sampling, setSampling] = useState(false);

  async function sample() {
    setSampling(true);
    const web = {}, apiR = {}, versions = {};
    for (let i = 0; i < 20; i++) {
      const r = await api.info();
      web[r.meta.webReplica] = (web[r.meta.webReplica] || 0) + 1;
      apiR[r.meta.apiReplica] = (apiR[r.meta.apiReplica] || 0) + 1;
      const v = r.ok ? `${r.body.version} · sale ${r.body.salePercent}% · cart ${r.body.cartStore}` : `HTTP ${r.meta.status}`;
      versions[v] = (versions[v] || 0) + 1;
    }
    setTally({ web, api: apiR, versions });
    setSampling(false);
    refreshInfo();
  }

  async function loadOrders() {
    const r = await api.recentOrders();
    if (r.ok) setOrders(r.body.orders);
  }

  async function crash() {
    const r = await api.crash();
    alert(r.ok ? `Replica ${r.body.crashing} is crashing. Watch the orchestrator replace it.` : "Chaos endpoints are disabled (CHAOS_ENABLED=false).");
  }

  return (
    <section className="ops">
      <div className="ops-head" onClick={() => setOpen(!open)}>
        <b>🔧 Ops panel</b> <span className="muted">(classroom view — what the orchestrator is doing)</span>
        <span className="right">{open ? "hide" : "show"}</span>
      </div>
      {open && (
        <div className="ops-body">
          <div className="kv">
            <div><span>Web replica (nginx)</span><code>{lastWeb || "…"}</code></div>
            <div><span>API replica</span><code>{info?.replica || "…"}</code></div>
            <div><span>API version</span><code>{info?.version || "…"}</code></div>
            <div><span>Web build</span><code>{WEB_VERSION}</code></div>
            <div><span>Cart store</span><code>{info?.cartStore || "…"}</code></div>
            <div><span>Sale</span><code>{info ? `${info.salePercent}%` : "…"}</code></div>
          </div>
          <div className="ops-actions">
            <button onClick={sample} disabled={sampling}>{sampling ? "Sampling…" : "Send 20 requests"}</button>
            <button onClick={loadOrders}>Recent orders</button>
            {info?.chaosEnabled && <button className="danger" onClick={crash}>Crash one API replica</button>}
          </div>
          {tally && (
            <div className="tallies">
              <Tally title="Answered by web replica" data={tally.web} />
              <Tally title="Answered by API replica" data={tally.api} />
              <Tally title="Version seen" data={tally.versions} />
            </div>
          )}
          {orders.length > 0 && (
            <table className="orders">
              <thead><tr><th>#</th><th>Total</th><th>Sale</th><th>API replica</th><th>Time</th></tr></thead>
              <tbody>
                {orders.map((o) => (
                  <tr key={o.id}><td>{o.id}</td><td>{rupees(o.total_paise)}</td><td>{o.sale_percent}%</td><td><code>{o.served_by}</code></td><td>{new Date(o.created_at).toLocaleTimeString()}</td></tr>
                ))}
              </tbody>
            </table>
          )}
        </div>
      )}
    </section>
  );
}

function Tally({ title, data }) {
  const max = Math.max(...Object.values(data));
  return (
    <div className="tally">
      <div className="tally-title">{title}</div>
      {Object.entries(data).map(([k, v]) => (
        <div key={k} className="bar-row">
          <code className="bar-label">{k}</code>
          <div className="bar"><div style={{ width: `${(v / max) * 100}%` }} /></div>
          <span className="bar-n">{v}</span>
        </div>
      ))}
    </div>
  );
}
