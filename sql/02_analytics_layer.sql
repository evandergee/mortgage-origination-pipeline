/* =============================================================================
   Analytics layer -- the questions a pipeline / production analyst answers
   -----------------------------------------------------------------------------
     orig.vFunnel               pull-through by application-cohort month
     orig.vCycleTime            median / p90 days application -> funded, by cohort
     orig.vStageCycleTime       median / p90 days spent in each stage
     orig.vSLABreaches          live loans past their stage SLA (business days)
     orig.vPipelineAging        live pipeline by stage x age bucket
     orig.vLockExpirations      active rate locks by time-to-expiration
     orig.vLoanOfficerScorecard trailing-12-month LO production
     orig.vPullThroughForecast  expected $ to fund in the next 30 / 60 / 90 days

   Idempotent (CREATE OR ALTER).  Run:  .\q.ps1 -File sql\02_analytics_layer.sql
   ============================================================================= */
SET NOCOUNT ON;
GO

/* ---- 1. Funnel / pull-through -------------------------------------------------- */
CREATE OR ALTER VIEW orig.vFunnel AS
WITH reached AS (
    SELECT ApplicationId,
        R_Processing   = MAX(CASE WHEN EventType = 'Processing'             THEN 1 ELSE 0 END),
        R_Underwriting = MAX(CASE WHEN EventType = 'Underwriting Submitted' THEN 1 ELSE 0 END),
        R_CondApproval = MAX(CASE WHEN EventType = 'Conditional Approval'   THEN 1 ELSE 0 END),
        R_ClearToClose = MAX(CASE WHEN EventType = 'Clear to Close'         THEN 1 ELSE 0 END),
        R_Closing      = MAX(CASE WHEN EventType = 'Closing'                THEN 1 ELSE 0 END),
        R_Funded       = MAX(CASE WHEN EventType IN ('Funded','Delivered')  THEN 1 ELSE 0 END)
    FROM orig.ApplicationEvent
    GROUP BY ApplicationId
)
SELECT
    CohortMonth = DATEFROMPARTS(YEAR(ap.ApplicationDate), MONTH(ap.ApplicationDate), 1),
    Applications          = COUNT(*),
    Reached_Processing    = SUM(r.R_Processing),
    Reached_Underwriting  = SUM(r.R_Underwriting),
    Reached_CondApproval  = SUM(r.R_CondApproval),
    Reached_ClearToClose  = SUM(r.R_ClearToClose),
    Reached_Closing       = SUM(r.R_Closing),
    Funded                = SUM(r.R_Funded),
    StillInPipeline       = SUM(CONVERT(int, cur.IsInPipeline)),
    PullThrough_Pct       = CAST(100.0 * SUM(r.R_Funded) / COUNT(*) AS decimal(5,1)),
    DecidedPullThrough_Pct = CAST(100.0 * SUM(r.R_Funded)
                                  / NULLIF(COUNT(*) - SUM(CONVERT(int, cur.IsInPipeline)), 0) AS decimal(5,1))
FROM orig.Application ap
JOIN reached r                  ON r.ApplicationId   = ap.ApplicationId
JOIN orig.vApplicationCurrent cur ON cur.ApplicationId = ap.ApplicationId
GROUP BY DATEFROMPARTS(YEAR(ap.ApplicationDate), MONTH(ap.ApplicationDate), 1);
GO

