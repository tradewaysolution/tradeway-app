-- Даты и компания у расчётов сделок. Можно запускать повторно: уже существующие поля не трогаются.
alter table deals add column if not exists start_date date;
alter table deals add column if not exists end_date date;
alter table deals add column if not exists company text;
