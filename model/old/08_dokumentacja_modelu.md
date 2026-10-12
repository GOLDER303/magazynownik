# Dokumentacja modelu bazy danych

System zarządzania magazynem małego przedsiębiorstwa budowlanego.
DBMS: **PostgreSQL 15+**, schemat `wms`.

---

## 1. Zmiany względem modelu wyjściowego

| # | Zmiana | Uzasadnienie |
|---|---|---|
| 1 | `user` → `app_user` | `user` jest słowem zastrzeżonym SQL i funkcją wbudowaną PostgreSQL — wymagałoby cudzysłowów w każdym zapytaniu. |
| 2 | Dodano `loan`, `loan_line`, `stock_movement` | Model wyjściowy nie zapisywał **żadnej** informacji o wypożyczeniach, mimo że są one w wymaganiach funkcjonalnych i w szacunku rozmiaru (15/dzień). |
| 3 | `item_type.is_serialized` + `unit` | Narzędzie i worek wkrętów to dwa różne byty. Narzędzie wymaga numeru seryjnego (trzeba wiedzieć *która* wiertarka jest u kogo), materiał sypki — tylko ilości w jednostce. |
| 4 | `grand_section_id` → `parent_section_id` | Nazwa „grand" sugeruje dziadka, a związek jest do bezpośredniego rodzica. |
| 5 | `permission` — zakres XOR | `warehouse_id` i `section_id` jednocześnie niepuste były niejednoznaczne. CHECK wymusza dokładnie jeden zakres. |
| 6 | `app_user.is_active` | Administrator „usuwa magazyniera", ale jego wypożyczenia i wpisy w dzienniku muszą przetrwać — usunięcie jest logiczne. |
| 7 | Wszystkie kolumny mają typy o jawnej długości, `NOT NULL` i CHECK | Model wyjściowy używał `string`/`number` bez ograniczeń. |
| 8 | Kolumna `note` → `remarks` | `Note` jest słowem kluczowym w DBML; nazwa `remarks` nie koliduje z parserem dbdiagram. |
| 9 | `item_type.is_consumable` + ruch `consumption` | Wkręty wydane na budowę nie wracają. Bez tego rozróżnienia każde wydanie materiału wisiałoby w nieskończoność jako niezwrócone. |
| 10 | `loan_status.returned` → `settled`, `returned_at` → `settled_at` | Dokument może zawierać wyłącznie materiały zużywalne — nazwanie go „zwróconym" byłoby nieprawdą. `settled` = rozliczony: wszystko wróciło **albo** zostało zużyte. |
| 12 | `loan.worker_id` → `borrower_id`, `loan.issued_by_id` → `loaner_id` | Nazwy wprost mówią, kto po której stronie stoi: `loaner` wydaje, `borrower` pobiera. `issued_by_id` nie odróżniało się od `issued_at`, a `worker_id` mieszało się z rolą `worker` w `user_type`. Zmiana objęła też klucze obce (`fk_loan_loaner`, `fk_loan_borrower`), indeksy (`idx_loan_loaner`, `idx_loan_borrower_status`) i kolumny widoków (`borrower_name`, `loaner_name`). |
| 11 | Ruch `transfer` + `from_section_id`/`to_section_id` | Przesunięcia między sekcjami i magazynami; bez nich przeniesienie towaru byłoby niewidoczne w audycie. |

---

## 2. Normalizacja

Model jest w **3NF**, a wszystkie relacje poza `item` spełniają też **BCNF**.

| Relacja | Klucz | Zależności funkcyjne | Postać |
|---|---|---|---|
| `app_user` | `id`; klucz kandydujący `login` | wszystkie atrybuty zależne tylko od `id` | BCNF |
| `warehouse` | `id`; kandydujący `name` | — | BCNF |
| `section` | `id` | kandydujący `(warehouse_id, parent_section_id, section_name)` | BCNF |
| `item_type` | `id`; kandydujące `name`, `short_name` | `is_serialized → (unit = 'pcs')` wymuszone przez CHECK, nie jest ZF na atrybutach kluczowych | BCNF |
| `item` | `id` | kandydujące: `(item_type_id, serial_number)` dla rzeczy seryjnych, `(item_type_id, section_id)` dla partii; `item_type_id → is_serialized, is_consumable` | 3NF — patrz niżej |
| `permission` | `id`; kandydujące `(user_id, warehouse_id)`, `(user_id, section_id)` | — | BCNF |
| `loan` | `id` | — | BCNF |
| `loan_line` | `id`; kandydujący `(loan_id, item_id)` | `item_id → is_consumable` — zależność przechodnia, patrz niżej | 3NF — patrz niżej |
| `stock_movement` | `id` | — | BCNF |

