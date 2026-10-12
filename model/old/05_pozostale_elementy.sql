-- =====================================================================
--  d. MODELOWANIE POZOSTALYCH ELEMENTOW BAZY DANYCH
--  PostgreSQL 15+ | wymaga uprzedniego uruchomienia 04_model_fizyczny.sql
--  Zawartosc: funkcje, wyzwalacze, widoki, procedury skladowane,
--             role i uprawnienia obiektowe.
-- =====================================================================
--  UWAGA: kazda funkcja i procedura ma przypiety SET search_path = wms, pg_temp.
--  Bez tego wywolanie z aplikacji (inny search_path) nie znalazloby tabel,
--  a funkcja stalaby sie wektorem podmiany obiektow (CVE-2018-1058).
-- =====================================================================

SET search_path TO wms, public;

-- =====================================================================
-- 1. FUNKCJE POMOCNICZE
-- =====================================================================

-- Porzadek poziomow hierarchii sekcji: area(1) > rack(2) > shelf(3)
CREATE FUNCTION fn_section_level(p_type section_type)
RETURNS SMALLINT
LANGUAGE sql IMMUTABLE PARALLEL SAFE
    SET search_path = wms, pg_temp
AS $$
    SELECT CASE p_type
             WHEN 'area'  THEN 1::SMALLINT
             WHEN 'rack'  THEN 2::SMALLINT
             WHEN 'shelf' THEN 3::SMALLINT
           END;
$$;

-- Ilosc aktualnie wypozyczona (pozycje ZWROTNE jeszcze niezwrocone).
-- Materialy zuzywalne sa pomijane: zeszly ze stanu juz w chwili wydania,
-- wiec liczenie ich tutaj byloby podwojnym odjeciem.
CREATE FUNCTION fn_item_on_loan(p_item_id BIGINT)
RETURNS NUMERIC(12,3)
LANGUAGE sql STABLE
    SET search_path = wms, pg_temp
AS $$
    SELECT COALESCE(SUM(ll.qty_issued - ll.qty_returned), 0)::NUMERIC(12,3)
    FROM   loan_line ll
    JOIN   loan l ON l.id = ll.loan_id
    WHERE  ll.item_id = p_item_id
      AND  NOT ll.is_consumable
      AND  l.status IN ('open', 'partially_returned');
$$;

-- Ilosc dostepna do wydania
CREATE FUNCTION fn_item_available(p_item_id BIGINT)
RETURNS NUMERIC(12,3)
LANGUAGE sql STABLE
    SET search_path = wms, pg_temp
AS $$
    SELECT i.quantity - fn_item_on_loan(i.id)
    FROM   item i WHERE i.id = p_item_id;
$$;

-- Uprawnienie efektywne: najblizszy przodek-sekcja z wpisem wygrywa,
-- w ostatecznosci uprawnienie magazynowe, inaczej 'denied'.
CREATE FUNCTION fn_effective_permission(p_user_id BIGINT, p_section_id BIGINT)
RETURNS permission_type
LANGUAGE plpgsql STABLE
    SET search_path = wms, pg_temp
AS $$
DECLARE
    v_result    permission_type;
    v_warehouse BIGINT;
BEGIN
    WITH RECURSIVE ancestors AS (
        SELECT s.id, s.parent_section_id, s.warehouse_id, 0 AS depth
        FROM   section s WHERE s.id = p_section_id
        UNION ALL
        SELECT s.id, s.parent_section_id, s.warehouse_id, a.depth + 1
        FROM   section s JOIN ancestors a ON s.id = a.parent_section_id
    )
    SELECT p.permission INTO v_result
    FROM   ancestors a
    JOIN   permission p ON p.section_id = a.id AND p.user_id = p_user_id
    ORDER  BY a.depth
    LIMIT  1;

    IF v_result IS NOT NULL THEN
        RETURN v_result;
    END IF;

    SELECT s.warehouse_id INTO v_warehouse FROM section s WHERE s.id = p_section_id;

    SELECT p.permission INTO v_result
    FROM   permission p
    WHERE  p.user_id = p_user_id AND p.warehouse_id = v_warehouse;

    RETURN COALESCE(v_result, 'denied'::permission_type);
END;
$$;

