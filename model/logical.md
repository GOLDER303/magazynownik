// =====================================================================
//  b. MODEL LOGICZNY  —  System zarzadzania magazynem
//  Notacja: DBML (https://dbdiagram.io)
// =====================================================================

Project magazyn_logiczny {
  database_type: 'Generic'
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

Enum permission_type {
  full_access [note: 'Odczyt + modyfikacja + wydawanie/przyjmowanie']
  edit        [note: 'Odczyt + modyfikacja stanu']
  preview     [note: 'Tylko odczyt']
  denied      [note: 'Jawna odmowa - nadpisuje uprawnienie odziedziczone z magazynu']
}


Enum loan_status {
  open               [note: 'Cos pozostaje do zwrotu']
  partially_returned [note: 'Czesc pozycji zwrotnych wrocila']
  settled            [note: 'Rozliczony - wszystko zwrocone albo zuzyte']
  cancelled          [note: 'Anulowane przed wydaniem']
}

Enum item_type {
  serializable [note: 'Ma numer seryjny']
  returnable [note: 'Nie ma numeru seryjnego, ale jest zwrotny']
  consumable [note: 'Zużywa się']
}

// ------------------------- ENCJE -------------------------------------

Table app_user {
  id            integer   [pk]
  login         string    [not null, unique]
  password_hash string    [not null, note: 'bcrypt']
  first_name    string    [not null]
  last_name     string    [not null]
  contact_number string   [null]
  address       string    [null]
  user_type     user_type [not null]
  is_active     boolean   [not null, default: true, note: 'false - uzytnownik usuniety']
  created_at    timestamp [not null]
}

Table section {
  id                integer      [pk]
  parent_section_id integer      [null, ref: > section.id, note: 'NULL = korzen hierarchii']
  section_name      string       [not null]
  section_type      section_type [not null]

  Note: '''
  Sekcja magazynu, hierarchia rekurencyjna: area > rack > shelf.
  '''
}

Table item_type {
  id            integer   [pk]
  name          string    [not null, unique]
  short_name    string    [not null, unique]
  item_type     item_type [not null]
  unit          unit_type [not null, default: 'pcs']
}

Table item {
  id            integer [pk]
  item_type_id  integer [not null, ref: > item_type.id]
  section_id    integer [not null, ref: > section.id]
  serial_number string  [null, note: 'Wymagany <=> is_serialized']
  quantity      decimal [not null, default: 0, note: 'Ilosc POSIADANA (nie: dostepna). Dla is_serialized: 1 na stanie, 0 po likwidacji.']
  created_at    timestamp [not null]
}

Table permission {
  id           integer         [pk]
  user_id      integer         [not null, ref: > app_user.id]
  section_id   integer         [null, ref: > section.id]
  permission   permission_type [not null]
  granted_by_id integer        [not null, ref: > app_user.id]
  granted_at   timestamp       [not null]

  Note: '''
  Uprawnienie uzytkownika do zakresu.'''
}

Table loan {
  id           integer     [pk]
  loaner_id   integer     [not null, ref: > app_user.id]
  borrower_id  integer     [not null, ref: > app_user.id]
  issued_at    timestamp   [not null]
  due_date     date        [not null, note: 'Termin zwrotu']
  settled_at   timestamp   [null, note: 'Wypelniane gdy status = settled']
  status       loan_status [not null, default: 'open']
  remarks      string      [null]

  Note: 'Naglowek dokumentu wydania. Jedno zdarzenie = kilka pozycji.'
}

Table loan_line {
  id            integer [pk]
  loan_id       integer [not null, ref: > loan.id]
  item_id       integer [not null, ref: > item.id]
  qty_issued    decimal [not null]
  qty_returned  decimal [not null, default: 0]

  Note: '''
  Pozycja dokumentu. Zwroty czesciowe dozwolone: qty_returned <= qty_issued.
  Pozycja na material zuzywalny ma qty_returned zawsze 0 i nie wstrzymuje
  rozliczenia dokumentu.
  '''
}
