const {chromium}=require('playwright');const fs=require('fs');const path=require('path');const assert=require('assert/strict');const root=path.resolve(__dirname,'..');
(async()=>{
 const browser=await chromium.launch({headless:true,executablePath:'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'});
 try{
 const page=await browser.newPage({viewport:{width:900,height:600}});
 await page.addInitScript(()=>{window.violations=[];document.addEventListener('securitypolicyviolation',e=>violations.push([e.violatedDirective,e.blockedURI]));window.originalInsert=CSSStyleSheet.prototype.insertRule;window.sheetEvents=0;document.addEventListener('__darkreader__updateSheet',()=>sheetEvents++,true)});
 await page.route('https://assets.focus-dark.test/**',r=>r.fulfill({status:404,body:''}));
 await page.route('https://focus-dark.test/**',r=>{
  if(r.request().url().endsWith('proxy.js'))return r.fulfill({contentType:'text/javascript',body:fs.readFileSync(path.resolve(root,'vendor/darkreader-proxy.js'),'utf8')});
  return r.fulfill({contentType:'text/html',headers:{'Content-Security-Policy':"script-src 'self'; style-src 'self' 'unsafe-inline'; img-src * data: blob:"},body:'<html><head><style>html,body{background:white;color:#111;margin:0;min-height:100%;font:20px system-ui}.dark,.dark body{background:#171719;color:#eee}.card{padding:32px;background-image:url(https://assets.focus-dark.test/missing.gif)}</style></head><body><h1>Strict security policy</h1><div class="card">Text and original image fallback</div></body></html>'});
 });
 await page.goto('https://focus-dark.test/test');
 const cdp=await page.context().newCDPSession(page);await cdp.send('Page.enable');
 const {frameTree}=await cdp.send('Page.getFrameTree');
 const {executionContextId}=await cdp.send('Page.createIsolatedWorld',{frameId:frameTree.frame.id,worldName:'focus-extension-test'});
 const errors=[];await cdp.send('Runtime.enable');cdp.on('Runtime.consoleAPICalled',e=>{if(e.executionContextId===executionContextId&&e.type==='error')errors.push(e.args.map(a=>a.description||a.value).join(' '))});
 const run=async expression=>{const r=await cdp.send('Runtime.evaluate',{expression,contextId:executionContextId,returnByValue:true,awaitPromise:true});if(r.exceptionDetails)throw Error(r.exceptionDetails.text+JSON.stringify(r.exceptionDetails.exception));return r.result.value};
 await run(`window.store={dark:{mode:'always',from:1140,to:420,brightness:100,contrast:100},darkNight:true,darkSites:{}};
 window.storageListeners=[];window.runtimeListeners=[];window.requests=[];
 window.chrome={runtime:{sendMessage:async m=>{requests.push(m);if(m.type==='darkConfig')return {invert:[],css:'',ignoreInlineStyle:[],ignoreImageAnalysis:[],ignoreCSSUrl:[]};if(m.type==='darkFetch')return {ok:false};return{}},onMessage:{addListener:fn=>runtimeListeners.push(fn)}},storage:{local:{get:async keys=>Object.fromEntries(keys.map(k=>[k,store[k]]))},onChanged:{addListener:fn=>storageListeners.push(fn)}}};
 window.patchDark=async mode=>{store.dark.mode=mode;for(const fn of storageListeners)fn({dark:{newValue:store.dark}},'local')};
 window.darkStatus=()=>{let value;for(const fn of runtimeListeners)fn({type:'darkStatus'},{},r=>value=r);return value};`);
 for(const file of ['dark-pre.js','vendor/darkreader.js','dark.js'])await run(fs.readFileSync(path.resolve(root,file),'utf8'));
 await page.addScriptTag({url:'https://focus-dark.test/proxy.js'});
 const until=async(fn,label)=>{for(let n=0;n<100;n++){if(await fn())return;await new Promise(r=>setTimeout(r,20))}throw Error('Timed out: '+label)};
 await until(()=>run("DarkReader.isEnabled() && darkStatus().status==='on'"),'initial engine');
 await page.waitForFunction(()=>getComputedStyle(document.body).backgroundColor!=='rgb(255, 255, 255)');
 assert.equal(await page.evaluate(()=>CSSStyleSheet.prototype.insertRule!==originalInsert),true);
 await page.evaluate(()=>document.styleSheets[0].insertRule('.card { background-color: rgb(200, 225, 250); color: #111; }', document.styleSheets[0].cssRules.length));
 await until(()=>page.evaluate(()=>sheetEvents>0),'CSSOM event');
 await run("patchDark('off')");await until(()=>run("!DarkReader.isEnabled() && darkStatus().status==='off'"),'Off');
 assert.equal(await page.evaluate(()=>CSSStyleSheet.prototype.insertRule===originalInsert),true);
 await run("patchDark('always')");await until(()=>run("DarkReader.isEnabled() && darkStatus().status==='on'"),'Always again');
 assert.equal(await page.evaluate(()=>CSSStyleSheet.prototype.insertRule!==originalInsert),true);
 await page.evaluate(()=>{const sheet=document.styleSheets[0];sheet.deleteRule(sheet.cssRules.length-1);document.documentElement.classList.add('dark')});await until(()=>run("!DarkReader.isEnabled() && darkStatus().status==='native'"),'native theme');
 await page.evaluate(()=>document.documentElement.classList.remove('dark'));await until(()=>run("DarkReader.isEnabled() && darkStatus().status==='on'"),'native light');
 await run("chrome.runtime.sendMessage({type:'cs-bg-fetch',id:9999,data:{url:'https://assets.focus-dark.test/missing.gif',responseType:'data-url'}})");
 await until(()=>run("requests.some(r=>r.type==='darkFetch')"),'optional image lookup');
 const css=await run('DarkReader.exportGeneratedCSS()');console.log('Generated styles',css.length,'image URL present',css.includes('https://assets.focus-dark.test/missing.gif'));assert.ok(css.includes('https://assets.focus-dark.test/missing.gif'));
 assert.deepEqual(await page.evaluate(()=>violations),[]);assert.deepEqual(errors,[]);
 console.log('PASS strict CSP + separate worlds: zero policy violations/extension console errors; CSSOM helper active, restores on Off, reactivates on Always; original missing-image URL preserved; native theme toggles work.');
 fs.mkdirSync(path.resolve(root,'../.shots/dark-pages-sync'),{recursive:true});await page.screenshot({path:path.resolve(root,'../.shots/dark-pages-sync/strict-csp.png')});
 }finally{await browser.close()}
})().catch(e=>{console.error(e);process.exit(1)});
