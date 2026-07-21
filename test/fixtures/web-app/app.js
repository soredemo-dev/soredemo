const eventLog = document.querySelector('#event-log');
const clickCount = document.querySelector('#click-count');
const projectPanel = document.querySelector('#project-form-panel');
const projectForm = document.querySelector('#project-form');
const projectName = document.querySelector('#project-name');
const result = document.querySelector('#result');
const analyticsStatus = document.querySelector('#analytics-status');

let clicks = 0;

function recordEvent(event) {
  const item = document.createElement('li');
  item.textContent = `${event.type}:${event.target.id || event.target.textContent.trim()}`;
  eventLog.append(item);
}

for (const eventName of ['pointerdown', 'pointerup', 'click']) {
  document.addEventListener(eventName, recordEvent);
}

document.addEventListener('click', () => {
  clicks += 1;
  clickCount.textContent = `Clicks: ${clicks}`;
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
});
