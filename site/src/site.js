// The site's bits of motion (Elaya's landing-page-design skill, B7 and B11):
// the phone menu, the scroll reveals and the tagline's word by word reveal. Everything here is
// an extra: without JavaScript the menu button stays hidden behind the desktop links on wide
// screens, every section is visible and the tagline is simply all lit.
const root = document.documentElement;
root.classList.add("js");

// The menu button opens a full height panel (styles.css does the movement).
const toggle = document.querySelector(".menu-toggle");
function setMenu(open) {
  root.classList.toggle("menu-open", open);
  toggle?.setAttribute("aria-expanded", String(open));
  toggle?.setAttribute("aria-label", open ? "Close the menu" : "Open the menu");
}
toggle?.addEventListener("click", () => setMenu(!root.classList.contains("menu-open")));
for (const link of document.querySelectorAll(".menu a")) link.addEventListener("click", () => setMenu(false));
// Widening past the phone layout (turning a big iPhone on its side, say) hides the menu and its
// button, so close it rather than leave it open where nobody can see it.
matchMedia("(max-width: 860px)").addEventListener("change", (event) => {
  if (!event.matches) setMenu(false);
});
document.addEventListener("keydown", (event) => {
  if (event.key === "Escape" && root.classList.contains("menu-open")) {
    setMenu(false);
    toggle?.focus();
  }
});

// Sections rise in once as they come into view, through IntersectionObserver rather than a
// scroll listener.
const reveals = document.querySelectorAll(".reveal");
if ("IntersectionObserver" in window) {
  const observer = new IntersectionObserver((entries) => {
    for (const entry of entries) {
      if (!entry.isIntersecting) continue;
      entry.target.classList.add("in");
      observer.unobserve(entry.target);
    }
  }, { rootMargin: "0px 0px -10% 0px", threshold: 0.08 });
  reveals.forEach((el) => observer.observe(el));
} else {
  reveals.forEach((el) => el.classList.add("in"));
}

// The tagline: each word is wrapped in a span, then lit in reading order as the paragraph
// scrolls up past a line 60% of the way down the screen. One scroll listener, throttled to a
// frame, and words stay lit once they're on.
const tagline = document.querySelector(".tagline");
if (tagline) {
  const words = [];
  for (const node of [...tagline.childNodes]) {
    if (node.nodeType !== Node.TEXT_NODE) continue;
    const parts = node.textContent.split(/(\s+)/);
    const frag = document.createDocumentFragment();
    for (const part of parts) {
      if (!part) continue;
      if (/^\s+$/.test(part)) { frag.append(part); continue; }
      const span = document.createElement("span");
      span.className = "word";
      span.textContent = part;
      words.push(span);
      frag.append(span);
    }
    node.replaceWith(frag);
  }
  let lit = 0;
  let queued = false;
  const update = () => {
    queued = false;
    const rect = tagline.getBoundingClientRect();
    const line = window.innerHeight * 0.6;
    // 0 when the top of the tagline reaches the line, 1 when its bottom does.
    const progress = Math.min(1, Math.max(0, (line - rect.top) / rect.height));
    const target = Math.ceil(progress * words.length);
    while (lit < target) words[lit++].classList.add("on");
    if (lit >= words.length) window.removeEventListener("scroll", onScroll);
  };
  const onScroll = () => {
    if (queued) return;
    queued = true;
    requestAnimationFrame(update);
  };
  window.addEventListener("scroll", onScroll, { passive: true });
  update();
}