COMMENT ON FUNCTION fn_effective_permission IS
  'Rozstrzyga uprawnienie uzytkownika do sekcji z uwzglednieniem dziedziczenia po hierarchii i po magazynie.';

-- =====================================================================
-- 2. WYZWALACZE INTEGRALNOSCI
-- =====================================================================

-- 2.1 Hierarchia sekcji: porzadek poziomow + brak cykli.
--     Obie reguly siegaja do WIERSZA RODZICA, wiec CHECK ich nie wyrazi
--     (PostgreSQL: "cannot use subquery in check constraint").
--     Regula "korzen musi byc strefa" zostala w CHECK ck_section_root_is_area,
--     bo dotyczy tylko kolumn tego samego wiersza.
CREATE FUNCTION trgf_section_hierarchy() RETURNS TRIGGER
LANGUAGE plpgsql
    SET search_path = wms, pg_temp
AS $$
DECLARE
    v_parent_type section_type;
    v_cursor      BIGINT;
    v_guard       INT := 0;
BEGIN
    -- korzen hierarchii: nie ma rodzica, wiec nie ma czego porownywac;
    -- jego typ pilnuje CHECK ck_section_root_is_area
    IF NEW.parent_section_id IS NULL THEN
        RETURN NEW;
    END IF;

    SELECT section_type INTO v_parent_type FROM section WHERE id = NEW.parent_section_id;

    IF fn_section_level(NEW.section_type) <= fn_section_level(v_parent_type) THEN
        RAISE EXCEPTION 'Sekcja % nie moze byc podrzedna wobec %', NEW.section_type, v_parent_type
            USING ERRCODE = '23514';
    END IF;

    -- wykrycie cyklu przy UPDATE (INSERT nie moze go utworzyc)
    v_cursor := NEW.parent_section_id;
    WHILE v_cursor IS NOT NULL LOOP
        IF v_cursor = NEW.id THEN
            RAISE EXCEPTION 'Cykl w hierarchii sekcji (id=%)', NEW.id USING ERRCODE = '23514';
        END IF;
        v_guard := v_guard + 1;
        IF v_guard > 100 THEN
            RAISE EXCEPTION 'Hierarchia sekcji zbyt gleboka lub uszkodzona' USING ERRCODE = '23514';
        END IF;
        SELECT parent_section_id INTO v_cursor FROM section WHERE id = v_cursor;
    END LOOP;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_section_hierarchy
    BEFORE INSERT OR UPDATE OF parent_section_id, section_type ON section
    FOR EACH ROW EXECUTE FUNCTION trgf_section_hierarchy();

-- 2.2 Role aktorow wypozyczenia
CREATE FUNCTION trgf_loan_roles() RETURNS TRIGGER
LANGUAGE plpgsql
    SET search_path = wms, pg_temp
AS $$
DECLARE
    v_borrower_type user_type;
    v_loaner_type user_type;
    v_borrower_ok   BOOLEAN;
    v_loaner_ok   BOOLEAN;
BEGIN
    SELECT user_type, is_active INTO v_borrower_type, v_borrower_ok
    FROM app_user WHERE id = NEW.borrower_id;
    SELECT user_type, is_active INTO v_loaner_type, v_loaner_ok
    FROM app_user WHERE id = NEW.loaner_id;

    IF v_borrower_type <> 'worker' THEN
        RAISE EXCEPTION 'Pobierajacy wypozyczenie musi miec role worker (ma %)', v_borrower_type
            USING ERRCODE = '23514';
    END IF;
    IF v_loaner_type NOT IN ('warehouseman', 'admin') THEN
        RAISE EXCEPTION 'Wydac moze tylko magazynier lub administrator (jest %)', v_loaner_type
            USING ERRCODE = '23514';
    END IF;
    IF NOT (v_borrower_ok AND v_loaner_ok) THEN
        RAISE EXCEPTION 'Konto pobierajacego lub wydajacego jest nieaktywne' USING ERRCODE = '23514';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_loan_roles
    BEFORE INSERT OR UPDATE OF borrower_id, loaner_id ON loan
    FOR EACH ROW EXECUTE FUNCTION trgf_loan_roles();

