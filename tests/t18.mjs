// Prueba de la actualización 9 en la app: menú de 4, síntomas, recomendados, membresía Plus, enlace/QR del médico, origen y anticipo.
import {chromium} from '/opt/npm-tools/node_modules/playwright/index.mjs';
import fs from 'fs';
const D='/tmp/claude-0/-home-claude/4541fbf9-33c8-5596-91a5-5a22d9b8083f/scratchpad/';
const b=await chromium.launch({executablePath:'/opt/pw-browsers/chromium'}).catch(()=>chromium.launch());
const out={};const errs=[];
const ctx=await b.newContext({viewport:{width:390,height:844}});
const p=await ctx.newPage();p.on('pageerror',e=>errs.push(e.message));
await p.route('**/supabase.js',r=>r.fulfill({body:fs.readFileSync(D+'scripts/mock5.js','utf8'),contentType:'text/javascript'}));
const src=fs.readFileSync(process.argv[2]||D+'health-digital.html','utf8').replace("SUPABASE_URL: ''","SUPABASE_URL: 'https://example.supabase.co'").replace("SUPABASE_ANON_KEY: ''","SUPABASE_ANON_KEY: 'x'");
await p.route('https://app.test/**',r=>r.fulfill({body:'<!doctype html><html><head><meta charset=utf8><meta name=viewport content="width=device-width,initial-scale=1"></head><body>'+src+'</body></html>',contentType:'text/html'}));
await ctx.route('https://cdnjs.cloudflare.com/ajax/libs/qrcodejs/1.0.0/qrcode.min.js',r=>r.fulfill({body:fs.readFileSync('/tmp/qrpkg/package/qrcode.min.js','utf8'),contentType:'text/javascript'}));
await p.goto('https://app.test/');await p.waitForTimeout(800);
const T=s=>p.evaluate(s);
// 1. Menú de 4
out.menu=await T(()=>[...document.querySelectorAll('#navIn button')].map(b=>b.textContent.trim()));
// 2. Síntomas
await p.fill('#q','tengo acné en la cara');await p.waitForTimeout(250);
out.acne=await T(()=>({nota:document.querySelector('#results .note')?.textContent.trim(),esp:[...new Set([...document.querySelectorAll('#results .doc .doc-main .muted')].map(x=>x.textContent.split(' · ')[0]))]}));
await p.fill('#q','me duele mucho el pecho');await p.waitForTimeout(250);
out.pecho=await T(()=>document.querySelector('#results .alerta-urg')?.textContent.trim());
await p.fill('#q','');await p.waitForTimeout(200);
out.orden=await T(()=>document.querySelector('#f-orden').selectedOptions[0].textContent);
// 3. Membresía desde Inicio
await p.click('.quick-acts [data-v=membresia]');await p.waitForTimeout(200);
out.membresia=await T(()=>({planes:[...document.querySelectorAll('.plan h3')].map(h=>h.textContent),precios:[...document.querySelectorAll('.plan-price')].map(x=>x.textContent.trim()),avisame:document.querySelectorAll('[data-act=avisame]').length,menuActivo:document.querySelector('#navIn [aria-current]')?.textContent.trim()}));
// 4. Médico se registra; segundo médico verificado para recomendar
await p.click('#cuentaBtn');await p.waitForTimeout(200);await p.click('[data-act=authModo][data-v=crear]');await p.click('label.rol:has(input[value=medico])');
await p.fill('#a-mail','ana@clinica.com');await p.fill('#a-pass','secreta123');await p.click('#authForm button[type=submit]');await p.waitForTimeout(600);
await p.fill('#d-nombre','Dra. Ana López Ruiz');await p.fill('#d-ced','12345678');await p.selectOption('#d-esp','Medicina General');
await p.fill('#d-uni','UNAM');await p.fill('#d-exp','10');await p.fill('#d-cons','Consultorio 304');await p.fill('#d-zona','Tlalpan');await p.fill('#d-dir','Calzada de Tlalpan 4000, Tlalpan, CDMX');
await p.fill('[name=sv-n]','Consulta general');await p.fill('[name=sv-p]','600');await p.check('#d-terms');await p.click('#donb-form button[type=submit]');await p.waitForTimeout(700);
await T(()=>{const d=__T.doctores[0];d.verificado=true;d.tarjeta_ok=true;__T.doctores.push({...JSON.parse(JSON.stringify(d)),id:'luis-perez-x1',user_id:'otro',nombre:'Dr. Luis Pérez',especialidad:'Cardiología',cedula:'99887766'});__save()});
await p.reload();await p.waitForTimeout(800);
await p.click('[data-act=tab][data-v=pagosmed]');await p.waitForTimeout(400);
out.pagosTexto=await T(()=>document.querySelector('#view h1+p').textContent);
await p.click('[data-act=tab][data-v=perfilmed]');await p.waitForTimeout(1500);
out.enlace=await T(()=>({url:document.querySelector('#enlaceCard code')?.textContent,qr:!!document.querySelector('#qrMed canvas,#qrMed img'),qrMsg:document.querySelector('#qrMed')?.textContent.trim(),wa:document.querySelector('#enlaceCard a[href^="https://wa.me"]')?.href.slice(0,60),agencia:/Health Digital Marketing/.test(document.body.textContent)}));
await p.selectOption('#recomSel','luis-perez-x1');await p.click('[data-act=agregarRecom]');await p.waitForTimeout(400);
await p.screenshot({path:D+'t18-medico.png',fullPage:true});
out.recom=await T(()=>({guardado:__T.doctores[0].recomendados,chips:[...document.querySelectorAll('#recomCard .recom-chip')].map(x=>x.textContent)}));
const docId=await T(()=>__T.doctores[0].id);
await p.click('[data-act=logout]');await p.waitForTimeout(500);
// 5. Paciente llega con el enlace del médico
await p.goto('https://app.test/?m='+docId);await p.waitForTimeout(1000);
out.abreConEnlace=await T(()=>({sheet:document.querySelector('.sheet h2')?.textContent,url:location.search,recomEnPerfil:document.querySelector('.recom-list')?.textContent.trim()}));
await p.keyboard.press('Escape');
await p.click('#cuentaBtn');await p.waitForTimeout(200);await p.click('[data-act=authModo][data-v=crear]');await p.fill('#a-mail','maria@correo.com');await p.fill('#a-pass','secreta123');await p.click('#authForm button[type=submit]');await p.waitForTimeout(600);
await p.fill('#o-nombre','María González');await p.check('#o-aviso');await p.click('#onbForm button[type=submit]');await p.waitForTimeout(500);
await p.fill('#q','Ana López');await p.waitForTimeout(300);
await p.click('.doc:has-text("Ana López") .doc-foot [data-act=rapido]');await p.waitForTimeout(200);
await p.click('[data-act=confirmar]');await p.waitForTimeout(500);
out.reserva1={origen:await T(()=>window.__ultimaReserva.p_origen||'(app)'),paso:await T(()=>document.querySelector('.hero-ok h2')?.textContent)};
await p.click('[data-act=close]');
// 6. Anticipo encendido
await T(()=>{__T.config_plataforma.push({clave:'anticipo_activo',valor:true},{clave:'anticipo_monto',valor:200});__save()});
await p.reload();await p.waitForTimeout(900);
await p.fill('#q','Luis Pérez');await p.waitForTimeout(300);
await p.click('.doc:has-text("Luis Pérez") .doc-foot [data-act=rapido]');await p.waitForTimeout(200);
out.notaAnticipo=await T(()=>[...document.querySelectorAll('.sheet .note')].map(n=>n.textContent.trim()).find(t=>/anticipo/.test(t)));
await p.click('[data-act=confirmar]');await p.waitForTimeout(500);
out.reserva2={origen:await T(()=>window.__ultimaReserva.p_origen||'(app)'),titulo:await T(()=>document.querySelector('.sheet h2')?.textContent),boton:await T(()=>document.querySelector('[data-act=pagarAnticipo]')?.textContent)};
await p.click('.sheet [data-act=pagarAnticipo]');await p.waitForTimeout(300);
out.pagos=await T(()=>window.__inv);
await p.click('.sheet [data-act=verCitas]').catch(()=>{});await p.waitForTimeout(300);
await p.click('[data-act=tab][data-v=citas]');await p.waitForTimeout(300);
out.citas=await T(()=>[...document.querySelectorAll('.cita')].map(c=>({pago:[...c.querySelectorAll('dt')].find(d=>d.textContent==='Pago')?.nextElementSibling.textContent,boton:c.querySelector('[data-act=pagarAnticipo]')?.textContent})));
await p.screenshot({path:D+'t18-citas.png'});
// 7. Lista de espera
await p.click('[data-act=tab][data-v=perfil]');await p.waitForTimeout(200);await p.click('#view [data-act=tab][data-v=membresia]');await p.waitForTimeout(200);
await p.click('[data-act=avisame][data-v=individual]');await p.waitForTimeout(400);
out.espera=await T(()=>({tabla:__T.lista_espera.map(x=>x.plan+'/'+x.precio+'/'+x.grupo),tag:[...document.querySelectorAll('.plan .tag.ok')].map(x=>x.textContent.trim())}));
await p.screenshot({path:D+'t18-membresia.png',fullPage:true});
// 8. El médico ve la cita de su paciente con 0%
await T(()=>{__T.citas.forEach(c=>{if(c.origen==='enlace_medico'){c.fecha=new Date(Date.now()-3*864e5).toISOString().slice(0,10);c.asistencia_medico='asistio'}});__save()});
await p.click('[data-act=tab][data-v=perfil]');await p.click('[data-act=logout]').catch(()=>{});await p.waitForTimeout(400);
console.log(JSON.stringify(out,null,1));console.log('ERRS',errs);await b.close();
