/* =============================================================================
   Validate the generated pipeline + the stage model
   -----------------------------------------------------------------------------
   One result set: Check | Detail | Status. Every row should read PASS.
   Run:  .\q.ps1 -File sql\03_validate.sql
   ============================================================================= */
SET NOCOUNT ON;
GO

;WITH
milestone_order AS (   -- each app's milestone events, with expected vs actual order
    SELECT e.ApplicationId, e.EventDate,
           StageNo = CASE e.EventType
               WHEN 'Application' THEN 1 WHEN 'Processing' THEN 2 WHEN 'Underwriting Submitted' THEN 3
               WHEN 'Conditional Approval' THEN 4 WHEN 'Clear to Close' THEN 5 WHEN 'Closing' THEN 6
               WHEN 'Funded' THEN 7 WHEN 'Delivered' THEN 8 END,
           DateRank = ROW_NUMBER() OVER (PARTITION BY e.ApplicationId ORDER BY e.EventDate,
                        CASE e.EventType WHEN 'Application' THEN 1 WHEN 'Processing' THEN 2
                        WHEN 'Underwriting Submitted' THEN 3 WHEN 'Conditional Approval' THEN 4
                        WHEN 'Clear to Close' THEN 5 WHEN 'Closing' THEN 6 WHEN 'Funded' THEN 7
                        WHEN 'Delivered' THEN 8 END),
           StageRank = ROW_NUMBER() OVER (PARTITION BY e.ApplicationId ORDER BY
                        CASE e.EventType WHEN 'Application' THEN 1 WHEN 'Processing' THEN 2
                        WHEN 'Underwriting Submitted' THEN 3 WHEN 'Conditional Approval' THEN 4
                        WHEN 'Clear to Close' THEN 5 WHEN 'Closing' THEN 6 WHEN 'Funded' THEN 7
                        WHEN 'Delivered' THEN 8 END)
    FROM orig.ApplicationEvent e
    WHERE e.EventType IN ('Application','Processing','Underwriting Submitted','Conditional Approval',
                          'Clear to Close','Closing','Funded','Delivered')
),
term AS (
    SELECT ApplicationId, MIN(EventDate) AS TermDate
    FROM orig.ApplicationEvent WHERE EventType IN ('Denied','Withdrawn','Cancelled')
    GROUP BY ApplicationId
),
funnel_mono AS (
    SELECT COUNT(*) AS Bad FROM orig.vFunnel
    WHERE Reached_Processing   < Reached_Underwriting
       OR Reached_Underwriting < Reached_CondApproval
       OR Reached_CondApproval < Reached_ClearToClose
       OR Reached_ClearToClose < Reached_Closing
       OR Reached_Closing      < Funded
),
checks AS (
    SELECT 1 AS Seq,
        'Every application has exactly one Application event' AS [Check],
        CONCAT((SELECT COUNT(*) FROM (SELECT ApplicationId FROM orig.ApplicationEvent
                WHERE EventType = 'Application' GROUP BY ApplicationId HAVING COUNT(*) <> 1) x),
               ' offenders; ',
               (SELECT COUNT(*) FROM orig.Application), ' apps') AS Detail,
        CASE WHEN (SELECT COUNT(*) FROM (SELECT ApplicationId FROM orig.ApplicationEvent
                   WHERE EventType = 'Application' GROUP BY ApplicationId HAVING COUNT(*) <> 1) x) = 0
                  AND (SELECT COUNT(DISTINCT ApplicationId) FROM orig.ApplicationEvent WHERE EventType='Application')
                      = (SELECT COUNT(*) FROM orig.Application)
             THEN 'PASS' ELSE '*** FAIL ***' END AS Status

    UNION ALL
    SELECT 2, 'Milestone events occur in stage order (date order = stage order)',
        CONCAT((SELECT COUNT(DISTINCT ApplicationId) FROM milestone_order WHERE DateRank <> StageRank), ' apps out of order'),
        CASE WHEN (SELECT COUNT(*) FROM milestone_order WHERE DateRank <> StageRank) = 0 THEN 'PASS' ELSE '*** FAIL ***' END

    UNION ALL
    SELECT 3, 'No milestone events after a terminal (Denied/Withdrawn/Cancelled) event',
        CONCAT((SELECT COUNT(*) FROM orig.ApplicationEvent e JOIN term t ON t.ApplicationId = e.ApplicationId
                WHERE e.EventType IN ('Processing','Underwriting Submitted','Conditional Approval',
                                      'Clear to Close','Closing','Funded','Delivered')
                  AND e.EventDate > t.TermDate), ' stray events'),
        CASE WHEN (SELECT COUNT(*) FROM orig.ApplicationEvent e JOIN term t ON t.ApplicationId = e.ApplicationId
                   WHERE e.EventType IN ('Processing','Underwriting Submitted','Conditional Approval',
                                         'Clear to Close','Closing','Funded','Delivered')
                     AND e.EventDate > t.TermDate) = 0 THEN 'PASS' ELSE '*** FAIL ***' END

    UNION ALL
    SELECT 4, 'vApplicationCurrent: exactly one row per application, flags sum to 1',
        CONCAT((SELECT COUNT(*) FROM orig.vApplicationCurrent) - (SELECT COUNT(*) FROM orig.Application), ' row delta; ',
               (SELECT COUNT(*) FROM orig.vApplicationCurrent
                WHERE IsInPipeline + IsFunded + IsFallout <> 1), ' bad flag rows'),
        CASE WHEN (SELECT COUNT(*) FROM orig.vApplicationCurrent) = (SELECT COUNT(*) FROM orig.Application)
                  AND (SELECT COUNT(*) FROM orig.vApplicationCurrent WHERE IsInPipeline + IsFunded + IsFallout <> 1) = 0
             THEN 'PASS' ELSE '*** FAIL ***' END

    UNION ALL
    SELECT 5, 'vStageDurations: exactly one current stage per in-pipeline loan, none for decided',
        CONCAT((SELECT COUNT(*) FROM (
                    SELECT sd.ApplicationId
                    FROM orig.vStageDurations sd
                    JOIN orig.vApplicationCurrent cur ON cur.ApplicationId = sd.ApplicationId
                    WHERE cur.IsInPipeline = 1 AND sd.IsCurrentStage = 1
                    GROUP BY sd.ApplicationId HAVING COUNT(*) <> 1) x), ' pipeline loans wrong; ',
               (SELECT COUNT(*) FROM orig.vStageDurations sd
                JOIN orig.vApplicationCurrent cur ON cur.ApplicationId = sd.ApplicationId
                WHERE cur.IsInPipeline = 0 AND sd.IsCurrentStage = 1), ' decided loans flagged current'),
        CASE WHEN (SELECT COUNT(*) FROM (
                    SELECT sd.ApplicationId FROM orig.vStageDurations sd
                    JOIN orig.vApplicationCurrent cur ON cur.ApplicationId = sd.ApplicationId
                    WHERE cur.IsInPipeline = 1 AND sd.IsCurrentStage = 1
                    GROUP BY sd.ApplicationId HAVING COUNT(*) <> 1) x) = 0
                  AND (SELECT COUNT(*) FROM orig.vStageDurations sd
                       JOIN orig.vApplicationCurrent cur ON cur.ApplicationId = sd.ApplicationId
                       WHERE cur.IsInPipeline = 0 AND sd.IsCurrentStage = 1) = 0
             THEN 'PASS' ELSE '*** FAIL ***' END

    UNION ALL
    SELECT 6, 'Funnel is monotonically non-increasing across stages, every cohort',
        CONCAT((SELECT Bad FROM funnel_mono), ' cohorts violating'),
        CASE WHEN (SELECT Bad FROM funnel_mono) = 0 THEN 'PASS' ELSE '*** FAIL ***' END

    UNION ALL
    SELECT 7, 'Stage durations: BusinessDays <= CalendarDays, no negatives',
        CONCAT((SELECT COUNT(*) FROM orig.vStageDurations
                WHERE BusinessDays > CalendarDays OR CalendarDays < 0), ' bad rows'),
        CASE WHEN (SELECT COUNT(*) FROM orig.vStageDurations
                   WHERE BusinessDays > CalendarDays OR CalendarDays < 0) = 0 THEN 'PASS' ELSE '*** FAIL ***' END

    UNION ALL
    SELECT 8, 'Calendar has one row per day with no gaps',
        CONCAT((SELECT DATEDIFF(DAY, MIN(CalendarDate), MAX(CalendarDate)) + 1 - COUNT(*) FROM orig.Calendar), ' missing days'),
        CASE WHEN (SELECT DATEDIFF(DAY, MIN(CalendarDate), MAX(CalendarDate)) + 1 - COUNT(*) FROM orig.Calendar) = 0
             THEN 'PASS' ELSE '*** FAIL ***' END

    UNION ALL
    SELECT 9, 'Overall pull-through in a sane band (60-75%)',
        (SELECT CONCAT(FORMAT(1.0 * SUM(Funded) / SUM(Applications), 'P1'), ' funded of ', SUM(Applications), ' apps')
         FROM orig.vFunnel),
        (SELECT CASE WHEN 1.0 * SUM(Funded) / SUM(Applications) BETWEEN 0.60 AND 0.75 THEN 'PASS' ELSE '*** FAIL ***' END
         FROM orig.vFunnel)
)
SELECT [Check], Detail, Status FROM checks ORDER BY Seq;
GO
