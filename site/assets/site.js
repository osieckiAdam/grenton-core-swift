// Install tabs: one panel visible at a time; the choice is remembered.
document.querySelectorAll("[data-tabs]").forEach((group) => {
  const buttons = [...group.querySelectorAll('[role="tab"]')];
  const show = (id) => {
    buttons.forEach((b) => {
      const selected = b.dataset.panel === id;
      b.setAttribute("aria-selected", selected);
      document.getElementById(b.dataset.panel).hidden = !selected;
    });
    try { localStorage.setItem("grenton-install-tab", id); } catch (e) {}
  };
  buttons.forEach((b) => b.addEventListener("click", () => show(b.dataset.panel)));
  let saved = null;
  try { saved = localStorage.getItem("grenton-install-tab"); } catch (e) {}
  show(buttons.some((b) => b.dataset.panel === saved) ? saved : buttons[0].dataset.panel);
});
