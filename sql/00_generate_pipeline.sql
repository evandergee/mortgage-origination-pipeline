/* =============================================================================
   Mortgage loan-origination pipeline -- synthetic data generator
   -----------------------------------------------------------------------------
   Models the front end of the mortgage business: applications moving through
   underwriting to funding, as an EVENT LOG.

       orig.LoanOfficer       12 LOs across 3 branches
       orig.Calendar          one row per date, IsBusinessDay (weekday & not a
                              US federal holiday) -- powers the SLA math
       orig.Application        ~6,000 apps, application-time attributes only
       orig.ApplicationEvent   the event log (Application, Processing, Appraisal
                              Ordered/Received, Underwriting Submitted, Conditional
                              Approval, Clear to Close, Closing, Funded, Delivered,
                              Denied/Withdrawn/Cancelled, Rate Locked / Extended /
                              Expired)
       orig.ApplicationPlan    synthetic-data driver ONLY -- not part of the model
                              (holds each app's fate + milestone dates)

   "Today" is 2026-09-01; apps dated 2023-01 .. 2026-08 so recent months are
   still an open pipeline. Set-based, idempotent.
   Run:  .\q.ps1 -File sql\00_generate_pipeline.sql       (~30-60s)
   ============================================================================= */
SET NOCOUNT ON;
GO

IF SCHEMA_ID('orig') IS NULL EXEC('CREATE SCHEMA orig');
GO

DROP TABLE IF EXISTS orig.ApplicationEvent;
DROP TABLE IF EXISTS orig.RateLock;
DROP TABLE IF EXISTS orig.ApplicationPlan;
DROP TABLE IF EXISTS orig.Application;
DROP TABLE IF EXISTS orig.LoanOfficer;
DROP TABLE IF EXISTS orig.Calendar;
DROP TABLE IF EXISTS orig.StageSLA;
GO

DECLARE @Today date = '2026-09-01';

/* ============================ orig.LoanOfficer ============================== */
CREATE TABLE orig.LoanOfficer (
    LoanOfficerId   int          NOT NULL CONSTRAINT PK_orig_LoanOfficer PRIMARY KEY,
    LoanOfficerName nvarchar(60) NOT NULL,
    Branch          nvarchar(30) NOT NULL,
    Region          nvarchar(10) NOT NULL,
    HireDate        date         NOT NULL
);
INSERT orig.LoanOfficer VALUES
 ( 1, N'Alicia Moreno',     N'Denver',    N'West',    '2019-03-11'),
 ( 2, N'Brandon Fielding',  N'Denver',    N'West',    '2021-07-06'),
 ( 3, N'Priya Nair',        N'Denver',    N'West',    '2022-02-14'),
 ( 4, N'Marcus Webb',       N'Denver',    N'West',    '2023-09-05'),
 ( 5, N'Sofia Delgado',     N'Austin',    N'Central', '2018-06-18'),
 ( 6, N'Trevor Lin',        N'Austin',    N'Central', '2020-11-30'),
 ( 7, N'Hannah Boyd',       N'Austin',    N'Central', '2022-08-22'),
 ( 8, N'Devin Okafor',      N'Austin',    N'Central', '2024-01-15'),
 ( 9, N'Rachel Stein',      N'Charlotte', N'East',    '2017-04-03'),
 (10, N'Omar Haddad',       N'Charlotte', N'East',    '2021-01-25'),
 (11, N'Jenna Kowalski',    N'Charlotte', N'East',    '2023-05-19'),
 (12, N'Cole Barrett',      N'Charlotte', N'East',    '2024-06-10');
GO

