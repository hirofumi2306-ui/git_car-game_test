-- ============================================================
-- フェーズB3: 改善バックログ対応（2026-11-28）
-- 1. gacha_pull の冪等リプレイ（duplicated）でも outcome/coins を返す（1-9）
-- 2. submit_run のシード有効期限を 30分 → 6時間に延長（1-6:
--    ポーズ放置ランで表示と確定数がずれる問題の緩和。シード方式自体は不変）
-- 前提: フェーズB2 適用済み。本文は B2 の関数定義に上記2点だけを入れたもの。
-- ============================================================

create or replace function public.gacha_pull(p_count int, p_req uuid)
returns jsonb
language plpgsql
security definer
as $$
declare
a uuid:= public.acc();
cost int;
w public.ruby_wallets%rowtype;
i int;
r double precision;
rar int;
comp text;
got3 boolean:= false;
v_pity int;
coin_bonus int:= 0;
results jsonb:= '[]'::jsonb;
inserted boolean;
begin
if a is null then raise exception 'not a member'; end if;
if p_count not in (1, 10) then
return jsonb_build_object('ok', false, 'reason', 'bad_count');
end if;
if p_req is null then
return jsonb_build_object('ok', false, 'reason', 'no_req_id');
end if;

-- 冪等性: 同じ回IDが記録済みなら、前回の結果を返して再課金しない
if exists (select 1 from public.gacha_log where player_id = a and req_id = p_req) then
-- B3: outcome/coins も再構築して返す（履歴から復元: 'coins'行はコイン300、
-- 会社はそのプレイヤーの初出ログなら new、2回目以降は coins=★×300）。
-- coin_bonus は表示用。端末は duplicated のとき加算してはいけない（二重加算防止）。
select jsonb_agg(x.obj order by x.id) into results from (
select g.id, jsonb_build_object(
'rarity', g.rarity, 'company_key', g.company_key,
'outcome', case
when g.company_key = 'coins' then 'coins'
when exists (select 1 from public.gacha_log g2
where g2.player_id = a and g2.company_key = g.company_key and g2.id < g.id)
then 'coins' else 'new' end,
'coins', case
when g.company_key = 'coins' then 300
when exists (select 1 from public.gacha_log g2
where g2.player_id = a and g2.company_key = g.company_key and g2.id < g.id)
then g.rarity * 300 else 0 end
) as obj
from public.gacha_log g
where g.player_id = a and g.req_id = p_req) x;
select coalesce(sum((e->>'coins')::int), 0) into coin_bonus
from jsonb_array_elements(results) e;
select * into w from public.ruby_wallets where player_id = a;
return jsonb_build_object('ok', true, 'duplicated', true,
'balance', w.balance, 'pity', w.pity,
'universal_shards', w.universal_shards,
'coin_bonus', coin_bonus, 'results', results);
end if;

cost:= case when p_count = 1 then 10 else 90 end;

insert into public.ruby_wallets(player_id) values (a)
on conflict (player_id) do nothing;
select * into w from public.ruby_wallets where player_id = a for update;
if w.balance < cost then
return jsonb_build_object('ok', false, 'reason', 'no_ruby', 'balance', w.balance);
end if;
perform public._grant_ruby(a, -cost, 'gacha', p_req::text);
v_pity := w.pity;

for i in 1..p_count loop
-- レアリティ決定（天井: ★4+なしが39回続いたら次は★4+確定、配分 ★4:★5 = 13:5）
if v_pity >= 39 then
rar:= case when random() < 13.0/18 then 4 else 5 end;
elsif p_count = 10 and i = 10 and not got3 then
-- 10連保証: ★3以上（20:13:5 の比率で抽選）
r:= random() * 38;
rar:= case when r < 20 then 3 when r < 33 then 4 else 5 end;
else
-- 通常抽選: ★1 30% / ★2 32% / ★3 20% / ★4 13% / ★5 5%
r:= random();
rar:= case when r < 0.30 then 1
when r < 0.62 then 2
when r < 0.82 then 3
when r < 0.95 then 4
else 5 end;
end if;
if rar >= 3 then got3:= true; end if;
if rar >= 4 then v_pity := 0; else v_pity := v_pity + 1; end if;

-- 会社決定と付与
if rar = 1 then
-- ★1 = コイン+300（万能かけら廃止に伴う代替）
comp:= 'coins';
coin_bonus:= coin_bonus + 300;
results:= results || jsonb_build_object(
'rarity', rar, 'company_key', comp, 'outcome', 'coins', 'coins', 300);
else
select company_key into comp from public.supplier_master
where rarity = rar order by random() limit 1;

insert into public.supplier_shards(player_id, company_key, shards, level)
values (a, comp, 0, 1)
on conflict (player_id, company_key) do nothing
returning true into inserted;

if inserted then
results:= results || jsonb_build_object(
'rarity', rar, 'company_key', comp, 'outcome', 'new');
else
-- 重複はレベル不問でコイン変換（★×300、ルビーには戻さない）
coin_bonus:= coin_bonus + rar * 300;
results:= results || jsonb_build_object(
'rarity', rar, 'company_key', comp, 'outcome', 'coins',
'coins', rar * 300);
end if;
end if;

insert into public.gacha_log(player_id, req_id, rarity, company_key, rates_version)
values (a, p_req, rar, comp, 'v2');
end loop;

update public.ruby_wallets
set pity = v_pity, updated_at = now()
where player_id = a;

return jsonb_build_object('ok', true,
'balance', w.balance - cost, 'pity', v_pity,
'universal_shards', w.universal_shards,
'coin_bonus', coin_bonus, 'results', results);
end;
$$;

-- ------------------------------------------------------------
-- submit_run: シード期限 6時間（それ以外は B2 と同一）
-- ------------------------------------------------------------
begin;

drop function public.submit_run(text, integer, integer, integer, integer, integer, date, text);

create function public.submit_run(
  p_mode text, p_score integer, p_kills integer, p_combo integer,
  p_stage integer, p_duration integer, p_daily date, p_version text,
  p_seed integer default null
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
  sd public.ruby_run_seeds%rowtype;
  seeded boolean := false;
  st int;
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

  -- ルビードロップ: 有効なシードがあれば端末表示と一致する決定論的抽選、
  -- なければ従来のサーバー乱数抽選。いずれも撃破ごとに4%、上限1プレイ10個・1日60個。
  if p_seed is not null then
    select * into sd from public.ruby_run_seeds where player_id = a;
    if found and sd.seed = p_seed and sd.used_at is null
       and sd.created_at > now() - interval '6 hours' then
      seeded := true;
    end if;
  end if;
  if seeded then
    st := p_seed;
    for i in 1..p_kills loop
      st := public._xs32(st);
      if ((st::bigint & 4294967295) % 100) < 4 then drops := drops + 1; end if;
    end loop;
    update public.ruby_run_seeds set used_at = now() where player_id = a;
  else
    for i in 1..p_kills loop
      if random() < 0.04 then drops := drops + 1; end if;
    end loop;
  end if;
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
