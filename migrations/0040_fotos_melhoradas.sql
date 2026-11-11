-- =============================================================================
-- Fotografias melhoradas (recortadas a 4:5, endireitadas, com a identificação da Requinte), publicadas no site do menu
-- em fotos/<sku>.jpg e fotos/<sku>-mini.jpg. O link anterior (Google Drive) fica guardado em foto_original.
-- =============================================================================
alter table menu_extra add column if not exists foto_original text;
update menu_extra e set foto_original = e.foto_url, foto_url = 'https://requintemoz.github.io/menu-cnb/fotos/' || a.sku || '.jpg'
  from menu_artigos a
  where a.item_id = e.item_id and e.foto_url like '%drive.google%'
    and a.sku in ('11622','11623','11624','11629','11630','11631','11834','11865','11867','11870','11903','11905','11921');
