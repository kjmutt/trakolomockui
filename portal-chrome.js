/* Shared portal chrome: notification bell + logged-in profile menu.
   Injected into the Self-Service Portal shell (contact, track, chat, my HR info).
   Reuses the same chrome-* components as the internal app shell (app-chrome.js). */
(function(){
  var container = document.querySelector('.portal-header .portal-links') || document.querySelector('.topbar .top-right');
  if(!container) return;

  var NOTIFS = [
    {icon:'🎫', cls:'info', title:'TS-4790 · Your VPN ticket was updated', sub:'Raj K. reproduced the issue and is working with networking', href:'track.html', time:'25m'},
    {icon:'✓', cls:'ok', title:'Leave request approved', sub:'Annual leave · Jul 28–29 · approved by Nadia P.', href:'portal-hr.html', time:'3h'},
    {icon:'💰', cls:'ok', title:'New payslip available', sub:'Jun 2026 · net pay $6,312.40', href:'portal-hr.html', time:'1d'},
    {icon:'📣', cls:'warn', title:'Open enrollment for benefits closes Aug 1', sub:'HR communication · update your elections before the deadline', href:'portal-hr.html', time:'2d'}
  ];

  var name = 'J. Okoye';
  var initials = 'JO';

  var isPortalLinks = container.classList.contains('portal-links');
  var ctaSelector = isPortalLinks ? 'a.cta' : 'a';
  var existingCta = container.querySelector(ctaSelector);
  var signOutHref = existingCta ? existingCta.getAttribute('href') : 'login.html';

  var chromeHtml =
    '<button class="chrome-btn chrome-bell" id="portal-chrome-bell" title="Notifications">🔔<span class="chrome-badge" id="portal-chrome-badge">' + NOTIFS.length + '</span></button>' +
    '<button class="avatar" id="portal-chrome-avatar" style="border:none;cursor:pointer;width:34px;height:34px;font-size:12.5px;" title="Account">' + initials + '</button>';

  if(isPortalLinks){
    if(existingCta) existingCta.remove();
    container.insertAdjacentHTML('beforeend', chromeHtml);
  } else {
    container.innerHTML = chromeHtml;
  }

  var root = document.createElement('div');
  root.innerHTML =
    '<div class="chrome-scrim" id="portal-chrome-scrim"></div>' +
    '<div class="chrome-pop" id="portal-chrome-notifs">' +
      '<div class="chrome-pop-head"><span>Notifications</span><button class="btn sm" id="portal-chrome-readall">Mark all read</button></div>' +
      NOTIFS.map(function(n){ return '<a class="chrome-notif" href="' + n.href + '"><span class="chrome-nicon ' + n.cls + '">' + n.icon + '</span><span><span class="cn-title">' + n.title + '</span><span class="cn-sub">' + n.sub + '</span></span><span class="cn-time">' + n.time + '</span></a>'; }).join('') +
    '</div>' +
    '<div class="chrome-pop" id="portal-chrome-menu">' +
      '<div class="chrome-menu-id"><span class="avatar" style="width:34px;height:34px;">' + initials + '</span><span><b>' + name + '</b><span class="cn-sub">Senior Product Analyst · Engineering</span></span></div>' +
      '<a class="chrome-menu-item" href="portal-home.html">🏠 Home</a>' +
      '<a class="chrome-menu-item" href="portal-workcentre.html">🗂 Work Centre</a>' +
      '<a class="chrome-menu-item" href="portal-assets.html">💻 My Assets</a>' +
      '<a class="chrome-menu-item" href="portal-hr.html">🪪 My HR info</a>' +
      '<a class="chrome-menu-item" href="track.html">🎫 Track a ticket</a>' +
      '<a class="chrome-menu-item" href="desk-log-ticket.html">✎ Log a ticket</a>' +
      '<a class="chrome-menu-item" href="' + signOutHref + '">→ Sign out</a>' +
    '</div>';
  document.body.appendChild(root);

  var scrim = document.getElementById('portal-chrome-scrim');
  var notifs = document.getElementById('portal-chrome-notifs');
  var menu = document.getElementById('portal-chrome-menu');

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

  document.getElementById('portal-chrome-bell').addEventListener('click', function(e){ openPop(notifs, e.currentTarget); });
  document.getElementById('portal-chrome-avatar').addEventListener('click', function(e){ openPop(menu, e.currentTarget); });
  scrim.addEventListener('click', closeAll);
  document.getElementById('portal-chrome-readall').addEventListener('click', function(){
    document.getElementById('portal-chrome-badge').style.display = 'none';
    notifs.querySelectorAll('.chrome-notif').forEach(function(n){ n.style.opacity = .55; });
  });
  document.addEventListener('keydown', function(e){ if(e.key === 'Escape') closeAll(); });
})();
