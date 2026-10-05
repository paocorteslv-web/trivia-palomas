// Tests del navegador con un db simulado que aplica rules.json y un lease único (acquire). NO reemplazan la prueba con sesiones reales.
// Las reglas de la BASE se prueban contra Postgres real en tests/sql (bash tests/sql/run.sh).
// Uso: node tests.js [carrito-supabase.html]
const fs=require("fs"),vm=require("vm"),A=require("assert"),path=require("path"),cp=require("child_process");
const FILE=process.argv[2]||"carrito-supabase.html",HTML=fs.readFileSync(path.join(__dirname,FILE),"utf8");
const code=HTML.split("<script>")[1].split("</script>")[0];
const RULES=JSON.parse(fs.readFileSync(__dirname+"/rules.json","utf8")).rules;
const LV={view:0,interact:1,admin:3},RL={ADMIN:3,OPERADOR:1};

// entorno aislado: cada llamada crea una app nueva con su propia "base" simulada
function mk(){
 const alerts=[],store={},leases={},env={role:"ADMIN",confirm:true,prompt:"",alerts,store};
 const el=()=>({innerHTML:"",textContent:""}),els={};
 const document={querySelector:s=>els[s]||(els[s]=el()),querySelectorAll:()=>[],getElementById:()=>null,addEventListener(){},createElement:()=>({click(){},remove(){}}),body:{appendChild(){}},head:{appendChild(){}}};
 const ctx=vm.createContext({console,document,crypto:require("crypto"),Intl,alert:m=>alerts.push(m),confirm:()=>env.confirm,prompt:()=>env.prompt,Blob,URL,setTimeout,clearTimeout,atob,btoa});
 vm.runInContext(code,ctx);const run=s=>vm.runInContext(s,ctx);
 const need=(c,op)=>{const r=RULES.find(r=>r.path==c),min=r?(r[op]||r.write):(op=="read"?"view":"interact");if(RL[env.role]<LV[min]){const e=new Error("not_granted");e.code="not_granted";throw e}};
 const sync=c=>{ctx.__s=Object.entries(store[c]).map(([id,d])=>({...d,id}));run(`D.${c}=__s;touch()`)};
 const put=(c,id,d)=>{(store[c]=store[c]||{})[id]={...d};sync(c)};
 ctx.mdb={collection:c=>({doc:id=>({async set(d){need(c,(store[c]||{})[id]?"update":"write");put(c,id,d)},
  async update(d){need(c,"update");Object.assign(store[c][id],d,{updated_at:new Date().toISOString()});sync(c)},
  async get(){const x=(store[c]||{})[id];return{exists:!!x,data:()=>x}},
  async acquire({ttlMs}){const k=c+id;if(leases[k]>Date.now())return{acquired:false};leases[k]=Date.now()+ttlMs;return{acquired:true}}})}),
  async batch(L){L.forEach(([c])=>need(c,"write"));L.forEach(([c,o])=>put(c,o.id,o))}};
 run("db=mdb");
 env.as=r=>{env.role=r;run(`me="${r}";admin=${r=="ADMIN"}`)};
 env.form=(id,f)=>{ctx.__f={id,dataset:{},reset(){},elements:Object.entries(f).map(([name,v])=>v&&typeof v=="object"&&"size"in v?{name,type:"file",files:[v]}:{name,value:String(v),type:"text"})};return run("onSubmit(__f)")};
 env.last=()=>alerts[alerts.length-1];env.run=run;env.ctx=ctx;env.leases=leases;
 return env}
const T=[];const t=(n,f)=>T.push([n,f]);const tick=()=>new Promise(r=>setTimeout(r,5));

