-- Контрагент по умолчанию у услуги каталога: при добавлении услуги в заказ он подставляется сам.
-- Можно запускать повторно. Данные не меняются: какой контрагент у какой услуги, задаётся отдельно.
alter table service_catalog add column if not exists carrier_id uuid references carriers(id);
