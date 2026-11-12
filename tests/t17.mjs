// Verificación del médico: avance por pasos, documentos privados e insignias públicas.
import {chromium} from '/opt/npm-tools/node_modules/playwright/index.mjs';
import fs from 'fs';
const b=await chromium.launch({executablePath:'/opt/pw-browsers/chromium'}).catch(()=>chromium.launch());
const out={};const errs=[];
const p=await b.newPage({viewport:{width:390,height:844}});p.on('pageerror',e=>errs.push(e.message));
await p.route('**/supabase.js',r=>r.fulfill({body:fs.readFileSync('tests/mock4.js','utf8'),contentType:'text/javascript'}));
const src=fs.readFileSync('index.html','utf8').replace(/SUPABASE_URL: '[^']*'/,"SUPABASE_URL: 'https://example.supabase.co'").replace(/SUPABASE_ANON_KEY: '[^']*'/,"SUPABASE_ANON_KEY: 'x'");
await p.route('https://app.test/**',r=>r.fulfill({body:'<!doctype html><html><head><meta charset=utf8><meta name=viewport content="width=device-width,initial-scale=1"></head><body>'+src+'</body></html>',contentType:'text/html'}));
await p.goto('https://app.test/');await p.waitForTimeout(800);
await p.click('#cuentaBtn');await p.waitForTimeout(200);await p.click('[data-act=authModo][data-v=crear]');await p.click('label.rol:has(input[value=medico])');
await p.fill('#a-mail','ana@clinica.com');await p.fill('#a-pass','secreta123');await p.click('#authForm button[type=submit]');await p.waitForTimeout(600);
await p.fill('#d-nombre','Dra. Ana López Ruiz');await p.fill('#d-ced','12345678');await p.selectOption('#d-esp','Cardiología');
await p.fill('#d-uni','UNAM');await p.fill('#d-exp','10');await p.fill('#d-tel','5512345678').catch(()=>{});await p.fill('#d-cons','Consultorio 304');await p.fill('#d-zona','Roma Norte');await p.fill('#d-dir','Calle Orizaba 50, Roma Norte, CDMX');
await p.fill('[name=sv-n]','Consulta');await p.fill('[name=sv-p]','800');await p.check('#d-terms');await p.click('#donb-form button[type=submit]');await p.waitForTimeout(900);
out.recienRegistrado=await p.evaluate(()=>({titulo:document.querySelector('.card.elev h3')?.textContent,pasos:[...document.querySelectorAll('.verif-paso')].map(x=>x.querySelector('b').textContent+' → '+(x.querySelector('.tag')?.textContent||'')),barra:document.querySelector('.verif-barra')?.getAttribute('aria-valuenow'),tel:/5512345678/.test(document.body.textContent)}));
await p.screenshot({path:'v1.png',fullPage:true});
// Sube cédula de especialidad (PDF)
await p.setInputFiles('#doc-especialidad',{name:'cedula-esp.pdf',mimeType:'application/pdf',buffer:Buffer.from('%PDF-1.4 prueba')});await p.waitForTimeout(700);
out.trasSubir=await p.evaluate(()=>({docs:(__T.docs||[]).map(d=>d.path.split('/')[1].split('-')[0]),estado:[...document.querySelectorAll('.verif-paso')].filter(x=>/especialidad/.test(x.textContent)).map(x=>x.querySelector('.tag')?.textContent||'')}));
// Archivo no permitido
await p.setInputFiles('#doc-consejo',{name:'virus.exe',mimeType:'application/x-msdownload',buffer:Buffer.from('MZ')});await p.waitForTimeout(300);
out.rechazaTipo=await p.evaluate(()=>document.querySelector('.toast')?.textContent||'');
// Health Digital aprueba cédula, identidad, especialidad; tarjeta registrada
await p.evaluate(()=>{const d=__T.doctores[0];__T.verificaciones_medico.push({paso:'cedula_sep',resultado:'aprobado',creado:new Date().toISOString(),doctor_id:d.id},{paso:'identidad',resultado:'aprobado',creado:new Date().toISOString(),doctor_id:d.id});Object.assign(d,{verificado:true,tarjeta_ok:true,esp_verificada:true});__save()});
await p.reload();await p.waitForTimeout(900);
out.publicado=await p.evaluate(()=>({nota:document.querySelector('.note')?.textContent?.trim().slice(0,40),insigniaActiva:[...document.querySelectorAll('.verif-paso')].filter(x=>/especialidad/i.test(x.textContent)).map(x=>x.querySelector('.tag')?.textContent||'')}));
await p.click('[data-act=tab][data-v=perfilmed]');await p.waitForTimeout(200);await p.click('[data-act=logout]');await p.waitForTimeout(500);
// Paciente invitado ve las insignias en el perfil público
await p.fill('#q','Ana López');await p.waitForTimeout(300);await p.click('.doc-hit');await p.waitForTimeout(300);
out.publico=await p.evaluate(()=>[...document.querySelectorAll('.sheet .tag.blue')].map(x=>x.textContent.trim()));
await p.screenshot({path:'v2.png'});
console.log(JSON.stringify(out,null,1));console.log('ERRS',errs);await b.close();
