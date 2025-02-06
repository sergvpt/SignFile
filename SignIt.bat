@echo off
if [%1] == [] goto ErrorNoParam
if not exist %1 goto ErrorNoParam

set FileName=
for %%F in (%1) do set FileName=%%~nxF
if [%FileName%] == [] goto ErrorFileName

echo START signing %FileName%

set SignPath=\\SERVERNAME\SignFolder\
set SignInput=%SignPath%_SignIn\
set SignOutput=%SignPath%_SignOut\
set SignInProgress=%SignOutput%InProgress\
set WaitingList=%SignInProgress%waiting.list

rem Если в папке SignOutput такой есть - удаляем
for %%f in (%FileName% %FileName%.NotSigned %FileName%.NotCheckedForVirus.NotSigned %FileName%.NotCheckedForVirus.Signed %FileName%.Virus.NotSigned %FileName%.Virus.Signed) do (
	if exist %SignOutput%%%f (
		echo Deleting %SignOutput%%%f
		del %SignOutput%%%f >nul 2>nul
		if exist %SignOutput%%%f.log (
			echo Deleting %SignOutput%%%f.log
			del %SignOutput%%%f.log >nul 2>nul
		)
	)
)

rem Копируем файл в папку для подписания
echo.
echo Copy %FileName% to %SignInput%
copy %1 %SignInput%%FileName% >nul 2>nul
if ERRORLEVEL 1 goto ErrorNoAccessToSignInFolder

rem Проверяем и оповещаем о наличии очереди на подписание
set WaitingTime=0
set WaitingFiles=

call :getWaitingFilesList

if "%WaitingFiles%" == "" goto noWaitingFiles

echo. & echo ========== WARNING ==========
echo You need to wait in a queue.

:showWaitingMessage
call :calculateWaitingTime "%WaitingFiles%"
echo. & echo =============================
echo NOW. Next files before you:
for %%f in (%WaitingFiles%) do (
	echo   - %%f
)
echo.
echo Estimated waiting time:
call :showWaitingTime %WaitingTime%

:noWaitingFiles
set waitFor=waitForFileGone
goto chooseMaxWaitingTime

:waitForFileGone
echo.
echo Before exit waiting time:
call :showWaitingTime %MaxWaiting%
set checkThat=checkFileGone
set gotoError=ErrorNoStarted
goto wait

rem Файл забран для подписания
:SigningStarted
echo. & echo ====== SIGING STARTED =======
call :calculateWaitingTime %FileName%
set waitFor=waitForFileSigned
goto chooseMaxWaitingTime

:waitForFileSigned
echo.
echo Estimated waiting time:
call :showWaitingTime %WaitingTime%
echo.
echo Before exit waiting time:
call :showWaitingTime %MaxWaiting%

set checkThat=checkFileSigned
set gotoError=ErrorNoExistSigned
goto wait

:checkFileGone
if not exist %SignInput%%FileName% goto SigningStarted
set WaitingFilesLock=
set "WaitingFilesLock=%WaitingFiles%"
call :getWaitingFilesList
if not "%WaitingFiles%" == "%WaitingFilesLock%" (
	if not "%WaitingFiles%" == "" (
		goto showWaitingMessage
	) else (
		goto SigningStarted
	)
)
goto waitCycle

:checkFileSigned
if exist %SignOutput%%FileName% goto FileSigned
if exist %SignOutput%%FileName%.NotSigned goto ErrorNoSigned
if exist %SignOutput%%FileName%.NotCheckedForVirus.NotSigned goto ErrorNotCheckedForVirusNotSigned
if exist %SignOutput%%FileName%.NotCheckedForVirus.Signed goto ErrorNotCheckedForVirusSigned
if exist %SignOutput%%FileName%.Virus.NotSigned goto ErrorVirusDetectedNotSigned
if exist %SignOutput%%FileName%.Virus.Signed goto ErrorVirusDetectedSigned
goto waitCycle

:FileSigned
echo.
echo Move signed %FileName% back to %1
echo.
copy /y %SignOutput%%FileName% %1 >nul
>nul ping localhost -n 2
del /f /q %SignOutput%%FileName% >nul
echo File %FileName% is signed and moved back
goto Success
exit /b 0

:getWaitingFilesList
setlocal enabledelayedexpansion
set WaitingFiles=
for /f "delims=" %%a in (%WaitingList%) do (
    if "%%a"=="%FileName%" set LineFound=true
	if not "!LineFound!" == "true" set "WaitingFiles=!WaitingFiles! %%a"
)
endlocal & set WaitingFiles=%WaitingFiles%
exit /b 0

