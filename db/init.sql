-- FreshCart seed data (runs once, on an EMPTY data directory only)
CREATE TABLE IF NOT EXISTS products (
  id          SERIAL PRIMARY KEY,
  sku         TEXT UNIQUE NOT NULL,
  name        TEXT NOT NULL,
  category    TEXT NOT NULL,
  emoji       TEXT NOT NULL,
  price_paise INTEGER NOT NULL CHECK (price_paise > 0),
  stock       INTEGER NOT NULL CHECK (stock >= 0)
);

CREATE TABLE IF NOT EXISTS orders (
  id           SERIAL PRIMARY KEY,
  cart_id      TEXT NOT NULL,
  total_paise  INTEGER NOT NULL,
  served_by    TEXT NOT NULL,          -- which API replica took the order
  sale_percent INTEGER NOT NULL DEFAULT 0,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS order_items (
  order_id   INTEGER NOT NULL REFERENCES orders(id),
  product_id INTEGER NOT NULL REFERENCES products(id),
  qty        INTEGER NOT NULL CHECK (qty > 0)
);

INSERT INTO products (sku, name, category, emoji, price_paise, stock) VALUES
  ('FRU-BAN-6',  'Bananas (6 pcs)',          'Fruits & Veg', '🍌',  4900, 400),
  ('FRU-APL-4',  'Shimla Apples (4 pcs)',    'Fruits & Veg', '🍎', 15900, 250),
  ('VEG-ONI-1K', 'Onions 1 kg',              'Fruits & Veg', '🧅',  4500, 500),
  ('VEG-TOM-5H', 'Tomatoes 500 g',           'Fruits & Veg', '🍅',  3200, 500),
  ('DAI-MLK-1L', 'Toned Milk 1 L',           'Dairy',        '🥛',  6800, 800),
  ('DAI-PNR-2H', 'Paneer 200 g',             'Dairy',        '🧀',  9500, 300),
  ('DAI-CRD-4H', 'Curd 400 g',               'Dairy',        '🥣',  5000, 300),
  ('STP-ATA-5K', 'Whole Wheat Atta 5 kg',    'Staples',      '🌾', 28900, 150),
  ('STP-RIC-1K', 'Basmati Rice 1 kg',        'Staples',      '🍚', 14900, 200),
  ('STP-DAL-1K', 'Toor Dal 1 kg',            'Staples',      '🫘', 17900, 200),
  ('SNK-CHP-1',  'Masala Chips 90 g',        'Snacks',       '🥔',  2000, 600),
  ('BEV-TEA-25', 'Assam Tea 250 g',          'Beverages',    '🍵', 14000, 200)
ON CONFLICT (sku) DO NOTHING;
