/* =============================================================================
   Power BI semantic layer  --  schema  pbi
   -----------------------------------------------------------------------------
   Import these six views into Power BI Desktop
   (Get Data -> SQL Server -> .\SQLEXPRESS / Chinook).  Star schema: two fact
   tables sharing conformed dimensions.

       pbi.DimDate            one row per calendar day  (mark as the date table)
       pbi.DimLoanOfficer     one row per loan officer
       pbi.DimStage           the six pipeline stages + their SLA
       pbi.FactApplication    one row per application  (volume, funnel, pull-through, locks)
       pbi.FactStageDuration  one row per application-stage  (cycle time, SLA breaches)
       pbi.FactForecast       one row per live pipeline loan  (pull-through-weighted forecast)

   Depends on the orig.* objects from ..\sql\00-02.  Idempotent.
   Run:  ..\q.ps1 -File powerbi\01_semantic_views.sql

   NOTE: pet-category-analytics also uses a `pbi` schema in this database; its
   pbi.DimDate is a weekly retail calendar. Re-run whichever project's Power BI
   script you are currently demoing.
   ============================================================================= */
SET NOCOUNT ON;
GO

IF SCHEMA_ID('pbi') IS NULL EXEC('CREATE SCHEMA pbi');
GO

/* ---------------------------------------------------------------- DimDate ---- */
CREATE OR ALTER VIEW pbi.DimDate AS
SELECT
    DateKey       = YEAR(CalendarDate) * 10000 + MONTH(CalendarDate) * 100 + DAY(CalendarDate),
    [Date]        = CalendarDate,
    [Year]        = YEAR(CalendarDate),
    [Quarter]     = CONCAT(YEAR(CalendarDate), '-Q', DATEPART(QUARTER, CalendarDate)),
    MonthNumber   = MONTH(CalendarDate),
    [Month]       = LEFT(DATENAME(MONTH, CalendarDate), 3),
    MonthYear     = CONCAT(LEFT(DATENAME(MONTH, CalendarDate), 3), ' ', YEAR(CalendarDate)),
    MonthYearSort = YEAR(CalendarDate) * 100 + MONTH(CalendarDate),
    DayName       = DATENAME(WEEKDAY, CalendarDate),
    IsBusinessDay = CONVERT(bit, IsBusinessDay)
FROM orig.Calendar;
GO

/* -------------------------------------------------------- DimLoanOfficer ---- */
CREATE OR ALTER VIEW pbi.DimLoanOfficer AS
SELECT
    lo.LoanOfficerId, lo.LoanOfficerName, lo.Branch, lo.Region, lo.HireDate,
    TenureYears = CAST(DATEDIFF(MONTH, lo.HireDate,
                       (SELECT MAX(EventDate) FROM orig.ApplicationEvent)) / 12.0 AS decimal(4,1))
FROM orig.LoanOfficer lo;
GO

/* -------------------------------------------------------------- DimStage ---- */
CREATE OR ALTER VIEW pbi.DimStage AS
SELECT StageKey = StageNo, StageName = Stage, StageOrder = StageNo, SLABusinessDays
FROM orig.StageSLA;
GO

