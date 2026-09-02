# Power BI report — page-by-page build guide

Four pages. Shared slicer panel on the left of every page (**View → Sync slicers**).

**Slicers (all pages):** `DimDate[Date]` (between-slider), `DimApplication`…
actually `FactApplication[Channel]`, `FactApplication[LoanPurpose]`,
`FactApplication[ProductType]`, `DimLoanOfficer[Branch]`.

---

## Page 1 — Executive

```
┌───────────┬──────────────────────────────────────────────────────────┐
│           │ [Applications] [Funded] [Pull-Through %]                  │  ← KPI cards
│  slicers  │ [Funded Volume] [Median App-to-Fund Days]                 │
│           ├───────────────────────────────┬──────────────────────────┤
│           │ Combo: Applications (columns) │ Funnel visual:           │
│           │  + Funded (columns) by        │  [Reached Stage (apps)]  │
│           │  DimDate[MonthYear]           │  by DimStage             │
│           ├───────────────────────────────┴──────────────────────────┤
│           │ Bar: Funded Volume by DimDate[MonthYear] + YoY % label   │
│           │ Donut: Applications by Channel                           │
└───────────┴──────────────────────────────────────────────────────────┘
```

## Page 2 — Cycle Time & Bottlenecks

- **Bar:** `Median Stage Days` by `DimStage[StageName]` (sorted by StageOrder) with `P90 Stage Days` as a line overlay — the bottleneck chart. Processing and Conditional Approval will stand out.
- **Line:** `Median App-to-Fund Days` by `DimDate[MonthYear]` — trend.
- **Column histogram:** `Applications` by `FactApplication[AppToFundBizDays]` (binned) — the cycle-time distribution.
- **Matrix:** rows `DimStage[StageName]`, values `Completed Stage Instances`, `Median Stage Days`, `P90 Stage Days`, `Avg Stage Days`.
- **Card:** `Median App-to-Fund Days` big.

## Page 3 — Live Pipeline & Forecast

- **Matrix:** rows `FactApplication[CurrentState]`, columns `FactApplication[PipelineAgeBucket]`, values `In Pipeline` and `Pipeline Volume` — the aging grid (filter `IsInPipeline = True`).
- **Table:** SLA breaches — `FactStageDuration` rows where `IsSLABreach = True`: ApplicationId, StageName, BusinessDays, SLABusinessDays, `Avg Days Over SLA`, LoanOfficerName. Sort by DaysOverSLA desc.
- **Bar:** `Expected to Fund` vs `Pipeline Amount (Forecast)` by `FactForecast[ExpectedFundWindow]` — the funding forecast.
- **Bar:** `Active Locks` by `FactApplication[LockExpirationBucket]` — lock expirations.
- **Cards:** `Lock Extension Rate %`, `Lock Pull-Through %`, `Expected Pull-Through %`.

## Page 4 — Loan Officers

- **Table:** per `DimLoanOfficer[LoanOfficerName]` — `Applications`, `Funded`, `In Pipeline`, `Funded Volume`, `Pull-Through %`, `Median App-to-Fund Days`, `Fallout Rate %`. Conditional-format Pull-Through %.
- **Scatter:** X = `Pull-Through %`, Y = `Funded Volume`, bubble = `Applications`, legend = `Branch`, details = `LoanOfficerName`.
- **Bar:** `Funded Volume` by `Branch`.
- **Bar:** `Pull-Through %` by `LoanOfficerName` sorted — the ~10-point spread top to bottom.

---

## The story the report should tell

1. ~68–72% pull-through; recent cohorts still working through the pipeline.
2. **Processing (~10 business days, waiting on the appraisal) and Conditional Approval (~9, clearing conditions) are the bottlenecks.**
3. A handful of loans in every stage are past SLA — concentrated in Underwriting and Conditional Approval.
4. The pipeline is worth ~$X to fund over the next 90 days on a pull-through-weighted basis.
5. Loan-officer pull-through ranges ~60% to ~77% on similar volume — a coaching opportunity.

Screenshot each page into `powerbi/screenshots/`.
