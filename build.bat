@echo off
setlocal
where cl.exe >nul 2>&1
if errorlevel 1 (
    echo Run build.bat from an x64 Native Tools Command Prompt for Visual Studio.
    exit /b 1
)
pushd "%~dp0" || exit /b 1
cl /nologo /O2 /MT /EHsc /W4 capture.cpp /Fe:capture.exe /link d3d11.lib dxgi.lib windowscodecs.lib ole32.lib user32.lib uuid.lib
set "BUILD_RESULT=%ERRORLEVEL%"
if exist capture.obj del capture.obj
popd
exit /b %BUILD_RESULT%