/* ------------------------------------------------------- FactApplication ---- */
CREATE OR ALTER VIEW pbi.FactApplication AS
WITH asof AS (SELECT AsOf = MAX(EventDate) FROM orig.ApplicationEvent),
funded AS (
    SELECT ApplicationId, FundedDate = MIN(EventDate)
    FROM orig.ApplicationEvent WHERE EventType = 'Funded' GROUP BY ApplicationId
),
fallout AS (
    SELECT ApplicationId, FalloutType = MIN(EventType), FalloutReason = MIN(Detail)
    FROM orig.ApplicationEvent
    WHERE EventType IN ('Denied','Withdrawn','Cancelled')
    GROUP BY ApplicationId
)
SELECT
    cur.ApplicationId,
    ApplicationDateKey = YEAR(ap.ApplicationDate) * 10000 + MONTH(ap.ApplicationDate) * 100 + DAY(ap.ApplicationDate),
    FundedDateKey      = YEAR(f.FundedDate) * 10000 + MONTH(f.FundedDate) * 100 + DAY(f.FundedDate),
    cur.LoanOfficerId,
    ap.Channel, ap.LoanPurpose, ap.ProductType, ap.PropertyState, ap.Occupancy,
    ap.LoanAmount, ap.PropertyValue, ap.LTV, ap.CreditScore, ap.DTI, ap.NoteRate,
    cur.CurrentState,
    DaysInCurrentStateBiz = cur.BusinessDaysInState,
    PipelineAgeBucket = CASE
        WHEN cur.IsInPipeline = 0 THEN NULL
        WHEN cur.BusinessDaysInState <=  5 THEN '1. 0-5 biz days'
        WHEN cur.BusinessDaysInState <= 10 THEN '2. 6-10'
        WHEN cur.BusinessDaysInState <= 20 THEN '3. 11-20'
        ELSE                                   '4. 21+ (stale)' END,
    IsInPipeline = CONVERT(bit, cur.IsInPipeline),
    IsFunded     = CONVERT(bit, cur.IsFunded),
    IsFallout    = CONVERT(bit, cur.IsFallout),
    fo.FalloutType,
    fo.FalloutReason,
    AppToFundBizDays = CASE WHEN cur.IsFunded = 1 THEN
          (SELECT MAX(BusinessDaySeq) FROM orig.Calendar WHERE CalendarDate = f.FundedDate)
        - (SELECT MAX(BusinessDaySeq) FROM orig.Calendar WHERE CalendarDate = ap.ApplicationDate) END,
    Locked             = CONVERT(bit, CASE WHEN rl.ApplicationId IS NOT NULL THEN 1 ELSE 0 END),
    LockStatus         = rl.Status,
    LockRate           = rl.LockRate,
    LockExtensionCount = ISNULL(rl.ExtensionCount, 0),
    LockExpirationBucket = CASE
        WHEN rl.Status IS NULL OR rl.Status <> 'Active' THEN NULL
        WHEN DATEDIFF(DAY, a.AsOf, rl.ExpirationDate) <  0 THEN '0. overdue'
        WHEN DATEDIFF(DAY, a.AsOf, rl.ExpirationDate) <= 7 THEN '1. next 7 days'
        WHEN DATEDIFF(DAY, a.AsOf, rl.ExpirationDate) <= 14 THEN '2. 8-14 days'
        WHEN DATEDIFF(DAY, a.AsOf, rl.ExpirationDate) <= 30 THEN '3. 15-30 days'
        ELSE                                                    '4. 30+ days' END
FROM orig.vApplicationCurrent cur
JOIN orig.Application ap ON ap.ApplicationId = cur.ApplicationId
CROSS JOIN asof a
LEFT JOIN funded  f  ON f.ApplicationId  = cur.ApplicationId
LEFT JOIN fallout fo ON fo.ApplicationId = cur.ApplicationId
LEFT JOIN orig.RateLock rl ON rl.ApplicationId = cur.ApplicationId;
GO

/* ---------------------------------------------------- FactStageDuration ---- */
CREATE OR ALTER VIEW pbi.FactStageDuration AS
SELECT
    sd.ApplicationId,
    StageKey       = sd.StageNo,
    cur.LoanOfficerId,
    EnteredDateKey = YEAR(sd.EnteredDate) * 10000 + MONTH(sd.EnteredDate) * 100 + DAY(sd.EnteredDate),
    sd.CalendarDays,
    sd.BusinessDays,
    sd.ExitReason,
    IsCurrentStage = CONVERT(bit, sd.IsCurrentStage),
    IsSLABreach    = CONVERT(bit, CASE WHEN sd.IsCurrentStage = 1 AND sd.BusinessDays > sla.SLABusinessDays THEN 1 ELSE 0 END),
    DaysOverSLA    = CASE WHEN sd.IsCurrentStage = 1 AND sd.BusinessDays > sla.SLABusinessDays
                          THEN sd.BusinessDays - sla.SLABusinessDays ELSE 0 END