### Świadome odstępstwo: kopie flag katalogowych

Trzy kolumny są kopiami wartości z tabeli nadrzędnej, czyli zależnościami
przechodnimi łamiącymi formalnie 3NF:

| Kolumna | Kopia z | Łańcuch zależności |
|---|---|---|
| `item.is_serialized` | `item_type.is_serialized` | `item.id → item_type_id → is_serialized` |
| `item.is_consumable` | `item_type.is_consumable` | `item.id → item_type_id → is_consumable` |
| `loan_line.is_consumable` | `item.is_consumable` | `loan_line.id → item_id → is_consumable` |

**Dlaczego mimo to zostaje:** bez tej kolumny warunku

```
(is_serialized AND quantity IN (0,1) AND serial_number IS NOT NULL)
   OR (NOT is_serialized AND serial_number IS NULL)
```

nie da się wyrazić jako `CHECK` — ograniczenie CHECK w SQL nie może odwoływać się
do innej tabeli. Alternatywą jest wyzwalacz, czyli przeniesienie reguły z warstwy
deklaratywnej do proceduralnej.

Ten sam argument dotyczy `loan_line.is_consumable`: bez niego warunku
„pozycja na materiał zużywalny ma `qty_returned = 0`" też nie dałoby się
zapisać deklaratywnie.

**Dlaczego to bezpieczne:** denormalizacja jest *kontrolowana* — spójność kopii
z oryginałem wymuszają złożone klucze obce:

```sql
-- item nie może skłamać o cechach swojego typu
CONSTRAINT fk_item_type FOREIGN KEY (item_type_id, is_serialized, is_consumable)
    REFERENCES item_type (id, is_serialized, is_consumable)

-- pozycja dokumentu nie może skłamać o zużywalności przedmiotu
CONSTRAINT fk_loan_line_item FOREIGN KEY (item_id, is_consumable)
    REFERENCES item (id, is_consumable)
```

Anomalia aktualizacji jest więc niemożliwa: baza nie pozwoli, by kopia rozjechała
się z katalogiem (testy A3, A8, I7), ani nie pozwoli zmienić flagi w katalogu,
dopóki istnieją egzemplarze.

### Odrzucone alternatywy dla hierarchii `section`

| Wariant | Odrzucony, bo |
|---|---|
| Osobne tabele `area`, `rack`, `shelf` | Trzy niemal identyczne tabele; dodanie czwartego poziomu = zmiana schematu i wszystkich zapytań. |
| Ścieżka materializowana (`'1/3/5'`) | Łamie 1NF (wartość złożona), uniemożliwia klucz obcy. |
| `ltree` | Rozszerzenie spoza standardu; nie wnosi tu nic ponad to, co daje `WITH RECURSIVE`. |

Przyjęto listę sąsiedztwa (*adjacency list*) z zapytaniami rekurencyjnymi —
widok `v_section_path`.

---

## 3. Katalog ograniczeń integralności

### Ograniczenia deklaratywne

