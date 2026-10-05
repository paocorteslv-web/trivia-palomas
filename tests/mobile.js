// Prueba en navegador real (Chromium) a 360×800 con un Supabase simulado dentro de la página.
// Uso: NODE_PATH=$(npm root -g) node tests/mobile.js [carpeta-capturas]
// Verifica: botones ≥ 48 px, inputs ≥ 16 px, sin scroll horizontal, venta en 3 toques, formularios que no pierden lo escrito
// cuando otro usuario guarda (Realtime), "actualizado hace", modo sin conexión en solo lectura y service worker.
const http=require("http"),fs=require("fs"),path=require("path"),A=require("assert");
const{chromium}=require("playwright");
const ROOT=path.join(__dirname,".."),OUT=process.argv[2]||"";
const ADMIN="11111111-1111-4111-8111-111111111111",OTHER="22222222-2222-4222-8222-222222222222";
const today=new Intl.DateTimeFormat("en-CA",{timeZone:"America/Argentina/Mendoza"}).format(new Date());
// Supabase falso (se sirve en lugar de la librería del CDN)
const FAKE=`(()=>{const now=()=>new Date().toISOString(),T=${JSON.stringify(today)};let n=0;
const rows=[{kind:"config",id:"main",date:null,data:{consumo:0.1,precio:1000,capital:50000,medios:["EFECTIVO","TRANSFERENCIA","QR"],cats:["Insumos","Otros"]}},
 {kind:"productos",id:"p1",date:null,data:{name:"Café",price:1500,active:true}},{kind:"productos",id:"p2",date:null,data:{name:"Tortafrita",price:800,active:true}},
 {kind:"inventario",id:"i1",date:null,data:{name:"Harina",unit:"kg",stock0:5,min:10}},
 {kind:"aperturas",id:T,date:T,data:{open:20000}},
 {kind:"ventas",id:"v0",date:T,data:{medio:"EFECTIVO",total:3000,items:[{pid:"p1",name:"Café",qty:2,price:1500}]}},
 {kind:"gastos",id:"g0",date:T,data:{medio:"TRANSFERENCIA",type:"DIRECT",amount:1200,desc:"Leche",cat:"Insumos"}},
 {kind:"futuros",id:"f0",date:T,data:{desc:"Alquiler",amount:90000,kind:"GASTO",freq:"MONTHLY"}}].map(r=>({created_by:"${ADMIN}",created_at:now(),updated_at:now(),deleted:false,...r}));
window.__rows=rows;window.__inserts=[];
function Q(t){const q={t,op:"select",f:{},body:null,one:false,maybe:false,rng:null};
 const api={select(){return api},order(){return api},eq(k,v){q.f[k]=v;return api},range(a,b){q.rng=[a,b];return api},single(){q.one=true;return api},maybeSingle(){q.maybe=true;return api},
  insert(b){q.op="insert";q.body=b;return api},upsert(b){q.op="insert";q.body=b;return api},update(b){q.op="update";q.body=b;return api},
  then(ok,ko){return new Promise(r=>setTimeout(r,20)).then(()=>{if(!navigator.onLine||window.__offline)return{data:null,error:{message:"TypeError: Failed to fetch"}};
   if(t=="profiles")return{data:[{id:"${ADMIN}",name:"admin@carrito.test",role:"ADMIN",active:true,created_at:now()},{id:"${OTHER}",name:"op@carrito.test",role:"OPERADOR",active:true,created_at:now()}],error:null};
   const match=r=>Object.entries(q.f).every(([k,v])=>r[k]==v);
   if(q.op=="insert"){const b=[].concat(q.body).map(r=>({...r,created_by:"${ADMIN}",created_at:now(),updated_at:now(),updated_by:"${ADMIN}"}));b.forEach(r=>{window.__inserts.push(r);const i=rows.findIndex(x=>x.kind==r.kind&&x.id==r.id);if(i>=0)rows[i]=r;else rows.push(r)});return{data:q.one?b[0]:b,error:null}}
   if(q.op=="update"){const r=rows.find(match);Object.assign(r,q.body,{updated_at:now()});return{data:q.one?r:[r],error:null}}
   let d=rows.filter(match);if(q.rng)d=d.slice(q.rng[0],q.rng[1]+1);return{data:q.one||q.maybe?d[0]||null:d,error:null}}).then(ok,ko)}};return api}
let ch;window.supabase={createClient:()=>({auth:{getSession:async()=>({data:{session:{user:{id:"${ADMIN}",email:"admin@carrito.test"}}}}),onAuthStateChange(){},signOut:async()=>({})},
 from:Q,storage:{from:()=>({createSignedUrl:async()=>({data:{signedUrl:"about:blank"}}),upload:async()=>({error:null})})},
 channel(){ch={on(e,f,cb){this.cb=cb;return this},subscribe(cb){cb("SUBSCRIBED");return this}};return ch},removeChannel(){}})};
// otro usuario guarda algo → llega por Realtime
window.__emit=r=>{r={created_by:"${OTHER}",created_at:now(),updated_at:now(),deleted:false,...r};rows.push(r);ch.cb({new:r})}})();`;
const MIME={".html":"text/html;charset=utf-8",".js":"text/javascript",".webmanifest":"application/manifest+json",".png":"image/png"};
const srv=http.createServer((q,s)=>{const u=decodeURIComponent(q.url.split("?")[0]),f=path.join(ROOT,u=="/"?"carrito-supabase.html":u);
 if(u=="/config.js"){s.writeHead(200,{"content-type":MIME[".js"]});return s.end('window.CARRITO_CONFIG={url:"https://demo.supabase.co",anonKey:"x.eyJyb2xlIjoiYW5vbiJ9.y"}')}
 if(!f.startsWith(ROOT)||!fs.existsSync(f)||fs.statSync(f).isDirectory()){s.writeHead(404);return s.end()}s.writeHead(200,{"content-type":MIME[path.extname(f)]||"application/octet-stream"});fs.createReadStream(f).pipe(s)});
