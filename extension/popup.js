"use strict";

const titleEl = document.getElementById("video-title");
const urlEl = document.getElementById("video-url");
const notYt = document.getElementById("not-youtube");
const pageInfo = document.getElementById("page-info");
const btn = document.getElementById("bookmark-btn");
const statusEl = document.getElementById("status");
const recentList = document.getElementById("recent-list");

let currentTab = null;

function isYouTubeVideo(url) {
  try {
    const u = new URL(url);
    return (
      (u.hostname === "www.youtube.com" || u.hostname === "youtube.com") &&
      u.pathname === "/watch" &&
      u.searchParams.has("v")
    );
  } catch {
    return false;
  }
}

function setStatus(msg, type = "") {
  statusEl.textContent = msg;
  statusEl.className = type;
}

function renderRecent(items) {
  if (!items || items.length === 0) {
    recentList.innerHTML = '<li style="color:#555">None yet</li>';
    return;
  }
  recentList.innerHTML = items
    .slice(-5)
    .reverse()
    .map(
      (item) =>
        `<li title="${escapeHtml(item.url)}">${escapeHtml(item.title || item.url)}</li>`
    )
    .join("");
}

function escapeHtml(str) {
  return String(str)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

browser.tabs.query({ active: true, currentWindow: true }).then(([tab]) => {
  currentTab = tab;
  if (isYouTubeVideo(tab.url)) {
    pageInfo.style.display = "";
    notYt.style.display = "none";
    titleEl.textContent = tab.title || tab.url;
    urlEl.textContent = tab.url;
    btn.disabled = false;
  } else {
    pageInfo.style.display = "none";
    notYt.style.display = "";
    btn.disabled = true;
  }
});

browser.storage.local.get("bookmarks").then(({ bookmarks }) => {
  renderRecent(bookmarks || []);
});

btn.addEventListener("click", () => {
  if (!currentTab || !isYouTubeVideo(currentTab.url)) return;

  btn.disabled = true;
  setStatus("Saving...");

  const entry = {
    url: currentTab.url,
    title: currentTab.title || "",
    timestamp: new Date().toLocaleString("sv"),
  };

  browser.runtime
    .sendMessage({ action: "bookmark", entry })
    .then((response) => {
      if (response && response.ok) {
        setStatus("Bookmarked!", "success");
        return browser.storage.local.get("bookmarks").then(({ bookmarks }) => {
          const list = bookmarks || [];
          list.push(entry);
          return browser.storage.local.set({ bookmarks: list }).then(() => {
            renderRecent(list);
          });
        });
      } else {
        const msg = (response && response.error) || "Unknown error";
        setStatus("Error: " + msg, "error");
        btn.disabled = false;
      }
    })
    .catch((err) => {
      setStatus("Failed to contact native host. Is it installed?", "error");
      console.error(err);
      btn.disabled = false;
    });
});