| Tabela | Ograniczenie | Reguła |
|---|---|---|
| `app_user` | `ck_app_user_login` | `login ~ '^[a-z0-9._-]{3,50}$'` |
| | `ck_app_user_hash` | `password_hash ~ '^\$2[abxy]\$[0-9]{2}\$[./A-Za-z0-9]{53}$'` — dokładna postać bcrypta, nie próg długości |
| | `ck_app_user_names` | imię i nazwisko nie mogą być samymi spacjami |
| | `ck_app_user_phone` | `'^\+?[0-9 ()-]{7,20}$'` albo NULL |
| `section` | `fk_section_parent` | złożony FK `(parent_section_id, warehouse_id) → section(id, warehouse_id)` — **rodzic leży w tym samym magazynie** |
| | `ck_section_no_self` | sekcja nie jest własnym rodzicem |
| | `ck_section_root_is_area` | `parent_section_id IS NOT NULL OR section_type = 'area'` — korzeń hierarchii musi być strefą |
| | `uq_section_name_in_parent` | nazwa unikalna wśród rodzeństwa (`NULLS NOT DISTINCT`) |
| `item_type` | `ck_item_type_short` | `'^[A-Z0-9_-]{2,20}$'` |
| | `ck_item_type_unit` | rzecz seryjna musi być liczona w sztukach |
| | `ck_item_type_flags` | `NOT (is_serialized AND is_consumable)` — narzędzie się nie zużywa |
| `item` | `ck_item_tracking` | rdzeń modelu hybrydowego (patrz §2) |
| | `fk_item_type` | złożony FK wymuszający zgodność flagi z katalogiem |
| | `uq_item_serial` | indeks **częściowy** `WHERE serial_number IS NOT NULL` |
| | `uq_item_bulk_per_section` | indeks **częściowy** `WHERE NOT is_serialized` — jedna partia typu na sekcję |
| | dziedzina `qty` | `VALUE >= 0` — stan nie zejdzie poniżej zera |
| `permission` | `ck_permission_scope` | `num_nonnulls(warehouse_id, section_id) = 1` |
| | `uq_permission_user_*` | dwa indeksy częściowe — jedno uprawnienie na użytkownika i zakres |
| `loan` | `ck_loan_actors` | pobierający ≠ wydający |
| | `ck_loan_settled_flag` | `(status = 'settled') = (settled_at IS NOT NULL)` |
| | `ck_loan_due` | `due_date >= (issued_at AT TIME ZONE 'Europe/Warsaw')::date` |
| `loan_line` | `ck_loan_line_returned` | `0 <= qty_returned <= qty_issued` |
| | `ck_loan_line_consumable` | `NOT is_consumable OR qty_returned = 0` — materiał zużywalny nie wraca |
| | `fk_loan_line_item` | złożony FK `(item_id, is_consumable) → item(id, is_consumable)` |
| | `uq_loan_line_item` | jeden przedmiot raz na dokumencie |
| `stock_movement` | `ck_movement_sign` | znak `qty_delta` zgodny z rodzajem ruchu |
| | `ck_movement_loan_link` | `(typ ∈ {issue, return, consumption}) = (loan_line_id IS NOT NULL)` |
| | `ck_movement_sections` | `(typ = transfer) = (obie sekcje NOT NULL)` |
| | `ck_movement_transfer_distinct` | sekcja źródłowa ≠ docelowa |
| | dziedzina `qty_delta` | `VALUE <> 0` — ruch zerowy nie ma sensu |

> **Dlaczego wzorzec, a nie `length(...) >= n`.** Kolumna trzyma wyjście bcrypta,
> które ma niezmienną postać: `$2<wariant>$<koszt>$` + 53 znaki soli i skrótu,
> łącznie **zawsze 60 znaków**. Próg długości przepuściłby dowolny dostatecznie
> długi ciąg, w tym hasło jawne — wzorzec nie przepuszcza niczego poza bcryptem
> (testy H5–H7). Stąd też `VARCHAR(60)`, a nie `VARCHAR(72)`: 72 to limit
> **wejścia** bcrypta, czyli maksymalna długość hasła, a nie długość wyniku.
>
> Jeśli backend użyje `DelegatingPasswordEncoder` ze Spring Security, zapisana
> wartość dostanie prefiks `{bcrypt}` (68 znaków) — wariant wzorca i długości
> jest podany w komentarzu przy ograniczeniu w `04_model_fizyczny.sql`.

> **Uwaga o strefie czasowej w `ck_loan_due`.** `timestamptz::date` jest funkcją
> *stable*, nie *immutable* — PostgreSQL odrzuciłby ją w `CHECK`. Podanie strefy
> jawnie (`AT TIME ZONE 'Europe/Warsaw'`) czyni wyrażenie niezmiennym.

### Reguły wymagające wyzwalaczy

