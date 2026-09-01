/* =============================================================================
   Guided tour -- loan-origination pipeline analytics
   Run:  .\q.ps1 -File sql\04_demo.sql
   ============================================================================= */
SET NOCOUNT ON;
GO

PRINT '========== 1. Pipeline snapshot -- current state of every application ==========';
SELECT
    CurrentState,
    Loans      = COUNT(*),
    LoanAmount = CAST(SUM(LoanAmount) AS decimal(16,2)),
    Bucket     = MAX(CASE WHEN IsInPipeline = 1 THEN 'in pipeline'
                          WHEN IsFunded    = 1 THEN 'funded'
                          ELSE 'fallout' END)
FROM orig.vApplicationCurrent
GROUP BY CurrentState
ORDER BY CASE CurrentState
    WHEN 'Application' THEN 1 WHEN 'Processing' THEN 2 WHEN 'Underwriting' THEN 3
    WHEN 'Conditional Approval' THEN 4 WHEN 'Clear to Close' THEN 5 WHEN 'Closing' THEN 6
    WHEN 'Funded' THEN 7 WHEN 'Delivered' THEN 8 ELSE 9 END;

PRINT '========== 2. Funnel -- pull-through by application cohort, last 12 months ==========';
SELECT TOP 12 CohortMonth, Applications, Reached_Underwriting, Reached_Closing, Funded,
       StillInPipeline, PullThrough_Pct, DecidedPullThrough_Pct
FROM orig.vFunnel ORDER BY CohortMonth DESC;

PRINT '========== 3. Funnel -- stage-to-stage conversion, all cohorts ==========';
SELECT
    Applications          = SUM(Applications),
    Pct_to_Processing     = CAST(100.0 * SUM(Reached_Processing)   / SUM(Applications)          AS decimal(5,1)),
    Pct_to_Underwriting   = CAST(100.0 * SUM(Reached_Underwriting) / SUM(Reached_Processing)    AS decimal(5,1)),
    Pct_to_CondApproval   = CAST(100.0 * SUM(Reached_CondApproval) / SUM(Reached_Underwriting)  AS decimal(5,1)),
    Pct_to_ClearToClose   = CAST(100.0 * SUM(Reached_ClearToClose) / SUM(Reached_CondApproval)  AS decimal(5,1)),
    Pct_to_Closing        = CAST(100.0 * SUM(Reached_Closing)      / SUM(Reached_ClearToClose)  AS decimal(5,1)),
    Pct_to_Funded         = CAST(100.0 * SUM(Funded)               / SUM(Reached_Closing)       AS decimal(5,1))
FROM orig.vFunnel;

PRINT '========== 4. Where the time goes -- median / p90 business days per stage ==========';
SELECT StageNo, StageName, CompletedInstances, Median_BusinessDays, P90_BusinessDays, Median_CalendarDays
FROM orig.vStageCycleTime WHERE StageNo BETWEEN 1 AND 6 ORDER BY StageNo;

PRINT '========== 5. Appraisal turn time (Ordered -> Received) ==========';
;WITH appr AS (
    SELECT ApplicationId,
           Ordered  = MIN(CASE WHEN EventType = 'Appraisal Ordered'  THEN EventDate END),
           Received = MIN(CASE WHEN EventType = 'Appraisal Received' THEN EventDate END)
    FROM orig.ApplicationEvent WHERE EventType LIKE 'Appraisal%'
    GROUP BY ApplicationId
)
SELECT DISTINCT
    Appraisals   = COUNT(*) OVER (),
    Median_Days  = CAST(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY DATEDIFF(DAY, Ordered, Received) * 1.0) OVER () AS decimal(5,1)),
    P90_Days     = CAST(PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY DATEDIFF(DAY, Ordered, Received) * 1.0) OVER () AS decimal(5,1)),
    Pct_over_21d = CAST(100.0 * SUM(CASE WHEN DATEDIFF(DAY, Ordered, Received) > 21 THEN 1 ELSE 0 END) OVER ()
                        / COUNT(*) OVER () AS decimal(5,1))
FROM appr WHERE Received IS NOT NULL;

PRINT '========== 6. SLA breaches -- live loans past their stage target ==========';
SELECT TOP 15 ApplicationId, CurrentState, BusinessDaysInState, SLABusinessDays, DaysOverSLA,
       LoanOfficerName, Branch, LoanAmount
FROM orig.vSLABreaches ORDER BY DaysOverSLA DESC;
SELECT BreachSummary_Stage = CurrentState, Loans = COUNT(*), AvgDaysOver = AVG(DaysOverSLA)
FROM orig.vSLABreaches GROUP BY CurrentState ORDER BY Loans DESC;

PRINT '========== 7. Pipeline aging -- live loans by stage x age ==========';
SELECT CurrentState, AgeBucket, Loans, LoanAmount
FROM orig.vPipelineAging
ORDER BY CASE CurrentState
    WHEN 'Application' THEN 1 WHEN 'Processing' THEN 2 WHEN 'Underwriting' THEN 3
    WHEN 'Conditional Approval' THEN 4 WHEN 'Clear to Close' THEN 5 WHEN 'Closing' THEN 6 END, AgeBucket;

PRINT '========== 8. Rate-lock desk ==========';
SELECT ExpirationWindow, Locks, LockedAmount, WA_LockRate FROM orig.vLockExpirations ORDER BY ExpirationWindow;
SELECT
    TotalLocks       = COUNT(*),
    ExtensionRate_Pct = CAST(100.0 * SUM(CASE WHEN ExtensionCount > 0 THEN 1 ELSE 0 END) / COUNT(*) AS decimal(5,1)),
    LockPullThrough_Pct = CAST(100.0 * SUM(CASE WHEN Status = 'Used' THEN 1 ELSE 0 END)
                               / NULLIF(SUM(CASE WHEN Status IN ('Used','Expired') THEN 1 ELSE 0 END), 0) AS decimal(5,1))
FROM orig.RateLock;

PRINT '========== 9. Loan-officer scorecard -- trailing 12 months ==========';
SELECT LoanOfficerName, Branch, Applications, Funded, InPipeline, FundedVolume,
       PullThrough_Pct, Purchase_Pct, Avg_NoteRate, Avg_AppToFund_Days
FROM orig.vLoanOfficerScorecard ORDER BY FundedVolume DESC;

PRINT '========== 10. Pull-through-weighted forecast -- expected $ to fund ==========';
SELECT FundWindow, Loans, PipelineAmount, ExpectedFundedAmount FROM orig.vPullThroughForecast ORDER BY FundWindow;
SELECT TotalPipeline = SUM(PipelineAmount), TotalExpectedToFund = SUM(ExpectedFundedAmount)
FROM orig.vPullThroughForecast;
GO
