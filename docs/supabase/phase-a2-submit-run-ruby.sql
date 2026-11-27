-- ============================================================
-- フェーズA2: submit_run 拡張（ルビードロップ付与）
-- 既存の検証ロジックは一切変えず、記録の挿入後にドロップ付与を追加。
-- 戻り値を void から jsonb に変えるため DROP → CREATE を1トランザクションで実行。
-- ロールバック: docs/supabase/rollback-submit-run-original.sql
-- ============================================================

begin;

drop function public.submit_run(text, integer, integer, integer, integer, integer, date, text);

create function public.submit_run(
  p_mode text, p_score integer, p_kills integer, p_combo integer,
  p_stage integer, p_duration integer, p_daily date, p_version text
)
returns jsonb
language plpgsql
security definer
as $$
declare
  last_t timestamptz;
  a uuid := public.acc();
  today date := (now() at time zone 'Asia/Tokyo')::date;
  drops int := 0;
  allowed int := 0;
  i int;
  w public.ruby_wallets%rowtype;
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

  -- ルビードロップ: 撃破ごとに4%抽選（サーバー乱数）。上限は1プレイ10個・1日60個。
  for i in 1..p_kills loop
    if random() < 0.04 then drops := drops + 1; end if;
  end loop;
  drops := least(drops, 10);
  insert into public.ruby_wallets(player_id) values (a) on conflict (player_id) do nothing;
  select * into w from public.ruby_wallets where player_id = a for update;
  if w.drops_day is distinct from today then
    update public.ruby_wallets set drops_today = 0, drops_day = today where player_id = a;
    w.drops_today := 0;
  end if;
  allowed := least(drops, greatest(0, 60 - w.drops_today));
  if allowed > 0 then
    perform public._grant_ruby(a, allowed, 'drop', p_mode);
    update public.ruby_wallets set drops_today = drops_today + allowed where player_id = a;
  end if;
  return jsonb_build_object('ok', true, 'ruby', allowed, 'ruby_capped', allowed < drops);
end;
$$;

commit;