Poniższych reguł nie da się wyrazić przez `CHECK`, bo odwołują się do innych
tabel albo do wielu wierszy. PostgreSQL odrzuca próbę obejścia tego podzapytaniem:
`ERROR: cannot use subquery in check constraint`.

Granica jest ostra i warto ją trzymać: **reguła patrząca wyłącznie na kolumny
własnego wiersza należy do `CHECK`, nie do wyzwalacza.** Dlatego warunek
„korzeń hierarchii musi być strefą" — choć pojęciowo należy do tej samej
rodziny co pozostałe reguły hierarchii — jest ograniczeniem `CHECK`
(`ck_section_root_is_area`), a nie częścią `trg_section_hierarchy`:
deklaratywnie, bez możliwości wyłączenia przez `ALTER TABLE ... DISABLE TRIGGER`
i bez kosztu wywołania funkcji przy każdym zapisie.

| Wyzwalacz | Reguła |
|---|---|
| `trg_section_hierarchy` | dziecko leży głębiej niż rodzic (`fn_section_level(dziecko) > fn_section_level(rodzic)`); brak cykli w hierarchii |
| `trg_loan_roles` | pobierający ma rolę `worker`, wydający `warehouseman`/`admin`, oba konta aktywne |
| `trg_loan_line_availability` | nie można wydać więcej, niż jest dostępne (`SELECT ... FOR UPDATE` eliminuje wyścig dwóch jednoczesnych wydań); pozycja na materiał zużywalny jest po utworzeniu niezmienna |
| `trg_loan_status` | status dokumentu i `settled_at` wyliczane z pozycji **zwrotnych** |
| `trg_movement_append_only` | `UPDATE`/`DELETE` na dzienniku zabronione |
| `trg_movement_apply` | `receipt`/`disposal`/`adjustment`/`consumption` zmieniają `item.quantity`; `transfer` zmienia `item.section_id` (rzecz seryjna) albo przenosi ilość między partiami (materiał sypki) |

---

## 4. Własność a dostępność

Rozdzielenie tych dwóch pojęć jest kluczową decyzją modelu:

```
item.quantity          = ile firma POSIADA         (zmieniają ruchy receipt/disposal/adjustment)
fn_item_on_loan(id)    = ile jest U PRACOWNIKÓW    (suma otwartych pozycji wypożyczeń)
qty_available          = quantity - on_loan        (widok v_item_stock)
```

Wypożyczenie rzeczy zwrotnej nie zmienia stanu posiadania, więc `issue`/`return`
**nie** modyfikują `item.quantity` — zmieniają tylko dostępność, liczoną z `loan_line`.
Dzięki temu nie ma dwóch źródeł prawdy o tej samej liczbie.

Dla rzeczy seryjnych `quantity ∈ {0, 1}`: `1` = na stanie, `0` = zlikwidowana.

### Materiały zużywalne

Materiał oznaczony `item_type.is_consumable` zachowuje się odwrotnie: w chwili
wydania powstaje ruch `consumption`, który **od razu** obniża `item.quantity`.
Taka pozycja nigdy nie trafia do `fn_item_on_loan` — liczenie jej tam odjęłoby
tę samą ilość drugi raz.

Konsekwencje dla dokumentu wydania:

- pozycja zużywalna ma `qty_returned` trwale równe 0 (`ck_loan_line_consumable`),
- `trg_loan_status` pomija ją przy liczeniu, czy zostało coś do zwrotu,
- dokument zawierający **wyłącznie** materiały zużywalne jest rozliczony
  (`settled`) natychmiast po wystawieniu — stąd zmiana nazwy statusu
  z `returned` na `settled`,
- raport `v_consumption_summary` pokazuje zużycie w podziale na pracownika,
  asortyment i miesiąc.

### Przesunięcia

Ruch `transfer` zmienia lokalizację, nie stan posiadania firmy. Mechanika zależy
od trybu ewidencji:

