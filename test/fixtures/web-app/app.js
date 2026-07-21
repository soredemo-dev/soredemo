const eventLog = document.querySelector('#event-log');
const clickCount = document.querySelector('#click-count');
const projectPanel = document.querySelector('#project-form-panel');
const projectForm = document.querySelector('#project-form');
const projectName = document.querySelector('#project-name');
const result = document.querySelector('#result');
const analyticsStatus = document.querySelector('#analytics-status');
const navigationResult = document.querySelector('#navigation-result');

const stored = JSON.parse(sessionStorage.getItem('soredemo-fixture-state') || '{}');
const state = {
  clicks: Number(stored.clicks || 0),
  hoverObserved: Boolean(stored.hoverObserved),
  keyEvents: Number(stored.keyEvents || 0),
  typedValue: String(stored.typedValue || ''),
  projectCreated: Boolean(stored.projectCreated),
};
window.__soredemoFixture = state;

function persist() {
  sessionStorage.setItem('soredemo-fixture-state', JSON.stringify(state));
}

function recordEvent(event) {
  const item = document.createElement('li');
  item.textContent = `${event.type}:${event.target.id || event.target.textContent.trim()}`;
  eventLog.append(item);
}

for (const eventName of ['pointerdown', 'pointerup', 'click']) {
  document.addEventListener(eventName, recordEvent);
}

document.addEventListener('click', () => {
  state.clicks += 1;
  clickCount.textContent = `Clicks: ${state.clicks}`;
  persist();
});

document.querySelector('#hover-target').addEventListener('pointerenter', () => {
  state.hoverObserved = true;
  persist();
});

projectName.addEventListener('keydown', () => {
  state.keyEvents += 1;
  persist();
});
projectName.addEventListener('input', () => {
  state.typedValue = projectName.value;
  persist();
});

document.querySelector('#preview-analytics').addEventListener('click', () => {
  analyticsStatus.textContent = 'Analytics preview ready.';
});

for (const target of document.querySelectorAll('[data-testid][data-application-clicks]')) {
  target.addEventListener('click', () => {
    const nextCount = Number(target.dataset.applicationClicks) + 1;
    target.dataset.applicationClicks = String(nextCount);
  });
}

document.querySelector('#new-project').addEventListener('click', () => {
  projectPanel.hidden = false;
});

projectForm.addEventListener('submit', (event) => {
  event.preventDefault();
  const name = projectName.value.trim();
  result.replaceChildren();
  const heading = document.createElement('h2');
  heading.textContent = name || 'Untitled project';
  result.append(heading);
  result.hidden = false;
  state.projectCreated = name === 'Soredemo';
  persist();
});

clickCount.textContent = `Clicks: ${state.clicks}`;
if (location.pathname === '/result' && state.hoverObserved && state.projectCreated) {
  navigationResult.hidden = false;
}
