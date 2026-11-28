-- ============================================================
-- フェーズB1: サプライヤーガチャ本体（未適用・レビュー用ドラフト）
-- gacha_pull / level_up_supplier / supplier_state / gacha_history
-- 前提: フェーズA1・A2 適用済み（ruby_wallets / supplier_shards / gacha_log 等）
-- 仕様: ユーザー確定プラン（2026-11-27）＋万能かけら追加合意分
--
-- ★1 の中身【確定 2026-11-28】: 追加12社は ★2〜★5 のみで ★1 に会社がないため、
-- ★1 = 「万能かけら ×1」とする（排出率45%）。ユーザーがこの案を承認済み。
-- ============================================================

-- ガチャ対象の会社マスタ（サーバー側で排出プールを管理する）
create table if not exists public.supplier_master (
company_key text primary key,
name text not null,
rarity int not null check (rarity between 1 and 5),
region text not null default 'JP' -- JP / OS
);
insert into public.supplier_master(company_key, name, rarity, region) values
('mitsuba', 'ミツバ', 2, 'JP'),
('astemo', '日立Astemo', 2, 'JP'),
('akebono', '曙ブレーキ', 2, 'JP'),
('advics', 'アドヴィックス', 3, 'JP'),
('toray', '東レ', 3, 'JP'),
('asahi_kasei', '旭化成', 3, 'JP'),
('sumitomo_electric', '住友電工', 3, 'JP'),
('mitsubishi_chemical', '三菱ケミカル', 3, 'JP'),
('brembo', 'ブレンボ', 4, 'OS'),
('zf', 'ZF', 4, 'OS'),
('tsmc', 'TSMC', 5, 'OS'),
('catl', 'CATL', 5, 'OS')
on conflict (company_key) do nothing;
alter table public.supplier_master enable row level security;

-- ------------------------------------------------------------
-- ガチャを引く: 1回30 / 10連270。抽選・消費・付与を1トランザクションで。
-- p_req = 回ID（端末が生成するUUID）。同じ回IDの再送は二重処理しない。
-- 戻り値: {ok, balance, pity, universal_shards, coin_bonus, results:[
-- {rarity, company_key, outcome: new|shard|coins|universal}]}
-- coin_bonus は「Lv5済み会社のダブり→コイン変換（★×300）」の合計。
-- コインは端末管理のため、端末がこの値を加算して保存する。
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
univ_gain int:= 0;
coin_bonus int:= 0;
results jsonb:= '[]'::jsonb;
s public.supplier_shards%rowtype;
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

cost:= case when p_count = 1 then 30 else 270 end;

insert into public.ruby_wallets(player_id) values (a)
on conflict (player_id) do nothing;
select * into w from public.ruby_wallets where player_id = a for update;
if w.balance < cost then
return jsonb_build_object('ok', false, 'reason', 'no_ruby', 'balance', w.balance);
end if;
perform public._grant_ruby(a, -cost, 'gacha', p_req::text);
v_pity := w.pity;

for i in 1..p_count loop
-- レアリティ決定（天井: ★4+なしが39回続いたら次は★4+確定）
if v_pity >= 39 then
rar:= case when random() < 7.0/8 then 4 else 5 end;
elsif p_count = 10 and i = 10 and not got3 then
-- 10連保証: ★3以上（17:7:1 の比率で抽選）
r:= random() * 25;
rar:= case when r < 17 then 3 when r < 24 then 4 else 5 end;
else
r:= random();
rar:= case when r < 0.45 then 1
when r < 0.75 then 2
when r < 0.92 then 3
when r < 0.99 then 4
else 5 end;
end if;
if rar >= 3 then got3:= true; end if;
if rar >= 4 then v_pity := 0; else v_pity := v_pity + 1; end if;

-- 会社決定と付与
if rar = 1 then
comp:= 'universal'; -- ★1 = 万能かけら×1
univ_gain:= univ_gain + 1;
results:= results || jsonb_build_object(
'rarity', rar, 'company_key', comp, 'outcome', 'universal');
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
select * into s from public.supplier_shards
where player_id = a and company_key = comp for update;
if s.level >= 5 then
-- 最大レベルのダブりはコイン変換（★×300、ルビーには戻さない）
coin_bonus:= coin_bonus + rar * 300;
results:= results || jsonb_build_object(
'rarity', rar, 'company_key', comp, 'outcome', 'coins',
'coins', rar * 300);
else
update public.supplier_shards
set shards = shards + 1
where player_id = a and company_key = comp;
results:= results || jsonb_build_object(
'rarity', rar, 'company_key', comp, 'outcome', 'shard');
end if;
end if;
end if;

