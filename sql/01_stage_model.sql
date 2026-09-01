/* =============================================================================
   Stage model -- turn the event log into pipeline stages
   -----------------------------------------------------------------------------
   Two views, both derived only from orig.ApplicationEvent (not the generator's
   plan table):

     orig.vStageDurations   one row per application per stage it occupied:
                            entered / exited dates, calendar days, BUSINESS days
                            (via orig.Calendar), how the stage ended.
     orig.vApplicationCurrent  one row per application: its current state
                            (working stage, or Funded / Delivered / Denied / ...),
                            how long it has sat there, and pipeline flags.

   Reference "as of" date = the latest event in the log.
   Run:  .\q.ps1 -File sql\01_stage_model.sql
   ============================================================================= */
SET NOCOUNT ON;
GO

CREATE OR ALTER VIEW orig.vStageDurations AS
WITH milestones AS (
    SELECT
        e.ApplicationId,
        e.EventDate,
        StageNo = CASE e.EventType
            WHEN 'Application'            THEN 1
            WHEN 'Processing'             THEN 2
            WHEN 'Underwriting Submitted' THEN 3
            WHEN 'Conditional Approval'   THEN 4
            WHEN 'Clear to Close'         THEN 5
            WHEN 'Closing'                THEN 6
            WHEN 'Funded'                 THEN 7
            WHEN 'Delivered'              THEN 8 END
    FROM orig.ApplicationEvent e
    WHERE e.EventType IN ('Application','Processing','Underwriting Submitted',
                          'Conditional Approval','Clear to Close','Closing','Funded','Delivered')
),
term AS (
    SELECT ApplicationId, MIN(EventDate) AS TermDate, MIN(EventType) AS TermType
    FROM orig.ApplicationEvent
    WHERE EventType IN ('Denied','Withdrawn','Cancelled')
    GROUP BY ApplicationId
),
asof AS (SELECT AsOf = MAX(EventDate) FROM orig.ApplicationEvent),
seq AS (
    SELECT
        m.ApplicationId, m.StageNo, m.EventDate AS EnteredDate,
        NextMilestoneDate = LEAD(m.EventDate) OVER (PARTITION BY m.ApplicationId ORDER BY m.StageNo),
        TermDate = CASE WHEN t.TermDate > m.EventDate THEN t.TermDate END,
        t.TermType
    FROM milestones m
    LEFT JOIN term t ON t.ApplicationId = m.ApplicationId
),
stage AS (
    SELECT s.*, a.AsOf,
        EffectiveExit = COALESCE(s.NextMilestoneDate, s.TermDate, a.AsOf),
        IsCurrentStage = CASE WHEN s.NextMilestoneDate IS NULL AND s.TermDate IS NULL
                                   AND s.StageNo <= 6 THEN 1 ELSE 0 END
    FROM seq s CROSS JOIN asof a
)
SELECT
    st.ApplicationId,
    st.StageNo,
    StageName = CASE st.StageNo
        WHEN 1 THEN 'Application' WHEN 2 THEN 'Processing' WHEN 3 THEN 'Underwriting'
        WHEN 4 THEN 'Conditional Approval' WHEN 5 THEN 'Clear to Close'
        WHEN 6 THEN 'Closing' WHEN 7 THEN 'Funded (post-closing)' WHEN 8 THEN 'Delivered' END,
    st.EnteredDate,
    ExitedDate = CASE WHEN st.IsCurrentStage = 1 THEN NULL ELSE st.EffectiveExit END,
    st.IsCurrentStage,
    ExitReason = CASE
        WHEN st.NextMilestoneDate IS NOT NULL THEN 'Advanced'
        WHEN st.TermDate IS NOT NULL          THEN st.TermType
        ELSE 'Still in stage' END,
    CalendarDays = DATEDIFF(DAY, st.EnteredDate, st.EffectiveExit),
    BusinessDays = cExit.BusinessDaySeq - cEnter.BusinessDaySeq
FROM stage st
JOIN orig.Calendar cEnter ON cEnter.CalendarDate = st.EnteredDate
JOIN orig.Calendar cExit  ON cExit.CalendarDate  = st.EffectiveExit;
GO

CREATE OR ALTER VIEW orig.vApplicationCurrent AS
WITH ranked AS (
    SELECT
        e.ApplicationId, e.EventType, e.EventDate,
        rn = ROW_NUMBER() OVER (PARTITION BY e.ApplicationId
             ORDER BY CASE e.EventType
                 WHEN 'Application' THEN 1 WHEN 'Processing' THEN 2 WHEN 'Underwriting Submitted' THEN 3
                 WHEN 'Conditional Approval' THEN 4 WHEN 'Clear to Close' THEN 5 WHEN 'Closing' THEN 6
                 WHEN 'Funded' THEN 7 WHEN 'Delivered' THEN 8 ELSE 9 END DESC,
                 e.EventDate DESC)
    FROM orig.ApplicationEvent e
    WHERE e.EventType NOT IN ('Rate Locked','Lock Extended','Lock Expired',
                              'Appraisal Ordered','Appraisal Received')
),
asof AS (SELECT AsOf = MAX(EventDate) FROM orig.ApplicationEvent)
SELECT
    r.ApplicationId,
    ap.ApplicationDate,
    ap.LoanOfficerId,
    ap.Channel,
    ap.LoanPurpose,
    ap.LoanAmount,
    CurrentState = CASE r.EventType
        WHEN 'Underwriting Submitted' THEN 'Underwriting'
        WHEN 'Conditional Approval'   THEN 'Conditional Approval'
        ELSE r.EventType END,
    CurrentStateDate = r.EventDate,
    IsInPipeline = CASE WHEN r.EventType IN ('Application','Processing','Underwriting Submitted',
                                             'Conditional Approval','Clear to Close','Closing')
                        THEN 1 ELSE 0 END,
    IsFunded     = CASE WHEN r.EventType IN ('Funded','Delivered') THEN 1 ELSE 0 END,
    IsFallout    = CASE WHEN r.EventType IN ('Denied','Withdrawn','Cancelled') THEN 1 ELSE 0 END,
    DaysInCurrentState  = DATEDIFF(DAY, r.EventDate, a.AsOf),
    BusinessDaysInState = cNow.BusinessDaySeq - cState.BusinessDaySeq,
    AppToNowCalendarDays = DATEDIFF(DAY, ap.ApplicationDate, a.AsOf)
FROM ranked r
JOIN orig.Application ap ON ap.ApplicationId = r.ApplicationId
CROSS JOIN asof a
JOIN orig.Calendar cState ON cState.CalendarDate = r.EventDate
JOIN orig.Calendar cNow   ON cNow.CalendarDate   = a.AsOf
WHERE r.rn = 1;
GO

PRINT 'Stage model built.';
GO
