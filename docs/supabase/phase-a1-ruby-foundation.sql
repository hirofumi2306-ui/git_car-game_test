-- ============================================================
-- フェーズA1: ルビー経済の土台（追加のみ・既存機能に影響なし）
-- テーブル5つ + 内部付与ヘルパー + ログインボーナス + 残高取得
-- 適用日: 2026-11-27 / 適用方法: Supabase Management API
-- ============================================================

create table if not exists public.ruby_wallets (
  player_id       uuid primary key references public.players(id),
  balance         int  not null default 0,
  drops_today     int  not null default 0,
  drops_day       date,
  streak_days     int  not null default 0,
  last_bonus_date date,
  pity            int  not null default 0,   -- 天井カウンター（フェーズBで使用）
  universal_shards int not null default 0,   -- 万能かけら
  updated_at      timestamptz not null default now()
);

-- 増減履歴（追記のみ）
create table if not exists public.ruby_ledger (
  id         bigint generated always as identity primary key,
  player_id  uuid not null references public.players(id),
  delta      int  not null,
  reason     text not null,   -- drop / boss / login_bonus / rank_daily / rank_weekly / first_clear / gacha / admin
  ref        text,
  created_at timestamptz not null default now()
);

-- サプライヤーのかけらとレベル（フェーズBで使用）
create table if not exists public.supplier_shards (
  player_id   uuid not null references public.players(id),
  company_key text not null,
  shards      int  not null default 0,
  level       int  not null default 1,
  primary key (player_id, company_key)
);

-- ガチャ履歴（フェーズBで使用）
create table if not exists public.gacha_log (
  id            bigint generated always as identity primary key,
  player_id     uuid not null references public.players(id),
  req_id        uuid,          -- 回ID（二重処理防止）
  rarity        int,
  company_key   text,
  rates_version text,
  created_at    timestamptz not null default now()
);

-- ランキング報酬の受取記録（フェーズCで使用）
create table if not exists public.rank_rewards (
  id          bigint generated always as identity primary key,
  period_kind text not null,   -- daily / weekly
  period_date date not null,
  player_id   uuid not null references public.players(id),
  rank        int,
  rubies      int,
  claimed_at  timestamptz not null default now(),
  unique (period_kind, period_date, player_id)
);

-- 既存テーブルと同じく、直接アクセス不可（RLS有効・ポリシーなし＝RPC経由のみ）
alter table public.ruby_wallets    enable row level security;
alter table public.ruby_ledger     enable row level security;
alter table public.supplier_shards enable row level security;
alter table public.gacha_log       enable row level security;
alter table public.rank_rewards    enable row level security;

-- 内部専用: ルビー付与（残高更新＋履歴を1トランザクションで）
create or replace function public._grant_ruby(p_player uuid, p_amount int, p_reason text, p_ref text)
returns int
language plpgsql
security definer
as $$
begin
  insert into public.ruby_wallets(player_id) values (p_player)
    on conflict (player_id) do nothing;
  update public.ruby_wallets
     set balance = balance + p_amount, updated_at = now()
   where player_id = p_player;
  insert into public.ruby_ledger(player_id, delta, reason, ref)
  values (p_player, p_amount, p_reason, p_ref);
  return p_amount;
end;
$$;
-- クライアントからは直接呼べないようにする
revoke execute on function public._grant_ruby(uuid, int, text, text) from public, anon, authenticated;

-- ログインボーナス: 日本時間で1日1回、3個。7日連続ごとに +10個。
create or replace function public.claim_login_bonus()
returns jsonb
language plpgsql
security definer
as $$
declare
  a uuid := public.acc();
  today date := (now() at time zone 'Asia/Tokyo')::date;
  w public.ruby_wallets%rowtype;
  g int;
  new_streak int;
begin
  if a is null then raise exception 'not a member'; end if;
  insert into public.ruby_wallets(player_id) values (a)
    on conflict (player_id) do nothing;
  select * into w from public.ruby_wallets where player_id = a for update;
  if w.last_bonus_date = today then
    return jsonb_build_object('ok', false, 'reason', 'already',
                              'balance', w.balance, 'streak', w.streak_days);
  end if;
  new_streak := case when w.last_bonus_date = today - 1 then w.streak_days + 1 else 1 end;
  g := 3 + case when new_streak % 7 = 0 then 10 else 0 end;
  perform public._grant_ruby(a, g, 'login_bonus', new_streak::text);
  update public.ruby_wallets
     set streak_days = new_streak, last_bonus_date = today
   where player_id = a;
  return jsonb_build_object('ok', true, 'granted', g,
                            'streak', new_streak, 'balance', w.balance + g);
end;
$$;

-- 残高とカウンターの取得（ホーム表示用）
create or replace function public.ruby_balance()
returns jsonb
language plpgsql
security definer
as $$
declare
  a uuid := public.acc();
  today date := (now() at time zone 'Asia/Tokyo')::date;
  w public.ruby_wallets%rowtype;
begin
  if a is null then raise exception 'not a member'; end if;
  insert into public.ruby_wallets(player_id) values (a)
    on conflict (player_id) do nothing;
  select * into w from public.ruby_wallets where player_id = a;
  return jsonb_build_object(
    'balance', w.balance,
    'drops_today', case when w.drops_day is distinct from today then 0 else w.drops_today end,
    'streak', w.streak_days,
    'pity', w.pity,
    'universal_shards', w.universal_shards,
    'bonus_today', (w.last_bonus_date = today)
  );
end;
$$;