-- 2.3 Nie mozna wydac wiecej, niz jest dostepne
CREATE FUNCTION trgf_loan_line_availability() RETURNS TRIGGER
LANGUAGE plpgsql
    SET search_path = wms, pg_temp
AS $$
DECLARE
    v_quantity  NUMERIC(12,3);
    v_committed NUMERIC(12,3);
BEGIN
    -- Pozycja na material zuzywalny jest niezmienna: odpowiadajacy jej ruch
    -- 'consumption' juz obnizyl stan, wiec ponowne przeliczenie dostepnosci
    -- odjeloby te sama ilosc drugi raz.
    IF TG_OP = 'UPDATE' AND NEW.is_consumable THEN
        RAISE EXCEPTION 'Pozycja na material zuzywalny (id=%) nie podlega zmianie', NEW.id
            USING ERRCODE = '23514';
    END IF;

    -- blokada wiersza przedmiotu eliminuje wyscig dwoch jednoczesnych wydan
    SELECT quantity INTO v_quantity FROM item WHERE id = NEW.item_id FOR UPDATE;

    SELECT COALESCE(SUM(ll.qty_issued - ll.qty_returned), 0)
      INTO v_committed
    FROM   loan_line ll
    JOIN   loan l ON l.id = ll.loan_id
    WHERE  ll.item_id = NEW.item_id
      AND  NOT ll.is_consumable
      AND  l.status IN ('open', 'partially_returned')
      AND  ll.id IS DISTINCT FROM NEW.id;

    IF NEW.qty_issued - NEW.qty_returned + v_committed > v_quantity THEN
        RAISE EXCEPTION
            'Brak dostepnej ilosci przedmiotu %: na stanie %, zajete %, zadane %',
            NEW.item_id, v_quantity, v_committed, NEW.qty_issued - NEW.qty_returned
            USING ERRCODE = '23514';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_loan_line_availability
    BEFORE INSERT OR UPDATE OF item_id, is_consumable, qty_issued, qty_returned ON loan_line
    FOR EACH ROW EXECUTE FUNCTION trgf_loan_line_availability();

-- 2.4 Status dokumentu wyliczany z pozycji
CREATE FUNCTION trgf_loan_status() RETURNS TRIGGER
LANGUAGE plpgsql
    SET search_path = wms, pg_temp
AS $$
DECLARE
    v_loan_id   BIGINT;
    v_lines     INT;
    v_open      INT;
    v_returned  NUMERIC(12,3);
BEGIN
    -- przy DELETE rekord NEW nie istnieje, przy INSERT nie istnieje OLD
    IF TG_OP = 'DELETE' THEN
        v_loan_id := OLD.loan_id;
    ELSE
        v_loan_id := NEW.loan_id;
    END IF;

    -- v_open liczy wylacznie pozycje ZWROTNE, ktore jeszcze nie wrocily:
    -- material zuzywalny jest rozliczony w chwili wydania.
    SELECT count(*),
           count(*) FILTER (WHERE NOT is_consumable AND qty_returned < qty_issued),
           COALESCE(SUM(qty_returned), 0)
      INTO v_lines, v_open, v_returned
    FROM   loan_line WHERE loan_id = v_loan_id;

    UPDATE loan SET
        status = CASE
                     WHEN status = 'cancelled' THEN 'cancelled'::loan_status
                     WHEN v_lines = 0          THEN 'open'::loan_status
                     WHEN v_open = 0           THEN 'settled'::loan_status
                     WHEN v_returned > 0       THEN 'partially_returned'::loan_status
                     ELSE 'open'::loan_status
                 END,
        settled_at = CASE
                         WHEN status <> 'cancelled' AND v_lines > 0 AND v_open = 0
                              THEN COALESCE(settled_at, now())
                         ELSE NULL
                     END
    WHERE id = v_loan_id;

    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_loan_status
    AFTER INSERT OR UPDATE OF is_consumable, qty_issued, qty_returned OR DELETE ON loan_line
    FOR EACH ROW EXECUTE FUNCTION trgf_loan_status();

-- 2.5 Dziennik ruchow jest nieusuwalny i niemodyfikowalny
CREATE FUNCTION trgf_movement_append_only() RETURNS TRIGGER
LANGUAGE plpgsql
    SET search_path = wms, pg_temp
