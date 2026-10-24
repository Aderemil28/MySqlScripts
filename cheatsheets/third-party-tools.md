# Third-party tools I use

These are free community tools. I do not copy their code into this repo, so I
always get the latest version and the authors keep credit and licensing.
Install them from the official sources below.

| Tool | What I use it for | Official source |
|---|---|---|
| Ola Hallengren Maintenance Solution | Backups, integrity checks, index and statistics maintenance | <https://ola.hallengren.com> / <https://github.com/olahallengren/sql-server-maintenance-solution> |
| sp_WhoIsActive (Adam Machanic) | Live activity, blocking, waits | <https://github.com/amachanic/sp_whoisactive> |
| First Responder Kit (Brent Ozar Unlimited) | sp_Blitz, sp_BlitzIndex, sp_BlitzFirst, sp_BlitzCache health and performance checks | <https://github.com/BrentOzarULTD/SQL-Server-First-Responder-Kit> |
| dbatools | PowerShell module for migrations, login copies, AG checks and more | <https://dbatools.io> |

Related scripts in this repo:

* `tsql/agent-jobs/ola-hallengren-job-schedules.sql` adds schedules to the jobs the Maintenance Solution creates.
* `cheatsheets/sp_whoisactive-usage.md` lists the sp_WhoIsActive parameter combinations I use most.
