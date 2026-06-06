// Slide-deck behavior: progress bar, generated nav dots, active-slide tracking,
// and arrow/space/Home/End keyboard navigation. Operates on the pre-rendered
// DOM (static Jaspr output); the Flutter embed hydrates independently.
(function () {
  function init() {
    var deck = document.getElementById('deck');
    var dots = document.getElementById('dots');
    var progress = document.getElementById('progress');
    if (!deck || !dots || !progress) return;
    var sections = Array.prototype.slice.call(document.querySelectorAll('section'));
    if (!sections.length) return;

    sections.forEach(function (s, i) {
      var a = document.createElement('a');
      a.href = '#';
      a.innerHTML = '<span>' + (s.dataset.title || ('Slide ' + (i + 1))) + '</span>';
      a.addEventListener('click', function (e) {
        e.preventDefault();
        s.scrollIntoView({ behavior: 'smooth' });
      });
      dots.appendChild(a);
    });
    var dotEls = Array.prototype.slice.call(dots.children);

    function onScroll() {
      var top = deck.scrollTop, h = deck.scrollHeight - deck.clientHeight;
      progress.style.width = (h > 0 ? (top / h) * 100 : 0) + '%';
      var active = 0, mid = top + deck.clientHeight / 2;
      sections.forEach(function (s, i) { if (s.offsetTop <= mid) active = i; });
      dotEls.forEach(function (d, i) { d.classList.toggle('active', i === active); });
    }
    deck.addEventListener('scroll', onScroll, { passive: true });
    onScroll();

    // The Flutter embeds size to their host box and scale inside Flutter
    // (FittedBox), so no host CSS transform is needed here.

    function current() {
      var mid = deck.scrollTop + deck.clientHeight / 2, a = 0;
      sections.forEach(function (s, i) { if (s.offsetTop <= mid) a = i; });
      return a;
    }
    window.addEventListener('keydown', function (e) {
      if (['ArrowDown', 'PageDown', ' '].indexOf(e.key) >= 0) {
        e.preventDefault();
        sections[Math.min(current() + 1, sections.length - 1)].scrollIntoView({ behavior: 'smooth' });
      } else if (['ArrowUp', 'PageUp'].indexOf(e.key) >= 0) {
        e.preventDefault();
        sections[Math.max(current() - 1, 0)].scrollIntoView({ behavior: 'smooth' });
      } else if (e.key === 'Home') {
        e.preventDefault();
        sections[0].scrollIntoView({ behavior: 'smooth' });
      } else if (e.key === 'End') {
        e.preventDefault();
        sections[sections.length - 1].scrollIntoView({ behavior: 'smooth' });
      }
    });
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
