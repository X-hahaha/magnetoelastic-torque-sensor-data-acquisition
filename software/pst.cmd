@echo off
rem pst - shortcut for plot_sensor_timeline.py
rem   pst              newest capture frame, plot l2_um
rem   pst 688          frame id contains 688
rem   pst 688 -c l3_um
rem   pst --list
rem Put this folder on PATH, then "pst 688" works from anywhere.
setlocal
set PYEXE=python
where %PYEXE% >nul 2>nul || set PYEXE=py
"%PYEXE%" "%~dp0pst.py" %*
