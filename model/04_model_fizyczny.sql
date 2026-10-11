-- =====================================================================
--  c. MODEL FIZYCZNY — PostgreSQL 15+
--  System zarzadzania magazynem przedsiebiorstwa budowlanego
--  Plik zrodlowy: tabele, typy, ograniczenia integralnosci, indeksy.
--  Widoki / funkcje / procedury / wyzwalacze -> 05_pozostale_elementy.sql
-- =====================================================================
--  Zalozenie instalacyjne:
--    CREATE DATABASE wms
--      ENCODING 'UTF8' LC_COLLATE 'pl_PL.UTF-8' LC_CTYPE 'pl_PL.UTF-8'
--      TEMPLATE template0;
-- =====================================================================

DROP SCHEMA IF EXISTS wms CASCADE;
CREATE SCHEMA wms;
SET search_path TO wms, public;

-- ---------------------------------------------------------------------
-- 1. DZIEDZINY I TYPY WYLICZENIOWE
-- ---------------------------------------------------------------------

CREATE TYPE user_type       AS ENUM ('admin', 'warehouseman', 'worker');
CREATE TYPE section_type    AS ENUM ('area', 'rack', 'shelf');
CREATE TYPE unit_type       AS ENUM ('pcs', 'kg', 'm', 'l');
CREATE TYPE permission_type AS ENUM ('full_access', 'edit', 'preview', 'denied');
CREATE TYPE movement_type   AS ENUM ('receipt', 'issue', 'return', 'consumption',
                                     'transfer', 'disposal', 'adjustment');
-- 'settled' zamiast 'returned': dokument moze zawierac same materialy zuzywalne,
-- ktore nigdy nie wracaja — wtedy "zwrocony" byloby mylace. Settled = rozliczony.
CREATE TYPE loan_status     AS ENUM ('open', 'partially_returned', 'settled', 'cancelled');

-- Dziedzina ilosci: skala 3 (gramy / milimetry / mililitry), nieujemna.
CREATE DOMAIN qty AS NUMERIC(12,3)
    CONSTRAINT ck_qty_nonneg CHECK (VALUE >= 0);

-- Dziedzina zmiany ilosci: moze byc ujemna, ale nie zerowa.
CREATE DOMAIN qty_delta AS NUMERIC(12,3)
    CONSTRAINT ck_qty_delta_nonzero CHECK (VALUE <> 0);

-- ---------------------------------------------------------------------
-- 2. UZYTKOWNICY
-- ---------------------------------------------------------------------
-- Nazwa "app_user": "user" jest slowem zastrzezonym w standardzie SQL
-- i funkcja biezacego uzytkownika w PostgreSQL.

CREATE TABLE app_user (
    id             BIGINT       GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    login          VARCHAR(50)  NOT NULL,
    password_hash  VARCHAR(60)  NOT NULL,
    first_name     VARCHAR(50)  NOT NULL,
    last_name      VARCHAR(50)  NOT NULL,
    contact_number VARCHAR(20),
    address        VARCHAR(200),
    user_type      user_type    NOT NULL,
    is_active      BOOLEAN      NOT NULL DEFAULT TRUE,
    created_at     TIMESTAMPTZ  NOT NULL DEFAULT now(),

    CONSTRAINT uq_app_user_login     UNIQUE (login),

    CONSTRAINT ck_app_user_login     CHECK (login ~ '^[a-z0-9._-]{3,50}$'),
    -- Skrot bcrypt ma niezmienna postac: $2<wariant>$<koszt>$<22 znaki soli>
    -- <31 znakow skrotu>, lacznie 60 znakow. Pinujemy ja dokladnie, bo prog
    -- dlugosci niczego nie gwarantuje. VARCHAR(60), nie 72 — 72 to limit
    -- WEJSCIA bcrypta (dlugosc hasla), a nie dlugosc wyniku.
    -- Uwaga: Spring Security z DelegatingPasswordEncoder zapisuje wartosc
    -- z prefiksem '{bcrypt}' (68 znakow). W takim wdrozeniu uzyj
    -- VARCHAR(68) i wzorca '^\{bcrypt\}\$2[abxy]\$[0-9]{2}\$[./A-Za-z0-9]{53}$'.
    CONSTRAINT ck_app_user_hash CHECK (
        password_hash ~ '^\$2[abxy]\$[0-9]{2}\$[./A-Za-z0-9]{53}$'),
    CONSTRAINT ck_app_user_names     CHECK (btrim(first_name) <> '' AND btrim(last_name) <> ''),
    CONSTRAINT ck_app_user_phone     CHECK (
        contact_number IS NULL OR contact_number ~ '^\+?[0-9 ()-]{7,20}$'),
    CONSTRAINT ck_app_user_address   CHECK (address IS NULL OR btrim(address) <> '')
);