/* ---- 2. Cycle time: application -> funded, by cohort ------------------------- */
CREATE OR ALTER VIEW orig.vCycleTime AS
WITH funded AS (
    SELECT
        CohortMonth = DATEFROMPARTS(YEAR(ap.ApplicationDate), MONTH(ap.ApplicationDate), 1),
        CalDays = DATEDIFF(DAY, ap.ApplicationDate, f.FundedDate),
        BizDays = (SELECT COUNT(*) FROM orig.Calendar c
                   WHERE c.IsBusinessDay = 1
                     AND c.CalendarDate >  ap.ApplicationDate
                     AND c.CalendarDate <= f.FundedDate)
    FROM orig.Application ap
    JOIN (SELECT ApplicationId, MIN(EventDate) AS FundedDate
          FROM orig.ApplicationEvent WHERE EventType = 'Funded' GROUP BY ApplicationId) f
      ON f.ApplicationId = ap.ApplicationId
)
SELECT DISTINCT
    CohortMonth,
    FundedLoans           = COUNT(*)                                                          OVER (PARTITION BY CohortMonth),
    Median_AppToFund_Cal  = CAST(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY CalDays) OVER (PARTITION BY CohortMonth) AS decimal(6,1)),
    P90_AppToFund_Cal     = CAST(PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY CalDays) OVER (PARTITION BY CohortMonth) AS decimal(6,1)),
    Median_AppToFund_Biz  = CAST(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY BizDays) OVER (PARTITION BY CohortMonth) AS decimal(6,1))
FROM funded;
GO

/* ---- 3. Time spent in each stage (completed stages) ------------------------- */
CREATE OR ALTER VIEW orig.vStageCycleTime AS
SELECT DISTINCT
    StageNo,
    StageName,
    CompletedInstances  = COUNT(*)                                                                  OVER (PARTITION BY StageNo),
    Median_BusinessDays = CAST(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY BusinessDays * 1.0) OVER (PARTITION BY StageNo) AS decimal(6,1)),
    P90_BusinessDays    = CAST(PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY BusinessDays * 1.0) OVER (PARTITION BY StageNo) AS decimal(6,1)),
    Median_CalendarDays = CAST(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY CalendarDays * 1.0) OVER (PARTITION BY StageNo) AS decimal(6,1))
FROM orig.vStageDurations
WHERE ExitReason = 'Advanced';
GO

/* ---- 4. SLA breaches: live loans past the stage service-level target -------- */
CREATE OR ALTER VIEW orig.vSLABreaches AS
SELECT
    cur.ApplicationId,
    cur.CurrentState,
    cur.CurrentStateDate,
    cur.BusinessDaysInState,
    sla.SLABusinessDays,
    DaysOverSLA = cur.BusinessDaysInState - sla.SLABusinessDays,
    lo.LoanOfficerName,
    lo.Branch,
    cur.LoanAmount,
    cur.LoanPurpose
FROM orig.vApplicationCurrent cur
JOIN orig.StageSLA sla   ON sla.Stage = cur.CurrentState
JOIN orig.LoanOfficer lo ON lo.LoanOfficerId = cur.LoanOfficerId
WHERE cur.IsInPipeline = 1
  AND cur.BusinessDaysInState > sla.SLABusinessDays;
GO

/* ---- 5. Pipeline aging: live loans by stage x age bucket ------------------- */
CREATE OR ALTER VIEW orig.vPipelineAging AS
SELECT
    CurrentState,
    AgeBucket = CASE
        WHEN BusinessDaysInState <=  5 THEN '1. 0-5 business days'
        WHEN BusinessDaysInState <= 10 THEN '2. 6-10'
        WHEN BusinessDaysInState <= 20 THEN '3. 11-20'
        ELSE                               '4. 21+ (stale)' END,
    Loans      = COUNT(*),
    LoanAmount = CAST(SUM(LoanAmount) AS decimal(16,2))
FROM orig.vApplicationCurrent
WHERE IsInPipeline = 1
GROUP BY CurrentState,
    CASE
        WHEN BusinessDaysInState <=  5 THEN '1. 0-5 business days'
        WHEN BusinessDaysInState <= 10 THEN '2. 6-10'
        WHEN BusinessDaysInState <= 20 THEN '3. 11-20'
        ELSE                               '4. 21+ (stale)' END;
GO

