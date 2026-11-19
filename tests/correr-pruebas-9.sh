#!/usr/bin/env bash
# Prueba la actualización 8 sobre una base con la 7 ya aplicada (usa correr-pruebas.sh primero).
set -u; cd "$(dirname "$0")"
psql -q -d hd_pruebas -c "select 1" >/dev/null
psql -q -v ON_ERROR_STOP=1 -d hd_pruebas -f ../actualizacion-9-enlace-anticipo.sql >/dev/null 2>&1 || { echo "FALLÓ la migración 9"; psql -q -v ON_ERROR_STOP=1 -d hd_pruebas -f ../actualizacion-9-enlace-anticipo.sql 2>&1 | grep -v NOTICE | head -5; exit 1; }
psql -q -v ON_ERROR_STOP=1 -d hd_pruebas -f ../actualizacion-9-enlace-anticipo.sql >/dev/null 2>&1 || { echo "FALLÓ al repetir la 9"; exit 1; }
psql -q -d hd_pruebas -f test9.sql 2>&1 | grep -v "^CONTEXT\|^SQL statement\|^PL/pgSQL\|^DETAIL\|^$" | sed 's/^psql:[a-z0-9.]*:[0-9]*: //' > resultado-test9.txt
echo "Resultados en resultado-test9.txt"
