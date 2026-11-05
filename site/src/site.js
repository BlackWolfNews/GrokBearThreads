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


// The hero's slideshow: a new window every few seconds, the dots to jump about, and it holds
// still while the pointer or focus is on it. With reduced motion it doesn't move on by itself.
const showcase = document.querySelector(".showcase");
if (showcase) {
  const SLIDE_MS = 6000;
  showcase.style.setProperty("--slide-ms", `${SLIDE_MS}ms`);
  const slides = [...showcase.querySelectorAll(".slide")];
  const copies = [...showcase.querySelectorAll(".slide-copy")];
  const dots = [...showcase.querySelectorAll(".dot")];
  const still = matchMedia("(prefers-reduced-motion: reduce)").matches;
  if (still) showcase.classList.add("still");
  let current = 0;
  let timer = 0;
  const show = (index) => {
    current = (index + slides.length) % slides.length;
    for (const [i, list] of [slides, copies, dots].entries()) {
      list.forEach((el, j) => {
        el.classList.toggle("on", j === current);
        // aria-hidden="" doesn't hide anything, so set "true" or take it off.
        const [name, on] = i < 2 ? ["aria-hidden", j !== current] : ["aria-current", j === current];
        if (on) el.setAttribute(name, "true");
        else el.removeAttribute(name);
      });
    }
    // The next window's picture starts loading now, so it's ready when its turn comes.
    const next = slides[(current + 1) % slides.length];
    if (next.loading === "lazy") next.loading = "eager";
    // Restart the dot's fill: drop the class, force a layout, put it back.
    const dot = dots[current];
    dot.classList.remove("on");
    void dot.offsetWidth;
    dot.classList.add("on");
    schedule();
  };
  const schedule = () => {
    clearTimeout(timer);
    if (!still && !showcase.classList.contains("paused")) timer = setTimeout(() => show(current + 1), SLIDE_MS);
  };
  dots.forEach((dot, i) => dot.addEventListener("click", () => show(i)));
  const pause = (on) => {
    showcase.classList.toggle("paused", on);
    if (!on) show(current);
    else clearTimeout(timer);
  };
  showcase.addEventListener("pointerenter", () => pause(true));
  showcase.addEventListener("pointerleave", () => pause(false));
  showcase.addEventListener("focusin", () => pause(true));
  showcase.addEventListener("focusout", () => pause(false));
  // Swipe on a phone.
  let startX = null;
  showcase.addEventListener("touchstart", (e) => { startX = e.touches[0].clientX; }, { passive: true });
  showcase.addEventListener("touchend", (e) => {
    if (startX === null) return;
    const dx = e.changedTouches[0].clientX - startX;
    startX = null;
    if (Math.abs(dx) > 40) show(current + (dx < 0 ? 1 : -1));
  });
  document.addEventListener("visibilitychange", () => (document.hidden ? clearTimeout(timer) : schedule()));
  schedule();
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
