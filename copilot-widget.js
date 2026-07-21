/* Trakolo Copilot — floating ChatGPT-style assistant.
   Include after setting window.COPILOT = {surface, title, greeting, prompts, answers}.
   Surfaces: 'agent' (desk.html), 'admin' (admin.html), 'ssp' (contact.html / track.html). */
(function(){
  const cfg = window.COPILOT;
  if(!cfg) return;
  try{ if(localStorage.getItem('trakolo-feature-copilot') === 'off') return; }catch(e){}

  const root = document.createElement('div');
  root.innerHTML = `
    <button class="copilot-bubble" id="copilot-bubble" title="Ask Trakolo Copilot">✦<span class="copilot-bubble-label">Copilot</span></button>
    <div class="copilot-panel" id="copilot-panel">
      <div class="copilot-head">
        <div class="copilot-head-icon">✦</div>
        <div><div class="copilot-head-title">${cfg.title}</div><div class="copilot-head-sub">Trakolo Copilot · always learning your workspace</div></div>
        <button class="copilot-close" id="copilot-close">✕</button>
      </div>
      <div class="copilot-body" id="copilot-body">
        <div class="copilot-msg bot">${cfg.greeting}</div>
        <div class="copilot-prompts" id="copilot-prompts">
          ${cfg.prompts.map((p,i) => `<button class="copilot-chip" data-i="${i}">${p.label}</button>`).join('')}
        </div>
      </div>
      <div class="copilot-inputrow">
        <input type="text" id="copilot-input" placeholder="Ask anything about Trakolo…" autocomplete="off">
        <button class="copilot-send" id="copilot-send">→</button>
      </div>
    </div>`;
  document.body.appendChild(root);

  const bubble = document.getElementById('copilot-bubble');
  const panel = document.getElementById('copilot-panel');
  const body = document.getElementById('copilot-body');
  const input = document.getElementById('copilot-input');

  bubble.addEventListener('click', () => { panel.classList.toggle('open'); if(panel.classList.contains('open')) input.focus(); });
  document.getElementById('copilot-close').addEventListener('click', () => panel.classList.remove('open'));

  function addMsg(cls, html){
    const el = document.createElement('div');
    el.className = 'copilot-msg ' + cls;
    el.innerHTML = html;
    body.appendChild(el);
    body.scrollTop = body.scrollHeight;
    return el;
  }

  function respondTo(text){
    const q = text.toLowerCase();
    let hit = cfg.answers.find(a => a.keywords.some(k => q.includes(k)));
    if(!hit) hit = cfg.fallback;
    const thinking = addMsg('bot thinking', '<span></span><span></span><span></span>');
    setTimeout(() => {
      thinking.classList.remove('thinking');
      thinking.innerHTML = hit.text + (hit.link ? `<a class="copilot-link" href="${hit.link.href}">${hit.link.label} →</a>` : '');
    }, 550 + Math.random()*350);
  }

  function ask(text){
    if(!text.trim()) return;
    addMsg('user', text.replace(/</g,'&lt;'));
    input.value = '';
    respondTo(text);
  }

  document.getElementById('copilot-prompts').addEventListener('click', e => {
    const btn = e.target.closest('.copilot-chip');
    if(!btn) return;
    ask(cfg.prompts[+btn.dataset.i].label);
  });
  document.getElementById('copilot-send').addEventListener('click', () => ask(input.value));
  input.addEventListener('keydown', e => { if(e.key === 'Enter') ask(input.value); });
})();
