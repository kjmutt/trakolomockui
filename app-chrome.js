/* Shared app chrome: global search (Cmd/Ctrl+K), notification bell, avatar menu.
   Injected into every app page's topbar; portal & platform pages don't load this. */
(function(){
  var topRight = document.querySelector('.topbar .top-right');
  if(!topRight) return;

  var SEARCH_INDEX = [
    {label:'TS-4833 · Password reset — locked out after new phone', sub:'Ticket · Resolved by AI', href:'desk.html', tag:'ticket'},
    {label:'TS-4821 · VPN drops on hybrid laptops', sub:'Ticket · Urgent · 18m left', href:'desk.html', tag:'ticket'},
    {label:'TS-4819 · Shared drive permissions for Finance', sub:'Ticket · High', href:'desk.html', tag:'ticket'},
    {label:'TS-4816 · Escalation: payroll SSO outage', sub:'Ticket · Escalated to L3', href:'desk.html', tag:'ticket'},
    {label:'TS-4812 · New starter laptop provisioning', sub:'Ticket · Unassigned', href:'desk.html', tag:'ticket'},
    {label:'CR-0091 · Promote bulk asset reassignment tool', sub:'Change request · Approved · deploys Jul 20', href:'desk.html', tag:'change'},
    {label:'CR-0092 · Promote asset query optimization', sub:'Change request · Pending approval', href:'desk-approvals.html', tag:'change'},
    {label:'PRB-0007 · VPN drops after AP firmware update', sub:'Problem · workaround posted · 12 incidents', href:'desk-problems.html', tag:'problem'},
    {label:'KB-0041 · Fix VPN drops when moving between floors', sub:'Knowledge base article', href:'desk-kb.html', tag:'article'},
    {label:'DEV-1058 · Bulk asset reassignment tool', sub:'Sprint card · Done · Sprint 34', href:'dev.html', tag:'card'},
    {label:'DEV-1063 · Optimize asset list query performance', sub:'Sprint card · awaiting CR-0092', href:'dev.html', tag:'card'},
    {label:'DEV-1031 · Escalation routing for L2 → L3 handoff', sub:'Sprint card · In progress', href:'dev.html', tag:'card'},
    {label:'HW-00417 · MacBook Pro 14" M4', sub:'Asset · D. Ferreira', href:'sam.html', tag:'asset'},
    {label:'HW-00392 · Dell Latitude 5440', sub:'Asset · In repair', href:'sam.html', tag:'asset'},
    {label:'SW-01188 · Figma — Full seat', sub:'Asset · Idle 40d, reclaim suggested', href:'sam.html', tag:'asset'},
    {label:'Service desk', sub:'Page · queue & tickets', href:'desk.html', tag:'page'},
    {label:'Service catalog', sub:'Page · structured requests', href:'desk-catalog.html', tag:'page'},
    {label:'Team workload', sub:'Page · drag to assign, pair, or claim', href:'desk-workload.html', tag:'page'},
    {label:'Approvals', sub:'Page · waiting on you', href:'desk-approvals.html', tag:'page'},
    {label:'Problems', sub:'Page · problem management', href:'desk-problems.html', tag:'page'},
    {label:'Knowledge base', sub:'Page · articles & deflection', href:'desk-kb.html', tag:'page'},
    {label:'On-call', sub:'Page · rota & paging', href:'desk-oncall.html', tag:'page'},
    {label:'Asset inventory', sub:'Page · SAM', href:'sam.html', tag:'page'},
    {label:'Bulk upload assets', sub:'Page · CSV import', href:'sam-bulk-upload.html', tag:'page'},
    {label:'Asset discovery', sub:'Page · agent & network scan', href:'sam-discovery.html', tag:'page'},
    {label:'Sprint board', sub:'Page · Sprint 34', href:'dev.html', tag:'page'},
    {label:'Epics & roadmap', sub:'Page · quarter view', href:'dev-roadmap.html', tag:'page'},
    {label:'Gantt', sub:'Page · sprint timeline with milestones', href:'dev-gantt.html', tag:'page'},
    {label:'Reports', sub:'Page · P1s, incidents, CSAT, velocity', href:'ops.html', tag:'page'},
    {label:'Admin settings', sub:'Page · config, license, audit log', href:'admin.html', tag:'page'},
    {label:'Data migration', sub:'Page · import from Jira, ServiceNow…', href:'data-migration.html', tag:'page'},
    {label:'Azure AD onboarding', sub:'Page · new starter automation', href:'azure-onboarding.html', tag:'page'},
    {label:'My day', sub:'Page · your dashboard', href:'home.html', tag:'page'},
    {label:'My profile', sub:'Page · personal preferences', href:'profile.html', tag:'page'},
    {label:'Site map', sub:'Page · every page as a list', href:'sitemap.html', tag:'page'}
  ];

  var NOTIFS = [
    {icon:'✓', cls:'warn', title:'CR-0092 is waiting on your approval', sub:'Change request · window Jul 22, 03:00 UTC · requested by Tomas K.', href:'desk-approvals.html', time:'2h'},
    {icon:'⏱', cls:'crit', title:'TS-4821 breaches SLA in 18 minutes', sub:'Urgent · VPN drops on hybrid laptops · assigned to Raj K.', href:'desk.html', time:'12m'},
    {icon:'☎', cls:'info', title:'You are on-call L3 next week', sub:'Jul 21 – 27 · covers the CR-0092 deploy window', href:'desk-oncall.html', time:'1d'}
  ];

  /* ---- inject topbar controls ---- */
  var avatarEl = topRight.querySelector('.avatar');
  var initials = avatarEl ? avatarEl.textContent.trim() : 'EM';
  topRight.innerHTML =
    '<button class="chrome-btn" id="chrome-search-btn" title="Search (Ctrl+K)">⌕ <span class="chrome-kbd">Ctrl K</span></button>' +
    '<button class="chrome-btn chrome-bell" id="chrome-bell" title="Notifications">🔔<span class="chrome-badge" id="chrome-badge">' + NOTIFS.length + '</span></button>' +
    '<button class="avatar" id="chrome-avatar" style="border:none;cursor:pointer;" title="Account">' + initials + '</button>';

  /* ---- overlays ---- */
  var root = document.createElement('div');
  root.innerHTML =
    '<div class="chrome-scrim" id="chrome-scrim"></div>' +
    '<div class="chrome-search" id="chrome-search" role="dialog" aria-label="Search">' +
      '<input type="text" id="chrome-search-input" placeholder="Search tickets, assets, cards, articles, pages…" autocomplete="off">' +
      '<div class="chrome-results" id="chrome-results"></div>' +
      '<div class="chrome-search-foot">Enter opens the first result · Esc closes</div>' +
    '</div>' +
    '<div class="chrome-pop" id="chrome-notifs">' +
      '<div class="chrome-pop-head"><span>Notifications</span><button class="btn sm" id="chrome-readall">Mark all read</button></div>' +
      NOTIFS.map(function(n){ return '<a class="chrome-notif" href="' + n.href + '"><span class="chrome-nicon ' + n.cls + '">' + n.icon + '</span><span><span class="cn-title">' + n.title + '</span><span class="cn-sub">' + n.sub + '</span></span><span class="cn-time">' + n.time + '</span></a>'; }).join('') +
    '</div>' +
    '<div class="chrome-pop" id="chrome-menu">' +
      '<div class="chrome-menu-id"><span class="avatar" style="width:34px;height:34px;">' + initials + '</span><span><b>E. Moreau</b><span class="cn-sub">Workspace admin · Acme Corp</span></span></div>' +
      '<a class="chrome-menu-item" href="home.html">▤ My day</a>' +
      '<a class="chrome-menu-item" href="profile.html">☺ My profile &amp; preferences</a>' +
      '<a class="chrome-menu-item" href="desk-approvals.html">✓ My approvals</a>' +
      '<a class="chrome-menu-item" href="admin.html">⚙ Admin settings</a>' +
      '<a class="chrome-menu-item" href="login.html">→ Sign out</a>' +
    '</div>';
  document.body.appendChild(root);

  var scrim = document.getElementById('chrome-scrim');
  var search = document.getElementById('chrome-search');
  var input = document.getElementById('chrome-search-input');
  var results = document.getElementById('chrome-results');
  var notifs = document.getElementById('chrome-notifs');
  var menu = document.getElementById('chrome-menu');

  function closeAll(){ [search, notifs, menu].forEach(function(p){ p.classList.remove('open'); }); scrim.classList.remove('open'); }
  function openPop(p, anchor){
    var wasOpen = p.classList.contains('open');
    closeAll();
    if(wasOpen) return;
    p.classList.add('open'); scrim.classList.add('open');
    if(anchor && p !== search){
      var r = anchor.getBoundingClientRect();
      p.style.top = (r.bottom + 8) + 'px';
      p.style.right = Math.max(12, window.innerWidth - r.right) + 'px';
    }
    if(p === search){ input.value=''; renderResults(''); setTimeout(function(){ input.focus(); }, 30); }
  }

  function renderResults(q){
    q = q.trim().toLowerCase();
    var hits = SEARCH_INDEX.filter(function(e){ return !q || (e.label + ' ' + e.sub).toLowerCase().indexOf(q) !== -1; }).slice(0, 9);
    results.innerHTML = hits.length
      ? hits.map(function(e){ return '<a class="chrome-result" href="' + e.href + '"><span class="cr-tag">' + e.tag + '</span><span><span class="cn-title">' + e.label + '</span><span class="cn-sub">' + e.sub + '</span></span></a>'; }).join('')
      : '<div class="chrome-empty">No matches — try a ticket ID, asset tag, or page name.</div>';
  }

  document.getElementById('chrome-search-btn').addEventListener('click', function(){ openPop(search); });
  document.getElementById('chrome-bell').addEventListener('click', function(e){ openPop(notifs, e.currentTarget); });
  document.getElementById('chrome-avatar').addEventListener('click', function(e){ openPop(menu, e.currentTarget); });
  scrim.addEventListener('click', closeAll);
  input.addEventListener('input', function(){ renderResults(input.value); });
  input.addEventListener('keydown', function(e){
    if(e.key === 'Enter'){ var first = results.querySelector('a.chrome-result'); if(first) location.href = first.getAttribute('href'); }
  });
  document.getElementById('chrome-readall').addEventListener('click', function(){
    document.getElementById('chrome-badge').style.display = 'none';
    notifs.querySelectorAll('.chrome-notif').forEach(function(n){ n.style.opacity = .55; });
  });
  document.addEventListener('keydown', function(e){
    if((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'k'){ e.preventDefault(); openPop(search); }
    if(e.key === 'Escape') closeAll();
  });

  /* ---- vertical icon rail (module switcher) ---- */
  var RAIL_ITEMS = [
    {href:'home.html', label:'Home', icon:'<path d="M2 7.5L8 2.5l6 5"/><path d="M3.5 6.5V13.5H12.5V6.5"/><path d="M6.5 13.5V10h3v3.5"/>'},
    {href:'desk-log-ticket.html', label:'IT', icon:'<path d="M2 5l6-3 6 3-6 3-6-3z"/><path d="M2 5v6l6 3 6-3V5"/>'},
    {href:'sam.html', label:'SAM', icon:'<rect x="2" y="3" width="12" height="8" rx="1"/><path d="M6 13h4M8 11v2"/>'},
    {href:'dev.html', label:'Dev', icon:'<rect x="2" y="2" width="12" height="12" rx="1.5"/><path d="M6 2v12M10.5 5.5v3"/>'},
    {href:'ops.html', label:'Ops', icon:'<path d="M2 4h6M2 8h9M2 12h4"/>'},
    {href:'docs.html', label:'Docs', icon:'<path d="M4 2h6l3 3v9H4z"/><path d="M10 2v3h3"/><path d="M6 9h4M6 11.5h4"/>'},
    {href:'admin.html', label:'Admin', icon:'<circle cx="8" cy="8" r="2.3"/><path d="M8 2v2M8 12v2M2 8h2M12 8h2M3.8 3.8l1.4 1.4M10.8 10.8l1.4 1.4M3.8 12.2l1.4-1.4M10.8 5.2l1.4-1.4"/>'},
    {href:'portal-admin-login.html', label:'Portal', icon:'<rect x="2" y="2" width="12" height="12" rx="2"/><path d="M2 6h12"/>'},
    {href:'profile.html', label:'Profile', icon:'<circle cx="8" cy="5.5" r="2.8"/><path d="M2.5 14c0-2.9 2.5-4.8 5.5-4.8s5.5 1.9 5.5 4.8"/>'}
  ];
  var modNav = document.querySelector('.mod-nav');
  var activeModEl = modNav ? modNav.querySelector('a.active') : null;
  var activeHref = activeModEl ? activeModEl.getAttribute('href') : null;
  var page = location.pathname.split('/').pop();

  var rail = document.createElement('div');
  rail.className = 'icon-rail';
  rail.innerHTML =
    '<a class="rail-brand" href="index.html" title="Trakolo home">' +
      '<svg width="22" height="22" viewBox="0 0 200 200"><rect x="8" y="8" width="184" height="184" rx="40" fill="#DEF6EC" stroke="#0C8266" stroke-width="8"/><path d="M55,150 L100,100 L150,50" fill="none" stroke="#0C8266" stroke-width="15" stroke-linecap="round" stroke-linejoin="round"/><circle cx="55" cy="150" r="18" fill="#5DCAA5" stroke="#0C8266" stroke-width="7"/><circle cx="100" cy="100" r="18" fill="#5DCAA5" stroke="#0C8266" stroke-width="7"/><circle cx="150" cy="50" r="23" fill="#0C8266" stroke="#0C8266" stroke-width="7"/></svg>' +
    '</a>' +
    '<div class="rail-items">' +
    RAIL_ITEMS.map(function(it){
      var active = (it.href === activeHref) || (it.href === page && !activeHref) ? ' active' : '';
      return '<a class="rail-item' + active + '" href="' + it.href + '" title="' + it.label + '">' +
        '<svg width="18" height="18" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4">' + it.icon + '</svg>' +
        '<span class="rail-label">' + it.label + '</span>' +
      '</a>';
    }).join('') +
    '</div>';
  document.body.classList.add('has-rail');
  document.body.appendChild(rail);
})();
