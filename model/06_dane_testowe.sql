-- =====================================================================
--  Dane testowe
--  Uruchamiac po 04_model_fizyczny.sql i 05_pozostale_elementy.sql
-- =====================================================================

SET search_path TO wms, public;

-- ---------------------------------------------------------------------
-- Uzytkownicy
-- ---------------------------------------------------------------------
INSERT INTO app_user (login, password_hash, first_name, last_name, contact_number, address, user_type) VALUES
  ('admin',    '$2b$12$FSfs5GTgt6HUhu7IViv8JWjw9KXkx.LYly/MZmzANan0BObo1CPcp', 'Anna',     'Kowalczyk',  '+48 601 100 200', 'Wroclaw, Powstancow Sl. 1', 'admin'),
  ('mnowak',   '$2b$12$MZmzANan0BObo1CPcp2DQdq3ERer4FSfs5GTgt6HUhu7IViv8JWjw', 'Marek',    'Nowak',      '+48 601 100 201', 'Wroclaw, Legnicka 5',       'warehouseman'),
  ('kwisnia',  '$2b$12$Tgt6HUhu7IViv8JWjw9KXkx.LYly/MZmzANan0BObo1CPcp2DQdq3', 'Katarzyna','Wisniewska', '+48 601 100 202', 'Wroclaw, Grabiszynska 9',   'warehouseman'),
  ('jzielak',  '$2b$12$an0BObo1CPcp2DQdq3ERer4FSfs5GTgt6HUhu7IViv8JWjw9KXkx.', 'Jan',      'Zielinski',  '+48 601 100 203', 'Olawa, Polna 3',            'worker'),
  ('pmaj',     '$2b$12$hu7IViv8JWjw9KXkx.LYly/MZmzANan0BObo1CPcp2DQdq3ERer4F', 'Piotr',    'Majewski',   '+48 601 100 204', 'Wroclaw, Krucza 12',        'worker');

-- ---------------------------------------------------------------------
-- Magazyny i hierarchia sekcji
-- ---------------------------------------------------------------------
INSERT INTO warehouse (name, address) VALUES
  ('Magazyn glowny',   'Wroclaw, Fabryczna 20'),
  ('Magazyn budowy A', 'Olawa, Przemyslowa 4');

INSERT INTO section (warehouse_id, parent_section_id, section_name, section_type) VALUES
  (1, NULL, 'Strefa narzedzi',   'area'),      -- id 1
  (1, NULL, 'Strefa materialow', 'area');      -- id 2
INSERT INTO section (warehouse_id, parent_section_id, section_name, section_type) VALUES
  (1, 1, 'Regal N1', 'rack'),                  -- id 3
  (1, 2, 'Regal M1', 'rack');                  -- id 4
INSERT INTO section (warehouse_id, parent_section_id, section_name, section_type) VALUES
  (1, 3, 'Polka N1-A', 'shelf'),               -- id 5
  (1, 4, 'Polka M1-A', 'shelf');               -- id 6
INSERT INTO section (warehouse_id, parent_section_id, section_name, section_type) VALUES
  (2, NULL, 'Kontener', 'area');               -- id 7 (drugi magazyn)

-- ---------------------------------------------------------------------
-- Asortyment: narzedzia seryjne, materialy zwrotne i zuzywalne
-- ---------------------------------------------------------------------
INSERT INTO item_type (name, short_name, is_serialized, is_consumable, unit) VALUES
  ('Wiertarka udarowa Bosch GSB 18V', 'WIERT-GSB', TRUE,  FALSE, 'pcs'),  -- 1
  ('Mlotowiertarka Hilti TE 7',       'MLOT-TE7',  TRUE,  FALSE, 'pcs'),  -- 2
  ('Wkret ciesielski 4x40',           'WKR-4X40',  FALSE, TRUE,  'kg'),   -- 3 zuzywalny
  ('Przewod zasilajacy 3x2.5',        'PRZ-325',   FALSE, FALSE, 'm'),    -- 4 zwrotny
  ('Piana montazowa PU 750 ml',       'PIANA-PU',  FALSE, TRUE,  'l');    -- 5 zuzywalny

