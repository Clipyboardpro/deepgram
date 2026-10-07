-- Docker olmadan düz PostgreSQL'de migration ve testleri koşabilmek için
-- Supabase'in sağladığı nesnelerin en küçük taklidi. YALNIZ yerel/CI testi
-- içindir; gerçek Supabase projesine asla uygulanmaz.

create role anon nologin noinherit;
create role authenticated nologin noinherit;
create role service_role nologin noinherit bypassrls;

create schema auth;
create schema storage;
create schema extensions;

grant usage on schema public, auth, extensions to anon, authenticated, service_role;
grant usage on schema storage to service_role;

create table auth.users (
  id     uuid primary key default gen_random_uuid(),
  email  text
);

-- Supabase'in auth.uid(): JWT'deki "sub" alanı.
create function auth.uid()
returns uuid
language sql
stable
as $$
  select coalesce(
    nullif(current_setting('request.jwt.claim.sub', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')
  )::uuid;
$$;

grant execute on function auth.uid() to anon, authenticated, service_role;

create table storage.buckets (
  id                  text primary key,
  name                text not null unique,
  public              boolean default false,
  file_size_limit     bigint,
  allowed_mime_types  text[],
  created_at          timestamptz default now()
);

-- Supabase public şemasındaki yeni nesnelere bu rollere varsayılan yetki verir;
-- migration'lardaki revoke'ların gerçekten işe yaradığını test edebilmek için
-- aynı davranış taklit edilir.
alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public grant all on sequences to anon, authenticated, service_role;
alter default privileges in schema public grant execute on functions to anon, authenticated, service_role;

-- pg_net/Vault yalnız yapısal taklit: ağ ve gerçek şifreleme YOKTUR.
-- db-test.sh yalnız bu iki extension CREATE satırını atlar; gerçek Supabase
-- CI tüm migration'ları değiştirmeden uygular. Bu dosya canlıya uygulanmaz.
create schema net;
create schema vault;
create table vault.secrets (id uuid primary key default gen_random_uuid(), name text unique, secret text not null);
create view vault.decrypted_secrets as select id, name, secret as decrypted_secret from vault.secrets;
create function vault.create_secret(new_secret text, new_name text default null, new_description text default '')
returns uuid language sql as $$
  insert into vault.secrets(secret,name) values(new_secret,new_name) returning id;
$$;
create function net.http_post(url text, body jsonb default '{}'::jsonb, params jsonb default '{}'::jsonb,
  headers jsonb default '{}'::jsonb, timeout_milliseconds integer default 1000)
returns bigint language sql as $$select null::bigint;$$;
