// =====================================================================
//  b. MODEL LOGICZNY  —  System zarzadzania magazynem
//  Notacja: DBML (https://dbdiagram.io)
// =====================================================================

Project magazyn_logiczny {
  database_type: 'PostgreSQL'
  Note: 'Model logiczny bazy danych systemu zarzadzania magazynem przedsiebiorstwa budowlanego'
}

// ------------------------- SLOWNIKI (dziedziny) ----------------------

Enum user_type {
  admin          [note: 'Administrator - zarzadza kontami i uprawnieniami']
  warehouseman   [note: 'Magazynier - operacje na stanie magazynowym']
  worker         [note: 'Pracownik - podglad stanu, pobierajacy rzeczy z magazynu']
}

Enum section_type {
  area   [note: 'Strefa - najwyzszy poziom hierarchii']
  rack   [note: 'Regal']
  shelf  [note: 'Polka - najnizszy poziom hierarchii']
}

Enum unit_type {
  pcs [note: 'sztuka']
  kg  [note: 'kilogram']
  m   [note: 'metr']
  l   [note: 'litr']
}

Enum item_kind {
  serializable [note: 'Ma numer seryjny, sledzony indywidualnie, zwrotny']
  returnable   [note: 'Bez numeru seryjnego, sledzony ilosciowo, zwrotny']
  consumable   [note: 'Zuzywalny, bez zwrotu']
}

Enum loan_status {
  open               [note: 'Cos pozostaje do zwrotu']
  partially_returned [note: 'Czesc pozycji zwrotnych wrocila']
  settled            [note: 'Rozliczony - wszystko zwrocone albo zuzyte']
  cancelled          [note: 'Anulowane przed wydaniem']
}

Enum return_condition {
  ok
  damaged
  lost
}

Table unit {
  id          integer     [pk, increment]
  symbol      varchar(10) [not null, unique, note: 'skrot wyswietlany przy ilosci, np. szt., kg, m, l']
  name        varchar(50) [not null, note: 'pelna nazwa, np. sztuka, kilogram']
  allows_fraction boolean [not null, default: false, note: 'czy ilosc moze byc ulamkowa (kg, m, l - tak; szt. - nie)']
  is_active   boolean     [not null, default: true]

  Note: 'Slownik jednostek miary; rozszerzalny bez zmiany kodu'
}

Table section_type {
  id           integer     [pk, increment]
  code         varchar(30) [not null, unique, note: 'stabilny identyfikator, np. area, rack, shelf, carton, container']
  name         varchar(80) [not null, note: 'nazwa do wyswietlania np. półka, regał (dla człowieka)']
  can_be_root  boolean     [not null, default: false, note: 'czy sekcja tego typu moze nie miec rodzica']
  is_active    boolean     [not null, default: true]

  Note: 'Slownik typow sekcji; rozszerzalny bez zmiany kodu'
}

Table section_type_parent {
  child_type_id  integer [not null, ref: > section_type.id]
  parent_type_id integer [not null, ref: > section_type.id]

  indexes {
    (child_type_id, parent_type_id) [pk]
  }

  Note: 'Dozwolone zagniezdzenia: jaki typ moze lezec w jakim (np. shelf w rack, carton w shelf)'
}

Table section {
  id                integer      [pk, increment]
  parent_section_id integer      [null, ref: > section.id, note: 'NULL = korzen hierarchii']
  section_name      varchar(100) [not null]
  section_type_id   integer      [not null, ref: > section_type.id]

  Note: 'Hierarchia rekurencyjna o zmiennej glebokosci; poprawnosc zagniezdzenia wg section_type_parent'
}
// ------------------------- UZYTKOWNICY -------------------------------

Table app_user {
  id             integer   [pk, increment]
  login          varchar(50)  [not null, unique]
  password_hash  varchar(255) [not null, note: 'bcrypt']
  first_name     varchar(80)  [not null]
  last_name      varchar(80)  [not null]
  contact_number varchar(20)
  address_id     integer   [not null, ref: > address.id]
  user_type      user_type [not null]
  is_active      boolean   [not null, default: true, note: 'false - uzytkownik usuniety (soft delete)']
  created_at     timestamp [not null, default: `now()`]
}

// ------------------------- KATALOG PRZEDMIOTOW -----------------------