| Tryb | Co się dzieje | Liczba ruchów |
|---|---|---|
| rzecz seryjna | jedyny wiersz `item` zmienia `section_id` | 1 (`qty_delta = 1`, symbolicznie „1 szt.") |
| materiał sypki | ilość przechodzi między partią źródłową a docelową; docelowa jest zakładana automatycznie, jeśli nie istnieje | 2 (`−qty` na źródle, `+qty` na celu) |

Suma `item.quantity` dla danego typu pozostaje stała — sprawdza to test J3.
Nie da się przenieść tego, co jest u pracownika: procedura odrzuca przesunięcie
ilości większej niż `fn_item_available` (testy J5, J7).

---

## 5. Uprawnienia — rozstrzyganie dostępu

`fn_effective_permission(user_id, section_id)` stosuje regułę „najbliższy wpis wygrywa":

1. Szuka wpisu `permission` dla sekcji lub jej **najbliższego przodka** w hierarchii.
2. Jeśli nie ma — bierze wpis na poziomie magazynu.
3. Jeśli nadal nie ma — zwraca `denied`.

Pozwala to nadać magazynierowi `full_access` do całego magazynu i jednocześnie
`denied` do jednej półki (np. z materiałami niebezpiecznymi) — testy C4–C7.

Role bazodanowe (`wms_reader` / `wms_operator` / `wms_admin`) są **drugą warstwą
obrony**. Pierwszą jest aplikacja backendowa sprawdzająca token JWT; baza
dodatkowo ogranicza to, co w ogóle da się wykonać na połączeniu.

Każda funkcja i procedura ma przypięte `SET search_path = wms, pg_temp` — bez tego
wywołanie z aplikacji (inny `search_path`) nie znalazłoby tabel, a sama funkcja
byłaby wektorem podmiany obiektów (CVE-2018-1058).

---

## 6. Szacunek rozmiaru

Założenia z opisu projektu: 10 000 przedmiotów, 4 magazynierów, 50 pracowników,
15 wypożyczeń dziennie. Horyzont: **5 lat**.

| Tabela | Wiersze | Dane | Indeksy | Razem |
|---|---:|---:|---:|---:|
| `app_user` | 55 | 16 kB | 48 kB | 64 kB |
| `warehouse` | 5 | 8 kB | 32 kB | 40 kB |
| `section` | 200 | 32 kB | 96 kB | 128 kB |
| `item_type` | 500 | 64 kB | 96 kB | 160 kB |
| `item` | 10 000 | 1,0 MB | 1,5 MB | 2,5 MB |
| `permission` | 500 | 48 kB | 64 kB | 112 kB |
| `loan` | 18 750 | 1,8 MB | 2,2 MB | 4,0 MB |
| `loan_line` | 56 250 | 2,8 MB | 2,8 MB | 5,6 MB |
| `stock_movement` | 131 250 | 8,4 MB | 6,0 MB | 14,4 MB |
| **Suma** | | **14,2 MB** | **12,8 MB** | **27 MB** |

Doliczając narzut katalogu systemowego, WAL, miejsce na `VACUUM` oraz logi,
**przyjęty limit 500 MB jest bezpieczny z dużym zapasem** — model mieści się
w ~6 % tej wartości i wystarczy na kilkanaście lat eksploatacji.

Wąskim gardłem przy wzroście będzie `stock_movement`. Gdyby liczba wierszy
przekroczyła kilka milionów, naturalnym krokiem jest partycjonowanie zakresowe
po `occurred_at` (po roku) i zamiana `idx_movement_time` na indeks BRIN.

---

## 7. Dobór indeksów

Indeksy w modelu pełnią **trzy różne funkcje** i mylenie ich ze sobą prowadzi
do złych decyzji przy strojeniu bazy.

### A. Obsługa kluczy obcych

PostgreSQL indeksuje automatycznie tylko stronę **wskazywaną** klucza obcego
(bo musi tam być `PRIMARY KEY`/`UNIQUE`), nigdy stronę wskazującą. Przy
`ON DELETE RESTRICT` każde usunięcie wiersza nadrzędnego sprawdza, czy ktoś się
na niego powołuje — bez indeksu jest to skanowanie sekwencyjne tabeli podrzędnej.

| Indeks | Chroni przed |
|---|---|
| `idx_item_type`, `idx_item_section` | skan 10 000 wierszy `item` przy usuwaniu typu lub sekcji |
| `idx_section_parent`, `idx_section_warehouse` | skan `section` przy usuwaniu sekcji nadrzędnej lub magazynu |
| `idx_loan_line_item` | skan pozycji dokumentów przy usuwaniu przedmiotu |
| `idx_movement_loan_line`, `idx_movement_user` | skan dziennika ruchów |

### B. Reguły integralności

Te nie służą szybkości — wymuszają zasady modelu. Istotne jest, że **predykat
indeksu częściowego ma w nich różny status**:

| Indeks | Rola predykatu |
|---|---|
| `uq_item_bulk_per_section` `WHERE NOT is_serialized` | **konieczny** — bez niego dwie wiertarki tego samego modelu na jednej półce (ta sama para `item_type_id, section_id`) zostałyby odrzucone |
| `uq_item_serial` `WHERE serial_number IS NOT NULL` | **tylko optymalizacja** — w indeksie unikalnym `NULL ≠ NULL`, więc partie bez numeru i tak się nie kolidują; zawężenie trzyma indeks mały |
| `uq_permission_user_warehouse` / `_section` | konieczny — rozdziela dwa rozłączne zakresy uprawnienia |
| `uq_loan_line_item`, `uq_item_type_name`, `uq_app_user_login` | bez predykatu, zwykłe reguły niepowtarzalności |

### C. Klucze pomocnicze pod złożone klucze obce

Nadklucze, nie klucze kandydujące — `id` samo jest już kluczem głównym, więc nie
wnoszą żadnej nowej informacji o unikalności. Istnieją wyłącznie dlatego, że
PostgreSQL wymaga pokrycia unikalnością kolumn wskazywanych przez klucz obcy:

| Klucz pomocniczy | Umożliwia |
|---|---|
| `uq_section_id_warehouse (id, warehouse_id)` | `fk_section_parent` — rodzic w tym samym magazynie |
| `uq_item_type_flags (id, is_serialized, is_consumable)` | `fk_item_type` — kopie flag zgodne z katalogiem |
| `uq_item_id_consumable (id, is_consumable)` | `fk_loan_line_item` — pozycja nie kłamie o zużywalności |

Uwaga: pod kluczem obcym **nie może** stać indeks częściowy — PostgreSQL odrzuca
to komunikatem `there is no unique constraint matching given keys`. Stąd te trzy
muszą być pełnymi ograniczeniami `UNIQUE`, a nie indeksami z predykatem.

### D. Przyspieszanie konkretnych zapytań

| Indeks | Obsługiwane zapytanie |
|---|---|
| `idx_item_available` (częściowy, `WHERE quantity > 0`) | „co jest w magazynie" — najczęstsze zapytanie wszystkich trzech ról |
| `idx_loan_line_outstanding` (częściowy) | wyliczanie dostępności w `fn_item_on_loan` i w wyzwalaczu |
| `idx_loan_overdue` (częściowy, tylko otwarte) | raport przeterminowanych — pomija zamknięte dokumenty |
| `idx_loan_borrower_status` | „co ma wypożyczone pracownik X" |
| `idx_movement_item_time` | historia ruchów przedmiotu, malejąco po dacie |
| `idx_movement_to_section` (częściowy, `WHERE movement_type = 'transfer'`) | „co przyszło do tej sekcji i skąd" |
| `idx_app_user_name` | wyszukiwanie pracownika po nazwisku |

Indeksy częściowe wybrano tam, gdzie zapytania zawsze filtrują po tym samym
warunku — indeks jest wtedy kilkakrotnie mniejszy od pełnego.

---

## 8. Weryfikacja

Model został uruchomiony na działającym serwerze PostgreSQL. Skrypt
`07_testy_ograniczen.sql` zawiera **72 testy** (pozytywnych i negatywnych)
pokrywających każde ograniczenie z §3 — wszystkie przechodzą.

Inwentarz utworzonych obiektów:

| Obiekt | Liczba |
|---|---:|
| tabele | 9 |
| typy wyliczeniowe | 6 |
| dziedziny | 2 |
| widoki | 7 |
| ograniczenia CHECK | 31 |
| klucze obce | 17 |
| klucze główne i unikalne | 17 |
| indeksy | 41 |
| wyzwalacze | 6 |
| funkcje | 10 |
| procedury składowane | 6 |