AS $$
BEGIN
    RAISE EXCEPTION 'stock_movement jest dziennikiem append-only: % zabronione', TG_OP
        USING ERRCODE = '42501';
END;
$$;

CREATE TRIGGER trg_movement_append_only
    BEFORE UPDATE OR DELETE ON stock_movement
    FOR EACH ROW EXECUTE FUNCTION trgf_movement_append_only();

-- 2.6 Ruch wlasnosciowy aktualizuje stan przedmiotu
CREATE FUNCTION trgf_movement_apply() RETURNS TRIGGER
LANGUAGE plpgsql
    SET search_path = wms, pg_temp
AS $$
DECLARE
    v_serialized BOOLEAN;
BEGIN
    IF NEW.movement_type IN ('receipt', 'disposal', 'adjustment', 'consumption') THEN
        -- ruchy wlasnosciowe: zmieniaja ile firma posiada
        UPDATE item
           SET quantity = quantity + NEW.qty_delta
         WHERE id = NEW.item_id;
        -- ujemny stan lub zlamanie reguly rzeczy seryjnej zatrzyma ck_item_* / dziedzina qty

    ELSIF NEW.movement_type = 'transfer' THEN
        -- przesuniecie: zmienia lokalizacje, nie zmienia stanu posiadania firmy
        SELECT is_serialized INTO v_serialized FROM item WHERE id = NEW.item_id;
        IF v_serialized THEN
            -- rzecz seryjna to jeden wiersz, ktory po prostu zmienia sekcje
            UPDATE item SET section_id = NEW.to_section_id WHERE id = NEW.item_id;
        ELSE
            -- material sypki: dwa wiersze (zrodlowy i docelowy), po jednym ruchu kazdy
            UPDATE item SET quantity = quantity + NEW.qty_delta WHERE id = NEW.item_id;
        END IF;
    END IF;
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_movement_apply
    AFTER INSERT ON stock_movement
    FOR EACH ROW EXECUTE FUNCTION trgf_movement_apply();

-- =====================================================================
-- 3. WIDOKI
-- =====================================================================

-- 3.1 Sciezka sekcji w hierarchii (rekurencyjny)
CREATE VIEW v_section_path AS
WITH RECURSIVE tree AS (
    SELECT s.id, s.warehouse_id, s.parent_section_id,
           s.section_name::TEXT AS path,
           1 AS depth
    FROM   section s WHERE s.parent_section_id IS NULL
    UNION ALL
    SELECT s.id, s.warehouse_id, s.parent_section_id,
           t.path || ' / ' || s.section_name,
           t.depth + 1
    FROM   section s JOIN tree t ON s.parent_section_id = t.id
)
SELECT t.id AS section_id, t.warehouse_id, w.name AS warehouse_name,
       t.path AS section_path, t.depth
FROM   tree t JOIN warehouse w ON w.id = t.warehouse_id;

COMMENT ON VIEW v_section_path IS 'Czytelna sciezka "Strefa A / Regal 3 / Polka 2" dla interfejsu uzytkownika.';

-- 3.2 Stan magazynowy pojedynczego zasobu — widok podstawowy aplikacji
CREATE VIEW v_item_stock AS
SELECT i.id                AS item_id,
       it.id               AS item_type_id,
       it.name             AS item_name,
       it.short_name,
       it.unit,
       it.is_serialized,
       it.is_consumable,
       i.serial_number,
       sp.warehouse_id,
       sp.warehouse_name,
       i.section_id,
       sp.section_path,
       i.quantity                              AS qty_owned,
       fn_item_on_loan(i.id)                   AS qty_on_loan,
       i.quantity - fn_item_on_loan(i.id)      AS qty_available
FROM   item i
JOIN   item_type it     ON it.id = i.item_type_id
JOIN   v_section_path sp ON sp.section_id = i.section_id;

COMMENT ON VIEW v_item_stock IS 'Podglad stanu dla wszystkich trzech rol. Rozdziela ilosc posiadana, wypozyczona i dostepna.';