// ── Escenario principal, en orden (A → H) ──
const E=mk(),run=E.run,t0=run("today()"),exp=()=>run(`dayExp("${t0}")`),oper=()=>run(`operating(live("ventas"),live("gastos"))`),saldo=()=>run("saldo()");
t("A ADMIN crea producto → OPERADOR lo ve y vende → ADMIN ve la venta",async()=>{E.as("ADMIN");await E.form("fprod",{name:"Café",price:500});await E.form("fcfg",{consumo:0.1,precio:1000,capital:5000,medios:"efectivo,transferencia",cats:"Insumos"});
 E.as("OPERADOR");A.equal(run('live("productos").length'),1);const pid=run('live("productos")[0].id');
 await E.form("fa",{open:10000});A.equal(run(`live("aperturas")[0].open`),10000);
 await E.form("fv",{["q_"+pid]:2,medio:"EFECTIVO",date:t0,notes:""});E.as("ADMIN");
 A.equal(run('live("ventas").length'),1);const v=run('live("ventas")[0]');A.equal(v.created_by,"OPERADOR");A.equal(v.total,1000);A.equal(v.items[0].price,500,"el precio queda guardado en el ítem");A.equal(exp(),11000)});
t("A' cambiar el precio del producto no cambia ventas ya cargadas",async()=>{const p=run('live("productos")[0]');E.prompt="800";E.ctx.__t={dataset:{ed:p.id}};await run("onClick(__t)");
 A.equal(run('live("productos")[0].price'),800);A.equal(run('live("ventas")[0].total'),1000)});
t("B gasto en efectivo baja la caja",async()=>{E.as("OPERADOR");await E.form("fg",{desc:"x",amount:200,type:"DIRECT",medio:"EFECTIVO",cat:"Insumos",date:t0});A.equal(exp(),10800)});
t("C gasto por transferencia no toca el efectivo",async()=>{const s=saldo();await E.form("fg",{desc:"y",amount:300,type:"INDIRECT",medio:"TRANSFERENCIA",cat:"Insumos",date:t0});A.equal(exp(),10800);A.equal(saldo(),s-300,"sí baja el saldo financiero")});
t("D retiro baja la caja y no cambia el resultado",async()=>{const o=oper(),s=saldo();await E.form("fr",{person:"p",amount:100,medio:"EFECTIVO",date:t0});A.equal(exp(),10700);A.equal(oper(),o);A.equal(saldo(),s-100);A.ok(!run('live("gastos").some(g=>g.person)'),"no se guarda como gasto")});
t("E combustible estimado: cambia el resultado, no el efectivo ni el saldo",async()=>{const o=oper(),e=exp(),s=saldo();await E.form("ff",{ini:1000,dest:1040,ret:1100,date:t0});
 const v=run('live("viajes")[0]');A.deepEqual([v.km,v.l,v.cost,v.consumo,v.precio],[100,10,10000,0.1,1000],"km=vuelta−inicio, l=km×consumo, costo=l×precio, guardados en el viaje");
 const g=run('live("gastos").find(g=>g.estimated)');A.equal(g.type,"INDIRECT");A.equal(g.medio,"ESTIMADO");A.equal(g.trip,v.id);
 A.equal(oper(),o-10000);A.equal(exp(),e);A.equal(saldo(),s);
 await E.form("ff",{ini:1100,dest:1050,ret:1200,date:t0});A.match(E.last(),/Kilometraje inválido/)});
t("H compra suma stock y baja caja/banco según medio",async()=>{E.as("ADMIN");await E.form("fi",{name:"Harina",unit:"kg",stock0:0,min:20,cost:"",supplier:""});E.as("OPERADOR");const it=run('live("inventario")[0].id'),e=exp(),s=saldo(),o=oper();
 await E.form("fcmp",{item:it,qty:10,amount:1000,medio:"EFECTIVO",desc:"h",cat:"Insumos",date:t0});A.equal(run('stockOf(live("inventario")[0])'),10);A.equal(exp(),e-1000);A.equal(saldo(),s-1000);A.equal(oper(),o,"la compra no es costo consumido");
 await E.form("fcmp",{item:it,qty:5,amount:500,medio:"TRANSFERENCIA",desc:"h",cat:"Insumos",date:t0});A.equal(exp(),e-1000);A.equal(saldo(),s-1500);A.equal(run('stockOf(live("inventario")[0])'),15);
 A.ok(run('alerts(proj())').includes("Stock bajo: Harina"))});
