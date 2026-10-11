-- =====================================================================
--  Testy ograniczen integralnosci
--  Uruchamiac po 04, 05 i 06. Kazdy test wypisuje PASS albo FAIL.
-- =====================================================================

SET search_path TO wms, public;

-- Pomocnik: oczekuje, ze podany SQL ZAKONCZY sie bledem.
CREATE OR REPLACE FUNCTION assert_fails(p_sql TEXT, p_label TEXT) RETURNS VOID
LANGUAGE plpgsql AS $$
BEGIN
    BEGIN
        EXECUTE p_sql;
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'PASS  %  (%)', rpad(p_label, 52), SQLERRM;
        RETURN;
    END;
    RAISE WARNING 'FAIL  %  <- operacja powinna zostac odrzucona', p_label;
END;
$$;

-- Pomocnik: oczekuje, ze warunek jest prawdziwy.
CREATE OR REPLACE FUNCTION assert_true(p_cond BOOLEAN, p_label TEXT) RETURNS VOID
LANGUAGE plpgsql AS $$
BEGIN
    IF p_cond THEN RAISE NOTICE 'PASS  %', p_label;
    ELSE           RAISE WARNING 'FAIL  %', p_label;
    END IF;
END;
$$;

-- ---------------------------------------------------------------------
-- A. Ewidencja hybrydowa (item / item_type)
-- ---------------------------------------------------------------------
SELECT assert_fails($q$
    INSERT INTO item (item_type_id, section_id, is_serialized, is_consumable, serial_number, quantity)
    VALUES (1, 5, TRUE, FALSE, NULL, 1) $q$,
    'A1 rzecz seryjna bez numeru seryjnego');

SELECT assert_fails($q$
    INSERT INTO item (item_type_id, section_id, is_serialized, is_consumable, serial_number, quantity)
    VALUES (3, 6, FALSE, TRUE, 'X-1', 10) $q$,
    'A2 partia materialu z numerem seryjnym');

SELECT assert_fails($q$
    INSERT INTO item (item_type_id, section_id, is_serialized, is_consumable, serial_number, quantity)
    VALUES (1, 5, FALSE, FALSE, NULL, 10) $q$,
    'A3 flaga niezgodna z katalogiem (zlozony FK)');

SELECT assert_fails($q$
    INSERT INTO item (item_type_id, section_id, is_serialized, is_consumable, serial_number, quantity)
    VALUES (1, 5, TRUE, FALSE, 'BSH-0001', 1) $q$,
    'A4 duplikat numeru seryjnego w typie');

SELECT assert_fails($q$
    INSERT INTO item (item_type_id, section_id, is_serialized, is_consumable, serial_number, quantity)
    VALUES (3, 6, FALSE, TRUE, NULL, 10) $q$,
    'A5 druga partia tego samego typu w sekcji');

SELECT assert_fails($q$
    INSERT INTO item_type (name, short_name, is_serialized, unit)
    VALUES ('Piasek', 'PIASEK', TRUE, 'kg') $q$,
    'A6 rzecz seryjna w jednostce innej niz szt.');

SELECT assert_fails($q$
    INSERT INTO item_type (name, short_name, is_serialized, is_consumable)
    VALUES ('Wiertlo jednorazowe', 'WIER-1X', TRUE, TRUE) $q$,
    'A7 rzecz seryjna oznaczona jako zuzywalna');

SELECT assert_fails($q$
    INSERT INTO item (item_type_id, section_id, is_serialized, is_consumable, quantity)
    VALUES (3, 5, FALSE, FALSE, 5) $q$,
    'A8 flaga zuzywalnosci niezgodna z katalogiem');

-- ---------------------------------------------------------------------
-- B. Hierarchia sekcji
-- ---------------------------------------------------------------------
SELECT assert_fails($q$
    INSERT INTO section (warehouse_id, parent_section_id, section_name, section_type)
    VALUES (2, 1, 'Obca polka', 'shelf') $q$,
    'B1 sekcja nadrzedna z innego magazynu');

