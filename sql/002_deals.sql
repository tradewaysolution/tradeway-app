create table service_catalog (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  basis text not null default 'fixed' check (basis in ('fixed', 'per_mark', 'per_sticker')),
  cost_rate numeric not null default 0,
  sale_rate numeric not null default 0,
  sort integer not null default 0
);
create table deals (
  id uuid primary key default gen_random_uuid(),
  client_id uuid references clients(id),
  title text not null,
  status text not null default 'draft' check (status in ('draft', 'active', 'done')),
  qty_marks integer not null default 0,
  qty_stickers integer not null default 0,
  pallets integer,
  tax_rate numeric not null default 0.18,
  final_price numeric,
  notes text,
  created_at timestamptz not null default now()
);
create table deal_lines (
  id uuid primary key default gen_random_uuid(),
  deal_id uuid not null references deals(id) on delete cascade,
  name text not null,
  basis text not null default 'fixed' check (basis in ('fixed', 'per_mark', 'per_sticker')),
  cost_rate numeric,
  sale_rate numeric,
  unconfirmed boolean not null default false,
  sort integer not null default 0
);
alter table trips add column deal_id uuid references deals(id);

-- Индексы: быстрый поиск строк по сделке, сделок по клиенту, рейсов по сделке
create index deals_client_id_idx on deals (client_id);
create index deal_lines_deal_id_idx on deal_lines (deal_id);
create index trips_deal_id_idx on trips (deal_id);

-- Доступ только для вошедших пользователей; без входа таблицы выглядят пустыми
alter table service_catalog enable row level security;
alter table deals enable row level security;
alter table deal_lines enable row level security;

create policy "authenticated full access" on service_catalog
  for all to authenticated using (true) with check (true);
create policy "authenticated full access" on deals
  for all to authenticated using (true) with check (true);
create policy "authenticated full access" on deal_lines
  for all to authenticated using (true) with check (true);
