-- История изменений: перед каждым изменением или удалением сохраняется прежняя версия.
-- Не чаще раза в 15 минут на документ, хранится 30 дней. Из программы не видна никому.
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
    if last_at is not null and last_at > now() - interval '15 minutes' then
      return new;
    end if;
  end if;
  insert into public.docs_history (path, data, op, saved_by) values (old.path, old.data, tg_op, auth.uid());
  delete from public.docs_history where saved_at < now() - interval '30 days';
  return coalesce(new, old);
end $$;

drop trigger if exists keep_history on public.docs;
create trigger keep_history before update or delete on public.docs
  for each row execute function public.keep_history();
