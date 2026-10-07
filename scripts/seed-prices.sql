-- Yönetim adımıdır; migration değildir. FakeProvider ücretli API çağırmaz.
insert into public.provider_prices(provider,model,price_version,usd_micros_per_minute,valid_from)
values ('fake','fake-v1','fake-v1-zero',0,'2026-10-07T00:00:00Z')
on conflict(provider,model,price_version) do nothing;