Table item_model {
  id           integer      [pk, increment]
  name         varchar(150) [not null, unique]
  short_name   varchar(50)  [not null, unique]
  kind         item_kind    [not null]
  unit_id      integer      [not null, ref: > unit.id]
  min_quantity decimal(12,3) [not null, default: 0, note: 'prog alertu o niskim stanie']
  description  text

  Note: 'Katalog: rodzaj/model przedmiotu (np. Wiertarka Bosch GSB 13, Wkret 5x50)'
}

Table item {
  id            integer       [pk, increment]
  item_model_id integer       [not null, ref: > item_model.id]
  section_id    integer       [not null, ref: > section.id]
  serial_number varchar(100)  [note: 'Wymagany <=> item_model.kind = serializable']
  quantity      decimal(12,3) [not null, default: 0, note: 'Ilosc POSIADANA (nie dostepna). serializable: 1 na stanie. Dostepna = quantity - niezwrocone pozycje (returnable/serializable).']
  is_active     boolean       [not null, default: true, note: 'false - zlikwidowany / wycofany']
  created_at    timestamp     [not null, default: `now()`]

  indexes {
    (item_model_id, serial_number) [unique, note: 'NULL-e dozwolone wielokrotnie']
    section_id
  }

  Note: '''
  Reguly zalezne od rodzaju (serial_number, quantity = 1) - serwis.
  '''
}


// ------------------------- WYPOZYCZENIA ------------------------------

Table loan {
  id             integer     [pk, increment]
  issued_by_id   integer     [not null, ref: > app_user.id, note: 'magazynier, ktory wydal']
  borrower_id    integer     [not null, ref: > app_user.id, note: 'komu wydano']
  issued_at      timestamp   [not null, default: `now()`]
  due_date       date        [note: 'Termin zwrotu; NULL gdy same materialy zuzywalne']
  settled_at     timestamp   [note: 'Wypelniane gdy status = settled']
  status         loan_status [not null, default: 'open', note: 'Pochodny od pozycji - aktualizowac w jednej transakcji ze zwrotem']
  remarks        text

  indexes {
    borrower_id
    status
  }

  Note: 'Naglowek dokumentu wydania. Jedno zdarzenie = kilka pozycji.'
}

Table loan_line {
  id           integer       [pk, increment]
  loan_id      integer       [not null, ref: > loan.id]
  item_id      integer       [not null, ref: > item.id]
  qty_issued   decimal(12,3) [not null, note: 'CHECK (qty_issued > 0)']

  indexes {
    loan_id
    item_id
  }

  Note: '''
  Pozycja dokumentu. Zwroty czesciowe dozwolone.
  consumable: qty_returned zawsze 0, pozycja nie wstrzymuje rozliczenia.
  serializable: qty_issued = 1; ta sama sztuka nie moze byc w dwoch otwartych wypozyczeniach.
  '''
}

Table loan_return {
  id             integer          [pk, increment]
  loan_line_id   integer          [not null, ref: > loan_line.id]
  qty            decimal(12,3)    [not null, note: 'CHECK (qty > 0)']
  condition      return_condition [not null, default: 'ok']
  returned_at    timestamp        [not null, default: `now()`]
  received_by_id integer          [not null, ref: > app_user.id, note: 'magazynier, ktory przyjal zwrot']
  comment        text

  indexes {
    loan_line_id
  }

  Note: 'Pojedyncze zdarzenie zwrotu (wspiera zwroty czesciowe i ocene stanu)'
}


Table country {
  id   integer     [pk, increment]
  code char(2)     [not null, unique, note: 'ISO 3166-1 alpha-2, np. PL']
  name varchar(80) [not null]
}

Table city {
  id         integer     [pk, increment]
  country_id integer     [not null, ref: > country.id]
  name       varchar(100) [not null]

  indexes {
    (country_id, name) [unique]
  }
}

Table address {
  id             integer     [pk, increment]
  city_id        integer     [not null, ref: > city.id]
  postal_code    varchar(10) [not null, note: 'np. 50-370']
  street         varchar(150) [note: 'NULL dla miejscowosci bez ulic']
  building_number varchar(20) [not null, note: 'tekst, bo zdarza sie 12A, 5/7']
  apartment_number varchar(20) [note: 'NULL dla domow']

  Note: 'Adres; moze byc wspoldzielony przez kilku uzytkownikow'
}