SELECT assert_fails($q$
    INSERT INTO section (warehouse_id, parent_section_id, section_name, section_type)
    VALUES (1, 5, 'Regal pod polka', 'rack') $q$,
    'B2 regal podrzedny wobec polki');

SELECT assert_fails($q$
    INSERT INTO section (warehouse_id, parent_section_id, section_name, section_type)
    VALUES (1, NULL, 'Wiszaca polka', 'shelf') $q$,
    'B3 polka bez sekcji nadrzednej');

-- Proba zapetlenia 1 -> 3 -> 5 -> 1. Porzadek poziomow sam w sobie wyklucza
-- cykle, wiec zatrzymuje ja juz kontrola poziomu; petla wykrywajaca cykl
-- w trgf_section_hierarchy jest druga linia obrony (gdyby porzadek poziomow
-- kiedykolwiek zluzowano).
SELECT assert_fails($q$ UPDATE section SET parent_section_id = 5 WHERE id = 1 $q$,
    'B4 proba zapetlenia hierarchii');

SELECT assert_fails($q$
    INSERT INTO section (warehouse_id, parent_section_id, section_name, section_type)
    VALUES (1, 1, 'Regal N1', 'rack') $q$,
    'B5 duplikat nazwy w tej samej sekcji nadrzednej');

-- ---------------------------------------------------------------------
-- C. Uprawnienia
-- ---------------------------------------------------------------------
SELECT assert_fails($q$
    INSERT INTO permission (user_id, warehouse_id, section_id, permission, granted_by_id)
    VALUES (5, NULL, NULL, 'preview', 1) $q$,
    'C1 uprawnienie bez zakresu');

SELECT assert_fails($q$
    INSERT INTO permission (user_id, warehouse_id, section_id, permission, granted_by_id)
    VALUES (5, 1, 5, 'preview', 1) $q$,
    'C2 uprawnienie z dwoma zakresami naraz');

SELECT assert_fails($q$
    INSERT INTO permission (user_id, warehouse_id, section_id, permission, granted_by_id)
    VALUES (2, 1, NULL, 'preview', 1) $q$,
    'C3 drugie uprawnienie do tego samego magazynu');

-- dziedziczenie uprawnien
SELECT assert_true(fn_effective_permission(2, 3) = 'full_access',
    'C4 magazynier dziedziczy full_access z magazynu');
SELECT assert_true(fn_effective_permission(2, 5) = 'denied',
    'C5 wpis na sekcji nadpisuje uprawnienie magazynowe');
SELECT assert_true(fn_effective_permission(3, 6) = 'edit',
    'C6 edit na polce M1-A mimo preview na magazynie');
SELECT assert_true(fn_effective_permission(5, 1) = 'denied',
    'C7 brak wpisu = brak dostepu');

-- ---------------------------------------------------------------------
-- D. Wypozyczenia: role i spojnosc dokumentu
-- ---------------------------------------------------------------------
SELECT assert_fails($q$
    INSERT INTO loan (borrower_id, loaner_id, due_date) VALUES (2, 1, CURRENT_DATE + 1) $q$,
    'D1 magazynier jako pobierajacy');

SELECT assert_fails($q$
    INSERT INTO loan (borrower_id, loaner_id, due_date) VALUES (4, 5, CURRENT_DATE + 1) $q$,
    'D2 pracownik jako wydajacy');

-- Wydanie samemu sobie blokuja dwa niezalezne mechanizmy: CHECK ck_loan_actors
-- oraz kontrola rol (nikt nie jest jednoczesnie worker i warehouseman),
-- dlatego komunikat pochodzi od wyzwalacza — uruchamia sie wczesniej.
SELECT assert_fails($q$
    INSERT INTO loan (borrower_id, loaner_id, due_date) VALUES (4, 4, CURRENT_DATE + 1) $q$,
    'D3 wydanie samemu sobie');