t("Validaciones: importes ≤ 0, fechas inválidas o futuras, venta vacía",async()=>{E.as("OPERADOR");const n0=run('D.gastos.length');
 for(const[f,d,m]of[["fg",{desc:"x",amount:0,type:"DIRECT",medio:"EFECTIVO",date:t0},/mayor a 0/],["fg",{desc:"x",amount:-5,type:"DIRECT",medio:"EFECTIVO",date:t0},/mayor a 0/],["fr",{person:"p",amount:"",medio:"EFECTIVO",date:t0},/mayor a 0/],
  ["fcmp",{item:"x",qty:1,amount:0,medio:"EFECTIVO",desc:"h",date:t0},/mayor a 0/],["fg",{desc:"x",amount:5,type:"DIRECT",medio:"EFECTIVO",date:"2026-02-30"},/Fecha inválida/],["fg",{desc:"x",amount:5,type:"DIRECT",medio:"EFECTIVO",date:"hoy"},/Fecha inválida/],
  ["fg",{desc:"x",amount:5,type:"DIRECT",medio:"EFECTIVO",date:run(`addDays("${t0}",1)`)},/futura/],["fv",{medio:"EFECTIVO",date:t0},/al menos un producto/],["fg",{desc:"x",amount:5,type:"DIRECT",medio:"ESTIMADO",date:t0},/medio de pago/],
  ["fa",{open:5},/ya fue abierta/],["fc",{counted:-1},/contado inválido/],["fp",{desc:"x",amount:5,kind:"GASTO",freq:"ONCE",date:t0},/Solo un ADMIN/]]){await E.form(f,d);A.match(E.last(),m,f+" "+JSON.stringify(d))}
 A.equal(run('D.gastos.length'),n0,"nada inválido se guardó")});
t("F arqueo cerrado + venta modificada → REQUIERE REVISIÓN; solo ADMIN recalcula",async()=>{E.as("OPERADOR");const e=exp();await E.form("fc",{counted:e,notes:""});const c=()=>run('live("cierres")[0]');
 A.equal(c().expected,e);A.equal(run('st(live("cierres")[0])'),"OK");A.equal(run('canDel("ventas",live("ventas")[0])'),false);
 const pid=run('live("productos")[0].id');await E.form("fv",{["q_"+pid]:1,medio:"EFECTIVO",date:t0});A.match(E.last(),/día ya está cerrado/);
 A.equal(await run(`recalc("${t0}")`),false,"OPERADOR no recalcula");
 await tick();E.as("ADMIN");await run('del("ventas",live("ventas")[0].id)');
 A.equal(run('st(live("cierres")[0])'),"REQUIERE REVISIÓN");A.equal(c().expected,e,"no se pisa el esperado al cierre");A.ok(run('alerts(proj())').includes("REQUIERE REVISIÓN"));
 A.equal(await run(`recalc("${t0}")`),true);A.equal(run('st(live("cierres")[0])'),"OK");A.equal(c().expected,e);A.equal(c().expected_rev,e-1000);A.equal(run('eff(live("cierres")[0])'),e-1000);
 await tick();await E.form("fv",{["q_"+pid]:1,medio:"TRANSFERENCIA",date:t0});A.equal(exp(),e-1000,"transferencia no cambia el efectivo");
 A.equal(run('st(live("cierres")[0])'),"REQUIERE REVISIÓN","pero cambió un movimiento del día → revisión");
 E.as("OPERADOR");await A.rejects(run(`db.collection("cierres").doc("${t0}").update({recalc:true})`),{code:"not_granted"})});
t("G dos aperturas simultáneas: solo una",async()=>{E.as("OPERADOR");const r=await Promise.all([1,2].map(()=>run('claim("aperturas","2099-01-01",{id:"2099-01-01",date:"2099-01-01",open:1})')));A.deepEqual(r.sort(),[false,true]);
 Object.keys(E.leases).forEach(k=>delete E.leases[k]);A.equal(await run('claim("aperturas","2099-01-01",{id:"x",date:"2099-01-01",open:9})'),false);A.equal(run('D.aperturas.find(a=>a.date=="2099-01-01").open'),1)});