:calculateWaitingTime
rem В качестве параметра 1 передаётся имя файла (можно несколько одновременно)
setlocal enabledelayedexpansion
set WaitingTime=0
for %%n in (%~1) do (
	set CurrentFile=
	if exist %SignInput%%%n set CurrentFile=%SignInput%%%n
	if exist %SignInProgress%%%n set CurrentFile=%SignInProgress%%%n
	if not "!CurrentFile!" == "" (
		for %%f in (!CurrentFile!) do (
			set CurrentFileSize=%%~zf
			
			rem Задаём скорость подписания в зависимости от типа файла
			set Ratio=2
			if "%%~xf" == ".msi" (
				set Ratio=2
			)
			if "%%~xf" == ".dll" (
				set Ratio=6
			)
			if "%%~xf" == ".exe" (
				echo.%%~nxf|findstr /C:"Setup" >nul 2>&1 && set Ratio=10 || set Ratio=2
			)
			set /a SigningSpeed=1000000*!Ratio!
			
			rem Высчитываем время подписания одного файла
			set /a TimeSignOneFile=!CurrentFileSize!/!SigningSpeed!
			if !TimeSignOneFile! lss 20 (
				set TimeSignOneFile=20
			)
			
			rem Высчитываем общее время подписания
			set /a WaitingTime=!WaitingTime!+!TimeSignOneFile!
		)
	)
)
endlocal & set WaitingTime=%WaitingTime%
exit /b 0

:chooseMaxWaitingTime
if %WaitingTime% equ 0 (
	set MaxWaiting=30
	goto %waitFor%
)
if %WaitingTime% lss 30 (
	set /a MaxWaiting=%WaitingTime%+60
	goto %waitFor%
)
if %WaitingTime% lss 100 (
	set /a MaxWaiting=%WaitingTime%+100
	goto %waitFor%
)
if %WaitingTime% lss 300 (
	set /a MaxWaiting=%WaitingTime%+200
	goto %waitFor%
)
set /a MaxWaiting=%WaitingTime%+500
goto %waitFor%
exit /b 0

:wait
echo. & echo To brake it push Ctrl+C
echo.
set FirstLoopStep=1
set CurrentLoopStep=%FirstLoopStep%
set LastLoopStep=10
<nul set /p "=0s"
goto waitCycle


:waitCycle
if %CurrentLoopStep% == %LastLoopStep% (
	setlocal enabledelayedexpansion
	set /a Mod=%CurrentLoopStep% %% 60
	if !Mod! == 0 (
		set /a CurrentLoopStepMin=%CurrentLoopStep%/60
		<nul set /p "=!CurrentLoopStepMin!m"
	) else (
		<nul set /p "=%CurrentLoopStep%s"
	)
	endlocal
	set /a FirstLoopStep+=10
	set /a LastLoopStep+=10
) else (
	<nul set /p "=."
)
>nul ping localhost -n 2
set /a CurrentLoopStep+=1
if %FirstLoopStep% gtr %MaxWaiting% goto %gotoError%
goto %checkThat%

:showWaitingTime
rem Параметр %~1 - время ожидания
setlocal enabledelayedexpansion
if %~1 lss 61 (
	echo - %~1 sec
) else (
    set WaitingTimeMin=0
	set /a WaitingTimeMin=%~1/60
	echo - !WaitingTimeMin! min
)
endlocal
exit /b 0

:ErrorNoAccessToSignInFolder
echo.
echo ERROR: No write access to folder %SignPath%
exit /b 2

:ErrorNotCheckedForVirusSigned
echo.
echo ERROR: File was not checked for virus :( Result file is %SignOutput%%FileName%.NotCheckedForVirus.Signed
exit /b 2

:ErrorNotCheckedForVirusNotSigned
echo.
echo ERROR: File was not checked for virus :( Result file is %SignOutput%%FileName%.NotCheckedForVirus.NotSigned
exit /b 2

:ErrorVirusDetectedSigned
echo.
echo ERROR: Virus detected :( Result file is %SignOutput%%FileName%.Virus.Signed
exit /b 2

:ErrorVirusDetectedNotSigned
echo.
echo ERROR: Virus detected :( Result file is %SignOutput%%FileName%.Virus.NotSigned
exit /b 2

:ErrorNoSigned
echo.
echo ERROR: File came back as Not Signed :( Result file is %SignOutput%%FileName%.NotSigned
exit /b 2

:ErrorNoExistSigned
echo.
echo ERROR: Signing not finished :( File didn't come to %SignOutput%%FileName%
exit /b 2

:ErrorNoStarted
echo.
echo ERROR: Signing not started :( File copied to %SignInput%%FileName%
exit /b 2

:ErrorFileName
echo ERROR: Couldn't get file name from parameters.
exit /b 2

:ErrorNoParam
echo USAGE: SignIt.bat "filename"
exit /b 2

:Success
exit /b 0
