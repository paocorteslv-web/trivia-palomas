// Service worker: guarda la INTERFAZ para abrir sin conexión. Nunca guarda llamadas a Supabase (datos, login, comprobantes).
const V="carrito-v1";
const SHELL=["./carrito-supabase.html","./manifest.webmanifest","./config.js","./icons/icon-192.png","./icons/icon-512.png","./icons/maskable-192.png","./icons/maskable-512.png"];
const CDN=["https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.45.4/dist/umd/supabase.min.js"];   // versiones fijas: inmutables
self.addEventListener("install",e=>e.waitUntil(caches.open(V).then(c=>Promise.allSettled([...SHELL,...CDN].map(u=>c.add(u)))).then(()=>self.skipWaiting())));
self.addEventListener("activate",e=>e.waitUntil(caches.keys().then(ks=>Promise.all(ks.filter(k=>k!=V).map(k=>caches.delete(k)))).then(()=>self.clients.claim())));
self.addEventListener("fetch",e=>{const r=e.request,u=new URL(r.url);if(r.method!="GET")return;
 // librerías de jsDelivr con versión fija (supabase-js, SheetJS): primero caché
 if(u.hostname=="cdn.jsdelivr.net"&&/@\d+\.\d+\.\d+\//.test(u.pathname))return e.respondWith(caches.match(r).then(m=>m||fetch(r).then(res=>{if(res.ok){const c=res.clone();caches.open(V).then(x=>x.put(r,c))}return res})));
 if(u.origin!=location.origin)return;   // Supabase y todo lo demás: directo a la red
 const p="./"+u.pathname.slice(new URL(self.registration.scope).pathname.length);
 if(!SHELL.includes(p))return;   // otras páginas del mismo sitio no se tocan
 // interfaz y config: primero red (para recibir actualizaciones), si no hay conexión, la copia guardada
 e.respondWith(fetch(r).then(res=>{if(res.ok){const c=res.clone();caches.open(V).then(x=>x.put(p,c))}return res}).catch(()=>caches.match(p)))});
