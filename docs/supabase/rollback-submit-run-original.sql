-- ロールバック用: 拡張前の submit_run（2026-11-27 時点の本体をそのまま保存）
begin;
drop function if exists public.submit_run(text, integer, integer, integer, integer, integer, date, text);
create function public.submit_run(
  p_mode text, p_score integer, p_kills integer, p_combo integer,
  p_stage integer, p_duration integer, p_daily date, p_version text
)
returns void
language plpgsql
security definer
as $$
declare last_t timestamptz; a uuid := public.acc(); today date := (now() at time zone 'Asia/Tokyo')::date;
begin
  if a is null then raise exception 'not a member'; end if;
  if p_mode !~ '^(normal|time|daily|c[1-8])$' then raise exception 'bad mode'; end if;
  if p_score < 0 or p_kills < 0 or p_duration < 0 or p_stage < 0 then raise exception 'bad value'; end if;
  if p_kills > p_duration * 4 + 10 or p_score > p_kills * 400 + 2000 * (p_stage + 1) then
    raise exception 'implausible score'; end if;
  select max(created_at) into last_t from public.runs where player_id = a;
  if last_t is not null and now() - last_t < interval '8 seconds' then raise exception 'too fast'; end if;
  if p_mode = 'daily' then
    if p_daily is null or p_daily < today - 1 or p_daily > today + 1 then raise exception 'bad daily date'; end if;
    if (select count(*) from public.runs where player_id = a and mode = 'daily' and daily_date = p_daily) >= 3 then
      raise exception 'daily limit'; end if;
  end if;
  insert into public.runs(player_id, mode, score, kills, max_combo, stage, duration, daily_date, version)
  values (a, p_mode, p_score, p_kills, p_combo, p_stage, p_duration, case when p_mode = 'daily' then p_daily else null end, p_version);
  if p_mode <> 'daily' then
    insert into public.best_scores(player_id, mode, score) values (a, p_mode, p_score)
    on conflict (player_id, mode) do update
      set score = greatest(public.best_scores.score, excluded.score),
          updated_at = case when excluded.score > public.best_scores.score then now() else public.best_scores.updated_at end;
  end if;
end;
$$;
commit;
