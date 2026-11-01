-- Полная схема базы «График ассистентов» (для нового проекта Supabase).
-- Порядок: 1) Authentication → Users → Add user (с галочкой Auto Confirm User),
--          2) запустить этот файл целиком в SQL Editor.
-- Скрипт можно запускать повторно — он ничего не задваивает.

-- ===== данные программы =====
create table if not exists public.docs (
  path text primary key,
  data jsonb not null,
  updated_at timestamptz not null default now(),
  updated_by uuid default auth.uid()
);
alter table public.docs enable row level security;
do $$ begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'docs') then
    alter publication supabase_realtime add table public.docs;
  end if;
end $$;

-- ===== организации и участники =====
create table if not exists public.orgs (
  id text primary key,
  name text not null,
  code text not null unique,
  created_at timestamptz not null default now()
);
alter table public.orgs enable row level security;

create table if not exists public.members (
  user_id uuid primary key references auth.users(id) on delete cascade,
  login text not null,
  name text,
  role text not null default 'pending',
  created_at timestamptz not null default now()
);
alter table public.members enable row level security;
alter table public.members add column if not exists card_id text;
alter table public.members add column if not exists org_id text references public.orgs(id) on delete set null;
alter table public.members drop constraint if exists members_role_check;
alter table public.members add constraint members_role_check
  check (role in ('pending','owner','admin','assistant','doctor','blocked'));

-- ===== служебные функции =====
create or replace function public.my_role() returns text
language sql stable security definer set search_path = public as $$
  select role from public.members where user_id = auth.uid() $$;
create or replace function public.my_card() returns text
language sql stable security definer set search_path = public as $$
  select card_id from public.members where user_id = auth.uid() $$;
create or replace function public.my_org() returns text
language sql stable security definer set search_path = public as $$
  select org_id from public.members where user_id = auth.uid() $$;
create or replace function public.is_owner() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.members where user_id = auth.uid() and role = 'owner') $$;
create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.members where user_id = auth.uid() and role in ('admin','owner')) $$;
create or replace function public.can_admin(o text) returns boolean
language sql stable security definer set search_path = public as $$
  select public.is_owner() or exists (
    select 1 from public.members where user_id = auth.uid() and role = 'admin' and org_id = o) $$;

-- ===== приглашения =====
create table if not exists public.invites (
  token text primary key,
  org_id text not null references public.orgs(id) on delete cascade,
  role text not null check (role in ('admin','assistant','doctor')),
  card_id text,
  card_name text,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '14 days',
  used_by uuid,
  used_at timestamptz
);
alter table public.invites enable row level security;

create or replace function public.invite_info(t text) returns json
language sql stable security definer set search_path = public as $$
  select json_build_object('org', o.name, 'role', i.role, 'card_name', i.card_name)
  from public.invites i join public.orgs o on o.id = i.org_id
  where i.token = t and i.used_by is null and i.expires_at > now() $$;
grant execute on function public.invite_info(text) to anon, authenticated;

-- ===== регистрация =====
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  o text;
  inv public.invites%rowtype;
  nm text := nullif(trim(coalesce(new.raw_user_meta_data->>'name', '')), '');
  k text;
begin
  update public.invites set used_by = new.id, used_at = now()
   where token = coalesce(new.raw_user_meta_data->>'invite', '')
     and used_by is null and expires_at > now()
  returning * into inv;
  if found then
    insert into public.members (user_id, login, name, role, org_id, card_id)
    values (new.id, split_part(new.email, '@', 1), coalesce(nm, ''), inv.role, inv.org_id, inv.card_id)
    on conflict (user_id) do nothing;
    if nm is not null and inv.card_id is not null and inv.role in ('assistant', 'doctor') then
      k := case inv.role when 'assistant' then 'assistants' else 'doctors' end;
      update public.docs
         set data = jsonb_set(data, array[k], (
               select coalesce(jsonb_agg(
                        case when el->>'id' = inv.card_id then jsonb_set(el, '{name}', to_jsonb(nm)) else el end
                        order by ord), '[]'::jsonb)
               from jsonb_array_elements(data->k) with ordinality t(el, ord))),
             updated_at = now()
       where path = inv.org_id || ':cfg/main' and jsonb_typeof(data->k) = 'array';
    end if;
  else
    select id into o from public.orgs
     where code = upper(trim(coalesce(new.raw_user_meta_data->>'code', '')));
    insert into public.members (user_id, login, name, role, org_id)
    values (new.id, split_part(new.email, '@', 1), coalesce(nm, ''), 'pending', o)
    on conflict (user_id) do nothing;
  end if;
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- ===== правила доступа =====
drop policy if exists "Организации: чтение" on public.orgs;
drop policy if exists "Организации: создание" on public.orgs;
drop policy if exists "Организации: изменение" on public.orgs;
create policy "Организации: чтение" on public.orgs for select to authenticated
  using (public.is_owner() or id = public.my_org());
create policy "Организации: создание" on public.orgs for insert to authenticated
  with check (public.is_owner());
create policy "Организации: изменение" on public.orgs for update to authenticated
  using (public.is_owner()) with check (public.is_owner());

drop policy if exists "Участники: чтение" on public.members;
drop policy if exists "Участники: изменение" on public.members;
create policy "Участники: чтение" on public.members for select to authenticated
  using (user_id = auth.uid() or public.is_owner()
         or (org_id is not null and public.can_admin(org_id)));
create policy "Участники: изменение" on public.members for update to authenticated
  using (public.is_owner() or (org_id is not null and public.can_admin(org_id) and role <> 'owner'))
  with check (public.is_owner() or (role <> 'owner' and org_id = public.my_org() and public.can_admin(org_id)));

