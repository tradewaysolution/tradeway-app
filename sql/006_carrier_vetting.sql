-- Модуль «Перевозчики · СБ»: проверки перевозчиков от агента СБ, страховки, документы, оценки рейсов.
-- Запускать целиком в Supabase → SQL Editor. Повторный запуск безопасен: уже созданное не трогается,
-- функция импорта просто обновляется. Существующие данные не меняются (у старых контрагентов статус
-- проверки станет «Не проверен» — это значение по умолчанию).

-- 1. Сводка проверки прямо у контрагента
alter table carriers
  add column if not exists country text,
  add column if not exists reg_code text,              -- ЄДРПОУ / IČO / NIP / VAT
  add column if not exists director text,
  add column if not exists iban text,
  add column if not exists vetting_status text default 'not_checked'
    check (vetting_status in ('not_checked','in_progress','approved','conditional','blocked')),
  add column if not exists vetting_score numeric(3,1) check (vetting_score between 0 and 10),
  add column if not exists vetting_max_level text
    check (vetting_max_level in ('base','standard','enhanced')),
  add column if not exists vetting_conditions text,
  add column if not exists last_checked_at date;

-- 2. Проверки и их пункты
create table if not exists carrier_checks (
  id uuid primary key default gen_random_uuid(),
  org_id uuid,                                   -- на будущее, пока пусто
  carrier_id uuid not null references carriers(id) on delete cascade,
  checked_at date not null default current_date,
  trip_context text,                             -- груз / стоимость / маршрут
  level text check (level in ('base','standard','enhanced')),
  verdict text check (verdict in ('approved','conditional','blocked')),
  score numeric(3,1) check (score between 0 and 10),
  conditions text,
  red_flags text[] default '{}',
  missing text[] default '{}',
  tasks text[] default '{}',                     -- задачи до погрузки
  card_url text,                                 -- карточка в Google Drive
  source text default 'agent',
  raw jsonb,                                     -- исходный JSON от агента
  created_at timestamptz default now()
);

create table if not exists carrier_check_items (
  id uuid primary key default gen_random_uuid(),
  check_id uuid not null references carrier_checks(id) on delete cascade,
  layer smallint check (layer in (1,2,3)),
  title text not null,
  result text check (result in ('pass','warn','fail','not_checked')),
  detail text,
  source text
);

-- 3. Страховки и документы перевозчика (сами файлы — в Google Drive, здесь только ссылки)
create table if not exists carrier_insurance (
  id uuid primary key default gen_random_uuid(),
  carrier_id uuid not null references carriers(id) on delete cascade,
  insurer text,
  policy_type text,                              -- 'cmr_liability' | 'cargo'
  limit_amount numeric,
  currency text,
  franchise_note text,
  exclusions text[] default '{}',
  confirmed_by_insurer boolean default false,
  valid_until date,
  drive_url text,
  created_at timestamptz default now()
);

create table if not exists carrier_documents (
  id uuid primary key default gen_random_uuid(),
  carrier_id uuid not null references carriers(id) on delete cascade,
  doc_type text,                                 -- 'registry_extract','contract','vehicle_reg','license','permit',...
  title text,
  valid_until date,
  drive_url text,
  created_at timestamptz default now()
);

-- 4. Оценка рейса: и для старых рейсов (trips), и для новых заказов (deals)
create table if not exists trip_ratings (
  id uuid primary key default gen_random_uuid(),
  trip_id uuid references trips(id) on delete cascade,
  deal_id uuid references deals(id) on delete cascade,
  carrier_id uuid not null references carriers(id) on delete cascade,
  on_time boolean,
  docs_score smallint check (docs_score between 1 and 5),
  comm_score smallint check (comm_score between 1 and 5),
  claims text,
  created_at timestamptz default now()
);

-- 5. Журнал: заказ сохранён с заблокированным перевозчиком — кто, когда и почему
create table if not exists carrier_overrides (
  id uuid primary key default gen_random_uuid(),
  carrier_id uuid not null references carriers(id) on delete cascade,
  trip_id uuid references trips(id) on delete cascade,
  deal_id uuid references deals(id) on delete cascade,
  reason text not null,
  created_by text default (auth.jwt() ->> 'email'),
  created_at timestamptz default now()
);

