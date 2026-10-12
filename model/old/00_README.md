# Model bazy danych — system zarządzania magazynem

Faza projektowa (punkty a–d) dla systemu zarządzania magazynem małego
przedsiębiorstwa budowlanego. DBMS: **PostgreSQL 15+**.

## Zawartość

| Plik | Punkt | Co zawiera |
|---|---|---|
| `01_model_konceptualny.md` | **a** | Diagram związków encji (Mermaid), opis encji, liczności, założenia dziedzinowe |
| `02_model_logiczny.dbml` | **b** | Model relacyjny w DBML — encje, atrybuty, klucze, związki; typy generyczne |
| `03_model_fizyczny.dbml` | **c** | Ten sam model z typami PostgreSQL i indeksami — wersja do wizualizacji |
| `04_model_fizyczny.sql` | **c** | Pełny DDL: tabele, typy ENUM, dziedziny, CHECK, klucze obce, indeksy |
| `05_pozostale_elementy.sql` | **d** | Funkcje, wyzwalacze, widoki, procedury składowane, role i uprawnienia |
| `06_dane_testowe.sql` | — | Dane przykładowe |
| `07_testy_ograniczen.sql` | — | 72 testy weryfikujące każde ograniczenie |
| `08_dokumentacja_modelu.md` | — | Uzasadnienie decyzji, normalizacja, katalog ograniczeń, szacunek rozmiaru |
| `09_notacja.md` | — | Legenda: co oznaczają symbole na diagramach Mermaid i dbdiagram |

## Uruchomienie

```bash
createdb -E UTF8 wms
psql -d wms -v ON_ERROR_STOP=1 -f model/04_model_fizyczny.sql
psql -d wms -v ON_ERROR_STOP=1 -f model/05_pozostale_elementy.sql
psql -d wms -f model/06_dane_testowe.sql
psql -d wms -f model/07_testy_ograniczen.sql    # oczekiwane: 72x PASS, 0x FAIL
```

> **PostgreSQL 14 i starsze:** jedyna niezgodność to `NULLS NOT DISTINCT`
> w indeksie `uq_section_name_in_parent`. Zamiennik dla PG 14 jest podany
> w komentarzu bezpośrednio nad tym indeksem w `04_model_fizyczny.sql`.

## Wizualizacja w dbdiagram.io

1. Wejdź na https://dbdiagram.io/d
2. Wklej całą zawartość `02_model_logiczny.dbml` (model logiczny)
   lub `03_model_fizyczny.dbml` (model fizyczny)
3. Eksport diagramu: *Export → PNG / PDF*

Oba pliki zostały sprawdzone oficjalnym parserem `@dbml/core` — ładują się
bez błędów (9 tabel, 6 typów wyliczeniowych, 17 związków).

Znaczenie symboli na obu diagramach opisuje `09_notacja.md`.

Diagram konceptualny z `01_model_konceptualny.md` renderuje się bezpośrednio
w GitHubie, GitLabie, Obsidianie i VS Code; można go też wkleić na
https://mermaid.live i wyeksportować do PNG/SVG.

## Dobór narzędzi

Żadne pojedyncze narzędzie nie obsługuje dobrze wszystkich czterech punktów
fazy projektowej, dlatego każdy artefakt powstał w narzędziu dopasowanym do
swojego poziomu abstrakcji.

**dbdiagram.io (DBML)** — punkty b i c. Narzędzie jest wymienione w wytycznych
projektu, a DBML to zwykły tekst, więc model wersjonuje się w gitcie i czyta
w diffie. Ograniczenia, na które trzeba uważać:

- nie wyraża `CHECK`, indeksów częściowych, widoków, wyzwalaczy ani procedur —
  u nas to **30 ograniczeń CHECK i 6 wyzwalaczy**, czyli większość reguł
  biznesowych; w plikach DBML są one opisane w blokach `Note`,
- nie zna złożonych kluczy obcych, a model używa trzech
  (`section → section`, `item → item_type`, `loan_line → item`),
- `Note` jest słowem kluczowym, więc kolumna nazywa się `remarks`, nie `note`,
- wartości typu wyliczeniowego muszą być w osobnych liniach.

Z tego powodu **źródłem prawdy dla modelu fizycznego jest `04_model_fizyczny.sql`**,
a `03_model_fizyczny.dbml` pełni rolę wizualizacji.

**Mermaid** — punkt a. Diagram konceptualny ma pokazywać encje i związki bez
typów danych i kluczy obcych; dbdiagram zawsze wymusza kolumny i typy, więc
wymuszałby przedwczesne decyzje implementacyjne. Mermaid renderuje się wprost
w Markdownie, więc diagram jest częścią dokumentu, a nie osobnym obrazkiem.

**Czysty SQL (PL/pgSQL)** — punkty c i d. Jedyny zapis, który da się uruchomić
i przetestować. Wytyczne projektu wymagają w punkcie 4a skryptów SQL z definicjami
tabel, widoków, funkcji, procedur i wyzwalaczy, więc ten sam plik posłuży
w fazie implementacji.

### Rozważone alternatywy

| Narzędzie | Dlaczego odrzucone |
|---|---|
| **Visual Paradigm CE** | Obsługuje pełną notację ERD i generuje DDL, ale format projektu jest binarny — nie da się go sensownie wersjonować ani przejrzeć w diffie. |
| **MySQL Workbench** | Model fizyczny tworzyłby się pod MySQL; typy ENUM, dziedziny, indeksy częściowe i PL/pgSQL wymagałyby ręcznego przepisania. |
| **pgModeler** | Jedyne narzędzie GUI naprawdę dopasowane do PostgreSQL, ale płatne w wersji binarnej i wprowadza zależność od własnego formatu. |
| **draw.io** | Czysty rysunek — nic nie waliduje, nic nie generuje; każda zmiana w schemacie wymaga ręcznej poprawki diagramu. |

## Weryfikacja

Model został uruchomiony na działającym serwerze PostgreSQL:

- `04` i `05` wykonują się bez błędów i ostrzeżeń,
- `07_testy_ograniczen.sql` — **72 PASS, 0 FAIL**,
- oba pliki DBML przechodzą przez parser `@dbml/core`,
- diagram konceptualny przechodzi przez parser Mermaid.