insert into public.gacha_log(player_id, req_id, rarity, company_key, rates_version)
values (a, p_req, rar, comp, 'v1');
end loop;

update public.ruby_wallets
set pity = v_pity, universal_shards = universal_shards + univ_gain,
updated_at = now()
where player_id = a;

return jsonb_build_object('ok', true,
'balance', w.balance - cost, 'pity', v_pity,
'universal_shards', w.universal_shards + univ_gain,
'coin_bonus', coin_bonus, 'results', results);
end;
$$;

-- ------------------------------------------------------------
-- レベルアップ: かけらをサーバーで消費する（会社かけら→万能かけらの順）。
-- コイン（200/400/700/1100）は端末管理のため、必要額を戻り値で伝え、
-- 端末が ok のときだけ差し引いて保存する（ユーザー確定プランの方式）。
-- 必要かけら: Lv1→2:2 / 2→3:4 / 3→4:8 / 4→5:16
-- ------------------------------------------------------------
create or replace function public.level_up_supplier(p_company text)
returns jsonb
language plpgsql
security definer
as $$
declare
a uuid:= public.acc();
s public.supplier_shards%rowtype;
w public.ruby_wallets%rowtype;
need int;
coin_cost int;
use_company int;
use_univ int;
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
need:= (array[2, 4, 8, 16])[s.level];
coin_cost:= (array[200, 400, 700, 1100])[s.level];

insert into public.ruby_wallets(player_id) values (a)
on conflict (player_id) do nothing;
select * into w from public.ruby_wallets where player_id = a for update;
if s.shards + w.universal_shards < need then
return jsonb_build_object('ok', false, 'reason', 'shards',
'have', s.shards + w.universal_shards, 'need', need);
end if;

use_company:= least(s.shards, need);
use_univ:= need - use_company;
update public.supplier_shards
set shards = shards - use_company, level = level + 1
where player_id = a and company_key = p_company;
if use_univ > 0 then
update public.ruby_wallets
set universal_shards = universal_shards - use_univ, updated_at = now()
where player_id = a;
end if;

return jsonb_build_object('ok', true,
'level', s.level + 1, 'coin_cost', coin_cost,
'used_company', use_company, 'used_universal', use_univ,
'shards_left', s.shards - use_company,
'universal_left', w.universal_shards - use_univ);
end;
$$;

-- 所持サプライヤーの状態（新会社のみ。既存15社は従来どおり端末側）
create or replace function public.supplier_state()
returns jsonb
language plpgsql
security definer
as $$
declare
a uuid:= public.acc();
w public.ruby_wallets%rowtype;
companies jsonb;
begin
if a is null then raise exception 'not a member'; end if;
insert into public.ruby_wallets(player_id) values (a)
on conflict (player_id) do nothing;
select * into w from public.ruby_wallets where player_id = a;
select coalesce(jsonb_agg(jsonb_build_object(
'company_key', ss.company_key, 'shards', ss.shards, 'level', ss.level)
order by ss.company_key), '[]'::jsonb)
into companies
from public.supplier_shards ss
where ss.player_id = a;
return jsonb_build_object(
'companies', companies, 'universal_shards', w.universal_shards);
end;
$$;

-- ガチャ履歴（新しい順）
create or replace function public.gacha_history(p_limit int default 20)
returns jsonb
language plpgsql
security definer
as $$
declare
a uuid:= public.acc();
rows jsonb;
begin
if a is null then raise exception 'not a member'; end if;
select coalesce(jsonb_agg(jsonb_build_object(
'rarity', g.rarity, 'company_key', g.company_key,
'created_at', g.created_at) order by g.id desc), '[]'::jsonb)
into rows
from (select * from public.gacha_log
where player_id = a order by id desc limit least(p_limit, 100)) g;
return jsonb_build_object('history', rows);
end;
$$;
