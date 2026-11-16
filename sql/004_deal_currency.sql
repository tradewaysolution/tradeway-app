-- Валюта сделки и курс к евро (сумма × fx_to_eur = сумма в евро). Уже добавлено в базу; файл для истории, повторный запуск безопасен.
alter table deals add column if not exists currency text not null default 'EUR';
alter table deals add column if not exists fx_to_eur numeric not null default 1;