COMMENT ON TABLE  app_user IS
  'Uzytkownicy systemu; user_type jest dyskryminatorem roli. Zgodnosc rol z operacjami
   wymusza wyzwalacz trg_loan_roles (nie klucz obcy — dla czytelnych komunikatow bledow).';
COMMENT ON COLUMN app_user.password_hash IS
  'Skrot bcrypt, zawsze 60 znakow. Nigdy haslo jawne — pilnuje tego ck_app_user_hash.';
COMMENT ON COLUMN app_user.is_active IS 'Usuniecie logiczne — historia wypozyczen musi przetrwac.';

CREATE INDEX idx_app_user_type_active ON app_user (user_type) WHERE is_active;
CREATE INDEX idx_app_user_name        ON app_user (last_name, first_name);

-- ---------------------------------------------------------------------
-- 3. MAGAZYNY I SEKCJE
-- ---------------------------------------------------------------------

CREATE TABLE warehouse (
    id      BIGINT       GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name    VARCHAR(100) NOT NULL,
    address VARCHAR(200) NOT NULL,

    CONSTRAINT uq_warehouse_name UNIQUE (name),
    CONSTRAINT ck_warehouse_name CHECK (btrim(name) <> ''),
    CONSTRAINT ck_warehouse_addr CHECK (btrim(address) <> '')
);

CREATE TABLE section (
    id                BIGINT       GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    warehouse_id      BIGINT       NOT NULL,
    parent_section_id BIGINT,
    section_name      VARCHAR(100) NOT NULL,
    section_type      section_type NOT NULL,

    CONSTRAINT fk_section_warehouse FOREIGN KEY (warehouse_id)
        REFERENCES warehouse (id) ON UPDATE CASCADE ON DELETE RESTRICT,

    -- klucz pomocniczy dla zlozonego FK ponizej
    CONSTRAINT uq_section_id_warehouse UNIQUE (id, warehouse_id),

    -- sekcja nadrzedna musi lezec w TYM SAMYM magazynie (deklaratywnie)
    CONSTRAINT fk_section_parent FOREIGN KEY (parent_section_id, warehouse_id)
        REFERENCES section (id, warehouse_id) ON UPDATE CASCADE ON DELETE RESTRICT,

    CONSTRAINT ck_section_no_self CHECK (parent_section_id IS DISTINCT FROM id),
    CONSTRAINT ck_section_name    CHECK (btrim(section_name) <> ''),
    -- Korzen hierarchii musi byc strefa. Regula patrzy wylacznie na kolumny
    -- tego samego wiersza, wiec nie potrzebuje wyzwalacza — CHECK jest
    -- deklaratywny, niewylaczalny i tanszy.
    CONSTRAINT ck_section_root_is_area CHECK (
        parent_section_id IS NOT NULL OR section_type = 'area')
);

-- Unikalnosc nazwy w obrebie sekcji nadrzednej. NULLS NOT DISTINCT (PG 15+)
-- sprawia, ze regula obejmuje takze korzenie hierarchii (parent IS NULL).
-- Odpowiednik dla PostgreSQL 14 i starszych (dwa indeksy czesciowe):
--   CREATE UNIQUE INDEX uq_section_name_in_parent ON section
--       (warehouse_id, parent_section_id, section_name)
--       WHERE parent_section_id IS NOT NULL;
--   CREATE UNIQUE INDEX uq_section_name_root ON section
--       (warehouse_id, section_name) WHERE parent_section_id IS NULL;
CREATE UNIQUE INDEX uq_section_name_in_parent
    ON section (warehouse_id, parent_section_id, section_name) NULLS NOT DISTINCT;
CREATE INDEX idx_section_parent    ON section (parent_section_id);
CREATE INDEX idx_section_warehouse ON section (warehouse_id);

COMMENT ON TABLE section IS
  'Hierarchia miejsc skladowania: area > rack > shelf. Brak cykli i porzadek poziomow wymusza trg_section_hierarchy.';

-- ---------------------------------------------------------------------
-- 4. ASORTYMENT I STAN
-- ---------------------------------------------------------------------