t("I OPERADOR no puede modificar configuración, productos, stock ni compromisos",async()=>{E.as("OPERADOR");
 for(const c of["config","productos","inventario","futuros","revisiones"])await A.rejects(run(`db.collection("${c}").doc("z").set({a:1})`),{code:"not_granted"});
 const before=JSON.stringify(E.store.config);await E.form("fcfg",{consumo:9,precio:9,capital:9,medios:"X",cats:"Y"});A.match(E.last(),/Solo un ADMIN/);A.equal(JSON.stringify(E.store.config),before);
 await E.form("fprod",{name:"X",price:1});A.match(E.last(),/Solo un ADMIN/);A.match(run("V.cfg()"),/Solo ADMIN/);
 run("render()");A.ok(!run('$("#nav").innerHTML').includes('data-t="cfg"'),"el menú no muestra Config");A.ok(!run("V.proy()").includes('id="fp"'));
 A.ok(!run("V.proy()").includes("data-del"),"no ve botones de borrar compromisos");E.as("ADMIN");run("render()");A.ok(run('$("#nav").innerHTML').includes('data-t="cfg"'))});
t("Retiros planificados separados del saldo operativo; capital incluido",async()=>{E.as("ADMIN");await E.form("fp",{desc:"r",amount:500,kind:"RETIRO",freq:"ONCE",date:run(`addDays("${t0}",2)`)});
 const w=run("proj()[0]");A.equal(w.ret,500);A.equal(w.saldo,w.so-500);A.equal(w.ini,saldo());A.equal(w.inc,0,"sin 7 días de historial no hay ingresos proyectados");A.equal(w.comb,0)});
t("Sin conexión: solo lectura, no se carga nada",async()=>{run("setRO(true)");const n0=run("D.retiros.length");await E.form("fr",{person:"p",amount:5,medio:"EFECTIVO",date:t0});A.match(E.last(),/Sin conexión: no se pueden cargar movimientos/);
 A.equal(run("D.retiros.length"),n0);A.equal(run('canDel("ventas",live("ventas")[0])'),false);A.match(run('$("#ban").innerHTML'),/Sin conexión: no se pueden cargar movimientos/);run("setRO(false)")});
t("Doble toque en Guardar: una sola venta",async()=>{E.as("ADMIN");const pid=run('live("productos")[0].id'),n0=run("D.ventas.length");E.ctx.__f={id:"fv",dataset:{},reset(){},elements:[{name:"q_"+pid,value:"1"},{name:"medio",value:"EFECTIVO"},{name:"date",value:t0}]};
 await Promise.all([run("onSubmit(__f)"),run("onSubmit(__f)")]);A.equal(run("D.ventas.length"),n0+1)});

// ── Pruebas aisladas ──
t("Hoy = fecha de Mendoza (no la del dispositivo)",async()=>{const r=mk().run;A.equal(r('today(new Date("2026-10-05T02:00:00Z"))'),"2026-10-04");A.equal(r('today(new Date("2026-10-05T03:00:00Z"))'),"2026-10-05");A.equal(r('today(new Date("2026-12-31T23:30:00-03:00"))'),"2026-12-31")});
t("Datos inválidos se ignoran y se avisan; la proyección no inventa ingresos",async()=>{const e=mk(),r=e.run;r('D.gastos.push({id:"bad",date:"2026-01-01",amount:-5,type:"DIRECT"});D.ventas.push({id:"v",date:"2026-01-01",total:999,medio:"EFECTIVO",items:[{qty:1,price:5}]})');
 A.ok(!r('live("gastos").some(g=>g.id=="bad")'));A.equal(r('live("ventas").length'),0,"total que no coincide con los ítems");A.match(r("alerts(proj())"),/2 registro\(s\) inválido/);A.equal(r("proj()[0].inc"),0)});
