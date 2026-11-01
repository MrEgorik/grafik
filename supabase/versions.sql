-- Совместная работа: номер версии у каждого документа и сохранение «только если не изменилось».
alter table public.docs add column if not exists version bigint not null default 1;

create or replace function public.docs_bump_version() returns trigger
language plpgsql as $$
begin
  if tg_op = 'INSERT' then new.version := 1; else new.version := coalesce(old.version, 0) + 1; end if;
  new.updated_at := now();
  return new;
end $$;
drop trigger if exists docs_bump_version on public.docs;
create trigger docs_bump_version before insert or update on public.docs
  for each row execute function public.docs_bump_version();

-- Сохранить документ, если его версия всё ещё base. Иначе вернуть текущую версию и данные,
-- чтобы программа объединила правки. Работает с правами пользователя (правила доступа действуют).
create or replace function public.save_doc(p text, d jsonb, base bigint) returns json
language plpgsql security invoker set search_path = public as $$
declare cur public.docs%rowtype; n int;
begin
  if d is null then
    if base is null then delete from public.docs where path = p;
    else delete from public.docs where path = p and version = base; end if;
    get diagnostics n = row_count;
    if n > 0 or not exists (select 1 from public.docs where path = p) then
      return json_build_object('ok', true, 'version', null);
    end if;
  elsif base is null then
    insert into public.docs (path, data, updated_by) values (p, d, auth.uid()) on conflict (path) do nothing;
    get diagnostics n = row_count;
    if n > 0 then return json_build_object('ok', true, 'version', 1); end if;
  else
    update public.docs set data = d, updated_by = auth.uid() where path = p and version = base;
    get diagnostics n = row_count;
    if n > 0 then return json_build_object('ok', true, 'version', base + 1); end if;
  end if;
  select * into cur from public.docs where path = p;
  if not found then
    if d is not null then
      insert into public.docs (path, data, updated_by) values (p, d, auth.uid()) on conflict (path) do nothing;
      get diagnostics n = row_count;
      if n > 0 then return json_build_object('ok', true, 'version', 1); end if;
    end if;
    return json_build_object('ok', false, 'denied', true);
  end if;
  return json_build_object('ok', false, 'version', cur.version, 'data', cur.data, 'by', cur.updated_by);
end $$;
grant execute on function public.save_doc(text, jsonb, bigint) to authenticated;
