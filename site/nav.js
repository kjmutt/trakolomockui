(function(){
  var toggle = document.querySelector('.nav-toggle');
  var links = document.querySelector('.nav-links');
  if(!toggle || !links) return;
  function close(){ links.classList.remove('open'); toggle.textContent = '☰'; toggle.setAttribute('aria-expanded','false'); }
  function open(){ links.classList.add('open'); toggle.textContent = '✕'; toggle.setAttribute('aria-expanded','true'); }
  toggle.addEventListener('click', function(){
    links.classList.contains('open') ? close() : open();
  });
  links.querySelectorAll('a').forEach(function(a){ a.addEventListener('click', close); });
  document.addEventListener('keydown', function(e){ if(e.key === 'Escape') close(); });
})();
