-- ============================================================
-- フェーズB2: ガチャ経済アップデート（2026-11-28 ユーザー指示）
-- 1. ガチャ価格: 1回 30→10 ルビー / 10連 270→90 ルビー
-- 2. 排出率アップ: ★1 30% / ★2 32% / ★3 20% / ★4 13% / ★5 5%
--    （従来 45/30/17/7/1。★5 はユーザーが 5% を明示指定）
--    天井・10連保証の配分も新比率に合わせて更新（★4:★5=13:5、保証 20:13:5）
-- 3. レベルアップをコインのみに（かけら消費を廃止。既存サプライヤーと同方式）
--    - 重複入手はレベル不問でコイン変換（★×300）
--    - ★1 は「コイン+300」（万能かけらは廃止。既存残高は DB に残るが使わない）
--    - コイン費用は従来どおり 200/400/700/1100（端末が戻り値を見て差し引く）
-- 4. ルビードロップのシード化: プレイ開始時に start_run_seed() で乱数シードを配り、
--    端末とサーバーが同じ xorshift32 で抽選する。これによりプレイ中の
--    ドロップ演出（端末）と結果画面の確定数（サーバー）が一致する。
--    シードなし/期限切れ/使用済みの場合は従来のサーバー乱数にフォールバック。
-- 前提: フェーズA1・A2・B1 適用済み
-- ============================================================

-- ------------------------------------------------------------
-- 内部ヘルパー: xorshift32（符号なし32bit演算を bigint で再現。JS実装と一致させること）
-- ------------------------------------------------------------
create or replace function public._xs32(x int)
returns int
language plpgsql
immutable
as $$
declare
  u bigint := x::bigint & 4294967295;
begin
  u := u # ((u << 13) & 4294967295);
  u := u # (u >> 17);
  u := u # ((u << 5) & 4294967295);
  if u >= 2147483648 then u := u - 4294967296; end if;
  return u::int;
end;
$$;
revoke execute on function public._xs32(int) from public, anon, authenticated;

-- ------------------------------------------------------------
-- ドロップ用シード（プレイヤーごとに最新1件のみ有効）
-- ------------------------------------------------------------
create table if not exists public.ruby_run_seeds (
  player_id  uuid primary key references public.players(id),
  seed       int not null,
  created_at timestamptz not null default now(),
  used_at    timestamptz
);
alter table public.ruby_run_seeds enable row level security;

create or replace function public.start_run_seed()
returns jsonb
language plpgsql
security definer
as $$
declare
  a uuid := public.acc();
  v_seed int;
begin
  if a is null then raise exception 'not a member'; end if;
  v_seed := floor(random() * 2147483646)::int + 1;  -- 1..2147483646（0は xorshift が退化するため除外）
  insert into public.ruby_run_seeds(player_id, seed, created_at, used_at)
  values (a, v_seed, now(), null)
  on conflict (player_id) do update
    set seed = excluded.seed, created_at = now(), used_at = null;
  return jsonb_build_object('ok', true, 'seed', v_seed);
end;
$$;

-- ------------------------------------------------------------
-- ガチャ: 価格 10/90・新確率・重複と★1はコイン変換
-- 戻り値: {ok, balance, pity, universal_shards, coin_bonus, results:[
-- {rarity, company_key, outcome: new|coins, coins?}]}
-- universal_shards は互換のため残す（今後増減しない）。
-- ------------------------------------------------------------
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
select jsonb_agg(jsonb_build_object(
'rarity', g.rarity, 'company_key', g.company_key) order by g.id)
into results
from public.gacha_log g
where g.player_id = a and g.req_id = p_req;
select * into w from public.ruby_wallets where player_id = a;
return jsonb_build_object('ok', true, 'duplicated', true,
'balance', w.balance, 'pity', w.pity,
'universal_shards', w.universal_shards, 'results', results);
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
-- レベルアップ: コインのみ（かけら消費を廃止）
-- コイン（200/400/700/1100）は端末管理のため、必要額を戻り値で伝え、
-- 端末が ok のときだけ差し引いて保存する（従来方式を維持）。
-- ------------------------------------------------------------
create or replace function public.level_up_supplier(p_company text)
returns jsonb
language plpgsql
security definer
as $$
declare
a uuid:= public.acc();
s public.supplier_shards%rowtype;
coin_cost int;
begin
if a is null then raise exception 'not a member'; end if;
if not exists (select 1 from public.supplier_master where company_key = p_company) then
return jsonb_build_object('ok', false, 'reason', 'unknown_company');
end if;
select * into s from public.supplier_shards
where player_id = a and company_key = p_company for update;
if not found then
return jsonb_build_object('ok', false, 'reason', 'not_owned');
end if;
if s.level >= 5 then
return jsonb_build_object('ok', false, 'reason', 'max_level');
end if;
coin_cost:= (array[200, 400, 700, 1100])[s.level];

update public.supplier_shards
set level = level + 1
where player_id = a and company_key = p_company;

return jsonb_build_object('ok', true,
'level', s.level + 1, 'coin_cost', coin_cost);
end;
$$;

-- ------------------------------------------------------------
-- submit_run 拡張: p_seed を追加（デフォルト null = 従来動作）
-- 戻り値が変わらないため CREATE OR REPLACE ではなく DROP → CREATE。
-- 既存の検証ロジックは一切変更なし。ドロップ抽選だけシード対応にする。
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
       and sd.created_at > now() - interval '30 minutes' then
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