-- 3.3 Stan zbiorczy per magazyn i typ asortymentu
CREATE VIEW v_warehouse_stock_summary AS
SELECT s.warehouse_id,
       w.name          AS warehouse_name,
       it.id           AS item_type_id,
       it.name         AS item_name,
       it.unit,
       SUM(i.quantity)                          AS qty_owned,
       SUM(fn_item_on_loan(i.id))               AS qty_on_loan,
       SUM(i.quantity - fn_item_on_loan(i.id))  AS qty_available
FROM   item i
JOIN   section   s  ON s.id  = i.section_id
JOIN   warehouse w  ON w.id  = s.warehouse_id
JOIN   item_type it ON it.id = i.item_type_id
GROUP  BY s.warehouse_id, w.name, it.id, it.name, it.unit;

-- 3.4 Wypozyczenia otwarte
CREATE VIEW v_active_loans AS
SELECT l.id              AS loan_id,
       l.status,
       l.issued_at,
       l.due_date,
       brw.id            AS borrower_id,
       brw.first_name || ' ' || brw.last_name AS borrower_name,
       lnr.first_name || ' ' || lnr.last_name AS loaner_name,
       ll.id             AS loan_line_id,
       it.name           AS item_name,
       i.serial_number,
       ll.is_consumable,
       ll.qty_issued,
       ll.qty_returned,
       CASE WHEN ll.is_consumable THEN 0
            ELSE ll.qty_issued - ll.qty_returned END AS qty_outstanding
FROM   loan l
JOIN   loan_line ll ON ll.loan_id = l.id
JOIN   item i       ON i.id  = ll.item_id
JOIN   item_type it ON it.id = i.item_type_id
JOIN   app_user brw ON brw.id = l.borrower_id
JOIN   app_user lnr ON lnr.id = l.loaner_id
WHERE  l.status IN ('open', 'partially_returned');

-- 3.5 Wypozyczenia przeterminowane
CREATE VIEW v_overdue_loans AS
SELECT *, CURRENT_DATE - due_date AS days_overdue
FROM   v_active_loans
WHERE  due_date < CURRENT_DATE;

-- 3.6 Zuzycie materialow — ile ktory pracownik pobral bezzwrotnie
CREATE VIEW v_consumption_summary AS
SELECT l.borrower_id,
       brw.first_name || ' ' || brw.last_name AS borrower_name,
       it.id              AS item_type_id,
       it.name            AS item_name,
       it.unit,
       date_trunc('month', l.issued_at)::date AS month,
       SUM(ll.qty_issued) AS qty_consumed
FROM   loan_line ll
JOIN   loan l       ON l.id  = ll.loan_id
JOIN   item i       ON i.id  = ll.item_id
JOIN   item_type it ON it.id = i.item_type_id
JOIN   app_user brw ON brw.id = l.borrower_id
WHERE  ll.is_consumable
  AND  l.status <> 'cancelled'
GROUP  BY l.borrower_id, borrower_name, it.id, it.name, it.unit, month;

COMMENT ON VIEW v_consumption_summary IS
  'Raport zuzycia materialow bezzwrotnych w podziale na pracownika, asortyment i miesiac.';

-- 3.7 Uprawnienia efektywne uzytkownikow do sekcji
CREATE VIEW v_user_section_permission AS
SELECT u.id   AS user_id,
       u.login,
       u.user_type,
       s.id   AS section_id,
       sp.section_path,
       fn_effective_permission(u.id, s.id) AS effective_permission
FROM   app_user u
CROSS  JOIN section s
JOIN   v_section_path sp ON sp.section_id = s.id
WHERE  u.is_active;

-- =====================================================================
-- 4. PROCEDURY SKLADOWANE (operacje biznesowe aplikacji)
-- =====================================================================

-- 4.1 Przyjecie na stan
CREATE PROCEDURE sp_receive_items(
    p_item_id BIGINT,
    p_qty     NUMERIC(12,3),
    p_user_id BIGINT,
    p_remarks    VARCHAR(500) DEFAULT NULL)
LANGUAGE plpgsql
    SET search_path = wms, pg_temp
AS $$
BEGIN
    IF p_qty <= 0 THEN
        RAISE EXCEPTION 'Ilosc przyjmowana musi byc dodatnia' USING ERRCODE = '22023';
    END IF;

    INSERT INTO stock_movement (item_id, movement_type, qty_delta, performed_by_id, remarks)
    VALUES (p_item_id, 'receipt', p_qty, p_user_id, p_remarks);
