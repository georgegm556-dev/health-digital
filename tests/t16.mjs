// Prueba de la fase P0 en la app: reservas por el servidor, perfiles de ejemplo, membresía apagada, diálogo accesible.
import {chromium} from '/opt/npm-tools/node_modules/playwright/index.mjs';
import fs from 'fs';
const b=await chromium.launch({executablePath:'/opt/pw-browsers/chromium'}).catch(()=>chromium.launch());
const out={};const errs=[];
const p=await b.newPage({viewport:{width:390,height:844}});p.on('pageerror',e=>errs.push(e.message));
await p.route('**/supabase.js',r=>r.fulfill({body:fs.readFileSync('tests/mock4.js','utf8'),contentType:'text/javascript'}));
// Uso (desde la raíz del repositorio): node tests/t16.mjs   · requiere Playwright con Chromium
const src=fs.readFileSync('index.html','utf8').replace(/SUPABASE_URL: '[^']*'/,"SUPABASE_URL: 'https://example.supabase.co'").replace(/SUPABASE_ANON_KEY: '[^']*'/,"SUPABASE_ANON_KEY: 'x'");
await p.route('https://app.test/**',r=>r.fulfill({body:'<!doctype html><html><head><meta charset=utf8><meta name=viewport content="width=device-width,initial-scale=1"></head><body>'+src+'</body></html>',contentType:'text/html'}));
await p.goto('https://app.test/');await p.waitForTimeout(800);
// Invitado: perfiles de ejemplo sin insignia de verificado
out.ejemplo=await p.evaluate(()=>({tags:document.querySelectorAll('.doc .tag.warn').length,verif:document.querySelectorAll('.doc .doc-name [title="Cédula verificada"]').length}));
// Diálogo: foco entra, Tab queda dentro, Escape regresa el foco
const trigger=p.locator('.doc-hit').first(); await trigger.focus(); await p.keyboard.press('Enter'); await p.waitForTimeout(300);
out.focoDentro=await p.evaluate(()=>!!document.querySelector('.sheet')?.contains(document.activeElement));
out.fondoInerte=await p.evaluate(()=>document.querySelector('.app').inert===true);
for(let i=0;i<60;i++) await p.keyboard.press('Tab');
out.tabAtrapado=await p.evaluate(()=>!!document.querySelector('.sheet')?.contains(document.activeElement));
out.badgeEjemploPerfil=await p.evaluate(()=>document.querySelector('.sheet .tag.warn')?.textContent||'');
// perfil de ejemplo no reservable en modo Supabase
await p.click('.sheet .slot:not([disabled])');await p.click('#ctaDoc');await p.waitForTimeout(200);
out.toastEjemplo=await p.evaluate(()=>document.querySelector('.toast')?.textContent||'');
await p.keyboard.press('Escape');await p.waitForTimeout(200);
out.focoRegresa=await p.evaluate(()=>document.activeElement?.classList.contains('doc-hit'));
out.fondoActivo=await p.evaluate(()=>document.querySelector('.app').inert===false);
// Membresía: próximamente, sin botones de compra
await p.click('[data-act=tab][data-v=membresia]');await p.waitForTimeout(200);
out.membresia=await p.evaluate(()=>({pronto:[...document.querySelectorAll('.plan button[disabled]')].map(b=>b.textContent),comprar:document.querySelectorAll('[data-act=plan]').length,nota:/abrirán pronto/.test(document.body.textContent)}));
// Médico real: se registra, Health Digital lo verifica
await p.click('#cuentaBtn');await p.waitForTimeout(200);await p.click('[data-act=authModo][data-v=crear]');await p.click('label.rol:has(input[value=medico])');
await p.fill('#a-mail','ana@clinica.com');await p.fill('#a-pass','secreta123');await p.click('#authForm button[type=submit]');await p.waitForTimeout(600);
await p.fill('#d-nombre','Dra. Ana López Ruiz');await p.fill('#d-ced','12345678');await p.selectOption('#d-esp','Medicina General');
await p.fill('#d-uni','UNAM');await p.fill('#d-exp','10');await p.fill('#d-cons','Consultorio 304');await p.fill('#d-zona','Roma Norte');await p.fill('#d-dir','Calle Orizaba 50, Roma Norte, CDMX');
await p.fill('[name=sv-n]','Consulta general');await p.fill('[name=sv-p]','600');await p.check('#d-terms');await p.click('#donb-form button[type=submit]');await p.waitForTimeout(700);
await p.evaluate(()=>{__T.doctores[0].verificado=true;__T.doctores[0].tarjeta_ok=true;__save()});
await p.click('[data-act=tab][data-v=perfilmed]');await p.waitForTimeout(200);await p.click('[data-act=logout]');await p.waitForTimeout(500);
// Paciente reserva: intenta alterar el precio en el navegador -> el servidor usa el del catálogo
await p.click('#cuentaBtn');await p.waitForTimeout(200);await p.click('[data-act=authModo][data-v=crear]');await p.fill('#a-mail','maria@correo.com');await p.fill('#a-pass','secreta123');await p.click('#authForm button[type=submit]');await p.waitForTimeout(600);
await p.fill('#o-nombre','María González');await p.check('#o-aviso');await p.click('#onbForm button[type=submit]');await p.waitForTimeout(500);
await p.fill('#q','Ana López');await p.waitForTimeout(300);
await p.click('.doc-foot [data-act=rapido]');await p.waitForTimeout(200);
out.sinOpcionMembresia=await p.evaluate(()=>!document.querySelector('input[name=metodo][value=membresia]'));
await p.evaluate(()=>{const d=DOCS_DB[0];d.servicios[0].p=1});            // manipulación en el navegador
await p.click('[data-act=confirmar]');await p.waitForTimeout(500);
await p.click('[data-act=confirmar]').catch(()=>{});                      // doble clic tardío
out.cita=await p.evaluate(()=>__T.citas.map(c=>({precio:c.precio,serv:c.servicio_id,folio:c.folio,idem:!!c.idem_key})));
out.listo=await p.evaluate(()=>document.querySelector('.hero-ok h2')?.textContent||'');
await p.click('[data-act=close]');
// Cancelar desde Citas usa la función del servidor
await p.click('[data-act=tab][data-v=citas]');await p.waitForTimeout(200);await p.click('[data-act=cancelar]');await p.click('[data-act=cancelarSi]');await p.waitForTimeout(400);
out.cancelada=await p.evaluate(()=>__T.citas.map(c=>c.estado+'/'+(c.cancelada_por||'')));
out.slotLibre=await p.evaluate(()=>__T.ocupados.length);
console.log(JSON.stringify(out,null,1));console.log('ERRS',errs);await b.close();
