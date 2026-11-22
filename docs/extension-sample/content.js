chrome.runtime.sendMessage({ kind: 'page', url: location.href }).then((answer) => {
  const tag = document.createElement('div');
  tag.id = 'spine-sample';
  tag.textContent = 'Chrome extension running · page ' + answer.pages + ' · tab ' + answer.tab;
  tag.style.cssText = 'position:fixed;left:0;right:0;bottom:0;z-index:2147483647;padding:14px;font:600 15px -apple-system;color:#fff;background:#2f7d6d;text-align:center';
  document.documentElement.appendChild(tag);
});
