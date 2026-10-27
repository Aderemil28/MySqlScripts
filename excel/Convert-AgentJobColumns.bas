Attribute VB_Name = "ConvertAgentJobColumns"
' =============================================================================
' Module  : Convert-AgentJobColumns.bas
' Purpose : SQL Agent stores times and dates as integers: 93000 means 09:30:00,
'           20261027 means 27 Oct 2026, and run_duration 13005 means 1h 30m 05s.
'           When you paste a job or schedule report from SSMS into Excel, this
'           macro turns those columns into readable times, dates and durations.
' Usage   : 1. In Excel press Alt+F11, then File > Import File, and pick this file.
'           2. Change the column letters in the ADJUST section to match your sheet.
'           3. Select the sheet with the data (headers in row 1) and run
'              ConvertAgentJobColumns (Alt+F8).
'           Run it once per sheet: running it twice converts converted values.
' Changes : Overwrites the cells in the listed columns of the active sheet.
'           Save a copy first if you need the raw values.
' Tip     : To get readable values from SQL directly instead, use
'           msdb.dbo.agent_datetime(run_date, run_time), as in
'           tsql/agent-jobs/jobs-schedule-and-next-run.sql.
' Fixes vs the original notes:
'   - durations of 100 hours or more were cut to 2 digits of hours; hours are
'     now worked out arithmetically, so 1000000 (100h) shows as 100:00:00
'   - 0 in a date column (job never ran) became an invalid date; now "Never"
'   - text values and blanks are skipped instead of raising a type error
' =============================================================================
Option Explicit

Public Sub ConvertAgentJobColumns()
    Dim ws As Worksheet
    Set ws = ActiveSheet

    Dim lastRow As Long
    lastRow = ws.Cells(ws.Rows.Count, "A").End(xlUp).Row
    If lastRow < 2 Then
        MsgBox "No data found below the header row.", vbExclamation
        Exit Sub
    End If

    ' ===== ADJUST THESE COLUMN LETTERS TO MATCH YOUR SHEET =====
    Dim timeCols As Variant, dateCols As Variant, durCols As Variant
    timeCols = Array("J", "M", "O")   ' active_start_time, next_run_time, last_run_time
    dateCols = Array("K", "L", "N")   ' active_end_date, next_run_date, last_run_date
    durCols = Array("P")              ' last_run_duration
    ' ===========================================================

    Dim c As Variant, r As Long, cell As Range, v As Long
    Dim hh As Long, mm As Long, ss As Long

    Application.ScreenUpdating = False

    ' ---- Time columns (clock time, HHMMSS) ----
    For Each c In timeCols
        For r = 2 To lastRow
            Set cell = ws.Range(c & r)
            If IsNumber(cell) Then
                v = CLng(cell.Value)
                cell.Value = TimeSerial(v \ 10000, (v \ 100) Mod 100, v Mod 100)
                cell.NumberFormat = "h:mm:ss AM/PM"
            End If
        Next r
    Next c

    ' ---- Date columns (YYYYMMDD) ----
    For Each c In dateCols
        For r = 2 To lastRow
            Set cell = ws.Range(c & r)
            If IsNumber(cell) Then
                v = CLng(cell.Value)
                If v = 99991231 Then
                    cell.Value = "No end date"
                ElseIf v = 0 Then
                    cell.Value = "Never"
                Else
                    cell.Value = DateSerial(v \ 10000, (v \ 100) Mod 100, v Mod 100)
                    cell.NumberFormat = "mmm dd, yyyy"
                End If
            End If
        Next r
    Next c

    ' ---- Duration columns (elapsed time, HHMMSS, hours can exceed 99) ----
    For Each c In durCols
        For r = 2 To lastRow
            Set cell = ws.Range(c & r)
            If IsNumber(cell) Then
                v = CLng(cell.Value)
                hh = v \ 10000
                mm = (v \ 100) Mod 100
                ss = v Mod 100
                cell.NumberFormat = "@"
                cell.Value = Format(hh, "00") & ":" & Format(mm, "00") & ":" & Format(ss, "00")
            End If
        Next r
    Next c

    Application.ScreenUpdating = True
    MsgBox "Done. Time, date and duration columns converted.", vbInformation
End Sub

' True when the cell holds a number (skips blanks, "NULL" text and errors)
Private Function IsNumber(ByVal cell As Range) As Boolean
    If IsError(cell.Value) Then Exit Function
    If IsEmpty(cell.Value) Then Exit Function
    IsNumber = IsNumeric(cell.Value)
End Function