t("Proyección: promedio por día de la semana con 7+ días; pagos semanales/mensuales",async()=>{const e=mk(),r=e.run,t=r("today()");e.as("ADMIN");
 for(let i=1;i<=14;i++)r(`D.ventas.push({id:"v${i}",date:addDays("${t}",-${i}),medio:"EFECTIVO",total:${i<=7?100:300},items:[{qty:1,price:${i<=7?100:300}}]})`);r("touch()");
 const w=r("proj()");A.equal(r("hist().ok"),true);A.equal(w[0].inc,6*200,"6 días futuros de la 1ª semana × promedio (100+300)/2; hoy no se proyecta");A.equal(w[1].inc,7*200);
 await e.form("fcfg",{consumo:0,precio:0,capital:1000,medios:"",cats:""});await e.form("fp",{desc:"sueldo",amount:50,kind:"SUELDO",freq:"WEEKLY",date:t});await e.form("fp",{desc:"alquiler",amount:70,kind:"GASTO",freq:"MONTHLY",date:t});
 const p=r("proj()");A.equal(p[0].sueldos,50);A.equal(p[1].sueldos,50);A.equal(p.reduce((s,x)=>s+x.gastos,0)>=70,true);A.equal(p[0].ini,1000+14*200);
 A.equal(p[0].so,p[0].ini+p[0].inc-p[0].compras-p[0].gastos-p[0].sueldos-p[0].comb);A.equal(p[1].ini,p[0].saldo);
 A.equal(r('occurs({date:"2026-01-31",freq:"MONTHLY"},"2026-02-28")'),true,"mensual del 31 cae el último día de febrero");A.equal(r('nextOcc({date:"2026-01-05",freq:"WEEKLY"},"2026-01-06")'),"2026-01-12")});
t("XSS: textos e ids se escapan",async()=>{const e=mk(),r=e.run;r(`D.productos.push({id:'"><img src=x onerror=alert(1)>',name:"<img src=x onerror=alert(2)>",price:5,active:true});D.inventario.push({id:"i'><b>",name:"<script>x</script>",unit:"<u>",stock0:0,min:1});touch()`);
 for(const v of["venta","cfg","stock","compra","inicio"]){const h=r(`V.${v}()`);A.ok(!/<img|<script|<u>|<b>x|'><b>/.test(h),v+": "+h.match(/.{20}(<img|<script|<u>|'><b>).{20}/))}
 A.equal(r(`esc("<a href='x'>\\"&")`),"&lt;a href=&#39;x&#39;&gt;&quot;&amp;")});
t("J comprobantes: solo con sesión activa y vía URL firmada; tipo y tamaño validados",async()=>{const e=mk(),r=e.run,calls=[];let session=null;
 e.ctx.__sb={auth:{getSession:async()=>({data:{session}})},storage:{from:b=>({createSignedUrl:async(p,s)=>{calls.push([b,p,s]);return{data:{signedUrl:"https://x/firmada?token=1"}}},upload:async()=>({error:null})})}};r("sb=__sb;me='8a7b6c5d-0000-4000-8000-000000000000'");
 const p="8a7b6c5d-0000-4000-8000-000000000000/1b2c3d4e-0000-4000-8000-000000000000.pdf";
 await A.rejects(r(`receiptUrl("${p}")`),/Iniciá sesión/);A.equal(calls.length,0);
 session={user:{}};await A.rejects(r('receiptUrl("../otro/archivo.html")'),/inválido/);
 A.equal(await r(`receiptUrl("${p}")`),"https://x/firmada?token=1");A.deepEqual(calls[0],["comprobantes",p,60]);
 A.ok(!/getPublicUrl/.test(code),"nunca URL pública");
 await A.rejects(r('up({size:6e6,type:"image/png"})'),/5 MB/);await A.rejects(r('up({size:10,type:"text/html"})'),/JPG, PNG o PDF/);A.match(await r('up({size:10,type:"image/jpeg"})'),/^8a7b6c5d-.*\/[0-9a-f-]{36}\.jpg$/)});