(async()=>{await new Promise(r=>srv.listen(0,"127.0.0.1",r));const base=`http://127.0.0.1:${srv.address().port}/`;
 const br=await chromium.launch();
 const ctx=await br.newContext({viewport:{width:360,height:800},deviceScaleFactor:2,isMobile:true,hasTouch:true,locale:"es-AR",timezoneId:"America/Argentina/Mendoza",serviceWorkers:"allow"});
 await ctx.route("https://cdn.jsdelivr.net/**",r=>r.request().url().includes("supabase-js")?r.fulfill({contentType:"text/javascript",body:FAKE}):r.abort());
 const pg=await ctx.newPage(),errs=[];pg.on("pageerror",e=>errs.push(e.message));pg.on("dialog",d=>{errs.dialog=d.message();d.accept()});
 const shot=async n=>{if(OUT)await pg.screenshot({path:path.join(OUT,n+".png"),fullPage:false})};
 const ok=[];const pass=m=>{ok.push(m);console.log("✔",m)};
 await pg.goto(base+"carrito-supabase.html");await pg.waitForSelector(".quick");await pg.waitForTimeout(300);
 // medidas de cada pestaña
 const tabs=await pg.$$eval("nav button",b=>b.map(x=>x.dataset.t).filter(t=>t!="out"));
 for(const t of tabs){await pg.click(`nav button[data-t="${t}"]`);await pg.waitForTimeout(80);
  const m=await pg.evaluate(()=>{const vis=e=>{const r=e.getBoundingClientRect(),s=getComputedStyle(e);return r.width>0&&r.height>0&&s.visibility!="hidden"&&s.opacity!="0"};
   const small=[...document.querySelectorAll("button,select,input:not([type=radio]):not([type=checkbox]),.chips span")].filter(vis).filter(e=>e.getBoundingClientRect().height<47.5).map(e=>e.outerHTML.slice(0,80));
   const font=[...document.querySelectorAll("input,select,textarea")].filter(vis).filter(e=>parseFloat(getComputedStyle(e).fontSize)<16).map(e=>e.name);
   return{small,font,sw:document.documentElement.scrollWidth}});
  A.deepEqual(m.small,[],`${t}: elementos táctiles < 48 px`);A.deepEqual(m.font,[],`${t}: inputs < 16 px`);A.ok(m.sw<=360,`${t}: scroll horizontal (${m.sw}px)`);await shot("tab-"+t)}
 pass(`${tabs.length} pestañas a 360×800: táctiles ≥ 48 px, inputs ≥ 16 px, sin scroll horizontal`);
 // venta en 3 toques: Venta → + Café → Guardar (efectivo y fecha de hoy ya elegidos)
 await pg.click('nav button[data-t="venta"]');await pg.click('#fv .qty button[data-inc="p1"]');await pg.click('#fv .qty button[data-inc="p1"]');
 A.equal(await pg.textContent("#vtot"),await pg.evaluate(()=>ARS(3000)));await pg.click("#fv button.p");await pg.waitForTimeout(200);
 const sale=await pg.evaluate(()=>__inserts.find(r=>r.kind=="ventas"));A.equal(sale.data.total,3000);A.equal(sale.data.medio,"EFECTIVO");A.equal(sale.date,await pg.evaluate(()=>today()));
 pass("venta cargada con 3–4 toques (Venta, +, +, Guardar), total en vivo");
 // lo escrito no se pierde cuando otro usuario guarda
 await pg.click('nav button[data-t="gasto"]');await pg.fill('#fg input[name=amount]',"4321");await pg.fill('#fg input[name=desc]',"Hielo");await pg.click('#fg .chips label:has-text("TRANSFERENCIA")');await pg.focus('#fg input[name=desc]');
 await pg.evaluate(t=>__emit({kind:"gastos",id:"gx",date:t,data:{medio:"EFECTIVO",type:"DIRECT",amount:777,desc:"Gasto de otro usuario",cat:"Otros"}}),today);await pg.waitForTimeout(400);
 A.ok((await pg.textContent("#app")).includes("Gasto de otro usuario"),"la lista se actualizó");
 A.equal(await pg.inputValue('#fg input[name=amount]'),"4321");A.equal(await pg.inputValue('#fg input[name=desc]'),"Hielo");A.equal(await pg.evaluate(()=>document.querySelector('#fg input[name=medio]:checked').value),"TRANSFERENCIA");
 A.equal(await pg.evaluate(()=>document.activeElement.name),"desc");pass("otro usuario guarda (Realtime): la lista se actualiza y el formulario abierto conserva lo escrito y el foco");
 await pg.click('nav button[data-t="inicio"]');await pg.waitForTimeout(100);
 A.match(await pg.textContent("#st"),/Actualizado hace .* · en vivo/);const home=await pg.textContent("#app");
 for(const s of["Ventas hoy","Gastos hoy","Resultado operativo","Efectivo inicial","Efectivo esperado","Efectivo contado","Diferencia","Saldo financiero","Retiros del mes","Necesidad de fondos","Próximos pagos","Stock bajo: Harina"])A.ok(home.includes(s),s);
 A.ok(home.includes(await pg.evaluate(()=>ARS(20000+3000+3000-777))),"efectivo esperado con la venta nueva y el gasto del otro usuario");await shot("inicio");
 pass("dashboard completo con 'Actualizado hace…', alertas y efectivo esperado al día");
 // sin conexión: último dato conocido en solo lectura
 const sw=await pg.evaluate(async()=>{const r=await navigator.serviceWorker.ready;return!!r.active});A.ok(sw,"service worker activo");
 // en este entorno el CDN real está bloqueado: se deja en la caché la librería simulada, como haría una primera visita con red
 await pg.evaluate(async b=>{const c=await caches.open("carrito-v1");await c.put("https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.45.4/dist/umd/supabase.min.js",new Response(b,{headers:{"content-type":"text/javascript"}}))},FAKE);
 await ctx.setOffline(true);await pg.evaluate(()=>{window.__offline=true;dispatchEvent(new Event("offline"))});await pg.waitForTimeout(150);
 A.equal((await pg.textContent("#ban")).trim(),"Sin conexión: no se pueden cargar movimientos");A.ok((await pg.textContent("#app")).includes("Ventas hoy"));
 await pg.click('nav button[data-t="venta"]');A.ok(await pg.$eval("#fv button.p",b=>b.disabled),"guardar deshabilitado");await shot("sin-conexion");
 await pg.reload();await pg.waitForTimeout(800);   // recarga sin red: interfaz desde el service worker + último dato guardado
 A.equal((await pg.textContent("#ban")).trim(),"Sin conexión: no se pueden cargar movimientos");A.ok((await pg.textContent("#app")).includes("Ventas hoy"),"abre sin conexión con el último dato");
 pass("sin conexión: aviso visible, datos en solo lectura, abre desde el service worker sin red");
 await ctx.setOffline(false);await pg.evaluate(()=>{window.__offline=false;dispatchEvent(new Event("online"))});await pg.waitForTimeout(400);A.equal((await pg.textContent("#ban")).trim(),"");pass("al volver la conexión se recarga y sale del modo solo lectura");
 A.deepEqual(errs.filter(e=>!/Failed to fetch/.test(e)),[],"errores de JavaScript");pass("sin errores de JavaScript");
 await br.close();srv.close();console.log(`MÓVIL: TODOS OK (${ok.length})`)})().catch(e=>{console.error("✘",e.message);process.exit(1)});
