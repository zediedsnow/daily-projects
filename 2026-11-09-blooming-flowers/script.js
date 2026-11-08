(() => {
  const garden = document.getElementById('garden');
  const stars = document.getElementById('stars');
  const particles = document.getElementById('particles');
  const scene = document.getElementById('scene');

  const small = Math.min(innerWidth, innerHeight) < 500;
  const rand = (a, b) => a + Math.random() * (b - a);

  // Stars
  const sf = document.createDocumentFragment();
  for (let i = 0; i < (small ? 40 : 70); i++) {
    const s = document.createElement('i');
    s.className = 'star';
    s.style.cssText = `left:${rand(0,100)}%;top:${rand(0,60)}%;--t:${rand(2,5)}s;--d:${rand(0,4)}s`;
    sf.appendChild(s);
  }
  stars.appendChild(sf);

  // Flowers: [x%, height(vh), size(vmin), hue, delay(s)]
  const hues = [330, 350, 45, 280, 15, 200, 320];
  function buildFlowers() {
    garden.innerHTML = '';
    const count = innerWidth < 500 ? 7 : 11;
    const frag = document.createDocumentFragment();
    for (let i = 0; i < count; i++) {
      const x = ((i + 0.5) / count) * 100 + rand(-3, 3);
      const middle = 1 - Math.abs(x - 50) / 55;          // taller in the middle
      const h = rand(26, 34) + middle * 22;               // vh
      const size = rand(15, 20) + middle * 6;             // vmin
      const hue = hues[i % hues.length] + rand(-8, 8);
      const delay = rand(0, 1.6) + Math.abs(x - 50) / 60;
      const petals = Math.random() < .5 ? 6 : 8;

      const f = document.createElement('div');
      f.className = 'flower';
      f.style.cssText = `--x:${x}%;--h:${h}vh;--s:${size}vmin;--hue:${hue};--d:${delay}s;--sw:${rand(1.5,3.5)}deg;--sway:${rand(4,7)}s`;

      let html = `<div class="stem"></div>
        <div class="leaf l" style="--ly:${rand(18,32)}%"></div>
        <div class="leaf r" style="--ly:${rand(38,52)}%"></div>
        <div class="head"><div class="halo"></div>`;
      for (let p = 0; p < petals; p++) {
        html += `<div class="petal" style="--a:${(360 / petals) * p}deg;--pd:${p * 0.05}s"></div>`;
      }
      html += `<div class="center"></div></div>`;
      f.innerHTML = html;
      frag.appendChild(f);
    }
    garden.appendChild(frag);
  }

  // Floating light particles
  const pf = document.createDocumentFragment();
  for (let i = 0; i < (small ? 18 : 30); i++) {
    const p = document.createElement('i');
    p.className = 'p';
    p.style.cssText = `--x:${rand(0,100)}%;--sz:${rand(4,9)}px;--hue:${[330,45,150,280][i%4]};--t:${rand(7,13)}s;--d:${rand(2,12)}s;--dx:${rand(-40,40)}px`;
    pf.appendChild(p);
  }
  particles.appendChild(pf);

  buildFlowers();

  // Tap to bloom again
  let last = 0;
  scene.addEventListener('click', () => {
    const now = Date.now();
    if (now - last < 1500) return;
    last = now;
    scene.classList.add('replay');
    buildFlowers();
    void scene.offsetWidth;          // restart animations
    scene.classList.remove('replay');
    const msg = scene.querySelector('.message');
    msg.style.animationDelay = '3.5s';
  });

  // Rebuild on orientation change so layout fits
  let t;
  let w = innerWidth;
  addEventListener('resize', () => {
    if (innerWidth === w) return;   // ignore mobile address-bar resizes
    w = innerWidth;
    clearTimeout(t); t = setTimeout(buildFlowers, 300);
  });
})();
