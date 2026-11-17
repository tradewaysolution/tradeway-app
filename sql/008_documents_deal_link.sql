-- 008: документ можно привязать к заказу с расчётом без рейса.
-- Раньше поле trip_id было обязательным, поэтому документы заказов с расчётом не сохранялись.
-- Теперь обязательно одно из двух: рейс (trip_id) или заказ (deal_id). Данные не меняются.
-- Можно запускать повторно.
alter table documents alter column trip_id drop not null;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'documents_trip_or_deal') then
    alter table documents add constraint documents_trip_or_deal check (trip_id is not null or deal_id is not null);
  end if;
end $$;