/* ============================ orig.Calendar ================================= */
CREATE TABLE orig.Calendar (
    CalendarDate   date NOT NULL CONSTRAINT PK_orig_Calendar PRIMARY KEY,
    IsWeekday      bit  NOT NULL,
    IsHoliday      bit  NOT NULL,
    IsBusinessDay  bit  NOT NULL,
    BusinessDaySeq int  NOT NULL   -- running count of business days from the start of the calendar;
                                   -- business days in (d1, d2] = seq(d2) - seq(d1)
);
;WITH d AS (
    SELECT DATEADD(DAY, value, CAST('2022-06-01' AS date)) AS dt
    FROM GENERATE_SERIES(0, DATEDIFF(DAY, '2022-06-01', '2027-12-31'))
),
f AS (
    SELECT dt,
        IsWeekday = CASE WHEN DATENAME(WEEKDAY, dt) IN ('Saturday','Sunday') THEN 0 ELSE 1 END,
        IsHoliday = CASE WHEN
               (MONTH(dt)=1  AND DAY(dt)=1)                                                        -- New Year's
            OR (MONTH(dt)=6  AND DAY(dt)=19)                                                       -- Juneteenth
            OR (MONTH(dt)=7  AND DAY(dt)=4)                                                        -- Independence Day
            OR (MONTH(dt)=11 AND DAY(dt)=11)                                                       -- Veterans Day
            OR (MONTH(dt)=12 AND DAY(dt)=25)                                                       -- Christmas
            OR (DATENAME(WEEKDAY,dt)='Monday'   AND MONTH(dt)=1  AND (DAY(dt)-1)/7+1 = 3)          -- MLK
            OR (DATENAME(WEEKDAY,dt)='Monday'   AND MONTH(dt)=2  AND (DAY(dt)-1)/7+1 = 3)          -- Presidents
            OR (DATENAME(WEEKDAY,dt)='Monday'   AND MONTH(dt)=5  AND DAY(dt) >= 25)                -- Memorial (last Mon)
            OR (DATENAME(WEEKDAY,dt)='Monday'   AND MONTH(dt)=9  AND (DAY(dt)-1)/7+1 = 1)          -- Labor
            OR (DATENAME(WEEKDAY,dt)='Monday'   AND MONTH(dt)=10 AND (DAY(dt)-1)/7+1 = 2)          -- Columbus
            OR (DATENAME(WEEKDAY,dt)='Thursday' AND MONTH(dt)=11 AND (DAY(dt)-1)/7+1 = 4)          -- Thanksgiving
            THEN 1 ELSE 0 END
    FROM d
)
INSERT orig.Calendar (CalendarDate, IsWeekday, IsHoliday, IsBusinessDay, BusinessDaySeq)
SELECT dt, IsWeekday, IsHoliday, bd,
       SUM(bd) OVER (ORDER BY dt ROWS UNBOUNDED PRECEDING)
FROM (SELECT dt, IsWeekday, IsHoliday,
             bd = CASE WHEN IsWeekday = 1 AND IsHoliday = 0 THEN 1 ELSE 0 END
      FROM f) g;
PRINT CONCAT('orig.Calendar       : ', @@ROWCOUNT, ' days');
GO

/* ============================ orig.Application ============================== */
CREATE TABLE orig.Application (
    ApplicationId   int           NOT NULL CONSTRAINT PK_orig_Application PRIMARY KEY,
    ApplicationDate date          NOT NULL,
    LoanOfficerId   int           NOT NULL,
    Channel         varchar(14)   NOT NULL,
    LoanPurpose     varchar(14)   NOT NULL,
    PropertyState   char(2)       NOT NULL,
    PropertyType    varchar(20)   NOT NULL,
    Occupancy       varchar(12)   NOT NULL,
    LoanAmount      decimal(12,2) NOT NULL,
    PropertyValue   decimal(12,2) NOT NULL,
    LTV             decimal(5,2)  NOT NULL,
    CreditScore     int           NOT NULL,
    DTI             decimal(5,2)  NOT NULL,
    ProductType     varchar(10)   NOT NULL,
    NoteRate        decimal(6,4)  NOT NULL
);