CREATE TABLE item_type (
    id            BIGINT       GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name          VARCHAR(100) NOT NULL,
    short_name    VARCHAR(20)  NOT NULL,
    is_serialized BOOLEAN      NOT NULL DEFAULT FALSE,
    is_consumable BOOLEAN      NOT NULL DEFAULT FALSE,
    unit          unit_type    NOT NULL DEFAULT 'pcs',

    CONSTRAINT uq_item_type_name  UNIQUE (name),
    CONSTRAINT uq_item_type_short UNIQUE (short_name),
    -- klucz pomocniczy dla zlozonego FK z item
    CONSTRAINT uq_item_type_flags UNIQUE (id, is_serialized, is_consumable),

    CONSTRAINT ck_item_type_name  CHECK (btrim(name) <> ''),
    CONSTRAINT ck_item_type_short CHECK (short_name ~ '^[A-Z0-9_-]{2,20}$'),
    -- rzecz ewidencjonowana indywidualnie musi byc liczona w sztukach
    CONSTRAINT ck_item_type_unit  CHECK (NOT is_serialized OR unit = 'pcs'),
    -- narzedzie z numerem seryjnym nie jest materialem zuzywalnym
    CONSTRAINT ck_item_type_flags CHECK (NOT (is_serialized AND is_consumable))
);

COMMENT ON COLUMN item_type.is_serialized IS
  'TRUE = kazda sztuka osobnym wierszem w item (narzedzia); FALSE = partia o ilosci (materialy).';
COMMENT ON COLUMN item_type.is_consumable IS
  'TRUE = material zuzywalny (wkrety, piana) — wydany schodzi ze stanu i nie wraca.';

CREATE TABLE item (
    id            BIGINT      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    item_type_id  BIGINT      NOT NULL,
    section_id    BIGINT      NOT NULL,
    is_serialized BOOLEAN     NOT NULL,
    is_consumable BOOLEAN     NOT NULL,
    serial_number VARCHAR(50),
    quantity      qty         NOT NULL DEFAULT 0,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),

    -- zlozony FK: kopie flag nie moga sie rozjechac z katalogiem
    CONSTRAINT fk_item_type FOREIGN KEY (item_type_id, is_serialized, is_consumable)
        REFERENCES item_type (id, is_serialized, is_consumable)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_item_section FOREIGN KEY (section_id)
        REFERENCES section (id) ON UPDATE CASCADE ON DELETE RESTRICT,

    -- klucz pomocniczy dla zlozonego FK z loan_line
    CONSTRAINT uq_item_id_consumable UNIQUE (id, is_consumable),

    -- jadro modelu hybrydowego
    -- quantity = 1 dla rzeczy seryjnej na stanie, 0 po likwidacji
    CONSTRAINT ck_item_tracking CHECK (
            (is_serialized     AND quantity IN (0, 1) AND serial_number IS NOT NULL)
         OR (NOT is_serialized AND serial_number IS NULL)),
    CONSTRAINT ck_item_serial CHECK (
        serial_number IS NULL OR btrim(serial_number) <> '')
);

COMMENT ON COLUMN item.quantity IS
  'Ilosc POSIADANA, nie dostepna. Dostepna = quantity - suma otwartych pozycji wypozyczen (widok v_item_stock).';

-- numer seryjny unikalny w obrebie typu (tylko dla rzeczy seryjnych)
CREATE UNIQUE INDEX uq_item_serial
    ON item (item_type_id, serial_number) WHERE serial_number IS NOT NULL;
-- jedna partia danego typu na sekcje (tylko dla rzeczy nieseryjnych)
CREATE UNIQUE INDEX uq_item_bulk_per_section
    ON item (item_type_id, section_id) WHERE NOT is_serialized;

CREATE INDEX idx_item_type    ON item (item_type_id);
CREATE INDEX idx_item_section ON item (section_id);
-- przyspiesza "co jest dostepne" (najczestsze zapytanie wszystkich trzech rol)
CREATE INDEX idx_item_available ON item (item_type_id, section_id)
    WHERE quantity > 0;

-- ---------------------------------------------------------------------
-- 5. UPRAWNIENIA
-- ---------------------------------------------------------------------