/* ---- 6. Rate-lock desk: active locks by time to expiration ----------------- */
CREATE OR ALTER VIEW orig.vLockExpirations AS
WITH asof AS (SELECT AsOf = (SELECT MAX(EventDate) FROM orig.ApplicationEvent))
SELECT
    ExpirationWindow = CASE
        WHEN DATEDIFF(DAY, a.AsOf, rl.ExpirationDate) < 0  THEN '0. already expired / overdue'
        WHEN DATEDIFF(DAY, a.AsOf, rl.ExpirationDate) <= 7  THEN '1. next 7 days'
        WHEN DATEDIFF(DAY, a.AsOf, rl.ExpirationDate) <= 14 THEN '2. 8-14 days'
        WHEN DATEDIFF(DAY, a.AsOf, rl.ExpirationDate) <= 30 THEN '3. 15-30 days'
        ELSE                                                    '4. 30+ days' END,
    Locks       = COUNT(*),
    LockedAmount = CAST(SUM(ap.LoanAmount) AS decimal(16,2)),
    WA_LockRate  = CAST(SUM(ap.LoanAmount * rl.LockRate) / SUM(ap.LoanAmount) AS decimal(6,4))
FROM orig.RateLock rl
JOIN orig.Application ap          ON ap.ApplicationId  = rl.ApplicationId
JOIN orig.vApplicationCurrent cur ON cur.ApplicationId = rl.ApplicationId
CROSS JOIN asof a
WHERE rl.Status = 'Active' AND cur.IsInPipeline = 1
GROUP BY CASE
        WHEN DATEDIFF(DAY, a.AsOf, rl.ExpirationDate) < 0  THEN '0. already expired / overdue'
        WHEN DATEDIFF(DAY, a.AsOf, rl.ExpirationDate) <= 7  THEN '1. next 7 days'
        WHEN DATEDIFF(DAY, a.AsOf, rl.ExpirationDate) <= 14 THEN '2. 8-14 days'
        WHEN DATEDIFF(DAY, a.AsOf, rl.ExpirationDate) <= 30 THEN '3. 15-30 days'
        ELSE                                                    '4. 30+ days' END;
GO

/* ---- 7. Loan-officer scorecard: trailing 12 months ------------------------- */
CREATE OR ALTER VIEW orig.vLoanOfficerScorecard AS
WITH win AS (
    SELECT AsOf, StartDate = DATEADD(MONTH, -12, AsOf)
    FROM (SELECT AsOf = (SELECT MAX(EventDate) FROM orig.ApplicationEvent)) x
),
a AS (
    SELECT ap.LoanOfficerId, ap.LoanPurpose, ap.LoanAmount, ap.NoteRate,
           cur.IsFunded, cur.IsInPipeline, cur.IsFallout,
           AppToFund = CASE WHEN cur.IsFunded = 1
                            THEN DATEDIFF(DAY, ap.ApplicationDate, f.FundedDate) END
    FROM orig.Application ap
    JOIN orig.vApplicationCurrent cur ON cur.ApplicationId = ap.ApplicationId
    CROSS JOIN win w
    LEFT JOIN (SELECT ApplicationId, MIN(EventDate) AS FundedDate
               FROM orig.ApplicationEvent WHERE EventType = 'Funded' GROUP BY ApplicationId) f
           ON f.ApplicationId = ap.ApplicationId
    WHERE ap.ApplicationDate >= w.StartDate
)
SELECT
    lo.LoanOfficerId,
    lo.LoanOfficerName,
    lo.Branch,
    Applications      = COUNT(*),
    Funded            = SUM(CONVERT(int, a.IsFunded)),
    InPipeline        = SUM(CONVERT(int, a.IsInPipeline)),
    Fallout           = SUM(CONVERT(int, a.IsFallout)),
    FundedVolume      = CAST(SUM(CASE WHEN a.IsFunded = 1 THEN a.LoanAmount ELSE 0 END) AS decimal(16,2)),
    PullThrough_Pct   = CAST(100.0 * SUM(CONVERT(int, a.IsFunded))
                             / NULLIF(COUNT(*) - SUM(CONVERT(int, a.IsInPipeline)), 0) AS decimal(5,1)),
    Purchase_Pct      = CAST(100.0 * SUM(CASE WHEN a.LoanPurpose = 'Purchase' THEN 1 ELSE 0 END) / COUNT(*) AS decimal(5,1)),
    Avg_NoteRate      = CAST(AVG(a.NoteRate) AS decimal(6,4)),
    Avg_AppToFund_Days = CAST(AVG(a.AppToFund * 1.0) AS decimal(6,1))