;WITH r AS (
    SELECT v.value AS ApplicationId,
        ABS(CHECKSUM(NEWID())) AS r1, ABS(CHECKSUM(NEWID())) AS r2, ABS(CHECKSUM(NEWID())) AS r3,
        ABS(CHECKSUM(NEWID())) AS r4, ABS(CHECKSUM(NEWID())) AS r5, ABS(CHECKSUM(NEWID())) AS r6,
        ABS(CHECKSUM(NEWID())) AS r7, ABS(CHECKSUM(NEWID())) AS r8
    FROM GENERATE_SERIES(1, 9000) AS v
),
d AS (
    SELECT ApplicationId,
        ApplicationDate = DATEADD(DAY, r1 % DATEDIFF(DAY, '2023-01-01', '2026-08-29'), CAST('2023-01-01' AS date)),
        LoanOfficerId   = r2 % 12 + 1,
        Channel         = CASE WHEN r3 % 10 < 6 THEN 'Retail' WHEN r3 % 10 < 9 THEN 'Broker' ELSE 'Correspondent' END,
        LoanPurpose     = CASE WHEN r4 % 10 < 5 THEN 'Purchase' WHEN r4 % 10 < 8 THEN 'RateTermRefi' ELSE 'CashOutRefi' END,
        PropertyState   = CONVERT(char(2), CHOOSE(r5 % 15 + 1,'CA','TX','FL','CO','NC','TX','FL','AZ','GA','WA','CA','NV','TN','SC','OR')),
        PropertyType    = CHOOSE(r6 % 8 + 1,'SingleFamily','SingleFamily','SingleFamily','SingleFamily','Condo','Condo','Townhouse','TwoToFourUnit'),
        Occupancy       = CASE WHEN r7 % 10 < 8 THEN 'Primary' WHEN r7 % 10 < 9 THEN 'SecondHome' ELSE 'Investment' END,
        PropertyValue   = CAST(200000 + (r5 % 800) * 1000 AS decimal(12,2)),
        CreditScore     = CASE WHEN r6 % 100 < 6 THEN 580 + (r6 % 60) ELSE 640 + (r6 % 180) END,
        DTI             = CAST(20 + (r7 % 30) AS decimal(5,2)),
        r8x = r8, r3x = r3, r4x = r4
    FROM r
),
d2 AS (
    SELECT *,
        LtvPct = CASE WHEN r8x % 100 < 25 THEN 80.0
                      WHEN r8x % 100 < 45 THEN 90.0 + (r8x % 6)
                      ELSE 55 + (r8x % 40) END
    FROM d
),
d3 AS (
    SELECT *,
        LoanAmount = CAST(ROUND(PropertyValue * LtvPct / 100.0, -2) AS decimal(12,2))
    FROM d2
)
INSERT orig.Application (ApplicationId, ApplicationDate, LoanOfficerId, Channel, LoanPurpose,
    PropertyState, PropertyType, Occupancy, LoanAmount, PropertyValue, LTV, CreditScore, DTI,
    ProductType, NoteRate)
SELECT
    ApplicationId, ApplicationDate, LoanOfficerId, Channel, LoanPurpose,
    PropertyState, PropertyType, Occupancy,
    LoanAmount, PropertyValue,
    CAST(100.0 * LoanAmount / PropertyValue AS decimal(5,2)),
    CreditScore, DTI,
    ProductType = CASE
        WHEN LoanAmount > 766550 THEN 'Jumbo30'
        WHEN CreditScore < 660 AND r4x % 3 = 0 THEN 'FHA30'
        WHEN r3x % 20 = 0 THEN 'VA30'
        WHEN r4x % 5 = 0 THEN 'Conv15'
        ELSE 'Conv30' END,
    NoteRate = CAST(
        CASE
            WHEN ApplicationDate < '2023-07-01' THEN 0.0625
            WHEN ApplicationDate < '2024-07-01' THEN 0.0705
            WHEN ApplicationDate < '2025-07-01' THEN 0.0668
            ELSE 0.0625 END
        + (r8x % 90) / 10000.0
        + CASE WHEN CreditScore < 680 THEN 0.0030 ELSE 0 END
        AS decimal(6,4))
FROM d3;
PRINT CONCAT('orig.Application     : ', @@ROWCOUNT, ' applications');
GO

/* ============================ orig.ApplicationPlan ========================= */
/* Stage numbering:
   1 Application  2 Processing  3 Underwriting  4 Conditional Approval
   5 Clear to Close  6 Closing  7 Funded  8 Delivered                          */
DECLARE @Today2 date = '2026-09-01';

CREATE TABLE orig.ApplicationPlan (
    ApplicationId  int         NOT NULL CONSTRAINT PK_orig_ApplicationPlan PRIMARY KEY,
    Fate           varchar(10) NOT NULL,   -- Funded | Denied | Withdrawn | Cancelled | InProcess
    MaxStage       tinyint     NOT NULL,
    D_Processing   date NULL,
    D_ApprOrdered  date NULL,
    D_ApprReceived date NULL,
    D_Underwriting date NULL,
    D_CondApproval date NULL,
    D_ClearToClose date NULL,
    D_Closing      date NULL,
    D_Funded       date NULL,
    D_Delivered    date NULL,
    TerminalDate   date NULL,
    DenialReason   varchar(30) NULL,
    Locked         bit  NOT NULL,
    LockDate       date NULL,
    LockTermDays   int  NULL,
    LockRate       decimal(6,4) NULL,
    ExtensionDate  date NULL,
    ExtensionDays  int  NULL,
    LockExpiredDate date NULL
);