CREATE TABLE permission (
    id            BIGINT          GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id       BIGINT          NOT NULL,
    warehouse_id  BIGINT,
    section_id    BIGINT,
    permission    permission_type NOT NULL,
    granted_by_id BIGINT          NOT NULL,
    granted_at    TIMESTAMPTZ     NOT NULL DEFAULT now(),

    CONSTRAINT fk_permission_user FOREIGN KEY (user_id)
        REFERENCES app_user (id) ON UPDATE CASCADE ON DELETE CASCADE,
    CONSTRAINT fk_permission_grantor FOREIGN KEY (granted_by_id)
        REFERENCES app_user (id) ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_permission_warehouse FOREIGN KEY (warehouse_id)
        REFERENCES warehouse (id) ON UPDATE CASCADE ON DELETE CASCADE,
    CONSTRAINT fk_permission_section FOREIGN KEY (section_id)
        REFERENCES section (id) ON UPDATE CASCADE ON DELETE CASCADE,

    -- zakres uprawnienia to DOKLADNIE jeden obiekt (XOR)
    CONSTRAINT ck_permission_scope CHECK (num_nonnulls(warehouse_id, section_id) = 1)
);

CREATE UNIQUE INDEX uq_permission_user_warehouse
    ON permission (user_id, warehouse_id) WHERE warehouse_id IS NOT NULL;
CREATE UNIQUE INDEX uq_permission_user_section
    ON permission (user_id, section_id)   WHERE section_id IS NOT NULL;
CREATE INDEX idx_permission_user ON permission (user_id);

COMMENT ON TABLE permission IS
  'Uprawnienie do magazynu ALBO sekcji. Uprawnienie do sekcji ma pierwszenstwo nad magazynowym (fn_effective_permission).';

-- ---------------------------------------------------------------------
-- 6. WYPOZYCZENIA
-- ---------------------------------------------------------------------

CREATE TABLE loan (
    id          BIGINT       GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    loaner_id   BIGINT       NOT NULL,
    borrower_id BIGINT       NOT NULL,
    issued_at   TIMESTAMPTZ  NOT NULL DEFAULT now(),
    due_date    DATE         NOT NULL,
    settled_at  TIMESTAMPTZ,
    status      loan_status  NOT NULL DEFAULT 'open',
    remarks     VARCHAR(500),

    -- loaner_id  = magazynier wydajacy (rola warehouseman/admin)
    -- borrower_id = pracownik pobierajacy (rola worker)
    CONSTRAINT fk_loan_loaner FOREIGN KEY (loaner_id)
        REFERENCES app_user (id) ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_loan_borrower FOREIGN KEY (borrower_id)
        REFERENCES app_user (id) ON UPDATE CASCADE ON DELETE RESTRICT,

    CONSTRAINT ck_loan_actors CHECK (borrower_id <> loaner_id),
    -- 'Europe/Warsaw' podane jawnie: wyrazenie musi byc IMMUTABLE w CHECK
    CONSTRAINT ck_loan_due CHECK (
        due_date >= (issued_at AT TIME ZONE 'Europe/Warsaw')::date),
    CONSTRAINT ck_loan_settled_flag CHECK (
        (status = 'settled') = (settled_at IS NOT NULL)),
    CONSTRAINT ck_loan_settled_ts CHECK (
        settled_at IS NULL OR settled_at >= issued_at),
    CONSTRAINT ck_loan_remarks CHECK (remarks IS NULL OR btrim(remarks) <> '')
);

CREATE INDEX idx_loan_borrower_status ON loan (borrower_id, status);
CREATE INDEX idx_loan_loaner          ON loan (loaner_id);
CREATE INDEX idx_loan_issued_at       ON loan (issued_at DESC);
-- raport przeterminowanych: tylko wypozyczenia niezamkniete
CREATE INDEX idx_loan_overdue ON loan (due_date)
    WHERE status IN ('open', 'partially_returned');

CREATE TABLE loan_line (
    id           BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    loan_id       BIGINT NOT NULL,
    item_id       BIGINT NOT NULL,
    is_consumable BOOLEAN NOT NULL,
    qty_issued    NUMERIC(12,3) NOT NULL,
    qty_returned  NUMERIC(12,3) NOT NULL DEFAULT 0,

    CONSTRAINT fk_loan_line_loan FOREIGN KEY (loan_id)
        REFERENCES loan (id) ON UPDATE CASCADE ON DELETE CASCADE,
    -- zlozony FK: pozycja wie, czy dotyczy materialu zuzywalnego, i nie moze sklamac
    CONSTRAINT fk_loan_line_item FOREIGN KEY (item_id, is_consumable)
        REFERENCES item (id, is_consumable) ON UPDATE CASCADE ON DELETE RESTRICT,

    CONSTRAINT uq_loan_line_item     UNIQUE (loan_id, item_id),
    CONSTRAINT ck_loan_line_issued   CHECK (qty_issued > 0),
    CONSTRAINT ck_loan_line_returned CHECK (qty_returned >= 0 AND qty_returned <= qty_issued),
    -- material zuzywalny nie wraca do magazynu
    CONSTRAINT ck_loan_line_consumable CHECK (NOT is_consumable OR qty_returned = 0)
);

