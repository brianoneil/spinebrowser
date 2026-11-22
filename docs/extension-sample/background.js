chrome.runtime.onInstalled.addListener(() => chrome.storage.local.set({ pages: 0 }));
chrome.runtime.onMessage.addListener((message, sender, reply) => {
  if (message.kind !== 'page') return;
  chrome.storage.local.get({ pages: 0 }).then(({ pages }) => {
    pages += 1;
    chrome.storage.local.set({ pages });
    chrome.action.setBadgeText({ text: String(pages) });
    reply({ pages, tab: sender.tab && sender.tab.id });
  });
  return true;
});
