chrome.tabs.query({ active: true, currentWindow: true }).then(async ([tab]) => {
  const { pages } = await chrome.storage.local.get({ pages: 0 });
  document.getElementById('out').textContent = (tab ? tab.title + ' — ' + tab.url : 'no tab') + ' · ' + pages + ' pages seen';
  document.getElementById('go').onclick = () => chrome.scripting.executeScript({ target: { tabId: tab.id }, func: () => { const t = document.getElementById('spine-sample'); t.textContent = 'The popup reached this page'; t.style.background = '#b3446c'; } }).then(() => { document.getElementById('out').textContent = 'Done'; }, (e) => { document.getElementById('out').textContent = String(e); });
});