// The hero's slideshow: each clip plays through, then the next one comes in. The features down
// the left jump about, and the playing one's bar fills for as long as its clip runs. It holds still while the pointer
// or focus is on it, and while it's off screen or the tab's hidden. With reduced motion nothing
// plays by itself: the features change which clip's first frame shows.
const showcase = document.querySelector(".showcase");
if (showcase) {
  const clips = [...showcase.querySelectorAll(".slide")];
  const features = [...showcase.querySelectorAll(".pick")];
  const still = matchMedia("(prefers-reduced-motion: reduce)").matches;
  if (still) showcase.classList.add("still");
  let current = 0;
  let inView = true;
  let fallback = 0;
  const held = () => still || showcase.classList.contains("paused") || !inView || document.hidden;
  // The bar fills over the clip's length, which is only known once its metadata has loaded.
  const fillFor = (clip) => showcase.style.setProperty("--slide-ms", `${Math.round((clip.duration || 8) * 1000)}ms`);
  const play = () => {
    const clip = clips[current];
    clearTimeout(fallback);
    showcase.classList.toggle("held", held());
    if (held()) return clip.pause();
    clip.play().catch(() => {
      // Autoplay refused (Low Power Mode on an iPhone, say): move on by the clock instead.
      fallback = setTimeout(() => show(current + 1), (clip.duration || 8) * 1000);
    });
  };
  const show = (index) => {
    clips[current].pause();
    current = (index + clips.length) % clips.length;
    for (const [i, list] of [clips, features].entries()) {
      list.forEach((el, j) => {
        el.classList.toggle("on", j === current);
        // aria-hidden="" doesn't hide anything, so set "true" or take it off.
        const [name, on] = i === 0 ? ["aria-hidden", j !== current] : ["aria-current", j === current];
        if (on) el.setAttribute(name, "true");
        else el.removeAttribute(name);
      });
    }
    const clip = clips[current];
    clip.preload = "auto";
    clip.currentTime = 0;
    // The next clip loads while this one plays, so it's ready when its turn comes.
    clips[(current + 1) % clips.length].preload = "auto";
    fillFor(clip);
    if (!clip.duration) clip.addEventListener("loadedmetadata", () => clip === clips[current] && restartFill(), { once: true });
    restartFill();
    play();
  };
  // Restarts the playing feature's bar: drop the class, force a layout, put it back.
  const restartFill = () => {
    fillFor(clips[current]);
    const feature = features[current];
    feature.classList.remove("on");
    void feature.offsetWidth;
    feature.classList.add("on");
  };
  clips.forEach((clip, i) => clip.addEventListener("ended", () => i === current && show(current + 1)));
  features.forEach((feature, i) => feature.addEventListener("click", () => show(i)));
  const hold = (on) => {
    showcase.classList.toggle("paused", on);
    play();
  };
  showcase.addEventListener("pointerenter", (e) => e.pointerType === "mouse" && hold(true));
  showcase.addEventListener("pointerleave", (e) => e.pointerType === "mouse" && hold(false));
  showcase.addEventListener("focusin", () => hold(true));
  showcase.addEventListener("focusout", () => hold(false));
  // Swipe on a phone.
  let startX = null;
  showcase.addEventListener("touchstart", (e) => { startX = e.touches[0].clientX; }, { passive: true });
  showcase.addEventListener("touchend", (e) => {
    if (startX === null) return;
    const dx = e.changedTouches[0].clientX - startX;
    startX = null;
    if (Math.abs(dx) > 40) show(current + (dx < 0 ? 1 : -1));
  });
  if ("IntersectionObserver" in window) {
    new IntersectionObserver(([entry]) => { inView = entry.isIntersecting; play(); }, { threshold: 0.25 }).observe(showcase);
  }
  document.addEventListener("visibilitychange", play);
  show(0);
}

// The install prompt: the button copies it, then says where it goes. If the clipboard says no
// (an old browser, or a page not served over https), the prompt gets selected for copying by hand.
for (const install of document.querySelectorAll(".install")) {
  const button = install.querySelector(".copy-prompt");
  const prompt = install.querySelector(".install-prompt");
  const next = install.querySelector(".install-next");
  const label = button.querySelector("span");
  let reset = 0;
  button.addEventListener("click", async () => {
    let copied = false;
    try {
      await navigator.clipboard.writeText(prompt.textContent);
      copied = true;
    } catch {
      getSelection().selectAllChildren(prompt);
    }
    button.classList.toggle("copied", copied);
    label.textContent = copied ? "Copied" : "Copy the install prompt";
    next.textContent = copied
      ? "Now paste it into Claude Code or Codex, and it'll take it from there."
      : "It's selected, so press ⌘C, then paste it into Claude Code or Codex.";
    next.classList.add("on");
    clearTimeout(reset);
    reset = setTimeout(() => {
      button.classList.remove("copied");
      label.textContent = "Copy the install prompt";
    }, 4000);
  });
}
