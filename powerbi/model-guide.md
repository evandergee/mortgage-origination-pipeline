# Power BI model — build guide

Done once in **Power BI Desktop**. ~15 minutes.

## 1. Connect and load

1. Run `powerbi\01_semantic_views.sql` first (creates the `pbi` schema).
2. Power BI Desktop → **Get data → SQL Server** — Server `.\SQLEXPRESS`, Database `Chinook`, **Import**.
3. Navigator → tick **pbi.DimDate, pbi.DimLoanOfficer, pbi.DimStage, pbi.FactApplication, pbi.FactStageDuration, pbi.FactForecast** → **Load**.
4. Rename the tables to drop the `pbi ` prefix (`DimDate`, `FactApplication`, …).

## 2. Relationships (Model view)

| From | To | Active? |
|---|---|---|
| `FactApplication[ApplicationDateKey]` | `DimDate[DateKey]` | **active** |
| `FactApplication[FundedDateKey]` | `DimDate[DateKey]` | **inactive** — used via `USERELATIONSHIP` in "…(by funded date)" measures |
| `FactApplication[LoanOfficerId]` | `DimLoanOfficer[LoanOfficerId]` | active |
| `FactStageDuration[EnteredDateKey]` | `DimDate[DateKey]` | active |
| `FactStageDuration[StageKey]` | `DimStage[StageKey]` | active |
| `FactStageDuration[LoanOfficerId]` | `DimLoanOfficer[LoanOfficerId]` | active |
| `FactForecast[CurrentStageKey]` | `DimStage[StageKey]` | active |

All many-to-one, single-direction filter. Two fact tables on conformed dimensions —
`FactApplication` and `FactStageDuration` don't relate to each other; they cross-filter
through `DimDate` / `DimLoanOfficer`.

## 3. Mark the date table

`DimDate` → **Table tools → Mark as date table** → **`Date`** column. It's a daily
calendar, so `TOTALYTD`, `SAMEPERIODLASTYEAR`, `DATESINPERIOD` all work normally.

## 4. Sort-by-column

| Column | Sort by |
|---|---|
| `DimDate[MonthYear]` | `DimDate[MonthYearSort]` |
| `DimDate[Month]` | `DimDate[MonthNumber]` |
| `DimStage[StageName]` | `DimStage[StageOrder]` |

## 5. Hide from report view

Every `*Id` and `*Key` column; `DimDate[MonthYearSort]`; `FactApplication[LockRate]` if unused.

## 6. Measures

Home → **Enter data** → one-column table **`_Measures`** → Load. Paste every measure from
`measures.dax`, then move them onto `_Measures` (Home table). Delete the dummy column.

Formatting: `Funded Volume`, `Pipeline Volume`, `*Amount*`, `Expected to Fund` →
Currency 0dp · `*%` measures → Percentage 1dp · `*Days` → whole number 1dp.

## 7. Model diagram

```
                          DimDate
                        ╱    │    ╲
         FactApplication   FactStageDuration   FactForecast
              │      ╲          │      ╲            │
        DimLoanOfficer ─────────┘   DimStage ───────┘
```