-- 6. Груз в заказах: акциз и стоимость (в старых рейсах и в новых заказах)
alter table trips
  add column if not exists cargo_excise boolean default false,
  add column if not exists cargo_value_eur numeric;
alter table deals
  add column if not exists cargo_excise boolean default false,
  add column if not exists cargo_value_eur numeric;

-- Индексы для быстрых выборок по перевозчику
create index if not exists carrier_checks_carrier_idx on carrier_checks (carrier_id, checked_at desc);
create index if not exists carrier_check_items_check_idx on carrier_check_items (check_id);
create index if not exists carrier_insurance_carrier_idx on carrier_insurance (carrier_id);
create index if not exists carrier_documents_carrier_idx on carrier_documents (carrier_id);
create index if not exists trip_ratings_carrier_idx on trip_ratings (carrier_id);
create index if not exists carrier_overrides_carrier_idx on carrier_overrides (carrier_id);
create index if not exists carriers_reg_idx on carriers (country, reg_code);

-- Доступ только для вошедших пользователей, как у остальных таблиц
alter table carrier_checks enable row level security;
alter table carrier_check_items enable row level security;
alter table carrier_insurance enable row level security;
alter table carrier_documents enable row level security;
alter table trip_ratings enable row level security;
alter table carrier_overrides enable row level security;

do $$
declare t text;
begin
  foreach t in array array['carrier_checks','carrier_check_items','carrier_insurance','carrier_documents','trip_ratings','carrier_overrides'] loop
    if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = t and policyname = 'authenticated full access') then
      execute format('create policy "authenticated full access" on %I for all to authenticated using (true) with check (true)', t);
    end if;
  end loop;
end $$;

-- 7. Импорт проверки от агента СБ одной операцией: либо сохраняется всё, либо ничего.
-- Работает с правами вошедшего пользователя (security invoker), поэтому защита таблиц действует как обычно.
create or replace function import_carrier_check(p jsonb) returns jsonb
language plpgsql security invoker set search_path = public as $$
declare
  c jsonb := coalesce(p->'carrier', '{}'::jsonb);
  k jsonb := coalesce(p->'check', '{}'::jsonb);
  v_country text := upper(nullif(trim(c->>'country'), ''));
  v_code text := nullif(regexp_replace(coalesce(c->>'reg_code', ''), '\s', '', 'g'), '');
  v_name text := nullif(trim(c->>'name'), '');
  v_contact text := nullif(concat_ws(', ', nullif(trim(c->>'phone'), ''), nullif(trim(c->>'email'), '')), '');
  v_checked date := coalesce(nullif(k->>'checked_at', '')::date, current_date);
  v_carrier uuid; v_check uuid; v_id uuid; v_created boolean := false; x jsonb;