CREATE INDEX idx_loan_line_item ON loan_line (item_id);
-- pozycje zwrotne jeszcze niezwrocone — podstawa wyliczania dostepnosci.
-- Materialy zuzywalne sa wylaczone: schodza ze stanu juz przy wydaniu.
CREATE INDEX idx_loan_line_outstanding ON loan_line (item_id, loan_id)
    WHERE NOT is_consumable AND qty_returned < qty_issued;

-- ---------------------------------------------------------------------
-- 7. DZIENNIK RUCHOW MAGAZYNOWYCH (append-only)
-- ---------------------------------------------------------------------

CREATE TABLE stock_movement (
    id              BIGINT        GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    item_id         BIGINT        NOT NULL,
    movement_type   movement_type NOT NULL,
    qty_delta       qty_delta     NOT NULL,
    loan_line_id    BIGINT,
    from_section_id BIGINT,
    to_section_id   BIGINT,
    performed_by_id BIGINT        NOT NULL,
    occurred_at     TIMESTAMPTZ   NOT NULL DEFAULT now(),
    remarks         VARCHAR(500),

    CONSTRAINT fk_movement_item FOREIGN KEY (item_id)
        REFERENCES item (id) ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_movement_loan_line FOREIGN KEY (loan_line_id)
        REFERENCES loan_line (id) ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_movement_user FOREIGN KEY (performed_by_id)
        REFERENCES app_user (id) ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_movement_from_section FOREIGN KEY (from_section_id)
        REFERENCES section (id) ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_movement_to_section FOREIGN KEY (to_section_id)
        REFERENCES section (id) ON UPDATE CASCADE ON DELETE RESTRICT,

    -- znak zmiany musi odpowiadac rodzajowi ruchu
    CONSTRAINT ck_movement_sign CHECK (
            (movement_type = 'receipt'     AND qty_delta > 0)
         OR (movement_type = 'disposal'    AND qty_delta < 0)
         OR (movement_type = 'consumption' AND qty_delta < 0)
         OR (movement_type = 'issue'       AND qty_delta < 0)
         OR (movement_type = 'return'      AND qty_delta > 0)
         OR (movement_type = 'adjustment')   -- dowolny znak, zero wyklucza dziedzina
         OR (movement_type = 'transfer')),   -- znak zalezy od strony przesuniecia
    -- ruch zwiazany z dokumentem wydania zawsze wskazuje pozycje i tylko on
    CONSTRAINT ck_movement_loan_link CHECK (
        (movement_type IN ('issue', 'return', 'consumption'))
            = (loan_line_id IS NOT NULL)),
    -- przesuniecie zawsze zna obie sekcje i tylko ono
    CONSTRAINT ck_movement_sections CHECK (
        (movement_type = 'transfer')
            = (from_section_id IS NOT NULL AND to_section_id IS NOT NULL)),
    CONSTRAINT ck_movement_transfer_distinct CHECK (
        from_section_id IS NULL OR from_section_id <> to_section_id)
);

CREATE INDEX idx_movement_item_time ON stock_movement (item_id, occurred_at DESC);
CREATE INDEX idx_movement_time      ON stock_movement (occurred_at DESC);
CREATE INDEX idx_movement_loan_line ON stock_movement (loan_line_id)
    WHERE loan_line_id IS NOT NULL;
CREATE INDEX idx_movement_user      ON stock_movement (performed_by_id);
-- historia przesuniec do sekcji ("co tu przyszlo i skad")
CREATE INDEX idx_movement_to_section ON stock_movement (to_section_id, occurred_at DESC)
    WHERE movement_type = 'transfer';

COMMENT ON COLUMN loan.settled_at IS
  'Chwila rozliczenia dokumentu: wszystko zwrocone albo zuzyte.';

COMMENT ON TABLE stock_movement IS
  'Dziennik audytowy. Append-only (trg_movement_append_only). Zrodlo prawdy dla item.quantity i lokalizacji.';
COMMENT ON COLUMN stock_movement.qty_delta IS
  'Dla transfer: ujemny po stronie zrodla, dodatni po stronie celu (material sypki); 1 dla rzeczy seryjnej, ktora tylko zmienia sekcje.';
