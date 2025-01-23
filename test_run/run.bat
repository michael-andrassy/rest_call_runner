@echo off

cd /d "%~dp0"

docker-compose up --abort-on-container-exit 

pause

