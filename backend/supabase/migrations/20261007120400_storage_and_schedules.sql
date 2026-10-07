-- Geçici ses bucket'ı ve zamanlanmış veritabanı temizliği.

-- Özel bucket. İstemci için hiçbir storage politikası yok: yükleme, sunucunun
-- ürettiği kısa ömürlü imzalı yükleme adresiyle (createSignedUploadUrl),
-- sağlayıcının okuması kısa ömürlü imzalı okuma adresiyle yapılır.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('transcription-audio', 'transcription-audio', false, 15728640, array['audio/mp4', 'audio/m4a', 'audio/aac'])
on conflict (id) do nothing;

-- pg_cron: her 10 dakikada bir veritabanı temizliği. Storage'daki ses
-- dosyalarının silinmesi ve dispatcher'ın tetiklenmesi Edge Function'lara
-- bağlı olduğu için (adres ve anahtar ortama göre değişir) ortam kurulumunda
-- ayrıca zamanlanır; bkz. docs/ortamlar.md.
create extension if not exists pg_cron with schema pg_catalog;

select cron.schedule(
  'cleanup-expired-work',
  '*/10 * * * *',
  $$select public.cleanup_expired_work()$$
);