;WITH a AS (
    SELECT ap.ApplicationId, ap.ApplicationDate, ap.LoanPurpose, ap.NoteRate, ap.CreditScore, ap.DTI,
        h1 = ABS(CHECKSUM(HASHBYTES('MD5', CONCAT('outcome', ap.ApplicationId)))),
        h2 = ABS(CHECKSUM(HASHBYTES('MD5', CONCAT('stage',   ap.ApplicationId)))),
        h3 = ABS(CHECKSUM(HASHBYTES('MD5', CONCAT('timing',  ap.ApplicationId)))),
        h4 = ABS(CHECKSUM(HASHBYTES('MD5', CONCAT('lock',    ap.ApplicationId))))
    FROM orig.Application ap
),
sched AS (   -- the happy-path milestone dates
    SELECT *,
        oProc  = 1 + h3 % 3,
        oAOrd  = (1 + h3 % 3) + 1 + (h3 / 3) % 4
    FROM a
),
sched2 AS (
    SELECT *,
        oARec  = oAOrd + 7 + (h3 / 7) % 10 + CASE WHEN h3 % 20 = 0 THEN 18 ELSE 0 END,
        oUw0   = CASE WHEN oAOrd + 9 > oProc + 6 THEN oAOrd + 9 ELSE oProc + 6 END
    FROM sched
),
sched3 AS (
    SELECT *,
        oUw   = oUw0 + 1 + (h3 / 11) % 5
    FROM sched2
),
sched4 AS (
    SELECT *,
        oCond = oUw   + 2 + (h3 / 13) % 6,
        oCtc0 = 0
    FROM sched3
),
sched5 AS (
    SELECT *,
        oCtc  = oCond + 5 + (h3 / 17) % 16
    FROM sched4
),
sched6 AS (
    SELECT *,
        oClos = oCtc + 3 + (h3 / 19) % 5
    FROM sched5
),
sched7 AS (
    SELECT *,
        oFund = oClos + CASE WHEN LoanPurpose = 'Purchase' THEN 1 + (h3 / 23) % 2 ELSE 4 + (h3 / 23) % 2 END
    FROM sched6
),
sched8 AS (
    SELECT *,
        oDeliv = oFund + 10 + (h3 / 29) % 20
    FROM sched7
),
fate0 AS (   -- natural outcome, ignoring "today"
    SELECT *,
        NatFate = CASE WHEN h1 % 100 < 8  THEN 'Denied'
                       WHEN h1 % 100 < 22 THEN 'Withdrawn'
                       WHEN h1 % 100 < 29 THEN 'Cancelled'
                       ELSE 'Funded' END,
        NatTermStage = CASE
            WHEN h1 % 100 < 8  THEN CASE WHEN h2 % 3 = 0 THEN 4 ELSE 3 END          -- Denied at UW
            WHEN h1 % 100 < 22 THEN CHOOSE(h2 % 6 + 1, 2, 2, 3, 5, 5, 6)             -- Withdrawn
            WHEN h1 % 100 < 29 THEN CHOOSE(h2 % 4 + 1, 2, 3, 3, 5)                   -- Cancelled
            ELSE 8 END
    FROM sched8
),
dated AS (
    SELECT *,
        dProc  = DATEADD(DAY, oProc,  ApplicationDate),
        dAOrd  = DATEADD(DAY, oAOrd,  ApplicationDate),
        dARec  = DATEADD(DAY, oARec,  ApplicationDate),
        dUw    = DATEADD(DAY, oUw,    ApplicationDate),
        dCond  = DATEADD(DAY, oCond,  ApplicationDate),
        dCtc   = DATEADD(DAY, oCtc,   ApplicationDate),
        dClos  = DATEADD(DAY, oClos,  ApplicationDate),
        dFund  = DATEADD(DAY, oFund,  ApplicationDate),
        dDeliv = DATEADD(DAY, oDeliv, ApplicationDate),
        TermDate0 = CASE NatFate
            WHEN 'Funded' THEN NULL
            WHEN 'Denied' THEN DATEADD(DAY, CASE WHEN NatTermStage = 4 THEN oCond ELSE oUw END + 1 + h2 % 4, ApplicationDate)
            WHEN 'Withdrawn' THEN DATEADD(DAY,
                 CASE NatTermStage WHEN 2 THEN oProc WHEN 3 THEN oUw WHEN 5 THEN oCtc ELSE oClos END + 1 + h2 % 7, ApplicationDate)
            ELSE DATEADD(DAY,
                 CASE NatTermStage WHEN 2 THEN oProc WHEN 3 THEN oUw ELSE oCtc END + 3 + h2 % 20, ApplicationDate)
          END
    FROM fate0
),
resolved AS (
    SELECT *,
        EffEnd = CASE WHEN NatFate = 'Funded' THEN dDeliv ELSE TermDate0 END,
        StageByToday = 1
            + CASE WHEN dProc <= @Today2 THEN 1 ELSE 0 END
            + CASE WHEN dUw   <= @Today2 THEN 1 ELSE 0 END
            + CASE WHEN dCond <= @Today2 THEN 1 ELSE 0 END
            + CASE WHEN dCtc  <= @Today2 THEN 1 ELSE 0 END
            + CASE WHEN dClos <= @Today2 THEN 1 ELSE 0 END
    FROM dated
),
final AS (
    SELECT *,
        Fate = CASE
            WHEN NatFate = 'Funded' AND dFund  <= @Today2 THEN 'Funded'
            WHEN EffEnd <= @Today2 THEN NatFate
            ELSE 'InProcess' END,
        MaxStage = CASE
            WHEN NatFate = 'Funded' AND dDeliv <= @Today2 THEN 8
            WHEN NatFate = 'Funded' AND dFund  <= @Today2 THEN 7
            WHEN EffEnd <= @Today2 THEN NatTermStage
            ELSE CASE WHEN StageByToday < NatTermStage THEN StageByToday ELSE NatTermStage END END
    FROM resolved
)
INSERT orig.ApplicationPlan (ApplicationId, Fate, MaxStage,
    D_Processing, D_ApprOrdered, D_ApprReceived, D_Underwriting, D_CondApproval,
    D_ClearToClose, D_Closing, D_Funded, D_Delivered, TerminalDate, DenialReason,
    Locked, LockDate, LockTermDays, LockRate, ExtensionDate, ExtensionDays, LockExpiredDate)
