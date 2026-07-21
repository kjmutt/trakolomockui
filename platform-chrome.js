/* Shared platform chrome: notification bell + logged-in profile menu.
   Injected into the Trakolo-staff platform console (tenant workspaces, services, plans). */
(function(){
  var topRight = document.querySelector('.platform-header .top-right');
  if(!topRight) return;

  var NOTIFS = [
    {icon:'⚠', cls:'crit', title:'Acme Corp — email ingestion service degraded', sub:'Retry queue backing up · 2nd occurrence this week', href:'saas-admin-services.html', time:'8m'},
    {icon:'💳', cls:'warn', title:'Globex Inc — payment failed on renewal', sub:'Business plan · retry scheduled in 24h', href:'saas-admin-plans.html', time:'1h'},
    {icon:'✓', cls:'ok', title:'New tenant provisioned — Initech LLC', sub:'Team plan · 12 seats · onboarding email sent', href:'saas-admin-console.html', time:'5h'}
  ];

  var name = 'T. Reyes';
  var initials = 'TR';
  var signOutHref = 'saas-admin-login.html';
  var existing = topRight.querySelector('a');
  if(existing) signOutHref = existing.getAttribute('href') || signOutHref;

  topRight.innerHTML =
    '<button class="chrome-btn chrome-bell" id="plat-chrome-bell" title="Notifications">🔔<span class="chrome-badge" id="plat-chrome-badge">' + NOTIFS.length + '</span></button>' +
    '<button class="avatar" id="plat-chrome-avatar" style="border:none;cursor:pointer;width:34px;height:34px;font-size:12.5px;" title="Account">' + initials + '</button>';

  var root = document.createElement('div');
  root.innerHTML =
    '<div class="chrome-scrim" id="plat-chrome-scrim"></div>' +
    '<div class="chrome-pop" id="plat-chrome-notifs">' +
      '<div class="chrome-pop-head"><span>Platform alerts</span><button class="btn sm" id="plat-chrome-readall">Mark all read</button></div>' +
      NOTIFS.map(function(n){ return '<a class="chrome-notif" href="' + n.href + '"><span class="chrome-nicon ' + n.cls + '">' + n.icon + '</span><span><span class="cn-title">' + n.title + '</span><span class="cn-sub">' + n.sub + '</span></span><span class="cn-time">' + n.time + '</span></a>'; }).join('') +
    '</div>' +
    '<div class="chrome-pop" id="plat-chrome-menu">' +
      '<div class="chrome-menu-id"><span class="avatar" style="width:34px;height:34px;">' + initials + '</span><span><b>' + name + '</b><span class="cn-sub">Platform operations · Trakolo staff</span></span></div>' +
      '<a class="chrome-menu-item" href="saas-admin-console.html">🏢 Tenant workspaces</a>' +
      '<a class="chrome-menu-item" href="saas-admin-services.html">⚙ Platform services</a>' +
      '<a class="chrome-menu-item" href="saas-admin-plans.html">💳 Plans &amp; entitlements</a>' +
      '<a class="chrome-menu-item" href="' + signOutHref + '">→ Sign out</a>' +
    '</div>';
  document.body.appendChild(root);

  var scrim = document.getElementById('plat-chrome-scrim');
  var notifs = document.getElementById('plat-chrome-notifs');
  var menu = document.getElementById('plat-chrome-menu');

  function closeAll(){ [notifs, menu].forEach(function(p){ p.classList.remove('open'); }); scrim.classList.remove('open'); }
  function openPop(p, anchor){
    var wasOpen = p.classList.contains('open');
    closeAll();
    if(wasOpen) return;
    p.classList.add('open'); scrim.classList.add('open');
    var r = anchor.getBoundingClientRect();
    p.style.top = (r.bottom + 8) + 'px';
    p.style.right = Math.max(12, window.innerWidth - r.right) + 'px';
  }

  document.getElementById('plat-chrome-bell').addEventListener('click', function(e){ openPop(notifs, e.currentTarget); });
  document.getElementById('plat-chrome-avatar').addEventListener('click', function(e){ openPop(menu, e.currentTarget); });
  scrim.addEventListener('click', closeAll);
  document.getElementById('plat-chrome-readall').addEventListener('click', function(){
    document.getElementById('plat-chrome-badge').style.display = 'none';
    notifs.querySelectorAll('.chrome-notif').forEach(function(n){ n.style.opacity = .55; });
  });
  document.addEventListener('keydown', function(e){ if(e.key === 'Escape') closeAll(); });
})();