FROM orig.vStageDurations sd
JOIN orig.vApplicationCurrent cur ON cur.ApplicationId = sd.ApplicationId
LEFT JOIN orig.StageSLA sla       ON sla.StageNo = sd.StageNo
WHERE sd.StageNo BETWEEN 1 AND 6;
GO

/* --------------------------------------------------------- FactForecast ---- */
CREATE OR ALTER VIEW pbi.FactForecast AS
WITH milestone AS (
    SELECT e.ApplicationId, e.EventDate,
           StageNo = CASE e.EventType
               WHEN 'Application' THEN 1 WHEN 'Processing' THEN 2 WHEN 'Underwriting Submitted' THEN 3
               WHEN 'Conditional Approval' THEN 4 WHEN 'Clear to Close' THEN 5 WHEN 'Closing' THEN 6 END
    FROM orig.ApplicationEvent e
    WHERE e.EventType IN ('Application','Processing','Underwriting Submitted',
                          'Conditional Approval','Clear to Close','Closing')
),
outcome AS (
    SELECT ApplicationId,
           IsFunded   = MAX(CASE WHEN EventType IN ('Funded','Delivered') THEN 1 ELSE 0 END),
           IsDecided  = MAX(CASE WHEN EventType IN ('Funded','Delivered','Denied','Withdrawn','Cancelled') THEN 1 ELSE 0 END),
           FundedDate = MIN(CASE WHEN EventType = 'Funded' THEN EventDate END)
    FROM orig.ApplicationEvent GROUP BY ApplicationId
),
rate AS (
    SELECT m.StageNo, FundProb = 1.0 * SUM(o.IsFunded) / COUNT(*)
    FROM milestone m JOIN outcome o ON o.ApplicationId = m.ApplicationId AND o.IsDecided = 1
    GROUP BY m.StageNo
),
speed AS (
    SELECT DISTINCT m.StageNo,
           MedianDaysToFund = CAST(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY DATEDIFF(DAY, m.EventDate, o.FundedDate))
                                   OVER (PARTITION BY m.StageNo) AS int)
    FROM milestone m JOIN outcome o ON o.ApplicationId = m.ApplicationId AND o.IsFunded = 1
    WHERE m.EventDate <= o.FundedDate
),
live AS (
    SELECT m.ApplicationId, ap.LoanAmount, StageNo = MAX(m.StageNo)
    FROM milestone m
    JOIN outcome o          ON o.ApplicationId  = m.ApplicationId AND o.IsDecided = 0
    JOIN orig.Application ap ON ap.ApplicationId = m.ApplicationId
    GROUP BY m.ApplicationId, ap.LoanAmount
)
SELECT
    live.ApplicationId,
    live.LoanAmount,
    CurrentStageKey      = live.StageNo,
    StageFundProbability = CAST(r.FundProb AS decimal(5,4)),
    ExpectedFundedAmount = CAST(live.LoanAmount * r.FundProb AS decimal(14,2)),
    ExpectedFundWindow   = CASE
        WHEN s.MedianDaysToFund <= 30 THEN '1. Next 30 days'
        WHEN s.MedianDaysToFund <= 60 THEN '2. 31-60 days'
        WHEN s.MedianDaysToFund <= 90 THEN '3. 61-90 days'
        ELSE                              '4. 90+ days' END
FROM live
JOIN rate  r ON r.StageNo = live.StageNo
JOIN speed s ON s.StageNo = live.StageNo;
GO

PRINT 'pbi semantic layer built (6 views).';
GO