INSERT INTO item (item_type_id, section_id, is_serialized, is_consumable, serial_number, quantity) VALUES
  (1, 5, TRUE,  FALSE, 'BSH-0001', 1),   -- 1
  (1, 5, TRUE,  FALSE, 'BSH-0002', 1),   -- 2
  (2, 5, TRUE,  FALSE, 'HIL-1001', 1),   -- 3
  (3, 6, FALSE, TRUE,  NULL, 0),         -- 4  wkrety
  (4, 6, FALSE, FALSE, NULL, 0),         -- 5  przewod
  (5, 6, FALSE, TRUE,  NULL, 0);         -- 6  piana

-- ---------------------------------------------------------------------
-- Uprawnienia
-- ---------------------------------------------------------------------
INSERT INTO permission (user_id, warehouse_id, section_id, permission, granted_by_id) VALUES
  (2, 1,    NULL, 'full_access', 1),   -- Nowak: caly magazyn glowny
  (2, NULL, 5,    'denied',      1),   -- ...poza polka N1-A
  (3, 1,    NULL, 'preview',     1),   -- Wisniewska: podglad magazynu glownego
  (3, NULL, 6,    'edit',        1),   -- ...z prawem edycji polki M1-A
  (4, 1,    NULL, 'preview',     1);

-- ---------------------------------------------------------------------
-- Przyjecia na stan
-- ---------------------------------------------------------------------
CALL sp_receive_items(4, 250.000, 2, 'Dostawa FV 12/2026 — wkrety');
CALL sp_receive_items(5, 500.000, 2, 'Dostawa FV 12/2026 — przewod');
CALL sp_receive_items(6,  48.000, 2, 'Dostawa FV 13/2026 — piana');

-- ---------------------------------------------------------------------
-- Dokument mieszany: narzedzie + material zwrotny + material zuzywalny
-- ---------------------------------------------------------------------
DO $$
DECLARE v_loan BIGINT;
BEGIN
    CALL sp_issue_loan(
        p_borrower_id  => 4,
        p_loaner_id    => 2,
        p_due_date     => CURRENT_DATE + 7,
        p_lines        => '[{"item_id": 1, "qty": 1},
                            {"item_id": 5, "qty": 25.5},
                            {"item_id": 4, "qty": 10}]'::jsonb,
        p_remarks      => 'Budowa Olawa - etap 1',
        p_loan_id      => v_loan);
    RAISE NOTICE 'Dokument mieszany nr % (pozycje 1-3)', v_loan;
END $$;

-- Wypozyczenie przeterminowane (do raportu)
DO $$
DECLARE v_loan BIGINT;
BEGIN
    CALL sp_issue_loan(4, 3, CURRENT_DATE + 7,
                       '[{"item_id": 3, "qty": 1}]'::jsonb, NULL, v_loan);
    -- cofniecie w czasie: ck_loan_due wymaga due_date >= data wydania,
    -- wiec oba pola trzeba zmienic jednoczesnie
    UPDATE loan
       SET issued_at = now() - INTERVAL '20 days',
           due_date  = CURRENT_DATE - 3
     WHERE id = v_loan;
    RAISE NOTICE 'Dokument przeterminowany nr % (pozycja 4)', v_loan;
END $$;

-- Dokument z samymi materialami zuzywalnymi — rozlicza sie od razu
DO $$
DECLARE v_loan BIGINT;
BEGIN
    CALL sp_issue_loan(5, 2, CURRENT_DATE + 14,
                       '[{"item_id": 6, "qty": 6}]'::jsonb,
                       'Piana na docieplenie', v_loan);
    RAISE NOTICE 'Dokument na materialy zuzywalne nr % (pozycja 5)', v_loan;
END $$;

-- ---------------------------------------------------------------------
-- Przesuniecia miedzy magazynami
-- ---------------------------------------------------------------------
-- narzedzie seryjne: jeden wiersz zmienia sekcje
CALL sp_transfer_items(2, 7, 1,  2, 'Wiertarka na budowe A');
-- material sypki: ilosc przechodzi do nowej partii w sekcji docelowej
CALL sp_transfer_items(5, 7, 50, 2, 'Przewod na budowe A');
