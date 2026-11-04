Project magazynownik {
  database_type: 'PostgreSQL'
  Note: 'System zarzadzania magazynem przedsiebiorstwa budowlanego'
}

// ============================ ENUMY ============================

Enum user_type {
  admin
  warehouseman
  worker
}

Enum item_kind {
  serializable [note: 'Numer seryjny, sledzony indywidualnie, zwrotny']
  returnable   [note: 'Bez numeru seryjnego, sledzony ilosciowo, zwrotny']
  consumable   [note: 'Zuzywalny, bez zwrotu']
}

Enum loan_status {
  open
  partially_returned
  settled
  cancelled
}

Enum return_condition {
  ok
  damaged
  lost
}

Enum movement_reason {
  receipt
  issue
  return
  correction
  write_off
}

// ============================ ADRESY ============================

Table country {
  id   integer     [pk, increment]
  code char(2)     [not null, unique, note: 'ISO 3166-1 alpha-2']
  name varchar(80) [not null]
}

Table city {
  id         integer      [pk, increment]
  country_id integer      [not null, ref: > country.id]
  name       varchar(100) [not null]

  indexes {
    (country_id, name) [unique]
  }
}

Table address {
  id               integer      [pk, increment]
  city_id          integer      [not null, ref: > city.id]
  postal_code      varchar(10)  [not null]
  street           varchar(150)
  building_number  varchar(20)  [not null]
  apartment_number varchar(20)
}

// ============================ UZYTKOWNICY ============================

Table app_user {
  id             integer      [pk, increment]
  login          varchar(50)  [not null, unique]
  password_hash  varchar(255) [not null]
  first_name     varchar(80)  [not null]
  last_name      varchar(80)  [not null]
  contact_number varchar(20)
  address_id     integer      [not null, ref: > address.id]
  user_type      user_type    [not null]
  is_active      boolean      [not null, default: true, note: 'soft delete']
  created_at     timestamp    [not null, default: `now()`]
}

// ============================ SLOWNIKI ============================

Table unit {
  id              integer     [pk, increment]
  symbol          varchar(10) [not null, unique, note: 'szt., kg, m, l, worek, opak.']
  name            varchar(50) [not null]
  allows_fraction boolean     [not null, default: false]
  is_active       boolean     [not null, default: true]
}

Table section_type {
  id          integer     [pk, increment]
  code        varchar(30) [not null, unique, note: 'stabilny identyfikator: area, rack, shelf, carton...']
  name        varchar(80) [not null, note: 'nazwa wyswietlana']
  can_be_root boolean     [not null, default: false]
  is_active   boolean     [not null, default: true]
}

Table section_type_parent {
  child_type_id  integer [not null, ref: > section_type.id]
  parent_type_id integer [not null, ref: > section_type.id]

  indexes {
    (child_type_id, parent_type_id) [pk]
  }
  Note: 'Walidacja, które sekcje mogą być zagnieżdżane w których'
}

// ============================ LOKALIZACJE ============================

Table section {
  id                integer      [pk, increment]
  parent_section_id integer      [null, ref: > section.id, note: 'NULL = korzen']
  section_name      varchar(100) [not null]
  section_type_id   integer      [not null, ref: > section_type.id]
  is_active         boolean      [not null, default: true]
}

// ============================ KATALOG ============================

Table category {
  id        integer      [pk, increment]
  parent_id integer      [null, ref: > category.id, note: 'NULL = kategoria glowna']
  name      varchar(100) [not null]
  is_active boolean      [not null, default: true]

  indexes {
    (parent_id, name) [unique, note: 'NULLS NOT DISTINCT w SQL']
  }
  Note: 'Drzewo kategorii, np. Materialy > Spoiwa > Cementy > Cement B24'
}

Table item_model {
  id           integer       [pk, increment]
  category_id  integer       [not null, ref: > category.id, note: 'dowolny wezel drzewa']
  name         varchar(150)  [not null, unique, note: 'np. Cement B24 5 kg, Wiertarka Bosch GSB 13']
  short_name   varchar(50)   [not null, unique]
  kind         item_kind     [not null]
  unit_id      integer       [not null, ref: > unit.id, note: 'w czym liczymy stan']
  min_quantity decimal(12,3) [not null, default: 0, note: 'prog alertu']
  description  text
  is_active    boolean       [not null, default: true]

  Note: 'Pozycja katalogowa (SKU): to, co fizycznie bierzesz do reki'
}

// ============================ STAN MAGAZYNU ============================

Table item {
  id            integer       [pk, increment]
  item_model_id integer       [not null, ref: > item_model.id]
  section_id    integer       [not null, ref: > section.id]
  serial_number varchar(100)  [note: 'wymagany <=> kind = serializable']
  quantity      decimal(12,3) [not null, default: 0, note: 'ilosc POSIADANA; dostepna = quantity - niezwrocone pozycje']
  is_active     boolean       [not null, default: true, note: 'false = zlikwidowany']
  version       bigint        [not null, default: 0, note: '@Version (optimistic locking)']
  created_at    timestamp     [not null, default: `now()`]

  indexes {
    (item_model_id, serial_number) [unique]
    section_id
  }
  Note: 'serializable: egzemplarz. returnable/consumable: stan modelu w lokalizacji.'
}

// ============================ WYPOZYCZENIA ============================

Table loan {
  id           integer     [pk, increment]
  issued_by_id integer     [not null, ref: > app_user.id]
  borrower_id  integer     [not null, ref: > app_user.id]
  issued_at    timestamp   [not null, default: `now()`]
  due_date     date        [note: 'NULL gdy same consumable']
  settled_at   timestamp
  status       loan_status [not null, default: 'open', note: 'pochodny; aktualizowac w jednej transakcji ze zwrotem']
  remarks      text

  indexes {
    borrower_id
    status
  }
}

Table loan_line {
  id         integer       [pk, increment]
  loan_id    integer       [not null, ref: > loan.id]
  item_id    integer       [not null, ref: > item.id]
  qty_issued decimal(12,3) [not null]

  indexes {
    (loan_id, item_id) [unique]
    item_id
  }
}

Table loan_return {
  id             integer          [pk, increment]
  loan_line_id   integer          [not null, ref: > loan_line.id]
  qty            decimal(12,3)    [not null]
  condition      return_condition [not null, default: 'ok']
  returned_at    timestamp        [not null, default: `now()`]
  received_by_id integer          [not null, ref: > app_user.id]
  comment        text

  indexes {
    loan_line_id
  }
  Note: 'Zdarzenie zwrotu; zwrocona ilosc pozycji = SUM(qty)'
}