SELECT assert_fails($q$
    INSERT INTO loan (borrower_id, loaner_id, due_date) VALUES (4, 2, CURRENT_DATE - 1) $q$,
    'D4 termin zwrotu przed data wydania');

SELECT assert_fails($q$
    UPDATE loan SET status = 'settled' WHERE id = 1 $q$,
    'D5 status settled bez daty rozliczenia');

-- ---------------------------------------------------------------------
-- E. Dostepnosc i stan magazynowy
-- ---------------------------------------------------------------------
SELECT assert_true((SELECT quantity FROM item WHERE id = 4) = 240,
    'E1 przyjeto 250 kg wkretow, zuzyto 10 -> stan 240');

SELECT assert_true((SELECT qty_available FROM v_item_stock WHERE item_id = 5) = 424.5,
    'E2 przewod: 500 - 50 przeniesione - 25.5 wypozyczone = 424.5');

SELECT assert_true((SELECT qty_available FROM v_item_stock WHERE item_id = 1) = 0,
    'E3 wiertarka BSH-0001 wypozyczona, dostepne 0');

SELECT assert_fails($q$
    CALL sp_issue_loan(5, 2, CURRENT_DATE + 3,
                       '[{"item_id": 1, "qty": 1}]'::jsonb) $q$,
    'E4 wydanie rzeczy juz wypozyczonej');

SELECT assert_fails($q$
    CALL sp_issue_loan(5, 2, CURRENT_DATE + 3,
                       '[{"item_id": 5, "qty": 1000}]'::jsonb) $q$,
    'E5 wydanie wiekszej ilosci niz dostepna');

SELECT assert_fails($q$ CALL sp_dispose_items(4, 1000, 2) $q$,
    'E6 likwidacja wiekszej ilosci niz dostepna');

SELECT assert_fails($q$
    CALL sp_issue_loan(5, 2, CURRENT_DATE + 3, '[]'::jsonb) $q$,
    'E7 dokument wydania bez pozycji');

-- ---------------------------------------------------------------------
-- F. Cykl zycia wypozyczenia
-- ---------------------------------------------------------------------
CALL sp_return_loan_line(2, 10.5, 2);          -- czesciowy zwrot przewodu
SELECT assert_true((SELECT status FROM loan WHERE id = 1) = 'partially_returned',
    'F1 zwrot czesciowy ustawia status partially_returned');

SELECT assert_true((SELECT qty_available FROM v_item_stock WHERE item_id = 5) = 435,
    'F2 zwrot 10.5 m zwiekszyl dostepnosc do 435');

SELECT assert_fails($q$ CALL sp_return_loan_line(2, 100, 2) $q$,
    'F3 zwrot wiekszy niz pozostalo do zwrotu');

CALL sp_return_loan_line(1, 1, 2);             -- zwrot wiertarki
CALL sp_return_loan_line(2, 15, 2);            -- reszta przewodu
SELECT assert_true((SELECT status FROM loan WHERE id = 1) = 'settled',
    'F4 dokument rozliczony mimo niezwracalnej pozycji na wkrety');
SELECT assert_true((SELECT settled_at IS NOT NULL FROM loan WHERE id = 1),
    'F5 rozliczenie dokumentu ustawia settled_at');
SELECT assert_true((SELECT qty_available FROM v_item_stock WHERE item_id = 1) = 1,
    'F6 zwrocona wiertarka znow dostepna');

SELECT assert_true((SELECT count(*) FROM v_overdue_loans WHERE loan_id = 2) = 1,
    'F7 raport przeterminowanych wykrywa wypozyczenie nr 2');

-- ---------------------------------------------------------------------
-- G. Dziennik audytowy
-- ---------------------------------------------------------------------
SELECT assert_fails($q$ UPDATE stock_movement SET qty_delta = 1 WHERE id = 1 $q$,
    'G1 modyfikacja dziennika ruchow');
SELECT assert_fails($q$ DELETE FROM stock_movement WHERE id = 1 $q$,
    'G2 usuniecie wpisu z dziennika');
