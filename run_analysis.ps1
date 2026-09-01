<#
    run_analysis.ps1 -- build the origination pipeline and run the full analysis.

      1. generate the synthetic application book + event log   (sql\00)
      2. build the stage model (event log -> stages)           (sql\01)
      3. build the analytics layer                             (sql\02)
      4. validate                                              (sql\03)
      5. guided tour                                           (sql\04)

    Needs SQL Server with the Chinook database (the orig schema is created there)
    and sqlcmd. Step 1 takes ~30-60s; the rest are seconds.
    Run:  .\run_analysis.ps1
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
function Sql($rel) { & "$root\q.ps1" -File (Join-Path $root $rel) | Write-Host }
function Head($n)  { Write-Host "`n### $n" -ForegroundColor Cyan }

Head '1. generate synthetic pipeline (~30-60s)'; Sql 'sql\00_generate_pipeline.sql'
Head '2. stage model';                           Sql 'sql\01_stage_model.sql'
Head '3. analytics layer';                        Sql 'sql\02_analytics_layer.sql'
Head '4. validation';                             Sql 'sql\03_validate.sql'
Head '5. guided tour';                            Sql 'sql\04_demo.sql'

Write-Host "`nDone. Every check in step 4 should read PASS." -ForegroundColor Green
