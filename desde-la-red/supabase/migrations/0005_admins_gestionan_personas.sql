-- ============================================================================
-- El Panel necesita poder ascender y retirar administradoras sin pasar por el
-- editor de SQL. La política original solo dejaba a cada quien editar su
-- propio perfil, así que una administradora no podía tocar el rol de nadie.
--
-- Dos límites que la base hace cumplir, no la interfaz:
--   · Nadie puede cambiar su propio rol. Así una administradora no se degrada
--     sola por error, y nadie se asciende a sí misma si algún día se abre esa
--     pantalla por otra vía.
--   · Nunca puede quedar la Red sin ninguna administradora.
-- ============================================================================

-- Un perfil solo puede cambiar de rol a través de esta función.
create or replace function public.set_member_role(target uuid, new_role text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'Solo una administradora puede cambiar roles';
  end if;

  if new_role not in ('member', 'admin') then
    raise exception 'Rol desconocido: %', new_role;
  end if;

  if target = auth.uid() then
    raise exception 'No puedes cambiar tu propio rol';
  end if;

  -- Retirar a alguien no puede dejar la Red sin quien publique.
  if new_role = 'member'
     and (select count(*) from public.profiles where role = 'admin') <= 1 then
    raise exception 'La Red necesita al menos una administradora';
  end if;

  update public.profiles set role = new_role where id = target;

  if not found then
    raise exception 'Esa persona no está en la Red';
  end if;
end;
$$;

revoke execute on function public.set_member_role(uuid, text) from public, anon;
grant execute on function public.set_member_role(uuid, text) to authenticated;

comment on function public.set_member_role is
  'Cambia el rol de otra persona. Solo para administradoras; nadie puede
   cambiar el suyo y nunca se queda la Red sin administradoras.';
