#!/usr/bin/env bash
# Prueba la actualización 8 sobre una base con la 7 ya aplicada (usa correr-pruebas.sh primero).
set -u; cd "$(dirname "$0")"
psql -q -d hd_pruebas -c "alter table auth.users add column if not exists email text" >/dev/null
psql -q -v ON_ERROR_STOP=1 -d hd_pruebas -f ../actualizacion-8-verificacion.sql >/dev/null 2>&1 || { echo "FALLÓ la migración 8"; psql -q -v ON_ERROR_STOP=1 -d hd_pruebas -f ../actualizacion-8-verificacion.sql 2>&1 | grep -v NOTICE | head -5; exit 1; }
psql -q -v ON_ERROR_STOP=1 -d hd_pruebas -f ../actualizacion-8-verificacion.sql >/dev/null 2>&1 || { echo "FALLÓ al repetir la 8"; exit 1; }
psql -q -d hd_pruebas -f test8.sql 2>&1 | grep -v "^CONTEXT\|^SQL statement\|^PL/pgSQL\|^DETAIL\|^$" | sed 's/^psql:[a-z0-9.]*:[0-9]*: //' > resultado-test8.txt
echo "Resultados en resultado-test8.txt"
