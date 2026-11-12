#!/usr/bin/env bash
# Prueba la actualización 7 en un Postgres 16 local (no toca Supabase).
# Uso: PGHOST=/tmp PGPORT=5497 PGUSER=postgres ./correr-pruebas.sh
set -u
cd "$(dirname "$0")"
P="psql -q -v ON_ERROR_STOP=1"
$P -c "drop database if exists hd_pruebas" -c "create database hd_pruebas" >/dev/null
psql -q -c "create role anon nologin" -c "create role authenticated nologin" >/dev/null 2>&1 || true
tail -n +2 pre_supabase_stub.sql | $P -d hd_pruebas >/dev/null 2>&1
$P -d hd_pruebas -f pre_storage_stub.sql >/dev/null
$P -d hd_pruebas -f ../supabase.sql >/dev/null 2>&1
$P -d hd_pruebas -f ../actualizacion-7-seguridad.sql >/dev/null 2>&1 || { echo "FALLÓ la migración"; exit 1; }
$P -d hd_pruebas -f ../actualizacion-7-seguridad.sql >/dev/null 2>&1 || { echo "FALLÓ al repetir la migración"; exit 1; }
$P -d hd_pruebas -f seed7.sql >/dev/null
filtra(){ grep -v "^CONTEXT\|^SQL statement\|^PL/pgSQL\|^DETAIL\|^[0-9a-f]\{8\}-\|^$" | sed 's/^psql:[a-z0-9.]*:[0-9]*: //'; }
psql -q -d hd_pruebas -f test7.sql 2>&1 | filtra > resultado-test7.txt
psql -q -d hd_pruebas -f test7b.sql 2>&1 | filtra > resultado-test7b.txt
echo "Resultados en resultado-test7.txt y resultado-test7b.txt"
