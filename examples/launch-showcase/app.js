const projectPanel = document.querySelector('#project-panel');
const projectForm = document.querySelector('#project-form');
const projectName = document.querySelector('#project-name');
const created = document.querySelector('#created');
const createdName = document.querySelector('#created-name');
const completion = document.querySelector('#completion');
const explore = document.querySelector('[data-testid="explore-automation"]');

const stored = JSON.parse(sessionStorage.getItem('northstar-showcase') || '{}');
const state = {
  hoverObserved: Boolean(stored.hoverObserved),
  keyEvents: Number(stored.keyEvents || 0),
  projectName: String(stored.projectName || ''),
  projectCreated: Boolean(stored.projectCreated),
};
window.__northstarShowcase = state;

function persist() {
  sessionStorage.setItem('northstar-showcase', JSON.stringify(state));
}

explore.addEventListener('pointerenter', () => {
  state.hoverObserved = true;
  explore.querySelector('.spark').textContent = '✧';
  persist();
});

document.querySelector('[data-testid="new-project"]').addEventListener('click', () => {
  projectPanel.hidden = false;
});

projectName.addEventListener('keydown', () => {
  state.keyEvents += 1;
  persist();
});

projectName.addEventListener('input', () => {
  state.projectName = projectName.value;
  persist();
});

projectForm.addEventListener('submit', (event) => {
  event.preventDefault();
  const name = projectName.value.trim() || 'Untitled project';
  createdName.textContent = name;
  created.hidden = false;
  state.projectName = name;
  state.projectCreated = true;
  persist();
});

if (location.pathname === '/complete') {
  document.body.classList.add('result-page');
  if (state.projectCreated && state.hoverObserved && state.keyEvents > 0) {
    completion.hidden = false;
  }
}
