-- =============================================================================
-- Menu digital CNB: segurança (RLS), permissões, tempo real e configuração inicial
-- Regra: ninguém escreve nas tabelas directamente; tudo passa por menu_api (security definer).
-- A equipa do restaurante pode LER as tabelas de movimento para receber os avisos em tempo real.
-- =============================================================================

do $$ declare t text; begin
  foreach t in array array['menu_config','menu_mesas','menu_artigos','menu_extra','menu_destaques','menu_regras','menu_turnos','menu_pedidos','menu_linhas',
    'menu_chamadas','menu_sugestoes','menu_cruzamento','menu_cartao','menu_brindes','menu_promocoes','menu_brindes_entregues','menu_avaliacoes','menu_supervisor','menu_presenca'] loop
    execute format('alter table %I enable row level security', t);
    execute format('revoke all on %I from anon, authenticated', t);
  end loop;
end $$;

create or replace function fn_e_equipa_menu() returns boolean language sql stable security definer set search_path = public, extensions as $$
  select exists (select 1 from staff where auth_user_id = auth.uid() and activo and menu_perfil is not null);
$$;

-- leitura para os avisos em tempo real (pedidos, linhas, chamadas, mesas, supervisor, turnos)
do $$ declare t text; begin
  foreach t in array array['menu_pedidos','menu_chamadas','menu_mesas','menu_supervisor','menu_turnos','menu_linhas'] loop
    execute format('grant select on %I to authenticated', t);
    execute format('drop policy if exists %I on %I', t || '_ler', t);
    execute format('create policy %I on %I for select to authenticated using (fn_e_equipa_menu())', t || '_ler', t);
  end loop;
end $$;

-- funções: só menu_api e as da entrada ficam abertas; tudo o resto é interno
do $$ declare f record; begin
  for f in select p.oid::regprocedure sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and (p.proname like 'menu\_%' or p.proname in ('fn_eu', 'fn_entrada_nomes', 'fn_entrada_verificar', 'fn_meus_acessos', 'fn_entrada_turno', 'fn_e_equipa_menu')) loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
  end loop;
end $$;
grant execute on function menu_api(text, jsonb) to anon, authenticated;
grant execute on function fn_entrada_nomes() to anon, authenticated;
grant execute on function fn_meus_acessos() to authenticated;
grant execute on function fn_entrada_turno() to authenticated;
grant execute on function fn_e_equipa_menu() to authenticated;
grant execute on function fn_entrada_verificar(text, text) to service_role;
grant execute on function menu_sincronizar_referencias() to service_role;
grant select, insert, update, delete on menu_artigos, menu_extra, menu_cruzamento to service_role;
grant select on menu_config, menu_pedidos, menu_linhas, menu_mesas to service_role;
grant select, update on staff to service_role;

-- avisos em tempo real nas páginas da equipa
do $$ declare t text; begin
  foreach t in array array['menu_pedidos','menu_chamadas','menu_mesas','menu_supervisor','menu_turnos'] loop
    begin execute format('alter publication supabase_realtime add table %I', t); exception when duplicate_object then null; end;
  end loop;
end $$;

-- configuração inicial (só o que ainda não existe; a importação da folha substitui estes valores)
insert into menu_config (chave, valor, nota) values
  ('nome_restaurante', 'Requinte Wine Restaurante', ''), ('nome_clube', 'Clube Náutico da Beira', ''),
  ('url_app', 'https://requintemoz.github.io/menu-cnb/', 'Endereço das páginas'),
  ('loyverse_store_id', '8fd1d2a4-9296-4204-a47a-991bb7ccaa79', 'Loja Clube Nautico da Beira no Loyverse'),
  ('dia_comeca_as', '06:00', 'Hora a que começa o dia operacional'),
  ('limite_aceitar_min', '2', ''), ('limite_registar_min', '5', ''), ('limite_chamada_min', '3', ''), ('limite_entregar_min', '20', ''),
  ('modo_registo', 'central', 'central: pedidos lançados no Loyverse por quem regista; vazio: cada garçom lança os seus'),
  ('mod_obrigatorio', 'Ponto da carne|Tipo de chá', 'grupos de modificadores que o cliente tem de escolher'),
  ('mod_escolha_unica', 'Temperatura|Como servir', 'grupos de modificadores de uma só opção'),
  ('esconder_sem_stock_categorias', 'Vinho Tinto|Vinho Branco e Rosé|Espumantes e Champanhes', 'categorias escondidas quando o stock é 0'),
  ('texto_boas_vindas', 'Bem-vindo. Peça daqui ou chame o garçom quando quiser.', ''),
  ('texto_boas_vindas_en', 'Welcome. Order from here or call the waiter whenever you like.', ''),
  ('texto_garcom_vem', 'O seu garçom já vem.', ''), ('texto_indisponivel', 'Desculpe, este artigo esgotou. O garçom vai propor-lhe uma alternativa.', ''),
  ('link_avaliacao_google', 'https://search.google.com/local/writereview?placeid=ChIJ9y6JsQ9AKh8R-BHwmpiaZTs', ''),
  ('link_instagram', 'https://www.instagram.com/requintegroup/', ''),
  ('texto_agradecimento', 'Foi um prazer recebê-lo no Requinte. Volte sempre!', ''),
  ('whatsapp_msg_brinde', 'Olá {nome}! O seu Cartão Requinte tem um brinde à sua espera: {brinde}. Basta mostrar o cartão no telemóvel na próxima visita. Até breve no Requinte, Clube Náutico da Beira.', '{nome} {brinde} {falta}'),
  ('whatsapp_msg_saudade', 'Olá {nome}! Há algum tempo que não o vemos no Requinte. Temos novidades no menu e a vista de sempre. Esperamos por si!', ''),
  ('whatsapp_msg_geral', 'Olá {nome}! ', ''), ('fid_dias_sem_visita', '30', ''), ('fid_pontos_por_valor', 'nao', ''),
  ('brinde_aniversario', 'Uma sobremesa à escolha', 'vazio = sem brinde de aniversário')
on conflict (chave) do nothing;
insert into menu_promocoes (id, nome, artigos, categorias, quantidade, brinde) values
  ('slush', 'Slush', 'Slush*', '', 10, 'Um slush à escolha'), ('sobremesas', 'Sobremesas', '', 'Sobremesas', 5, 'Uma sobremesa à escolha')
on conflict (id) do nothing;
