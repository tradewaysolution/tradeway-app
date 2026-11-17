-- 007: загрузка документов рейса прямо из CRM на Google Диск
-- Документ теперь можно привязать и к рейсу (trip_id), и к заказу с расчётом (deal_id).
alter table documents add column if not exists deal_id uuid references deals(id) on delete cascade;
alter table documents add column if not exists drive_file_id text;
create index if not exists documents_deal_id_idx on documents (deal_id);

-- Настройки сайта (адрес и пароль загрузчика на Диск). Видны только после входа.
create table if not exists app_settings (
  key text primary key,
  value text not null
);
alter table app_settings enable row level security;
drop policy if exists "authenticated full access" on app_settings;
create policy "authenticated full access" on app_settings
  for all to authenticated using (true) with check (true);

-- После запуска этого файла добавить две строки (значения не хранить в репозитории!):
-- insert into app_settings (key, value) values
--   ('docs_upload_url', '<адрес веб-приложения Apps Script>'),
--   ('docs_upload_secret', '<пароль из свойств скрипта SECRET>');