FROM orig.LoanOfficer lo
JOIN a ON a.LoanOfficerId = lo.LoanOfficerId
GROUP BY lo.LoanOfficerId, lo.LoanOfficerName, lo.Branch;
GO

/* ---- 8. Pull-through-weighted forecast ------------------------------------------
   Each live pipeline loan is worth  LoanAmount x P(fund | reached its stage),
   expected to close around  today + (historical median days from that stage to
   funding).  Sum by 30 / 60 / 90-day window.
   ---------------------------------------------------------------------------------- */
CREATE OR ALTER VIEW orig.vPullThroughForecast AS
WITH milestone AS (   -- milestone events for the six working stages, straight from the log
    SELECT e.ApplicationId, e.EventDate,
           StageNo = CASE e.EventType
               WHEN 'Application' THEN 1 WHEN 'Processing' THEN 2 WHEN 'Underwriting Submitted' THEN 3
               WHEN 'Conditional Approval' THEN 4 WHEN 'Clear to Close' THEN 5 WHEN 'Closing' THEN 6 END
    FROM orig.ApplicationEvent e
    WHERE e.EventType IN ('Application','Processing','Underwriting Submitted',
                          'Conditional Approval','Clear to Close','Closing')
),
outcome AS (   -- one pass over the log: is each app funded? decided (out of pipeline)?
    SELECT ApplicationId,
           IsFunded  = MAX(CASE WHEN EventType IN ('Funded','Delivered') THEN 1 ELSE 0 END),
           IsDecided = MAX(CASE WHEN EventType IN ('Funded','Delivered','Denied','Withdrawn','Cancelled') THEN 1 ELSE 0 END),
           FundedDate = MIN(CASE WHEN EventType = 'Funded' THEN EventDate END)
    FROM orig.ApplicationEvent GROUP BY ApplicationId
),
stage_fund_rate AS (   -- of decided apps that reached stage N, what % funded?
    SELECT m.StageNo, Reached = COUNT(*), Funded = SUM(o.IsFunded)
    FROM milestone m
    JOIN outcome o ON o.ApplicationId = m.ApplicationId AND o.IsDecided = 1
    GROUP BY m.StageNo
),
days_to_fund AS (
    SELECT m.StageNo, D = DATEDIFF(DAY, m.EventDate, o.FundedDate)
    FROM milestone m
    JOIN outcome o ON o.ApplicationId = m.ApplicationId AND o.IsFunded = 1
    WHERE m.EventDate <= o.FundedDate
),
speed AS (
    SELECT DISTINCT StageNo,
           MedianDaysToFund = CAST(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY D) OVER (PARTITION BY StageNo) AS int)
    FROM days_to_fund
),
live AS (   -- in-pipeline apps and the highest working stage they have reached
    SELECT m.ApplicationId, ap.LoanAmount, StageNo = MAX(m.StageNo)
    FROM milestone m
    JOIN outcome o     ON o.ApplicationId = m.ApplicationId AND o.IsDecided = 0
    JOIN orig.Application ap ON ap.ApplicationId = m.ApplicationId
    GROUP BY m.ApplicationId, ap.LoanAmount
),
proj AS (
    SELECT
        l.LoanAmount,
        FundProb = 1.0 * r.Funded / r.Reached,
        FundWindow = CASE
            WHEN s.MedianDaysToFund <= 30 THEN '1. next 30 days'
            WHEN s.MedianDaysToFund <= 60 THEN '2. 31-60 days'
            WHEN s.MedianDaysToFund <= 90 THEN '3. 61-90 days'
            ELSE                              '4. 90+ days' END
    FROM live l
    JOIN stage_fund_rate r ON r.StageNo = l.StageNo
    JOIN speed s           ON s.StageNo = l.StageNo
)
SELECT
    FundWindow,
    Loans                = COUNT(*),
    PipelineAmount       = CAST(SUM(LoanAmount) AS decimal(16,2)),
    ExpectedFundedAmount = CAST(SUM(LoanAmount * FundProb) AS decimal(16,2))
FROM proj
GROUP BY FundWindow;
GO

PRINT 'Analytics layer built.';
GO
