(function(){
const K='mockdb';const T0=JSON.parse(sessionStorage.getItem(K)||'null')||{perfiles:[],citas:[],ocupados:[],resenas:[],doctores:[],cobros_medicos:[],config_plataforma:[{clave:'cobertura_membresia',valor:false},{clave:'venta_membresias',valor:false}],senales:[]};
const T=Object.assign({config_plataforma:[{clave:'cobertura_membresia',valor:false},{clave:'venta_membresias',valor:false}],senales:[]},T0);
const save=()=>sessionStorage.setItem(K,JSON.stringify(T));
let sess=JSON.parse(sessionStorage.getItem('sess')||'null');const subs=[];
const uidOf=e=>'u-'+e.replace(/[^a-z]/g,'');
function Q(t){let filters=[],op='select',payload=null,single=false,maybe=false;
 const q={select(){return q},eq(k,v){filters.push(r=>r[k]===v);return q},gte(k,v){filters.push(r=>r[k]>=v);return q},order(){return q},
 maybeSingle(){maybe=true;return q},single(){single=true;return q},
 insert(p){op='insert';payload=p;return q},upsert(p){op='upsert';payload=p;return q},update(p){op='update';payload=p;return q},delete(){op='delete';return q},
 then(res,rej){try{res(run())}catch(e){rej(e)}}};
 function run(){const m=r=>filters.every(f=>f(r));let out;
  if(op==='insert'){const p={...payload};if(t!=='perfiles'&&!p.id)p.id=Math.random().toString(36).slice(2);if(T[t].some(r=>r.id===p.id))return{error:{code:'23505',message:'dup'}};if(t!=='perfiles')p.user_id=sess.user.id;if(t==='doctores'){p.verificado=false;p.tarjeta_ok=false;p.suspendido=false}T[t].push(p);out={data:single?{id:p.id}:[p],error:null}}
  else if(op==='upsert'){const i=T[t].findIndex(r=>r.id===payload.id);if(i>=0)T[t][i]={...T[t][i],...payload};else T[t].push({...payload});out={data:null,error:null}}
  else if(op==='update'){T[t].filter(m).forEach(r=>Object.assign(r,payload));out={data:[],error:null}}
  else if(op==='delete'){T[t]=T[t].filter(r=>!m(r));out={data:null,error:null}}
  else{let rows=T[t];if(t==='doctores')rows=rows.filter(r=>(r.verificado&&r.tarjeta_ok)||r.user_id===sess.user.id);
    if(t==='citas'&&!filters.length)rows=[];const d=rows.filter(m).map(r=>JSON.parse(JSON.stringify(r)));out=maybe?{data:d[0]||null,error:null}:{data:d,error:null}}
  save();return out}
 return q}
const start=c=>{const [y,mo,d]=c.fecha.split('-').map(Number);const [H,M]=c.hora.split(':').map(Number);return new Date(y,mo-1,d,H,M).getTime()};
const est=c=>{if(c.estado==='cancelada')return 'sin_comision';const t=start(c),n=Date.now();if(n<t)return 'pendiente';if(c.asistencia_medico==='no_asistio'&&c.asistencia_paciente==='asistio')return 'en_revision';if(c.asistencia_medico==='no_asistio')return 'no_asistio';if(c.asistencia_medico==='asistio')return 'cobrable';if(n>t+72*36e5)return 'cobrable';return 'por_confirmar'};
const rpcs={

 // Simulación de las funciones del servidor (actualización 7): precio y servicio salen del catálogo del médico.
 reservar_cita:a=>{const u=sess.user.id;const prev=T.citas.find(c=>c.user_id===u&&c.idem_key===a.p_idem);if(prev)return prev;
   const d=T.doctores.find(x=>x.id===a.p_doctor);if(!d||!d.verificado||!d.tarjeta_ok||d.suspendido)throw new Error('medico_no_disponible');
   const sv=(d.servicios||[]).find(x=>x.id===a.p_servicio);if(!sv)throw new Error('servicio_invalido');
   if(!(d.horas||[]).includes(a.p_hora))throw new Error('fuera_de_agenda');
   const key=d.id+'_'+a.p_fecha+'_'+a.p_hora.replace(':','');if(T.ocupados.some(o=>o.id===key))throw new Error('horario_ocupado');
   if(a.p_usar_membresia)throw new Error('sin_cobertura');
   const c={id:Math.random().toString(36).slice(2),user_id:u,doctor_id:d.id,fecha:a.p_fecha,hora:a.p_hora,modalidad:a.p_modalidad,paciente:a.p_paciente,motivo:a.p_motivo,estado:'confirmada',cubierta:false,precio:sv.p,servicio:sv.n,servicio_id:sv.id,slot:key,folio:'HD'+Math.random().toString(36).slice(2,8).toUpperCase(),idem_key:a.p_idem,creada:new Date().toISOString()};
   T.ocupados.push({id:key,doctor_id:d.id,fecha:a.p_fecha,hora:a.p_hora,modalidad:a.p_modalidad,tipo:'cita',user_id:u});T.citas.push(c);return c},
 reprogramar_cita:a=>{const c=T.citas.find(x=>x.id===a.p_cita&&x.user_id===sess.user.id);if(!c)throw new Error('cita_no_encontrada');
   const key=c.doctor_id+'_'+a.p_fecha+'_'+a.p_hora.replace(':','');if(T.ocupados.some(o=>o.id===key))throw new Error('horario_ocupado');
   T.ocupados=T.ocupados.filter(o=>o.id!==c.slot);T.ocupados.push({id:key,doctor_id:c.doctor_id,fecha:a.p_fecha,hora:a.p_hora,tipo:'cita',user_id:c.user_id});Object.assign(c,{fecha:a.p_fecha,hora:a.p_hora,modalidad:a.p_modalidad,slot:key});return c},
 cancelar_cita:a=>{const c=T.citas.find(x=>x.id===a.p_cita&&x.user_id===sess.user.id);if(!c)throw new Error('cita_no_encontrada');c.estado='cancelada';c.cancelada_por='paciente';T.ocupados=T.ocupados.filter(o=>o.id!==c.slot);return c},
 bloquear_horario:a=>{const d=T.doctores.find(x=>x.user_id===sess.user.id);if(!d)throw new Error('no_medico');const key=d.id+'_'+a.p_fecha+'_'+a.p_hora.replace(':','');if(T.ocupados.some(o=>o.id===key))throw new Error('horario_ocupado');T.ocupados.push({id:key,doctor_id:d.id,fecha:a.p_fecha,hora:a.p_hora,tipo:'bloqueo',user_id:sess.user.id});return null},
 liberar_bloqueo:a=>{const d=T.doctores.find(x=>x.user_id===sess.user.id);T.ocupados=T.ocupados.filter(o=>!(o.doctor_id===d.id&&o.fecha===a.p_fecha&&o.hora===a.p_hora&&o.tipo==='bloqueo'));return null},
 borrar_mis_datos:()=>{const u=sess.user.id;T.citas.filter(c=>c.user_id===u&&c.estado==='confirmada').forEach(c=>{c.estado='cancelada';T.ocupados=T.ocupados.filter(o=>o.id!==c.slot)});T.citas.filter(c=>c.user_id===u).forEach(c=>{c.paciente='Paciente';c.motivo=null});T.perfiles=T.perfiles.filter(p=>p.id!==u);return null},
 mis_resenas:()=>T.resenas.filter(r=>r.user_id===sess.user.id).map(r=>({id:r.id,cita_id:r.cita_id})),
 mi_doctor:()=>T.doctores.filter(d=>d.user_id===sess.user.id),
 marcar_asistencia:({p_cita,p_valor})=>{const c=T.citas.find(x=>x.id===p_cita);c.asistencia_medico=p_valor;return null},
 confirmar_asistencia:({p_cita,p_valor})=>{const c=T.citas.find(x=>x.id===p_cita);c.asistencia_paciente=p_valor;return null},
 cancelar_por_medico:({p_cita})=>{const c=T.citas.find(x=>x.id===p_cita);c.estado='cancelada';c.cancelada_por='medico';T.ocupados=T.ocupados.filter(o=>o.id!==c.slot);return null},
 estado_cuenta:({p_desde,p_hasta})=>{const d=T.doctores.find(x=>x.user_id===sess.user.id);return T.citas.filter(c=>c.doctor_id===d.id&&c.fecha>=p_desde&&c.fecha<=p_hasta).map(c=>{const e=est(c);return {cita_id:c.id,fecha:c.fecha,hora:c.hora,paciente:c.paciente,servicio:c.servicio,precio:c.precio,cubierta:c.cubierta,estado:e,comision:e==='cobrable'&&!c.cubierta?c.precio*0.1:0,credito:e==='cobrable'&&c.cubierta?c.precio*0.9:0}})}
};
window.supabase={createClient(){return{
 auth:{async getSession(){return{data:{session:sess}}},onAuthStateChange(cb){subs.push(cb)},
  async signUp({email,options}){sess={user:{id:uidOf(email),email,user_metadata:(options&&options.data)||{}}};sessionStorage.setItem('meta-'+email,JSON.stringify(sess.user.user_metadata));sessionStorage.setItem('sess',JSON.stringify(sess));subs.forEach(f=>f('SIGNED_IN',sess));return{data:{session:sess},error:null}},
  async signInWithPassword({email}){sess={user:{id:uidOf(email),email,user_metadata:JSON.parse(sessionStorage.getItem('meta-'+email)||'{}')}};sessionStorage.setItem('sess',JSON.stringify(sess));subs.forEach(f=>f('SIGNED_IN',sess));return{error:null}},
  async signOut(){sess=null;sessionStorage.removeItem('sess');subs.forEach(f=>f('SIGNED_OUT',null));return{error:null}}},
 rpc:async(n,a)=>{if(!rpcs[n])return{data:null,error:{code:'PGRST202',message:'not found'}};try{const r=rpcs[n](a||{});save();return{data:r,error:null}}catch(e){return{data:null,error:{code:'P0001',message:e.message||String(e)}}}},
 functions:{async invoke(n,{body}){(window.__inv=window.__inv||[]).push(body);return{data:{ok:true}}}},
 storage:{from(b){return{async upload(path,blob){const r=new FileReader();const u=await new Promise(ok=>{r.onload=()=>ok(r.result);r.readAsDataURL(blob)});sessionStorage.setItem('foto:'+path,u);return{error:null}},getPublicUrl(path){return{data:{publicUrl:'https://example.supabase.co/storage/v1/object/public/fotos-medicos/'+path}}},async remove(){return{}}}}},
 from:t=>Q(t),channel(){const c={on(){return c},subscribe(){return c}};return c},removeChannel(){}}}};
window.__T=T;window.__save=save;})();