END;
$$;

-- 4.2 Likwidacja / zlomowanie
CREATE PROCEDURE sp_dispose_items(
    p_item_id BIGINT,
    p_qty     NUMERIC(12,3),
    p_user_id BIGINT,
    p_remarks    VARCHAR(500) DEFAULT NULL)
LANGUAGE plpgsql
    SET search_path = wms, pg_temp
AS $$
DECLARE
    v_available NUMERIC(12,3);
BEGIN
    IF p_qty <= 0 THEN
        RAISE EXCEPTION 'Ilosc likwidowana musi byc dodatnia' USING ERRCODE = '22023';
    END IF;

    v_available := fn_item_available(p_item_id);
    IF p_qty > v_available THEN
        RAISE EXCEPTION 'Nie mozna zlikwidowac % — dostepne tylko %', p_qty, v_available
            USING ERRCODE = '23514';
    END IF;

    INSERT INTO stock_movement (item_id, movement_type, qty_delta, performed_by_id, remarks)
    VALUES (p_item_id, 'disposal', -p_qty, p_user_id, p_remarks);
END;
$$;

-- 4.3 Wydanie: jeden dokument, wiele pozycji
--     p_lines: '[{"item_id": 1, "qty": 2}, {"item_id": 7, "qty": 5.5}]'
CREATE PROCEDURE sp_issue_loan(
    p_borrower_id  BIGINT,
    p_loaner_id    BIGINT,
    p_due_date     DATE,
    p_lines        JSONB,
    p_remarks      VARCHAR(500) DEFAULT NULL,
    INOUT p_loan_id BIGINT DEFAULT NULL)
LANGUAGE plpgsql
    SET search_path = wms, pg_temp
AS $$
DECLARE
    v_line       JSONB;
    v_line_id    BIGINT;
    v_item_id    BIGINT;
    v_qty        NUMERIC(12,3);
    v_consumable BOOLEAN;
BEGIN
    IF jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) = 0 THEN
        RAISE EXCEPTION 'Dokument wydania musi zawierac co najmniej jedna pozycje'
            USING ERRCODE = '22023';
    END IF;

    INSERT INTO loan (loaner_id, borrower_id, due_date, remarks)
    VALUES (p_loaner_id, p_borrower_id, p_due_date, p_remarks)
    RETURNING id INTO p_loan_id;

    FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines) LOOP
        v_item_id := (v_line ->> 'item_id')::BIGINT;
        v_qty     := (v_line ->> 'qty')::NUMERIC(12,3);

        SELECT is_consumable INTO v_consumable FROM item WHERE id = v_item_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Przedmiot % nie istnieje', v_item_id USING ERRCODE = '23503';
        END IF;

        INSERT INTO loan_line (loan_id, item_id, is_consumable, qty_issued)
        VALUES (p_loan_id, v_item_id, v_consumable, v_qty)
        RETURNING id INTO v_line_id;

        -- material zuzywalny schodzi ze stanu od razu ('consumption' zmienia quantity);
        -- rzecz zwrotna tylko blokuje dostepnosc ('issue' jest wpisem audytowym)
        INSERT INTO stock_movement
               (item_id, movement_type, qty_delta, loan_line_id, performed_by_id)
        VALUES (v_item_id,
                CASE WHEN v_consumable THEN 'consumption' ELSE 'issue' END::movement_type,
                -v_qty, v_line_id, p_loaner_id);
    END LOOP;
END;
$$;

-- 4.4 Przyjecie zwrotu (takze czesciowego)
CREATE PROCEDURE sp_return_loan_line(
    p_loan_line_id BIGINT,
    p_qty          NUMERIC(12,3),
    p_user_id      BIGINT)
LANGUAGE plpgsql
    SET search_path = wms, pg_temp
AS $$
DECLARE
    v_item_id     BIGINT;
    v_outstanding NUMERIC(12,3);
    v_consumable  BOOLEAN;
