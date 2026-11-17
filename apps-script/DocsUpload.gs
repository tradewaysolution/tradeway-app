/**
 * TradeWay CRM — загрузчик документов на Google Диск.
 * Отдельный проект Apps Script, запускается от имени владельца Диска.
 *
 * Свойства скрипта (Project Settings → Script properties), в репозиторий НЕ класть:
 *   SECRET   — длинный случайный пароль; тот же пишется в Supabase app_settings.docs_upload_secret
 *   ROOT_ID  — ID папки «TradeWay Docs»
 *
 * Деплой: Deploy → New deployment → Web app, Execute as: Me, Who has access: Anyone.
 *
 * Структура: TradeWay Docs / <Клиент> / <Папка заказа> / файлы
 * Удаление: файл переносится в подпапку «_удалённые» той же папки заказа.
 */
function doPost(e) {
  try {
    var req = JSON.parse(e.postData.contents);
    var props = PropertiesService.getScriptProperties();
    if (!req.secret || req.secret !== props.getProperty('SECRET')) return out_({ok: false, error: 'Нет доступа'});
    if (req.action === 'upload') return out_(upload_(req, props.getProperty('ROOT_ID')));
    if (req.action === 'rename') return out_(rename_(req));
    if (req.action === 'trash') return out_(trash_(req));
    return out_({ok: false, error: 'Неизвестное действие'});
  } catch (err) {
    return out_({ok: false, error: String(err && err.message || err)});
  }
}

function upload_(req, rootId) {
  var root = DriveApp.getFolderById(rootId);
  var client = sub_(root, clean_(req.client) || 'Без клиента');
  var order = sub_(client, clean_(req.folder) || 'Без названия');
  var blob = Utilities.newBlob(Utilities.base64Decode(req.data), req.mime || 'application/octet-stream', clean_(req.name) || 'file');
  var f = order.createFile(blob);
  return {ok: true, id: f.getId(), url: f.getUrl(), name: f.getName(), folderUrl: order.getUrl()};
}

function rename_(req) {
  var f = DriveApp.getFileById(req.id);
  var name = clean_(req.name);
  if (!name) return {ok: false, error: 'Пустое имя'};
  f.setName(name);
  return {ok: true, name: f.getName()};
}

function trash_(req) {
  var f = DriveApp.getFileById(req.id);
  var parents = f.getParents();
  if (!parents.hasNext()) return {ok: false, error: 'Нет папки'};
  var bin = sub_(parents.next(), '_удалённые');
  f.moveTo(bin);
  return {ok: true};
}

function sub_(parent, name) {
  var it = parent.getFoldersByName(name);
  return it.hasNext() ? it.next() : parent.createFolder(name);
}

function clean_(s) {
  return String(s == null ? '' : s).replace(/[\\\/:*?"<>|]/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 150);
}

function out_(obj) {
  return ContentService.createTextOutput(JSON.stringify(obj)).setMimeType(ContentService.MimeType.JSON);
}
