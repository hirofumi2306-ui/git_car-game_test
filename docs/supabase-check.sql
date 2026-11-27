-- ============================================================
-- Supabase サーバー側チェック用 SQL
-- 使い方: Supabase ダッシュボード → SQL Editor に貼って実行し、
-- 結果を Muse に見せる（スクショ or コピペ）。
-- ============================================================

-- パスワードのハッシュ化チェック
-- register / login / set_password 関数の本体に
-- crypt() やハッシュ処理が含まれているかを確認する。
SELECT p.proname AS 関数名,
CASE WHEN p.prosrc ILIKE '%crypt(%'
OR p.prosrc ILIKE '%digest(%'
OR p.prosrc ILIKE '%hash%' THEN 'ハッシュ処理あり'
ELSE '★ハッシュ処理が見当たらない'
END AS 判定
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
AND p.proname IN ('register', 'login', 'set_password');

-- パスワードを保存しているテーブルとカラムの特定
SELECT table_name AS テーブル, column_name AS カラム, data_type AS 型
FROM information_schema.columns
WHERE table_schema = 'public'
AND (column_name ILIKE '%pass%' OR column_name ILIKE '%pw%' OR column_name ILIKE '%hash%');

-- 保存されている値の形式（中身そのものではなく長さと先頭だけ）
-- ※ <テーブル> と <カラム> はの結果に置き換えること。
-- 判定の目安:
-- 先頭が $2a$ / $2b$ → bcrypt でハッシュ化されている（正常）
-- 文字数が短く、先頭が普通の文字 → 平文の疑い（要対応）
-- SELECT length(<カラム>) AS 文字数, left(<カラム>, 4) AS 先頭4文字
-- FROM public.<テーブル> LIMIT 5;

-- スコア送信の検証チェック
-- submit_run 関数の本体を表示する。
-- 「ありえないスコアをはじく条件分岐」があるか目視で確認する。
SELECT p.prosrc AS submit_run_本体
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname = 'submit_run';
