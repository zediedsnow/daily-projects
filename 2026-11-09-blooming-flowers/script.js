(() => {
  const stalks = document.getElementById('stalks');
  const bouquet = document.getElementById('bouquet');
  const stars = document.getElementById('stars');
  const particles = document.getElementById('particles');
  const scene = document.getElementById('scene');
  const hint = document.getElementById('hint');

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

  // Floating light particles
  const pf = document.createDocumentFragment();
  for (let i = 0; i < (small ? 18 : 30); i++) {
    const p = document.createElement('i');
    p.className = 'p';
    p.style.cssText = `--x:${rand(0,100)}%;--sz:${rand(4,9)}px;--hue:${[330,45,150,280][i%4]};--t:${rand(7,13)}s;--d:${rand(2,12)}s;--dx:${rand(-40,40)}px`;
    pf.appendChild(p);
  }
  particles.appendChild(pf);

  // Bouquet slots, from the centre outwards, so it grows bigger as flowers are added.
  // [angle deg, stem length u, head size u]
  const layers = [
    { h: 68, s: 22, z: 1, a: [0] },
    { h: 61, s: 20, z: 2, a: [-10, 10, -20, 20] },
    { h: 53, s: 18, z: 3, a: [-5, 5, -28, 28, -16, 16] },
    { h: 45, s: 16, z: 4, a: [-12, 12, -32, 32, -22, 22, 0] },
  ];
  const slots = [];
  layers.forEach(L => L.a.forEach(a => slots.push({ ...L, ang: a })));
  const MAX = slots.length;

  // pinks, reds, peach, lilac, white-ish, yellow
  const palette = [[335, '66%'], [350, '62%'], [20, '68%'], [285, '70%'], [320, '82%'], [45, '64%'], [5, '60%'], [300, '66%']];

  let count = 0, timer = null, lastTap = 0;

  function addFlower(delay = 0) {
    if (count >= MAX) return;
    const s = slots[count];
    const [hue, lt] = palette[count % palette.length];
    const petals = [5, 6, 8][Math.floor(Math.random() * 3)];
    const inner = Math.random() < .55;

    const stalk = document.createElement('div');
    stalk.className = 'stalk';
    stalk.style.cssText = `--rot:${s.ang + rand(-2, 2)}deg;z-index:${s.z}`;

    const f = document.createElement('div');
    f.className = 'flower';
    f.style.cssText = `--h:calc(var(--u) * ${s.h + rand(-2, 2)});--s:calc(var(--u) * ${s.s + rand(-1, 1)});--hue:${hue + rand(-6, 6)};--lt:${lt};--d:${delay}s;--sw:${rand(1, 2.5)}deg;--sway:${rand(4, 7)}s;--spin:${rand(0, 60)}deg`;

    let html = `<div class="stem"></div>
      <div class="leaf ${Math.random() < .5 ? 'l' : 'r'}" style="--ly:${rand(48, 60)}%"></div>
      <div class="head"><div class="halo"></div>`;
    for (let p = 0; p < petals; p++)
      html += `<div class="petal" style="--a:${(360 / petals) * p}deg;--pd:${p * 0.04}s"></div>`;
    if (inner)
      for (let p = 0; p < 5; p++)
        html += `<div class="petal in" style="--a:${72 * p + 36}deg;--pd:${0.3 + p * 0.04}s"></div>`;
    html += `<div class="center"></div></div>`;
    f.innerHTML = html;
    stalk.appendChild(f);
    stalks.appendChild(stalk);

    count++;
    bouquet.style.transform = `scale(${0.8 + 0.2 * (count / MAX)})`;
    if (count >= MAX) {
      clearInterval(timer);
      setTimeout(() => { hint.textContent = 'tap to make it bloom again'; }, 2500);
    }
  }

  function start() {
    clearInterval(timer);
    stalks.innerHTML = '';
    count = 0;
    hint.textContent = 'tap to add more flowers';
    bouquet.style.transform = 'scale(.8)';
    addFlower(0.2); addFlower(0.6); addFlower(0.9);
    timer = setInterval(() => addFlower(0), 1100);
  }

  scene.addEventListener('click', () => {
    if (count < MAX) {          // tap = more flowers, faster
      addFlower(0); addFlower(0.15);
      return;
    }
    const now = Date.now();
    if (now - lastTap < 1500) return;
    lastTap = now;
    start();                    // full bouquet: start blooming again
  });

  start();
})();