drop policy if exists "Приглашения: чтение" on public.invites;
drop policy if exists "Приглашения: создание" on public.invites;
drop policy if exists "Приглашения: удаление" on public.invites;
create policy "Приглашения: чтение" on public.invites for select to authenticated using (public.can_admin(org_id));
create policy "Приглашения: создание" on public.invites for insert to authenticated with check (public.can_admin(org_id));
create policy "Приглашения: удаление" on public.invites for delete to authenticated using (public.can_admin(org_id));

drop policy if exists "Орг: чтение" on public.docs;
drop policy if exists "Орг: добавление" on public.docs;
drop policy if exists "Орг: изменение" on public.docs;
drop policy if exists "Орг: удаление" on public.docs;
create policy "Орг: чтение" on public.docs for select to authenticated using (
  public.can_admin(split_part(path, ':', 1))
  or (split_part(path, ':', 1) = public.my_org() and (
       (public.my_role() in ('assistant','doctor')
         and (split_part(path, ':', 2) = 'cfg/main' or split_part(path, ':', 2) like 'pub/%'))
    or (public.my_role() = 'assistant' and split_part(path, ':', 2) = 'avail/' || public.my_card())))
);
create policy "Орг: добавление" on public.docs for insert to authenticated with check (
  public.can_admin(split_part(path, ':', 1))
  or (split_part(path, ':', 1) = public.my_org() and public.my_role() = 'assistant'
      and split_part(path, ':', 2) = 'avail/' || public.my_card())
);
create policy "Орг: изменение" on public.docs for update to authenticated
  using (public.can_admin(split_part(path, ':', 1))
    or (split_part(path, ':', 1) = public.my_org() and public.my_role() = 'assistant'
        and split_part(path, ':', 2) = 'avail/' || public.my_card()))
  with check (public.can_admin(split_part(path, ':', 1))
    or (split_part(path, ':', 1) = public.my_org() and public.my_role() = 'assistant'
        and split_part(path, ':', 2) = 'avail/' || public.my_card()));
create policy "Орг: удаление" on public.docs for delete to authenticated using (
  public.can_admin(split_part(path, ':', 1))
  or (split_part(path, ':', 1) = public.my_org() and public.my_role() = 'assistant'
      and split_part(path, ':', 2) = 'avail/' || public.my_card())
);

-- ===== закрепление дат после дедлайна =====
create or replace function public.guard_avail() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  p text := coalesce(new.path, old.path);
  org text := split_part(p, ':', 1);
  cfg jsonb; c jsonb; d text;
  oldd jsonb := '{}'::jsonb; newd jsonb := '{}'::jsonb;
  today date := (now() at time zone 'Europe/Moscow')::date;
begin
  if split_part(p, ':', 2) not like 'avail/%' or public.can_admin(org) then
    return coalesce(new, old);
  end if;
  if tg_op in ('UPDATE','DELETE') then oldd := coalesce(old.data->'dates', '{}'::jsonb); end if;
  if tg_op in ('INSERT','UPDATE') then newd := coalesce(new.data->'dates', '{}'::jsonb); end if;
  select data into cfg from public.docs where path = org || ':cfg/main';
  for c in select * from jsonb_array_elements(coalesce(cfg->'collect', '[]'::jsonb)) loop
    if today > (c->>'deadline')::date then
      for d in select key from jsonb_each(oldd) union select key from jsonb_each(newd) loop
        if d >= c->>'from' and d <= c->>'to' and (oldd->d) is distinct from (newd->d) then
          raise exception 'Даты с % по % уже закреплены', to_char((c->>'from')::date, 'DD.MM'), to_char((c->>'to')::date, 'DD.MM');
        end if;
      end loop;
    end if;
  end loop;
  return coalesce(new, old);
end $$;
drop trigger if exists guard_avail on public.docs;
create trigger guard_avail before insert or update or delete on public.docs
  for each row execute function public.guard_avail();

-- ===== история изменений (30 дней) =====
create table if not exists public.docs_history (
  id bigserial primary key,
  path text not null,
  data jsonb not null,
  op text not null,
  saved_by uuid,
  saved_at timestamptz not null default now()
);
alter table public.docs_history enable row level security;
create index if not exists docs_history_path_idx on public.docs_history (path, saved_at desc);
create or replace function public.keep_history() returns trigger
language plpgsql security definer set search_path = public as $$
declare last_at timestamptz;
begin
  if tg_op = 'UPDATE' then
    select max(saved_at) into last_at from public.docs_history where path = old.path;
    if last_at is not null and last_at > now() - interval '15 minutes' then return new; end if;
  end if;
  insert into public.docs_history (path, data, op, saved_by) values (old.path, old.data, tg_op, auth.uid());
  delete from public.docs_history where saved_at < now() - interval '30 days';
  return coalesce(new, old);
end $$;
drop trigger if exists keep_history on public.docs;
create trigger keep_history before update or delete on public.docs
  for each row execute function public.keep_history();

-- ===== первая организация и главный администратор (для нового проекта) =====
insert into public.orgs (id, name, code)
values ('test', 'Тестовая клиника', upper(substr(md5(random()::text), 1, 6)))
on conflict (id) do nothing;
insert into public.members (user_id, login, role, org_id)
select id, split_part(email, '@', 1), 'owner', 'test' from auth.users
where not exists (select 1 from public.members where role = 'owner')
on conflict (user_id) do update set role = 'owner', org_id = coalesce(public.members.org_id, 'test');