begin
  if coalesce(p->>'tw_carrier_check', '') <> '1' then raise exception 'Неизвестный формат: нужно поле "tw_carrier_check": 1'; end if;
  if v_name is null or v_country is null or v_code is null then raise exception 'У перевозчика должны быть название, страна и код'; end if;

  select id into v_carrier from carriers where upper(country) = v_country and reg_code = v_code limit 1;
  if v_carrier is null and v_country = 'UA' then
    select id into v_carrier from carriers where edrpou = v_code limit 1;
  end if;

  if v_carrier is null then
    insert into carriers (name, type, currency, country, reg_code, edrpou, director, iban, contact)
    values (v_name, 'carrier', case when v_country = 'UA' then 'UAH' else 'EUR' end, v_country, v_code, case when v_country = 'UA' then v_code end,
            nullif(trim(c->>'director'), ''), nullif(trim(c->>'iban'), ''), v_contact)
    returning id into v_carrier;
    v_created := true;
  else
    update carriers set
      country = coalesce(country, v_country),
      reg_code = coalesce(reg_code, v_code),
      director = coalesce(nullif(trim(c->>'director'), ''), director),
      iban = coalesce(nullif(trim(c->>'iban'), ''), iban),
      contact = coalesce(contact, v_contact)
    where id = v_carrier;
  end if;

  insert into carrier_checks (carrier_id, checked_at, trip_context, level, verdict, score, conditions,
                              red_flags, missing, tasks, card_url, source, raw)
  values (v_carrier, v_checked, nullif(k->>'trip_context', ''), k->>'level', k->>'verdict',
          nullif(k->>'score', '')::numeric, nullif(k->>'conditions', ''),
          array(select jsonb_array_elements_text(coalesce(k->'red_flags', '[]'::jsonb))),
          array(select jsonb_array_elements_text(coalesce(k->'missing', '[]'::jsonb))),
          array(select jsonb_array_elements_text(coalesce(k->'tasks', '[]'::jsonb))),
          nullif(k->>'card_url', ''), 'agent', p)
  returning id into v_check;

  for x in select * from jsonb_array_elements(coalesce(p->'items', '[]'::jsonb)) loop
    insert into carrier_check_items (check_id, layer, title, result, detail, source)
    values (v_check, (x->>'layer')::smallint, x->>'title', x->>'result', nullif(x->>'detail', ''), nullif(x->>'source', ''));
  end loop;

  -- Страховка: тот же страховщик и тип полиса — обновляем, иначе добавляем
  for x in select * from jsonb_array_elements(coalesce(p->'insurance', '[]'::jsonb)) loop
    v_id := null;
    select id into v_id from carrier_insurance
      where carrier_id = v_carrier and coalesce(insurer, '') = coalesce(x->>'insurer', '') and coalesce(policy_type, '') = coalesce(x->>'policy_type', '')
      limit 1;
    if v_id is null then
      insert into carrier_insurance (carrier_id, insurer, policy_type, limit_amount, currency, franchise_note, exclusions, confirmed_by_insurer, valid_until, drive_url)
      values (v_carrier, x->>'insurer', x->>'policy_type', nullif(x->>'limit_amount', '')::numeric, nullif(x->>'currency', ''), nullif(x->>'franchise_note', ''),
              array(select jsonb_array_elements_text(coalesce(x->'exclusions', '[]'::jsonb))),
              coalesce((x->>'confirmed_by_insurer')::boolean, false), nullif(x->>'valid_until', '')::date, nullif(x->>'drive_url', ''));
    else
      update carrier_insurance set
        limit_amount = coalesce(nullif(x->>'limit_amount', '')::numeric, limit_amount),
        currency = coalesce(nullif(x->>'currency', ''), currency),
        franchise_note = coalesce(nullif(x->>'franchise_note', ''), franchise_note),
        exclusions = case when jsonb_typeof(x->'exclusions') = 'array' then array(select jsonb_array_elements_text(x->'exclusions')) else exclusions end,
        confirmed_by_insurer = coalesce((x->>'confirmed_by_insurer')::boolean, confirmed_by_insurer),
        valid_until = coalesce(nullif(x->>'valid_until', '')::date, valid_until),
        drive_url = coalesce(nullif(x->>'drive_url', ''), drive_url)
      where id = v_id;
    end if;
  end loop;

  -- Документы: тот же тип и название — обновляем, иначе добавляем
  for x in select * from jsonb_array_elements(coalesce(p->'documents', '[]'::jsonb)) loop
    v_id := null;
    select id into v_id from carrier_documents
      where carrier_id = v_carrier and coalesce(doc_type, '') = coalesce(x->>'doc_type', '') and coalesce(title, '') = coalesce(x->>'title', '')
      limit 1;
    if v_id is null then
      insert into carrier_documents (carrier_id, doc_type, title, valid_until, drive_url)
      values (v_carrier, x->>'doc_type', x->>'title', nullif(x->>'valid_until', '')::date, nullif(x->>'drive_url', ''));
    else
      update carrier_documents set
        valid_until = coalesce(nullif(x->>'valid_until', '')::date, valid_until),
        drive_url = coalesce(nullif(x->>'drive_url', ''), drive_url)
      where id = v_id;
    end if;
  end loop;

  -- Сводка у перевозчика: только если эта проверка не старее последней
  update carriers set
    vetting_status = k->>'verdict',
    vetting_score = nullif(k->>'score', '')::numeric,
    vetting_max_level = case when k->>'verdict' = 'blocked' then null else k->>'level' end,
    vetting_conditions = nullif(k->>'conditions', ''),
    last_checked_at = v_checked
  where id = v_carrier and (last_checked_at is null or last_checked_at <= v_checked);

  return jsonb_build_object('carrier_id', v_carrier, 'check_id', v_check, 'created', v_created);
end $$;

revoke all on function import_carrier_check(jsonb) from public, anon;
grant execute on function import_carrier_check(jsonb) to authenticated;