SELECT assert_fails($q$
    INSERT INTO stock_movement (item_id, movement_type, qty_delta, performed_by_id)
    VALUES (4, 'receipt', -5, 2) $q$,
    'G3 przyjecie z ujemna iloscia');
SELECT assert_fails($q$
    INSERT INTO stock_movement (item_id, movement_type, qty_delta, performed_by_id)
    VALUES (4, 'issue', -5, 2) $q$,
    'G4 wydanie bez powiazanej pozycji dokumentu');
SELECT assert_fails($q$
    INSERT INTO stock_movement (item_id, movement_type, qty_delta, loan_line_id, performed_by_id)
    VALUES (4, 'receipt', 5, 1, 2) $q$,
    'G5 przyjecie powiazane z pozycja dokumentu');

-- ---------------------------------------------------------------------
-- H. Walidacja pol
-- ---------------------------------------------------------------------
SELECT assert_fails($q$
    INSERT INTO app_user (login, password_hash, first_name, last_name, user_type)
    VALUES ('AB', 'x', 'A', 'B', 'worker') $q$,
    'H1 login za krotki i haslo bez skrotu');
SELECT assert_fails($q$
    INSERT INTO app_user (login, password_hash, first_name, last_name, contact_number, user_type)
    VALUES ('tester1', '$2b$12$9KXkx.LYly/MZmzANan0BObo1CPcp2DQdq3ERer4FSfs5GTgt6HUh', 'A', 'B', 'abc', 'worker') $q$,
    'H2 telefon w nieprawidlowym formacie');
SELECT assert_fails($q$
    INSERT INTO app_user (login, password_hash, first_name, last_name, user_type)
    VALUES ('tester2', '$2b$12$9KXkx.LYly/MZmzANan0BObo1CPcp2DQdq3ERer4FSfs5GTgt6HUh', '   ', 'B', 'worker') $q$,
    'H3 imie zlozone z samych spacji');
SELECT assert_fails($q$
    INSERT INTO item_type (name, short_name) VALUES ('Cos', 'male litery') $q$,
    'H4 skrot katalogowy w zlym formacie');

-- Najgrozniejszy blad aplikacji: zapis hasla jawnego zamiast skrotu bcrypt.
SELECT assert_fails($q$
    INSERT INTO app_user (login, password_hash, first_name, last_name, user_type)
    VALUES ('tester3', 'tajneHaslo123', 'A', 'B', 'worker') $q$,
    'H5 haslo jawne zamiast skrotu bcrypt');

SELECT assert_fails($q$
    INSERT INTO app_user (login, password_hash, first_name, last_name, user_type)
    VALUES ('tester4', '$2b$12$zakrotki', 'A', 'B', 'worker') $q$,
    'H6 skrot bcrypt o niepelnej dlugosci');

SELECT assert_fails($q$
    INSERT INTO app_user (login, password_hash, first_name, last_name, user_type)
    VALUES ('tester5', '$2z$12$Tgt6HUhu7IViv8JWjw9KXkx.LYly/MZmzANan0BObo1CPcp2DQdq3', 'A', 'B', 'worker') $q$,
    'H7 nieznany wariant algorytmu ($2z$)');

-- ---------------------------------------------------------------------
-- I. Materialy zuzywalne
-- ---------------------------------------------------------------------
SELECT assert_fails($q$ CALL sp_return_loan_line(3, 5, 2) $q$,
    'I1 zwrot materialu zuzywalnego');

SELECT assert_true((SELECT status FROM loan WHERE id = 3) = 'settled',
    'I2 dokument na same materialy zuzywalne rozlicza sie od razu');
SELECT assert_true((SELECT settled_at IS NOT NULL FROM loan WHERE id = 3),
    'I3 ...i dostaje date rozliczenia');

SELECT assert_true(fn_item_on_loan(4) = 0,
    'I4 wydane wkrety nie wisza na pracowniku (zeszly ze stanu)');
SELECT assert_true((SELECT quantity FROM item WHERE id = 6) = 42,
    'I5 piana: 48 przyjete - 6 wydane = 42');