t("Exportar: CSV con BOM, ';', DD/MM/YYYY, coma decimal, filtro de período, sin fórmulas",async()=>{const e=mk(),r=e.run,t=r("today()");e.as("ADMIN");
 r(`D.ventas.push({id:"v1",date:"${t}",medio:"EFECTIVO",total:1500.5,items:[{name:"=SUMA(A1)",qty:1,price:1500.5}]},{id:"v2",date:"2020-01-01",medio:"QR",total:7,items:[{name:"Viejo",qty:1,price:7}]});
  D.gastos.push({id:"g",date:"${t}",type:"INDIRECT",medio:"ESTIMADO",estimated:true,amount:10,desc:"Combustible estimado"});touch()`);
 r('per={p:"dia"}');const R=r("range()"),csv=r(`exportCSV("ventas",range())`);A.equal(csv.charCodeAt(0),0xfeff);
 const lines=csv.slice(1).split("\r\n");A.equal(lines.length,2,"solo el día elegido");A.match(lines[0],/^"Fecha";"Venta";"Producto"/);A.match(lines[1],new RegExp("^"+t.split("-").reverse().join("/")+";"));A.match(lines[1],/;1500,5;/);A.match(lines[1],/"'=SUMA\(A1\)"/);
 r('per={p:"custom",from:"2020-01-01",to:"2020-01-31"}');A.match(r(`exportCSV("ventas",range())`),/Viejo/);r('per={p:"mes"}');A.equal(r("range()")[0],t.slice(0,8)+"01");r('per={p:"semana"}');A.equal(r("dow(range()[0])"),1,"semana de lunes a domingo");
 r('per={p:"dia"}');const all=r(`exportCSV("todos",range())`);for(const s of["Ventas","Gastos","Retiros","Compras","Caja","Arqueos","Combustible","Proyección","Resultado"])A.ok(all.includes(`"${s}"`),s);
 A.match(r(`exportCSV("resultado",range())`),/"Resultado operativo";1490,5/);
 const sheets=[];e.ctx.window={XLSX:{utils:{book_new:()=>({}),aoa_to_sheet:(a,o)=>({a,o}),book_append_sheet:(wb,ws,n)=>sheets.push([n,ws])},writeFile:(wb,n)=>sheets.file=n}};r("var window=globalThis.window");
 await r(`exportXLSX("todos",range())`);A.equal(sheets.length,9);A.equal(Object.prototype.toString.call(sheets[0][1].a[1][0]),"[object Date]","fechas como fecha de Excel");A.equal(sheets[0][1].o.dateNF,"dd/mm/yyyy");A.match(sheets.file,/\.xlsx$/)});
t("Respaldo JSON (solo ADMIN) incluye anulados",async()=>{const e=mk(),r=e.run;r('D.ventas.push({id:"x",deleted:true,date:"2026-01-01"});touch()');const j=JSON.parse(r("backup()"));A.ok(j.records.some(x=>x.id=="x"&&x.deleted));
 e.as("OPERADOR");r('tab="rep"');A.ok(!r("V.rep()").includes("data-backup"));e.as("ADMIN");A.ok(r("V.rep()").includes("data-backup"))});
t("Paginación: trae todo aunque el servidor corte en 1000 o menos filas",async()=>{for(const cap of[1000,500]){const e=mk(),r=e.run,rows=Array.from({length:2345},(_,i)=>({kind:"ventas",id:"v"+i,date:"2026-01-01",data:{},created_at:String(i).padStart(6,"0")}));
 const q={select(){return q},order(){return q},range(a,b){const d=rows.slice(a,Math.min(b+1,a+cap));return Promise.resolve({data:d,error:null})}};e.ctx.__sb={from:()=>q};r("sb=__sb");A.equal((await r("fetchAll()")).length,2345)}});
t("Seguridad: sin claves secretas en el repo; config.js fuera de git",async()=>{const files=cp.execSync("git ls-files",{cwd:__dirname}).toString().split("\n").filter(f=>f&&fs.existsSync(path.join(__dirname,f)));
 for(const f of files){const s=fs.readFileSync(path.join(__dirname,f),"utf8");A.ok(!/sb_secret_[A-Za-z0-9]/.test(s),f);for(const m of s.match(/eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/g)||[]){A.notEqual(JSON.parse(Buffer.from(m.split(".")[1],"base64")).role,"service_role",f)}}
 A.ok(!files.includes("config.js"));A.match(fs.readFileSync(path.join(__dirname,".gitignore"),"utf8"),/^config\.js$/m);
 const e=mk();A.equal(e.run(`jwtRole("x."+btoa(JSON.stringify({role:"service_role"}))+".y")`),"service_role")});

(async()=>{let f=0;for(const[n,fn]of T){try{await fn();console.log("✔",n)}catch(e){f++;console.log("✘",n,"\n  ",e.message)}}console.log(f?`${f} FALLAN`:`TODOS OK (${T.length})`);process.exit(f?1:0)})();
