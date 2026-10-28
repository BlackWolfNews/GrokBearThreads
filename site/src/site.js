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