SELECT assert_true(
    (SELECT count(*) FROM stock_movement
      WHERE movement_type = 'consumption' AND loan_line_id IS NOT NULL) = 2,
    'I6 wydanie materialu zuzywalnego tworzy ruch consumption');

SELECT assert_fails($q$
    INSERT INTO loan_line (loan_id, item_id, is_consumable, qty_issued)
    VALUES (1, 6, FALSE, 1) $q$,
    'I7 pozycja klamie o zuzywalnosci przedmiotu');

SELECT assert_fails($q$
    UPDATE loan_line SET qty_returned = 1 WHERE id = 3 $q$,
    'I8 modyfikacja pozycji na material zuzywalny');

SELECT assert_true(
    (SELECT qty_consumed FROM v_consumption_summary
      WHERE borrower_id = 4 AND item_type_id = 3) = 10,
    'I9 raport zuzycia pokazuje 10 kg wkretow dla Zielinskiego');

-- ---------------------------------------------------------------------
-- J. Przesuniecia miedzy sekcjami i magazynami
-- ---------------------------------------------------------------------
SELECT assert_true((SELECT section_id FROM item WHERE id = 2) = 7,
    'J1 narzedzie seryjne zmienilo sekcje na Kontener');
SELECT assert_true((SELECT warehouse_id FROM v_item_stock WHERE item_id = 2) = 2,
    'J2 ...czyli trafilo do drugiego magazynu');

SELECT assert_true((SELECT SUM(quantity) FROM item WHERE item_type_id = 4) = 500,
    'J3 przesuniecie materialu nie zmienia stanu posiadania firmy');
SELECT assert_true(
    (SELECT quantity FROM item WHERE item_type_id = 4 AND section_id = 7) = 50,
    'J4 partia docelowa zalozona automatycznie z iloscia 50');

SELECT assert_fails($q$ CALL sp_transfer_items(3, 7, 1, 2) $q$,
    'J5 przesuniecie rzeczy bedacej u pracownika');
SELECT assert_fails($q$ CALL sp_transfer_items(2, 7, 1, 2) $q$,
    'J6 przesuniecie do sekcji, w ktorej rzecz juz jest');
SELECT assert_fails($q$ CALL sp_transfer_items(5, 7, 10000, 2) $q$,
    'J7 przesuniecie wiekszej ilosci niz dostepna');
SELECT assert_fails($q$ CALL sp_transfer_items(2, 5, 2, 2) $q$,
    'J8 przesuniecie czesci rzeczy z numerem seryjnym');
SELECT assert_fails($q$ CALL sp_transfer_items(5, 999, 1, 2) $q$,
    'J9 przesuniecie do nieistniejacej sekcji');

SELECT assert_fails($q$
    INSERT INTO stock_movement (item_id, movement_type, qty_delta, performed_by_id)
    VALUES (5, 'transfer', 10, 2) $q$,
    'J10 ruch transfer bez wskazania sekcji');
SELECT assert_fails($q$
    INSERT INTO stock_movement (item_id, movement_type, qty_delta,
                                from_section_id, to_section_id, performed_by_id)
    VALUES (5, 'receipt', 10, 6, 7, 2) $q$,
    'J11 ruch przyjecia z sekcjami przesuniecia');
SELECT assert_fails($q$
    INSERT INTO stock_movement (item_id, movement_type, qty_delta,
                                from_section_id, to_section_id, performed_by_id)
    VALUES (5, 'transfer', 10, 6, 6, 2) $q$,
    'J12 przesuniecie z sekcji do niej samej');

-- ---------------------------------------------------------------------
-- Podsumowanie stanu po testach
-- ---------------------------------------------------------------------
SELECT item_id, item_name, serial_number, is_consumable, section_path,
       qty_owned, qty_on_loan, qty_available
FROM   v_item_stock ORDER BY item_id;

DROP FUNCTION assert_fails(TEXT, TEXT);
DROP FUNCTION assert_true(BOOLEAN, TEXT);