SELECT
    ApplicationId, Fate, MaxStage,
    CASE WHEN MaxStage >= 2 THEN dProc  END,
    CASE WHEN MaxStage >= 2 THEN dAOrd  END,
    CASE WHEN MaxStage >= 2 AND dARec <= @Today2 THEN dARec END,
    CASE WHEN MaxStage >= 3 THEN dUw    END,
    CASE WHEN MaxStage >= 4 THEN dCond  END,
    CASE WHEN MaxStage >= 5 THEN dCtc   END,
    CASE WHEN MaxStage >= 6 THEN dClos  END,
    CASE WHEN MaxStage >= 7 THEN dFund  END,
    CASE WHEN MaxStage >= 8 THEN dDeliv END,
    CASE WHEN Fate IN ('Denied','Withdrawn','Cancelled') THEN TermDate0 END,
    CASE WHEN Fate = 'Denied' THEN CHOOSE(h2 % 6 + 1,
         'DTI too high','Credit history','Collateral (appraisal)','Insufficient funds',
         'Incomplete application','Unverifiable information') END,
    Locked        = CASE WHEN h4 % 100 < 88 THEN 1 ELSE 0 END,
    LockDate      = CASE WHEN h4 % 100 < 88 THEN DATEADD(DAY, h4 % 8, ApplicationDate) END,
    LockTermDays  = CASE WHEN h4 % 100 < 88 THEN CHOOSE((h4 / 8) % 5 + 1, 30, 45, 45, 45, 60) END,
    LockRate      = CASE WHEN h4 % 100 < 88 THEN NoteRate END,
    ExtensionDate = NULL, ExtensionDays = NULL, LockExpiredDate = NULL
FROM final;
PRINT CONCAT('orig.ApplicationPlan : ', @@ROWCOUNT, ' (fate split below)');
GO

/* ---- lock extensions & expirations (need the milestone dates just written) --- */
DECLARE @Today3 date = '2026-09-01';

UPDATE p
SET ExtensionDate = DATEADD(DAY, -3, DATEADD(DAY, p.LockTermDays, p.LockDate)),
    ExtensionDays = CHOOSE(ABS(CHECKSUM(HASHBYTES('MD5', CONCAT('ext', p.ApplicationId)))) % 3 + 1, 7, 15, 30)
