-- Сброс пароля сотруднику ответственным своей организации (или главным администратором).
-- Нельзя сбросить пароль главному администратору и самому себе (для себя — «Сменить пароль»).
create extension if not exists pgcrypto with schema extensions;

create or replace function public.admin_set_password(target uuid, new_password text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare t public.members%rowtype;
begin
  if auth.uid() is null then raise exception 'Нужно войти в программу'; end if;
  if target = auth.uid() then raise exception 'Свой пароль меняйте в «Настройках» → «Сменить пароль»'; end if;
  if length(coalesce(new_password, '')) < 6 then raise exception 'Пароль должен быть не короче 6 символов'; end if;
  select * into t from public.members where user_id = target;
  if not found then raise exception 'Пользователь не найден'; end if;
  if t.role = 'owner' then raise exception 'Пароль главного администратора так сбросить нельзя'; end if;
  if not (public.is_owner() or (t.org_id is not null and public.can_admin(t.org_id))) then
    raise exception 'Нет прав сбрасывать пароль этому пользователю';
  end if;
  update auth.users
     set encrypted_password = extensions.crypt(new_password, extensions.gen_salt('bf')),
         updated_at = now()
   where id = target;
  -- выйти на всех устройствах со старым паролем
  begin
    delete from auth.sessions where user_id = target;
  exception when others then null;
  end;
end $$;

revoke all on function public.admin_set_password(uuid, text) from public, anon;
grant execute on function public.admin_set_password(uuid, text) to authenticated;
