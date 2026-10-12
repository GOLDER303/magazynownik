```mermaid
erDiagram
    UZYTKOWNIK            ||--o{ UPRAWNIENIE          : "posiada"
    MAGAZYN               ||--o{ UPRAWNIENIE          : "jest zakresem"
    SEKCJA                ||--o{ UPRAWNIENIE          : "jest zakresem"

    MAGAZYN               ||--|{ SEKCJA               : "dzieli sie na"
    SEKCJA                ||--o{ SEKCJA               : "zawiera (hierarchia)"

    TYP_PRZEDMIOTU        ||--o{ PRZEDMIOT            : "klasyfikuje"
    SEKCJA                ||--o{ PRZEDMIOT            : "przechowuje"

    UZYTKOWNIK            ||--o{ WYPOZYCZENIE         : "pobiera (pracownik)"
    UZYTKOWNIK            ||--o{ WYPOZYCZENIE         : "wydaje (magazynier)"
    WYPOZYCZENIE          ||--|{ POZYCJA_WYPOZYCZENIA : "zawiera"
    PRZEDMIOT             ||--o{ POZYCJA_WYPOZYCZENIA : "jest przedmiotem"
```
