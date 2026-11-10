-- fn_chamar_funcao chama funções do servidor com a chave de serviço: só o agendador (postgres) a pode usar
do $$ begin
  if to_regprocedure('fn_chamar_funcao(text,jsonb)') is not null then revoke all on function fn_chamar_funcao(text, jsonb) from public, anon, authenticated; end if;
  if to_regprocedure('fn_ligar_staff_auth()') is not null then revoke all on function fn_ligar_staff_auth() from public, anon, authenticated; end if;
  if to_regprocedure('fn_mensagem_inserida()') is not null then revoke all on function fn_mensagem_inserida() from public, anon, authenticated; end if;
  if to_regprocedure('fn_importar_pulseiras(jsonb,text,text,boolean)') is not null then revoke all on function fn_importar_pulseiras(jsonb, text, text, boolean) from public, anon; end if;
  if to_regprocedure('fn_marcar_pulseira_inventario(text,text,text)') is not null then revoke all on function fn_marcar_pulseira_inventario(text, text, text) from public, anon; end if;
  if to_regprocedure('fn_resumo_inventario()') is not null then revoke all on function fn_resumo_inventario() from public, anon; end if;
end $$;
alter view menu_v_visiveis set (security_invoker = true);
revoke all on menu_v_visiveis from anon, authenticated;
