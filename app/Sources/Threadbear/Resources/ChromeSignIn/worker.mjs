import { bridgeRequest, redirectRule } from './bridge.mjs';

async function remove(tabId) {
  await chrome.declarativeNetRequest.updateSessionRules({ removeRuleIds: [tabId] });
  await chrome.alarms.clear('sign-in-' + tabId);
}

// activeTab is granted by this toolbar click, only on the local sign-in
// page Mike has chosen. No content script or cookie access is needed.
export async function startSignIn(tab) {
  const bridge = bridgeRequest(tab.url);
  const rule = redirectRule(tab.id, bridge);
  await chrome.declarativeNetRequest.updateSessionRules({ removeRuleIds: [tab.id], addRules: [rule] });
  await chrome.alarms.create('sign-in-' + tab.id, { delayInMinutes: 10 });
  await chrome.action.setBadgeText({ tabId: tab.id, text: '' });
  await chrome.tabs.update(tab.id, { url: bridge.loginURL });
}

chrome.action.onClicked.addListener(async (tab) => {
  try {
    await startSignIn(tab);
  } catch (error) {
    if (tab.id) {
      await remove(tab.id);
      await chrome.action.setBadgeText({ tabId: tab.id, text: '!' });
      await chrome.action.setTitle({ tabId: tab.id, title: error.message });
    }
  }
});

chrome.tabs.onRemoved.addListener((tabId) => { void remove(tabId); });
chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name.startsWith('sign-in-')) void remove(Number(alarm.name.slice(8)));
});