FROM orig.ApplicationPlan p
WHERE p.Locked = 1
  AND p.Fate IN ('Funded','InProcess')
  AND COALESCE(p.D_Closing, p.D_Funded, @Today3) > DATEADD(DAY, p.LockTermDays, p.LockDate)
  AND DATEADD(DAY, -3, DATEADD(DAY, p.LockTermDays, p.LockDate)) <= @Today3;

UPDATE p
SET LockExpiredDate = DATEADD(DAY, p.LockTermDays, p.LockDate)
FROM orig.ApplicationPlan p
WHERE p.Locked = 1
  AND p.Fate = 'Cancelled'
  AND ABS(CHECKSUM(HASHBYTES('MD5', CONCAT('exp', p.ApplicationId)))) % 100 < 45
  AND DATEADD(DAY, p.LockTermDays, p.LockDate) <= p.TerminalDate;
GO

/* ============================ orig.ApplicationEvent ======================== */
CREATE TABLE orig.ApplicationEvent (
    ApplicationEventId int          NOT NULL IDENTITY(1,1) CONSTRAINT PK_orig_ApplicationEvent PRIMARY KEY,
    ApplicationId      int          NOT NULL,
    EventType          varchar(24)  NOT NULL,
    EventDate          date         NOT NULL,
    Detail             varchar(40)  NULL,
    CONSTRAINT FK_orig_Event_App FOREIGN KEY (ApplicationId) REFERENCES orig.Application (ApplicationId)
);
DECLARE @Today4 date = '2026-09-01';

INSERT orig.ApplicationEvent (ApplicationId, EventType, EventDate, Detail)
SELECT ApplicationId, EventType, EventDate, Detail FROM (
    SELECT ap.ApplicationId, 'Application' AS EventType, ap.ApplicationDate AS EventDate, NULL AS Detail
    FROM orig.Application ap
    UNION ALL SELECT ApplicationId, 'Rate Locked', LockDate,
        CONCAT(LockTermDays, 'd @ ', FORMAT(LockRate, 'P3'))
        FROM orig.ApplicationPlan WHERE Locked = 1 AND LockDate <= @Today4
    UNION ALL SELECT ApplicationId, 'Lock Extended', ExtensionDate, CONCAT('+', ExtensionDays, ' days')
        FROM orig.ApplicationPlan WHERE ExtensionDate IS NOT NULL AND ExtensionDate <= @Today4
    UNION ALL SELECT ApplicationId, 'Lock Expired', LockExpiredDate, NULL
        FROM orig.ApplicationPlan WHERE LockExpiredDate IS NOT NULL AND LockExpiredDate <= @Today4
    UNION ALL SELECT ApplicationId, 'Processing', D_Processing, NULL
        FROM orig.ApplicationPlan WHERE D_Processing IS NOT NULL AND D_Processing <= @Today4
    UNION ALL SELECT ApplicationId, 'Appraisal Ordered', D_ApprOrdered, NULL
        FROM orig.ApplicationPlan WHERE D_ApprOrdered IS NOT NULL AND D_ApprOrdered <= @Today4
    UNION ALL SELECT ApplicationId, 'Appraisal Received', D_ApprReceived, NULL
        FROM orig.ApplicationPlan WHERE D_ApprReceived IS NOT NULL AND D_ApprReceived <= @Today4
    UNION ALL SELECT ApplicationId, 'Underwriting Submitted', D_Underwriting, NULL
        FROM orig.ApplicationPlan WHERE D_Underwriting IS NOT NULL AND D_Underwriting <= @Today4
    UNION ALL SELECT ApplicationId, 'Conditional Approval', D_CondApproval, NULL
        FROM orig.ApplicationPlan WHERE D_CondApproval IS NOT NULL AND D_CondApproval <= @Today4
    UNION ALL SELECT ApplicationId, 'Clear to Close', D_ClearToClose, NULL
        FROM orig.ApplicationPlan WHERE D_ClearToClose IS NOT NULL AND D_ClearToClose <= @Today4
    UNION ALL SELECT ApplicationId, 'Closing', D_Closing, NULL
        FROM orig.ApplicationPlan WHERE D_Closing IS NOT NULL AND D_Closing <= @Today4
    UNION ALL SELECT ApplicationId, 'Funded', D_Funded, NULL
        FROM orig.ApplicationPlan WHERE D_Funded IS NOT NULL AND D_Funded <= @Today4
    UNION ALL SELECT ApplicationId, 'Delivered', D_Delivered, NULL
        FROM orig.ApplicationPlan WHERE D_Delivered IS NOT NULL AND D_Delivered <= @Today4
    UNION ALL SELECT ApplicationId, 'Denied', TerminalDate, DenialReason
        FROM orig.ApplicationPlan WHERE Fate = 'Denied' AND TerminalDate <= @Today4
    UNION ALL SELECT ApplicationId, 'Withdrawn', TerminalDate, NULL
        FROM orig.ApplicationPlan WHERE Fate = 'Withdrawn' AND TerminalDate <= @Today4
    UNION ALL SELECT ApplicationId, 'Cancelled', TerminalDate, NULL
        FROM orig.ApplicationPlan WHERE Fate = 'Cancelled' AND TerminalDate <= @Today4
) e;
PRINT CONCAT('orig.ApplicationEvent: ', @@ROWCOUNT, ' events');