BEGIN
    SELECT item_id, qty_issued - qty_returned, is_consumable
      INTO v_item_id, v_outstanding, v_consumable
    FROM   loan_line WHERE id = p_loan_line_id FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Pozycja wypozyczenia % nie istnieje', p_loan_line_id
            USING ERRCODE = '23503';
    END IF;
    IF v_consumable THEN
        RAISE EXCEPTION 'Pozycja % dotyczy materialu zuzywalnego — nie podlega zwrotowi',
            p_loan_line_id USING ERRCODE = '23514';
    END IF;
    IF p_qty <= 0 OR p_qty > v_outstanding THEN
        RAISE EXCEPTION 'Nieprawidlowa ilosc zwrotu % (do zwrotu: %)', p_qty, v_outstanding
            USING ERRCODE = '23514';
    END IF;

    UPDATE loan_line SET qty_returned = qty_returned + p_qty WHERE id = p_loan_line_id;

    INSERT INTO stock_movement
           (item_id, movement_type, qty_delta, loan_line_id, performed_by_id)
    VALUES (v_item_id, 'return', p_qty, p_loan_line_id, p_user_id);
END;
$$;

-- 4.5 Przesuniecie miedzy sekcjami (takze miedzy magazynami)
--     Rzecz seryjna: jeden wiersz item zmienia sekcje.
--     Material sypki: ilosc przechodzi miedzy dwoma wierszami item
--                     (zrodlowa i docelowa partia tego samego typu).
CREATE PROCEDURE sp_transfer_items(
    p_item_id       BIGINT,
    p_to_section_id BIGINT,
    p_qty           NUMERIC(12,3),
    p_user_id       BIGINT,
    p_remarks       VARCHAR(500) DEFAULT NULL)
LANGUAGE plpgsql
    SET search_path = wms, pg_temp
AS $$
DECLARE
    v_serialized   BOOLEAN;
    v_consumable   BOOLEAN;
    v_type_id      BIGINT;
    v_from_section BIGINT;
    v_available    NUMERIC(12,3);
    v_target_item  BIGINT;
BEGIN
    SELECT is_serialized, is_consumable, item_type_id, section_id
      INTO v_serialized, v_consumable, v_type_id, v_from_section
    FROM   item WHERE id = p_item_id FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Przedmiot % nie istnieje', p_item_id USING ERRCODE = '23503';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM section WHERE id = p_to_section_id) THEN
        RAISE EXCEPTION 'Sekcja docelowa % nie istnieje', p_to_section_id
            USING ERRCODE = '23503';
    END IF;
    IF v_from_section = p_to_section_id THEN
        RAISE EXCEPTION 'Sekcja zrodlowa i docelowa sa takie same' USING ERRCODE = '22023';
    END IF;
    IF p_qty <= 0 THEN
        RAISE EXCEPTION 'Przenoszona ilosc musi byc dodatnia' USING ERRCODE = '22023';
    END IF;

    IF v_serialized AND p_qty <> 1 THEN
        RAISE EXCEPTION 'Rzecz z numerem seryjnym przenosi sie w calosci (ilosc = 1)'
            USING ERRCODE = '22023';
    END IF;

    -- nie da sie przeniesc tego, co jest u pracownika
    v_available := fn_item_available(p_item_id);
    IF p_qty > v_available THEN
        RAISE EXCEPTION 'Nie mozna przeniesc % — dostepne w sekcji zrodlowej tylko %',
            p_qty, v_available USING ERRCODE = '23514';
    END IF;

    IF v_serialized THEN
        -- wyzwalacz trg_movement_apply zmieni section_id
        INSERT INTO stock_movement (item_id, movement_type, qty_delta,
                                    from_section_id, to_section_id, performed_by_id, remarks)
        VALUES (p_item_id, 'transfer', 1,
                v_from_section, p_to_section_id, p_user_id, p_remarks);
    ELSE
        -- partia docelowa: znajdz albo zaloz pusta
        SELECT id INTO v_target_item
        FROM   item
        WHERE  item_type_id = v_type_id
          AND  section_id   = p_to_section_id
          AND  NOT is_serialized
        FOR UPDATE;

        IF NOT FOUND THEN
            INSERT INTO item (item_type_id, section_id, is_serialized, is_consumable, quantity)
            VALUES (v_type_id, p_to_section_id, FALSE, v_consumable, 0)
            RETURNING id INTO v_target_item;
        END IF;

        -- dwa ruchy: ubytek po stronie zrodla, przybytek po stronie celu
        INSERT INTO stock_movement (item_id, movement_type, qty_delta,
                                    from_section_id, to_section_id, performed_by_id, remarks)
        VALUES (p_item_id, 'transfer', -p_qty,
                v_from_section, p_to_section_id, p_user_id, p_remarks);

        INSERT INTO stock_movement (item_id, movement_type, qty_delta,
                                    from_section_id, to_section_id, performed_by_id, remarks)
        VALUES (v_target_item, 'transfer', p_qty,
                v_from_section, p_to_section_id, p_user_id, p_remarks);
    END IF;
END;
$$;

-- 4.6 Korekta inwentaryzacyjna
CREATE PROCEDURE sp_adjust_stock(
    p_item_id BIGINT,
    p_counted NUMERIC(12,3),
    p_user_id BIGINT,
    p_remarks    VARCHAR(500) DEFAULT 'Inwentaryzacja')
LANGUAGE plpgsql
    SET search_path = wms, pg_temp
AS $$
DECLARE
    v_current NUMERIC(12,3);
    v_delta   NUMERIC(12,3);
BEGIN
    SELECT quantity INTO v_current FROM item WHERE id = p_item_id FOR UPDATE;
    v_delta := p_counted - v_current;

    IF v_delta = 0 THEN
        RETURN;  -- brak roznicy, brak wpisu w dzienniku
    END IF;

    INSERT INTO stock_movement (item_id, movement_type, qty_delta, performed_by_id, remarks)
    VALUES (p_item_id, 'adjustment', v_delta, p_user_id, p_remarks);
END;
$$;

-- =====================================================================
-- 5. ROLE BAZODANOWE I UPRAWNIENIA OBIEKTOWE
-- =====================================================================
-- Aplikacja backendowa laczy sie jako wms_app i sama rozstrzyga role
-- uzytkownika na podstawie tokenu JWT. Role ponizej sa druga warstwa
-- obrony — ograniczaja to, co w ogole da sie zrobic w bazie.

-- Role sa obiektami KLASTRA, nie bazy danych — przezywaja DROP DATABASE,
-- dlatego tworzymy je warunkowo (skrypt musi byc uruchamialny wielokrotnie).
DO $roles$
DECLARE
    r TEXT;
BEGIN
    FOREACH r IN ARRAY ARRAY['wms_reader', 'wms_operator', 'wms_admin'] LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
            EXECUTE format('CREATE ROLE %I NOLOGIN', r);
        END IF;
    END LOOP;
END
$roles$;

GRANT USAGE ON SCHEMA wms TO wms_reader, wms_operator, wms_admin;

-- odczyt stanu: wszystkie role
GRANT SELECT ON v_item_stock, v_warehouse_stock_summary, v_section_path TO wms_reader;
GRANT SELECT ON v_active_loans, v_overdue_loans, v_consumption_summary TO wms_operator;
GRANT wms_reader TO wms_operator;

-- magazynier: operacje przez procedury, bez bezposredniego DML na stanie
GRANT SELECT ON ALL TABLES IN SCHEMA wms TO wms_operator;
GRANT EXECUTE ON PROCEDURE sp_receive_items, sp_dispose_items, sp_issue_loan,
                           sp_return_loan_line, sp_transfer_items, sp_adjust_stock
      TO wms_operator;
GRANT INSERT, UPDATE ON item, item_type, section TO wms_operator;

-- administrator: pelne zarzadzanie kontami i uprawnieniami
GRANT wms_operator TO wms_admin;
GRANT INSERT, UPDATE, DELETE ON app_user, permission, warehouse TO wms_admin;

-- konto techniczne aplikacji backendowej
DO $app$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'wms_app') THEN
        CREATE ROLE wms_app LOGIN PASSWORD 'zmienic_w_srodowisku_docelowym';
    END IF;
END
$app$;
GRANT wms_admin TO wms_app;

-- nikt nie modyfikuje dziennika audytowego (dodatkowo blokuje trigger)
REVOKE UPDATE, DELETE ON stock_movement FROM wms_operator, wms_admin, wms_app;