CREATE INDEX IX_orig_Event_App  ON orig.ApplicationEvent (ApplicationId, EventType) INCLUDE (EventDate);
CREATE INDEX IX_orig_Event_Type ON orig.ApplicationEvent (EventType, EventDate)     INCLUDE (ApplicationId);
GO

/* ============================ orig.RateLock ================================ */
CREATE TABLE orig.RateLock (
    ApplicationId  int          NOT NULL CONSTRAINT PK_orig_RateLock PRIMARY KEY,
    LockDate       date         NOT NULL,
    LockTermDays   int          NOT NULL,
    LockRate       decimal(6,4) NOT NULL,
    ExtensionCount int          NOT NULL,
    ExtensionDays  int          NOT NULL,
    ExpirationDate date         NOT NULL,   -- LockDate + term + extension days
    Status         varchar(8)   NOT NULL,   -- Active | Used | Expired
    CONSTRAINT FK_orig_RateLock_App FOREIGN KEY (ApplicationId) REFERENCES orig.Application (ApplicationId)
);
INSERT orig.RateLock (ApplicationId, LockDate, LockTermDays, LockRate, ExtensionCount,
    ExtensionDays, ExpirationDate, Status)
SELECT
    p.ApplicationId, p.LockDate, p.LockTermDays, p.LockRate,
    CASE WHEN p.ExtensionDate IS NOT NULL THEN 1 ELSE 0 END,
    ISNULL(p.ExtensionDays, 0),
    DATEADD(DAY, p.LockTermDays + ISNULL(p.ExtensionDays, 0), p.LockDate),
    CASE WHEN p.MaxStage >= 7          THEN 'Used'
         WHEN p.Fate     = 'InProcess' THEN 'Active'
         ELSE 'Expired' END
FROM orig.ApplicationPlan p
WHERE p.Locked = 1;
PRINT CONCAT('orig.RateLock        : ', @@ROWCOUNT, ' locks');
GO

/* ============================ orig.StageSLA ================================ */
CREATE TABLE orig.StageSLA (
    Stage           varchar(24) NOT NULL CONSTRAINT PK_orig_StageSLA PRIMARY KEY,
    StageNo         tinyint     NOT NULL,
    SLABusinessDays int         NOT NULL
);
INSERT orig.StageSLA VALUES
 ('Application',           1, 2),
 ('Processing',            2, 10),
 ('Underwriting',          3, 3),
 ('Conditional Approval',  4, 10),
 ('Clear to Close',        5, 5),
 ('Closing',               6, 4);
GO

PRINT '';
SELECT Fate, Applications = COUNT(*),
       Pct = CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS decimal(5,1))
FROM orig.ApplicationPlan GROUP BY Fate ORDER BY Applications DESC;

SELECT EventType, Events = COUNT(*) FROM orig.ApplicationEvent GROUP BY EventType
ORDER BY MIN(CASE EventType
    WHEN 'Application' THEN 1 WHEN 'Rate Locked' THEN 2 WHEN 'Processing' THEN 3
    WHEN 'Appraisal Ordered' THEN 4 WHEN 'Appraisal Received' THEN 5
    WHEN 'Underwriting Submitted' THEN 6 WHEN 'Conditional Approval' THEN 7
    WHEN 'Clear to Close' THEN 8 WHEN 'Closing' THEN 9 WHEN 'Funded' THEN 10
    WHEN 'Delivered' THEN 11 ELSE 12 END);
GO

PRINT 'Pipeline generation complete.';
GO
